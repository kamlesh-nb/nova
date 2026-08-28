# 21. How Nova works: architecture

The earlier chapters showed Nova from the outside: the syntax you write and the behaviour you get.
This chapter looks under the bonnet. It is not needed to write Nova, but it explains why the language
behaves the way it does, which helps when you are reasoning about performance, memory, or a tricky
concurrency bug. Nothing here changes the surface language; it is the same Nova, seen from the
implementer's side.

## Three languages, one toolchain

Nova is built from three parts, each in the language that suits it best:

- **The compiler is written in Zig.** It reads your `.nova` files and lowers them, through LLVM, to a
  native binary. Zig was chosen for its simplicity and its direct, allocator-explicit control over
  memory, which matters in a compiler that manipulates large trees.
- **The runtime is written in C++20.** It is the small library every Nova program links against: the
  async scheduler, the network reactor, channels, and the memory primitives. C++ was chosen for its
  mature concurrency facilities and coroutines.
- **The standard library is written in Nova itself.** Collections, strings, JSON and BSON, the HTTP and
  web framework, the SQL layer, crypto and TLS: all of it is Nova compiled from source, not a foreign
  binding. The language is expressive enough to write its own standard library, which is the best
  evidence that it is expressive enough for yours.

The native toolchain is the primary target. WebAssembly is a secondary, best-effort target with a
smaller, runtime-free surface, where the host supplies input and output.

## From source to binary

A single `.nova` file travels through a fixed pipeline. Each stage hands a more precise representation
to the next:

1. **Lexer.** Turns the source text into tokens.
2. **Parser.** Builds the abstract syntax tree (AST) from the tokens.
3. **Type checker and semantic analysis.** This is where the real work happens. It resolves names and
   imports, checks types, resolves traits, and, crucially, produces a fully typed intermediate
   representation. Optionals are checked here (an unguarded optional field access is a compile error,
   not a runtime surprise), and ownership is decided here (see the memory section below).
4. **Monomorphisation.** Generics are not type-erased. `List<int>` and `List<string>` become two
   distinct concrete types with their own code. The compiler instantiates each generic for every set
   of type arguments it is actually used with. This costs some binary size and buys full speed: a
   `List<int>` stores and loads real 32-bit integers, with no boxing.
5. **Code generation.** The typed IR is lowered to LLVM IR, then to a native object file. LLVM does the
   machine-level optimisation and instruction selection.
6. **Linking.** The object is linked against the runtime library into a final executable. Nova can do
   this in-process (it can carry LLD, the LLVM linker, inside the compiler), so a delivered `nova`
   needs no external `clang` or system linker to produce a binary.

Two representations of your program exist at once during a build: the front end merges the whole
import graph into one typed program so monomorphisation and cross-module resolution can see everything,
and the back end then emits one object file per source file so the linker can drop the parts your
program never uses.

### Honest primitives

Nova's number types mean exactly what they say, because that is what maps cleanly onto the machine and
onto LLVM. `int` is a 32-bit signed integer, `long` is 64-bit, and there is a distinct `ptr` type for
raw addresses. This honesty matters at the boundary with the runtime: a heap address is 64 bits, so it
must be held in a `long` or a `ptr`, never an `int`, or the top half is lost. You rarely touch this in
application code, but it is the reason the primitive sizes are fixed and not "whatever is convenient".

## Traits are fat pointers

A trait object (a value used through a trait rather than its concrete type) is represented as a pair:
a pointer to the value, and a pointer to a vtable of function pointers for that concrete type under
that trait. This is the same "fat pointer" shape used by many systems languages. Slot zero of every
vtable is the destructor, which is how the runtime cleans up a trait object without knowing its
concrete type. Dynamic dispatch is a load from the vtable and an indirect call; there is no runtime
type reflection beyond this.

## Memory management: ARC, not a garbage collector

Nova manages memory with **automatic reference counting** (ARC), decided at compile time, not with a
tracing garbage collector. Chapter 13 covers this from the writing-code side; here is the mechanism.

Every heap object carries an 8-byte header immediately before the data it hands you: a reference count
and a length. The compiler inserts `retain` (increment) and `release` (decrement) calls around the
places where ownership begins and ends, following the rules it worked out during semantic analysis.
When a release drops the count to zero, the object's destructor runs and its memory is freed, right
then. There is no background collector, no stop-the-world pause, and no non-determinism about when
cleanup happens: an object dies at a point you could, in principle, mark in the source.

The consequences are the ones you would expect from deterministic cleanup:

- Resources tied to an object (a file handle, a socket, a database connection) are released promptly
  when the object goes out of scope, not "eventually".
- Cost is proportional to the retain and release traffic, which the compiler tries to minimise, not to
  the size of the live heap.
- The correctness of ownership is the compiler's responsibility. This is why memory-safety work on the
  compiler is verified under AddressSanitizer, which turns a mistaken free into a located report rather
  than a mysterious corruption that surfaces far away.

Underneath, pages come from the operating system through `mmap`, and the allocator hands out honestly
reference-counted blocks (there is no hidden per-thread arena that would confuse ownership across
cores).

## The concurrency model

Chapter 15 shows `async`, `await`, `spawn`, futures, and channels as you use them. The engine beneath
them has two pieces: coroutines and a reactor.

**Coroutines.** An `async fn` compiles to an LLVM coroutine: a function that can suspend and resume,
with its live state saved in a heap frame across the suspension. `spawn` starts one as an independent
task and hands you a `future`; `await` suspends the current coroutine until the awaited one completes
and yields its value. Because suspension is explicit, a synchronous function that tries to block-drive
async work while already running inside the event loop is a detectable error, not a silent deadlock.

**The reactor.** Non-blocking I/O is driven by an event loop built directly on the operating system's
readiness or completion facility. There is no third-party async framework underneath; the reactor is
part of the runtime. The backend is selected per platform:

| Platform | Backend | Model |
|----------|---------|-------|
| macOS and BSD | kqueue | readiness |
| Linux | epoll (default) or io_uring | readiness / completion |
| Windows | IOCP | completion |

On a readiness backend the kernel tells the reactor when a socket can be read or written, and the
runtime then does the transfer. On a completion backend (IOCP, io_uring) the runtime hands the kernel
the operation and is told when it has finished. The runtime hides this difference so the same Nova code
runs on all of them; the design notes in the repository record the traps that live at that seam.

On top of coroutines and the reactor sit the higher-level tools you actually reach for: `when_all` and
`selectAny` to combine futures, channels to pass values between tasks, and an actor style built on
channels and coroutines. The runtime can run on multiple cores, with a share-nothing arrangement of one
reactor per core for server workloads.

## The runtime library and self-contained delivery

Everything the compiler needs at your program's link time is bundled: the C++ runtime is prebuilt into
a single static library, `libnovacore.a`, and the compiler can link with LLD in-process. So a Nova
toolchain is genuinely self-contained. On the machine that runs `nova build`, there is no requirement
for a system `clang`, a system linker, or an installed LLVM: the compiler carries what it needs and
links against the prebuilt runtime archive. The next chapter shows how those bundles are built, and how
one machine can build them for another architecture.

## Where the pieces live

If you want to read the implementation, the shape is:

- `src/` is the compiler: the lexer and parser, `sema/` (the authoritative typed-IR passes: infer,
  monomorphise, ownership, lower), and `codegen/` (the LLVM lowering).
- `src/runtime/` is the C++ runtime (the scheduler and reactor, the memory primitives).
- `src/std/` is the standard library, in Nova.
- `packages/` holds the concrete database drivers, which plug into the standard library's database seam.

## Where to go next

- Chapter 13 for ownership and memory from the writing-code side.
- Chapter 15 for the concurrency API in practice.
- Chapter 22 for building and distributing the toolchain, including cross-compilation.
- The [language specification](../language-specification.md) for the precise contract behind the
  surface language.
