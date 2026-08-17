# Nova lldb data formatters (Gap 4, item 3).
#
# Nova heap objects carry an 8-byte ARC header before the payload pointer: a refcount (i32 @ ptr-8)
# and a length (i32 @ ptr-4). `string` is a pointer to `len` bytes of UTF-8 and is NOT NUL-terminated,
# so lldb's built-in char* summary is unsafe (it would over-read); these read the explicit length.
#
# Load with:  command script import <this file>
# (registered automatically by __lldb_init_module below.)

import lldb


def _read_arc_len(process, ptr):
    """The i32 length stored at ptr-4 (little-endian). None on failure or an implausible length."""
    err = lldb.SBError()
    raw = process.ReadMemory(ptr - 4, 4, err)
    if err.Fail() or raw is None:
        return None
    n = int.from_bytes(raw, "little", signed=True)
    if n < 0 or n > 64 * 1024 * 1024:
        return None
    return n


def nova_string_summary(valobj, internal_dict):
    ptr = valobj.GetValueAsUnsigned(0)
    if ptr == 0:
        return '""'
    process = valobj.GetProcess()
    n = _read_arc_len(process, ptr)
    if n is None:
        return "<string len?>"
    if n == 0:
        return '""'
    err = lldb.SBError()
    data = process.ReadMemory(ptr, n, err)
    if err.Fail() or data is None:
        return "<string ?>"
    return '"' + data.decode("utf-8", "replace") + '"'


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "type summary add -F nova_formatters.nova_string_summary string"
    )
