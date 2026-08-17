# Nova lldb data formatters (optional, for detailed debug display).
#
# Load in an lldb session with:  command script import ~/.nova/std/debug/nova_formatters.py
# The Nova VS Code launch config does this automatically via "initCommands".
#
# Primitives and strings already display natively without this script (strings are NUL-terminated).
# This adds richer display; extend the providers below as struct/container DITypes are wired.
#
# Nova heap objects carry an 8-byte ARC header before the payload pointer: refcount (i32 @ ptr-8) and
# length (i32 @ ptr-4). `string` is a pointer to `len` UTF-8 bytes (also NUL-terminated).

import lldb

# A formatter must NEVER raise -- an exception breaks the whole Variables panel for that frame (which is
# how "cannot debug handlers" happened: an uninitialised/garbage `string` slot in an async handler frame
# made ReadMemory(ptr-4) underflow addr_t and throw). Guard every pointer and wrap every provider so a
# bad value degrades to a placeholder, never a traceback.
_MIN_PTR = 0x1000
_MAX_PTR = 1 << 48


def _plausible(ptr):
    return isinstance(ptr, int) and _MIN_PTR <= ptr < _MAX_PTR


def _arc_len(process, ptr):
    if not _plausible(ptr):
        return None
    err = lldb.SBError()
    raw = process.ReadMemory(ptr - 4, 4, err)
    if err.Fail() or raw is None:
        return None
    n = int.from_bytes(raw, "little", signed=True)
    return n if 0 <= n <= 64 * 1024 * 1024 else None


def nova_string_summary(valobj, internal_dict):
    try:
        ptr = valobj.GetValueAsUnsigned(0)
        if ptr == 0:
            return '""'
        if not _plausible(ptr):
            return "<str?>"
        process = valobj.GetProcess()
        n = _arc_len(process, ptr)
        if n is None:
            return "<str?>"
        if n == 0:
            return '""'
        err = lldb.SBError()
        data = process.ReadMemory(ptr, n, err)
        if err.Fail() or data is None:
            return "<str?>"
        return '"' + data.decode("utf-8", "replace") + '"'
    except Exception:
        return "<str?>"


def _read_i32(process, addr):
    if not _plausible(addr):
        return None
    err = lldb.SBError()
    raw = process.ReadMemory(addr, 4, err)
    if err.Fail() or raw is None:
        return None
    return int.from_bytes(raw, "little", signed=True)


def _read_ptr(process, addr):
    if not _plausible(addr):
        return None
    err = lldb.SBError()
    raw = process.ReadMemory(addr, 8, err)
    if err.Fail() or raw is None:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _count(n):
    if n is None or n < 0 or n > 64 * 1024 * 1024:
        return None
    return "%d element%s" % (n, "" if n == 1 else "s")


# The compiler names a container DIType with its element type: List<i32>, List<string>, List<Point>,
# List<List<i32>>, ... Parse the OUTERMOST element out of "List<...>".
def _elem_name(type_name):
    if not type_name:
        return None
    i = type_name.find("<")
    if i < 0 or not type_name.endswith(">"):
        return None
    return type_name[i + 1:-1].strip()


# RawBuffer slots are UNIFORM 8 bytes (Nova's i64 value-slot model): a primitive occupies the low bytes
# of an 8-byte slot, a boxed element (string/class/nested container) is an 8-byte pointer. So the element
# STRIDE is always 8; only the DISPLAY type varies (an `int` reads 4 bytes at the slot start, etc.).
# (Inline value-struct elements, which have a real-width stride, are a known follow-up.)
_ELEM_SLOT = 8
_PRIM = {
    "i8": "signed char", "u8": "unsigned char", "bool": "bool",
    "i16": "short", "u16": "unsigned short",
    "i32": "int", "u32": "unsigned int", "int": "int", "uint": "unsigned int",
    "i64": "long long", "u64": "unsigned long long", "long": "long long",
    "f32": "float", "f64": "double", "float": "double",
}


def _elem_type(target, elem):
    # returns the SBType to display an element as (or None). Stride is always _ELEM_SLOT.
    if elem in _PRIM:
        t = target.FindFirstType(_PRIM[elem])
        return t if t and t.IsValid() else None
    # string / class / nested container: the slot holds an 8-byte pointer; render via the Nova type's own
    # typedef (its summary/synthetic then applies) -- e.g. `string`, a struct typedef, or `List<...>`.
    t = target.FindFirstType(elem)
    if not (t and t.IsValid()):
        t = target.FindFirstType("string")
    return t if t and t.IsValid() else None


# List<T> value struct { data ptr @0 -> RawBuffer, len @8, cap @12 }; RawBuffer { data @0 (element run),
# cap @8, len @12 }. The synthetic children read the run and present each element as its real type.
class ListChildren(object):
    def __init__(self, valobj, internal_dict):
        self.valobj = valobj
        self.count = 0
        self.base = 0
        self.etype = None

    def update(self):
        try:
            proc = self.valobj.GetProcess()
            lp = self.valobj.GetValueAsUnsigned(0)
            rb = _read_ptr(proc, lp)
            if not rb:
                self.count = 0
                return False
            self.count = max(0, _read_i32(proc, rb + 12) or 0)
            self.base = _read_ptr(proc, rb) or 0
            self.etype = _elem_type(self.valobj.GetTarget(), _elem_name(self.valobj.GetTypeName()) or "")
        except Exception:
            self.count = 0
        return False

    def num_children(self):
        return min(self.count, 4096)

    def get_child_index(self, name):
        try:
            return int(name.strip("[]"))
        except Exception:
            return -1

    def get_child_at_index(self, i):
        if i < 0 or i >= self.count or not self.etype or not _plausible(self.base):
            return None
        try:
            return self.valobj.CreateValueFromAddress("[%d]" % i, self.base + i * _ELEM_SLOT, self.etype)
        except Exception:
            return None


def nova_list_summary(valobj, internal_dict):
    try:
        ptr = valobj.GetValueAsUnsigned(0)
        if ptr == 0:
            return "(empty)"
        proc = valobj.GetProcess()
        rb = _read_ptr(proc, ptr)
        n = _read_i32(proc, rb + 12) if rb else _read_i32(proc, ptr + 8)
        return _count(n) or "List"
    except Exception:
        return "List"


# Map<K,V> class { cap @0, len @4, ... }; Set<T> class { map ptr @0 }. Count only (open-addressing makes
# element expansion non-trivial; a follow-up can walk the slot table).
def nova_map_summary(valobj, internal_dict):
    try:
        ptr = valobj.GetValueAsUnsigned(0)
        if ptr == 0:
            return "(empty)"
        return _count(_read_i32(valobj.GetProcess(), ptr + 4)) or "Map"
    except Exception:
        return "Map"


def nova_set_summary(valobj, internal_dict):
    try:
        ptr = valobj.GetValueAsUnsigned(0)
        if ptr == 0:
            return "(empty)"
        proc = valobj.GetProcess()
        mp = _read_ptr(proc, ptr)
        if not mp:
            return "Set"
        return _count(_read_i32(proc, mp + 4)) or "Set"
    except Exception:
        return "Set"


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("type summary add -F nova_formatters.nova_string_summary string")
    # Containers are named with their element type (List<i32>, List<string>, ...). Match by regex.
    # List gets a summary (element count) AND a synthetic child provider so it expands to [0],[1],... .
    # The summary also overrides the bogus char* rendering of the typedef's u8 pointee.
    debugger.HandleCommand('type summary add -x "^List<" -F nova_formatters.nova_list_summary')
    debugger.HandleCommand('type synthetic add -x "^List<" --python-class nova_formatters.ListChildren')
    debugger.HandleCommand('type summary add -x "^Map<" -F nova_formatters.nova_map_summary')
    debugger.HandleCommand('type summary add -x "^Set<" -F nova_formatters.nova_set_summary')
