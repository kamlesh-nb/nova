# Conformance corpus: Windows and Linux failure lists

Measured on both hosts at the same commit, `ReleaseFast`, `conformance/run.sh -j 3`.
Corpus size is 444 = 374 positive cases + 70 `expect_fail` cases.

- **Windows** — Windows 10 Pro 19045, native host, IOCP reactor, LLVM 21.
- **Linux** — WSL2 Ubuntu 24.04, kernel 6.18, epoll reactor, LLVM 21.

Running BOTH is what makes the list interpretable. "Fails on Windows" turned out to
mean four different things, and three of the seven Windows failures were not Windows
problems at all.

## Result

| Gate | Before | After |
|---|---|---|
| Windows | 437/444 | **442/444** |
| Linux | 440/444 | **443/444** |

Both hosts are now at their ceiling. Every remaining failure is inapplicable by
design on that host — there is no outstanding bug in either list.

## Before

| Case | Windows | Linux | What it actually was |
|---|---|---|---|
| `42_nested_owned_aggregates` | FAIL | FAIL | compiler: value-struct copy ownership |
| `118_actor` | FAIL | FAIL | compiler: generic-field layout mismatch |
| `163_process` | FAIL | pass | Windows stdlib: unnarrowed optional |
| `188_kqueue_readiness` | FAIL | FAIL | **macOS only — inapplicable** |
| `189_epoll_event_layout` | FAIL | FAIL | Windows: inapplicable. Linux: real bug |
| `256_dns_ipv6` | FAIL | pass | Windows stdlib: missing `connectBlocking6` |
| `413_file_write_ok` | FAIL | pass | the test itself hardcoded `/tmp` |

## After

| Case | Windows | Linux | Why |
|---|---|---|---|
| `188_kqueue_readiness` | FAIL | FAIL | needs macOS; `kqueue`/`kevent` do not link elsewhere |
| `189_epoll_event_layout` | FAIL | pass | needs Linux; `epoll_ctl` does not link on Windows |

Both are `LNK2019`/link-time failures that never reach a test — asserting a
platform's kernel struct layout on a host that has no such kernel. They are the
mirror image of each other and neither is fixable off its own platform.

## The seven, one at a time

### `42_nested_owned_aggregates` — value-struct copy settled no ownership

`Outer{ inner: Inner{ items: List<string>() } }` crashed; binding the inner literal
to a variable first did not. Minimised to: a struct literal used as a field
initialiser inside another struct literal, where the inner struct owns a container.
Element type and the presence of other fields were both irrelevant.
`KYTE_VALUE_STRUCTS_OFF=1` made it pass, which located it in the value-struct path.

`buildValueStructCopyInto` duplicates inline bytes and explicitly does not touch
refcounts — its own doc-comment says callers must follow it with
`retainValueStructOwnedFields`. Every other call site did. The struct-literal field
loop did neither that nor `consumeTemporary`, so the `Inner` temporary stayed queued
for release and destroyed the very list `Outer` had just copied a pointer to.
Binding to a variable survived only because the `let` copy added a retain of its own.

Fixed in `expressions.zig` with the same borrow-vs-temporary split `takeOwnedElement`
and the field-assign path already use: a borrow deep-retains, a temporary is consumed.

### `118_actor` — a generic field's layout and its store path disagreed

Located by `--asan`, which is the only reason it was findable:

```
READ of size 4 in kyte_release (alloc.cpp:534)
    #1 ActorCell_i32_init
0x...038 is located 8 bytes before 160-byte region [0x...040,0x...0e0)
allocated by: kyte_chan_new (concurrency.cpp:1221)  #3 Mailbox_i32_init
```

The pointer being released was the wake channel from `kyte_chan_new` — a plain
`malloc` block with no ARC header, hence the read 8 bytes before the region.

`getFieldOffset` sizes fields with `getTypeSize(type_ref, true)`, whose `.generic`
branch returns 8 unconditionally: a generic *declaration* cannot be laid out, because
a field of the bare type parameter has no size until instantiation. The store paths
instead asked `fieldStoredInline(baseName)`, which only sees `"Mailbox"` and answers
"value struct, store it inline". So `ActorCell<M> { mbox: Mailbox<M>, behavior:
Behavior<M> }` reserved 8 bytes for `mbox` and copied 16 into it. `mbox.signal`
landed on `behavior`, and `self.behavior = behavior` then released that word as the
field's previous value.

Confirmed rather than inferred: two structs of identical shape differing only in
generic-ness — the non-generic one passes, the generic one crashes.

Fixed with `fieldStoredInlineRef(type_ref)`, phrased against `getTypeSize` itself
(`getTypeSize(t, true) == getTypeSize(t, false)`) so the store decision is derived
from the layout rather than re-deriving the rule. All four sites now use it. The
layout was deliberately NOT changed to make generic fields inline: that would move
every generic struct's field offsets, and the generic declaration genuinely cannot
be sized.

### `163_process` — an optional the Windows module did not narrow

`List.get` returns `T | undefined`; `quoteArg` takes a plain `string`. The POSIX
module escapes this only because it concatenates the element rather than passing it
as an argument. Narrowed with `?? ""` in `buildCommandLine`; the index is bounded by
`size()`, so the default is unreachable.

### `188_kqueue_readiness` — macOS only

Asserts `kqueue`/`kevent` struct layouts. Unresolved externals on both other hosts.
Permanent and correct; not a gap to close.

### `189_epoll_event_layout` — an `int` constant that does not fit an `int`

The recorded diagnosis ("a signedness bug in the epoll event accessor") was **wrong**,
and worth correcting because it points at the innocent side. The accessor is right:
`evEvents` sign-extends to `-2147483647`, the correct reading of `0x80000001`.

The wrong side is the constant expression. `EPOLLET` was declared
`pub const EPOLLET: int = 2147483648`, which does not fit a 32-bit signed `int`;
`EPOLLIN | EPOLLET` then folded to `2147483649`. Verified with a standalone probe
having nothing to do with epoll: a `const … : int` set to `2147483648`, OR-ed with
`1`, yields `2147483649`, while the same value round-tripped through
`write_i32`/`read_i32` yields `-2147483647`.

Fixed by spelling the constant as the signed bit pattern, `-2147483648`. The kernel
mask is a `uint32_t` and Kyte's `int` is signed, so the top bit has no positive
spelling. `setEvent`'s `write_i32` still puts `0x80000000` on the wire, and constant,
fold and round trip now agree. `EPOLLET` is not used by the reactor itself —
`eventsFor` only uses `EPOLLIN`/`EPOLLOUT`/`EPOLLONESHOT`, all of which fit — so the
blast radius was this constant and this case.

**Still open, deliberately not fixed here:** the compiler neither truncates nor
rejects an `int` constant that exceeds 32 bits. That is a language-semantics decision
(truncate like C, or error) and wants a spec change, not a quiet edit. A scan found no
other `int` constant in the tree above `2147483647`.

### `256_dns_ipv6` — a Winsock entry point that was never written

`net/dial` routes any IPv6 literal to `socket.connectBlocking6`, which
`os/windows/socket` never implemented. Added `AF_INET6`, `newTcp6`,
`makeSockaddrIn6` and `connectBlocking6`.

Worth recording: `AF_INET6` is **23** on Windows against 10 on Linux and 30 on
Darwin — the one sockaddr constant that differs on all three platforms. The struct
layout itself is shared, because Windows `SOCKADDR_IN6` leads with a `USHORT` family
field exactly as Linux does; Darwin is the odd one out with its 1-byte `sin6_len`
prefix, which is why the POSIX module branches and the Windows one does not.

### `413_file_write_ok` — the test was wrong, not the stdlib

Hardcoded `/tmp/kyte_writeok_413.txt`. On Windows a leading `/` resolves against the
current drive root, so this asked for `C:\tmp\`, which need not exist; the write
failed and the case read as a stdlib gap. Now uses `dir.Dir.tempDir()`, the idiom
conformance 211 already used.

## A note on macOS

None of these are macOS-specific, and none of the fixes are platform-conditional —
`42` and `118` are both in target-neutral codegen. But `42` and `118` are memory
bugs, and whether a memory bug *crashes* is allocator luck:

- `42` released a list and kept using it. Freed memory that still reads back
  plausibly gives a passing test.
- `118` released a pointer 8 bytes past a `malloc` block's start. On most allocators
  that offset is readable metadata, so it decrements a garbage refcount and silently
  corrupts `behavior` instead of faulting.

So a green macOS corpus would be consistent with both bugs being present there and
merely not firing — the same shape as `123_any_container`, which passed the plain
corpus on every host while double-releasing and was only ever caught by `--asan`.
This has not been verified: **there is no macOS host in this setup.** The claim is
that the fixes are correct everywhere, not that macOS was previously broken.

## Reproducing

```bash
# Windows (PowerShell), needs C:\LLVM\bin on PATH at RUN time too
$env:KYTE_LLVM_PREFIX = 'C:/LLVM'; zig build -Doptimize=ReleaseFast
conformance/run.sh -j 3

# Linux / WSL2
export KYTE_LLVM_PREFIX=/usr/lib/llvm-21; zig build -Doptimize=ReleaseFast
conformance/run.sh -j 3
KYTE_ASAN=1 zig build -Doptimize=ReleaseFast && conformance/run.sh --asan -j 3
```

Two traps that both present as a mass compiler regression and are neither:

- A **Debug** build cannot pass the corpus on any platform. `cli.run` installs a
  leak-detecting allocator and exits 1 on leaks; the driver legitimately leaks ~12k
  allocations, so every case prints `Results: N passed, 0 failed` and still exits 1.
- On Windows, `C:\LLVM\bin` missing from PATH at run time makes every case report
  `<compile/link error>` with `kyte.exe` exiting `0xC0000135`. Measured this session:
  it also trips the harness self-test and aborts with `HARNESS INTEGRITY BROKEN`,
  which reads like a classifier regression rather than a missing DLL.
