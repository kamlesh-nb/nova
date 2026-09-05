# Kyte lldb data formatters (optional, for detailed debug display).
#
# Load in an lldb session with:  command script import ~/.kyte/std/debug/kyte_formatters.py
# The Kyte VS Code launch config does this automatically via "initCommands".
#
# Primitives and strings already display natively without this script (strings are NUL-terminated).
# This adds richer display; extend the providers below as struct/container DITypes are wired.
#
# Kyte heap objects carry an 8-byte ARC header before the payload pointer: refcount (i32 @ ptr-8) and
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


def _str_ptr(valobj):
    # `string` is a single-member struct { data: u8* } in DWARF (so lldb-dap shows the summary, not the
    # raw pointer address). The pointer lives in member 0; older/plain char* strings put it in the scalar
    # value. Try the scalar first, then fall back to child 0 ("data").
    ptr = valobj.GetValueAsUnsigned(0)
    if _plausible(ptr):
        return ptr
    try:
        ch = valobj.GetChildAtIndex(0)
        if ch and ch.IsValid():
            return ch.GetValueAsUnsigned(0)
    except Exception:
        pass
    return ptr


def kyte_string_summary(valobj, internal_dict):
    try:
        ptr = _str_ptr(valobj)
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


# `str.Str` is a BORROWED string view -- a struct { ptr: long, len: int } into a backing buffer, NOT
# NUL-terminated. Read exactly `len` bytes at `ptr` (no ARC header, unlike `string`). Shows the text of
# every borrowed ORM column so a struct's Str fields read as "..." instead of a raw pointer number.
def kyte_str_summary(valobj, internal_dict):
    try:
        proc = valobj.GetProcess()
        # Str is a single-member aggregate { obj: *StrData } (empty GetValue -> no address prefix). Read the
        # object pointer from the variable's storage, then ptr @0 and len @8 from the StrData payload.
        obj = _self_ptr(valobj)
        if obj == 0:
            return '""'
        if not _plausible(obj):
            return "<str?>"
        ptr = _read_ptr(proc, obj)
        n = _read_i32(proc, obj + 8)
        if ptr is None or n is None:
            return "<str?>"
        if n == 0:
            return '""'
        if not _plausible(ptr) or n < 0 or n > 64 * 1024 * 1024:
            return "<str?>"
        err = lldb.SBError()
        data = proc.ReadMemory(ptr, n, err)
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


# The underlying object pointer for a container/string variable. List/Map/Set are emitted as a single-
# member struct { ptr } (an aggregate, so lldb-dap shows the summary and not the raw address), so the
# scalar value is empty -- read the 8-byte pointer from the variable's own storage instead. Falls back to
# the scalar for the older pointer-typedef representation. Used by every provider/summary so the display
# works regardless of which representation the binary carries.
def _self_ptr(valobj):
    p = valobj.GetValueAsUnsigned(0)
    if _plausible(p):
        return p
    try:
        addr = valobj.GetLoadAddress()
        if addr != lldb.LLDB_INVALID_ADDRESS:
            q = _read_ptr(valobj.GetProcess(), addr)
            if q is not None:
                return q
    except Exception:
        pass
    return p


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


# RawBuffer slots are UNIFORM 8 bytes (Kyte's i64 value-slot model): a primitive occupies the low bytes
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
    # string / class / nested container: the slot holds an 8-byte pointer; render via the Kyte type's own
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
            lp = _self_ptr(self.valobj)
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


def kyte_list_summary(valobj, internal_dict):
    try:
        ptr = _self_ptr(valobj)
        if ptr == 0:
            return "(empty)"
        proc = valobj.GetProcess()
        rb = _read_ptr(proc, ptr)
        n = _read_i32(proc, rb + 12) if rb else _read_i32(proc, ptr + 8)
        return _count(n) or "List"
    except Exception:
        return "List"


# Map<K,V> class { cap: int @0, len: int @4, keys: RawBuffer @8, vals: RawBuffer @16, slots: ptr @24 }.
# `slots` is a byte-per-bucket state array: 0 EMPTY / 1 TOMBSTONE / 2 OCCUPIED. keys[i]/vals[i] live in
# the RawBuffer element runs (data @0), uniform 8-byte slots like List. Set<T> class { map: Map<T,_> @0 }.
_SLOT_OCCUPIED = 2


def kyte_map_summary(valobj, internal_dict):
    try:
        ptr = _self_ptr(valobj)
        if ptr == 0:
            return "(empty)"
        return _count(_read_i32(valobj.GetProcess(), ptr + 4)) or "Map"
    except Exception:
        return "Map"


def kyte_set_summary(valobj, internal_dict):
    try:
        ptr = _self_ptr(valobj)
        if ptr == 0:
            return "(empty)"
        proc = valobj.GetProcess()
        mp = _read_ptr(proc, ptr)
        if not mp:
            return "Set"
        return _count(_read_i32(proc, mp + 4)) or "Set"
    except Exception:
        return "Set"


# Split the two type params out of "Map<K, V>" at the TOP-LEVEL comma (so a nested "Map<int, List<int>>"
# keeps V intact). Returns (K, V) or (None, None).
def _two_params(type_name):
    inner = _elem_name(type_name)
    if inner is None:
        return (None, None)
    depth = 0
    for i, ch in enumerate(inner):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif ch == "," and depth == 0:
            return (inner[:i].strip(), inner[i + 1:].strip())
    return (None, None)


# Read the primitive integer key at an 8-byte slot, for naming a child "[<key>]" when K is int-like.
def _int_key_name(proc, addr, kelem):
    if kelem in ("i8", "u8", "i16", "u16", "i32", "u32", "int", "uint", "bool"):
        v = _read_i32(proc, addr)
        return None if v is None else "[%d]" % v
    if kelem in ("i64", "u64", "long"):
        v = _read_ptr(proc, addr)
        return None if v is None else "[%d]" % v
    if kelem == "string" or kelem == "Str":
        p = _read_ptr(proc, addr)
        if _plausible(p):
            n = _arc_len(proc, p) if kelem == "string" else None
            if n:
                err = lldb.SBError()
                data = proc.ReadMemory(p, n, err)
                if not err.Fail() and data is not None:
                    return '["%s"]' % data.decode("utf-8", "replace")
    return None


# Walk the open-addressing table and present each OCCUPIED bucket. For a Map, each child is the VALUE named
# by its key ("[1]", '["alpha"]', or "[i]" when the key is not a readable primitive). For a Set, each child
# is the KEY itself. Shared by MapChildren (want_values=True) and SetChildren (False).
class _TableChildren(object):
    def __init__(self, valobj, want_values):
        self.valobj = valobj
        self.want_values = want_values
        self.entries = []  # list of (name, address, sbtype)

    def _map_ptr(self):
        p = _self_ptr(self.valobj)
        if self.want_values:
            return p  # the Map object itself
        return _read_ptr(self.valobj.GetProcess(), p)  # Set { map @0 } -> inner Map

    def update(self):
        self.entries = []
        try:
            proc = self.valobj.GetProcess()
            target = self.valobj.GetTarget()
            mp = self._map_ptr()
            if not _plausible(mp):
                return False
            cap = _read_i32(proc, mp + 0) or 0
            slots = _read_ptr(proc, mp + 24)
            keys_run = _read_ptr(proc, _read_ptr(proc, mp + 8) or 0)
            vals_run = _read_ptr(proc, _read_ptr(proc, mp + 16) or 0)
            if self.want_values:
                k, v = _two_params(self.valobj.GetTypeName())  # Map<K, V>
            else:
                k, v = (_elem_name(self.valobj.GetTypeName()), None)  # Set<T> -- one param
            ktype = _elem_type(target, k or "")
            vtype = _elem_type(target, v or "")
            if not _plausible(slots) or not _plausible(keys_run):
                return False
            err = lldb.SBError()
            state = proc.ReadMemory(slots, min(cap, 1 << 20), err)
            if err.Fail() or state is None:
                return False
            idx = 0
            for i in range(min(cap, len(state))):
                if state[i] != _SLOT_OCCUPIED:
                    continue
                kaddr = keys_run + i * _ELEM_SLOT
                if self.want_values:
                    name = _int_key_name(proc, kaddr, k or "") or ("[%d]" % idx)
                    if _plausible(vals_run) and vtype:
                        self.entries.append((name, vals_run + i * _ELEM_SLOT, vtype))
                else:
                    if ktype:
                        self.entries.append(("[%d]" % idx, kaddr, ktype))
                idx += 1
        except Exception:
            self.entries = []
        return False

    def num_children(self):
        return min(len(self.entries), 4096)

    def get_child_index(self, name):
        for i, e in enumerate(self.entries):
            if e[0] == name:
                return i
        return -1

    def get_child_at_index(self, i):
        if i < 0 or i >= len(self.entries):
            return None
        name, addr, t = self.entries[i]
        try:
            return self.valobj.CreateValueFromAddress(name, addr, t)
        except Exception:
            return None


class MapChildren(_TableChildren):
    def __init__(self, valobj, internal_dict):
        _TableChildren.__init__(self, valobj, True)


class SetChildren(_TableChildren):
    def __init__(self, valobj, internal_dict):
        _TableChildren.__init__(self, valobj, False)


# How VS Code shows a clean `"kyte"` and not a raw address: lldb-dap builds the displayed value from
# SBValue::GetValue(), which for a POINTER type is the address -- so a pointer-typed string always showed
# `0x… "kyte"`, address first, whatever summary we registered. The compiler now emits `string` as a
# single-member STRUCT { data: u8* } (see diStringType); an aggregate has an empty GetValue(), so lldb-dap
# shows only the summary below. kyte_string_summary reads the pointer from member 0 via _str_ptr.
def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("type summary add -F kyte_formatters.ky_string_summary string")
    # str.Str -- borrowed string view { ptr, len }. Show its text; the ptr/len members stay expandable.
    debugger.HandleCommand("type summary add -F kyte_formatters.ky_str_summary Str")
    # Containers are named with their element type (List<i32>, List<string>, ...). Match by regex.
    # List gets a summary (element count) AND a synthetic child provider so it expands to [0],[1],... .
    # The summary also overrides the bogus char* rendering of the typedef's u8 pointee.
    debugger.HandleCommand('type summary add -x "^List<" -F kyte_formatters.ky_list_summary')
    debugger.HandleCommand('type synthetic add -x "^List<" --python-class kyte_formatters.ListChildren')
    # Map/Set get a count summary AND a synthetic that walks the open-addressing table: Map expands to each
    # value named by its key ("[1]", '["alpha"]'); Set expands to its members.
    debugger.HandleCommand('type summary add -x "^Map<" -F kyte_formatters.ky_map_summary')
    debugger.HandleCommand('type synthetic add -x "^Map<" --python-class kyte_formatters.MapChildren')
    debugger.HandleCommand('type summary add -x "^Set<" -F kyte_formatters.ky_set_summary')
    debugger.HandleCommand('type synthetic add -x "^Set<" --python-class kyte_formatters.SetChildren')
