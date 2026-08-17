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


def _arc_len(process, ptr):
    err = lldb.SBError()
    raw = process.ReadMemory(ptr - 4, 4, err)
    if err.Fail() or raw is None:
        return None
    n = int.from_bytes(raw, "little", signed=True)
    return n if 0 <= n <= 64 * 1024 * 1024 else None


def nova_string_summary(valobj, internal_dict):
    ptr = valobj.GetValueAsUnsigned(0)
    if ptr == 0:
        return '""'
    process = valobj.GetProcess()
    n = _arc_len(process, ptr)
    if n is None:
        return "<string len?>"
    if n == 0:
        return '""'
    err = lldb.SBError()
    data = process.ReadMemory(ptr, n, err)
    if err.Fail() or data is None:
        return "<string ?>"
    return '"' + data.decode("utf-8", "replace") + '"'


def _read_i32(process, addr):
    err = lldb.SBError()
    raw = process.ReadMemory(addr, 4, err)
    if err.Fail() or raw is None:
        return None
    return int.from_bytes(raw, "little", signed=True)


def _read_ptr(process, addr):
    err = lldb.SBError()
    raw = process.ReadMemory(addr, 8, err)
    if err.Fail() or raw is None:
        return None
    return int.from_bytes(raw, "little", signed=False)


def _count(n):
    if n is None or n < 0 or n > 64 * 1024 * 1024:
        return None
    return "%d element%s" % (n, "" if n == 1 else "s")


# List<T> is a value struct { data ptr @0 -> RawBuffer, len int @8, cap int @12 }. size() is
# data.count() = the shared RawBuffer's len @12, which is authoritative; read via the data pointer.
def nova_list_summary(valobj, internal_dict):
    ptr = valobj.GetValueAsUnsigned(0)
    if ptr == 0:
        return "(empty)"
    proc = valobj.GetProcess()
    rb = _read_ptr(proc, ptr)
    n = _read_i32(proc, rb + 12) if rb else _read_i32(proc, ptr + 8)
    return _count(n) or "List"


# Map<K,V> is a class { cap int @0, len int @4, ... }. len is the live count.
def nova_map_summary(valobj, internal_dict):
    ptr = valobj.GetValueAsUnsigned(0)
    if ptr == 0:
        return "(empty)"
    return _count(_read_i32(valobj.GetProcess(), ptr + 4)) or "Map"


# Set<T> is a class { map: Map<T,bool> ptr @0 }, so its count is that Map's len @4.
def nova_set_summary(valobj, internal_dict):
    ptr = valobj.GetValueAsUnsigned(0)
    if ptr == 0:
        return "(empty)"
    proc = valobj.GetProcess()
    mp = _read_ptr(proc, ptr)
    if not mp:
        return "Set"
    return _count(_read_i32(proc, mp + 4)) or "Set"


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "type summary add -F nova_formatters.nova_string_summary string"
    )
    # Container element COUNT (T-independent). Reliable at a statement boundary now that expression
    # statements carry the correct line (the earlier "stale count" was a debug line off-by-one, not a
    # value-struct-copy divergence). Per-element expansion still needs the element type in the DIType name.
    debugger.HandleCommand("type summary add -F nova_formatters.nova_list_summary List")
    debugger.HandleCommand("type summary add -F nova_formatters.nova_map_summary Map")
    debugger.HandleCommand("type summary add -F nova_formatters.nova_set_summary Set")
