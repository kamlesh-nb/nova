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


# NOTE on containers (List/Map/Set): a reliable count/element view is NOT done here on purpose. `size()`
# is `data.count()` (the shared RawBuffer's len), but under value-struct copy semantics the len field in
# the debugger-visible alloca can be a STALE copy while the program's own size() reads a different (live)
# copy -- so a raw-memory read can report e.g. 2 for a list the program correctly sees as 3. Showing a
# count that can disagree with the program is worse than showing none, so containers currently display as
# their address only (via the compiler's named pointer typedef). A reliable view needs either evaluating
# size() at the stop, or the value-struct-copy len update to be made consistent -- tracked as follow-up.


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        "type summary add -F nova_formatters.nova_string_summary string"
    )
