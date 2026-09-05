# LLD: CLI entry, compile pipeline, and the command drivers

This part of the low-level design covers the "outer shell" of the Kyte compiler: the process entry
point, the argument dispatch layer, the shared compile/link pipeline that turns Kyte source into a
linked binary, and the individual command drivers (`build`, `test`, `fmt`, `get`/restore, `init`/`add`)
that sit on top of it. A single invocation `kyte <cmd> ...` flows like this: the OS calls
`main.zig:main`, which forwards `std.process.Init` (the process' argv, IO handle, and environment map)
to `cli.zig:run`. `run` sets up an arena allocator, reads `argv[1]`, and either prints version/usage or
dispatches to the matching command module: `scaffold` (init/add), `tester` (test), `format` (fmt),
`packages` (get), or `builder` (build and the bare `kyte <file>` compile form). Every compiling command
(`build`, `test`) reaches into `pipeline.zig` for the real work: import resolution, source loading and
merging, the codegen prelude (route/serde/mediator source generation), target derivation, and the
native/wasm/cross link. The compiled binaries do not stand alone: they depend on a shared install laid
down by `zig build` under `~/.kyte` (the `HOME`/`USERPROFILE` directory), specifically `~/.kyte/std`
(the standard library sources read as a fallback), `~/.kyte/lib` (the C++ runtime archives such as
`libkytecore.a` and `kytecore_asan`), `~/.kyte/cache` (fetched package git repos), and `~/.kyte/deps`
(vendored native libraries such as webview). A `.ky` path under `src/std/` is first looked for in the
current working directory, then in this shared `~/.kyte/std` copy, which is why a compiler installed
once works from any project directory.

A recurring, load-bearing convention across every file here: environment variables are read through
`init.environ_map.get("VAR")`, never `std.posix.getenv` or `std.c.getenv` (neither works in this Zig
build). The `init` value (`std.process.Init`) threads the IO handle (`init.io`) and the environment map
(`init.environ_map`) through the whole call tree, so almost every function takes `init` or its pieces.

---

## `src/main.zig` (20 lines)

**Role in the pipeline:** The process entry wrapper, kept deliberately thin. Zig looks for `pub fn main`
in the exe's root source file (wired in `build.zig`), so this file exists only to satisfy that and to
turn expected user-facing compilation errors into a clean one-line message instead of a Zig stack trace.
All real dispatch lives in `cli.zig`.

**Key types & data structures:** None of its own. Uses `std.process.Init` (passed straight through).

**Module-level state / constants:** None. Imports `std` and `cli.zig`.

**Functions:**
- **`fn main(init: std.process.Init) !void`** (pub; entry point)
  - Calls `cli.run(init)`. On error, consults `cli.userErrorHint(e)`: if that returns a hint (meaning the
    error is a user-level compilation failure, not an internal compiler bug), it prints a bold red
    `error: <hint> (compilation failed)` line (suppressing the message when the hint is the empty
    string, which the type-check / parse errors use because they already printed their own diagnostics)
    and exits with status 1. If `userErrorHint` returns null, the error is re-raised so Zig prints its
    normal trace.
  - Side effects: writes to stderr via `std.debug.print`; calls `std.process.exit(1)`.
  - Gotcha: the ANSI colour escape sequence and the "(compilation failed)" suffix are the only
    formatting here. The distinction between "user error" and "compiler bug" is entirely delegated to
    `userErrorHint`.

---

## `src/cli.zig` (107 lines)

**Role in the pipeline:** The thin routing layer between `main.zig` and the command implementations. It
parses `argv[1]`, handles `version`/`--version`/`-v` and the no-argument usage line, and delegates each
subcommand to its own module. It also owns the mapping from an error value to a user-facing hint
(`userErrorHint`). It references the dormant optimiser tree so the exe build compiles it on the real
path.

**Key types & data structures:** None of its own.

**Module-level state / constants:**
- Imports the command modules: `scaffold`, `tester`, `format`, `packages`, `builder`.
- `const optimiser = @import("optimiser/driver.zig")`: the middle-end scaffold. It is dormant:
  `optimiser.enabled` is false, so `optimiser.run()` never fires and codegen keeps its AST path. The
  import exists so the exe build actually compiles the optimiser tree.
- Reads `build_options.ky_version`, `build_options.ky_abi_version` (for the `version` command) and
  `builtin.zig_version` / `builtin.target` (pinned Zig + host triple). These are single sources of truth
  baked in by `build.zig`.

**Functions:**
- **`fn run(init: std.process.Init) !void`** (pub; the dispatcher)
  - A `comptime` block references `optimiser.pipeline` and `&optimiser.optimise` to force the whole
    optimiser tree (IR + passes + lowering + verifier) to compile even though the middle-end is off.
    No runtime cost. Then `if (optimiser.enabled) optimiser.run();` (never taken at M0).
  - Creates a page-allocator-backed `std.heap.ArenaAllocator` for the whole command (deinit on return),
    and turns `init.minimal.args` into a slice.
  - If fewer than 2 args, prints the usage line and returns.
  - `version`/`--version`/`-v`: prints the language version, the runtime ABI contract version, the
    pinned Zig version, and the `<arch>-<os>` host, all from `build_options`/`builtin`.
  - Dispatch table (string compares on `args[1]`): `init` → `scaffold.cmdInit`; `add` → if
    `args[2] == "feature"` and there are at least 4 args, `scaffold.cmdAddFeature(.., args[3])`, else a
    usage line; `test` → `tester.cmdTest`; `fmt` → `format.cmdFmt`; `get` → `packages.cmdGet`.
  - Fall-through: everything else (including `build` and a bare `kyte <file>`) goes to
    `builder.cmdBuild`.
  - Side effects: allocates the command arena; writes usage/version text to stderr.
  - Gotcha: the arena is the *root* allocator for the entire command. Command drivers that want
    pass-scoped memory (the `--watch` loop in `builder`) create their own child arenas.
- **`fn userErrorHint(e: anyerror) ?[]const u8`** (pub; error classifier)
  - Maps selected error values to a short human hint, returning null for everything else (which
    `main.zig` then surfaces as an internal compiler error with a trace).
  - `error.TypeCheckError`, `error.ExpectedToken`, `error.UnexpectedToken` map to `""` (empty hint):
    these already printed their own diagnostics, so `main.zig` just exits 1 silently.
  - `error.IdentifierNotFound` → "undefined identifier"; `error.FunctionNotFound` → "undefined
    function"; `error.VariableNotFound` → "undefined variable"; `error.MethodOrFunctionNotFound` → "no
    such method or function"; `error.AmbiguousName` → "ambiguous name"; `error.StructTypeNotFound` →
    "unknown struct type"; `error.FieldAccessObjectNotStruct` → "field access on a non-struct value".
  - Pure function, no side effects.

---

## `src/pipeline.zig` (1876 lines)

**Role in the pipeline:** The frontend-to-backend driver core shared by every command. It holds import
resolution (the recursive `loadProgram` walk plus `resolveImportPath` and its package/cache fallbacks),
source loading, the codegen prelude (route, serde binder, and mediator source generation that is parsed
back into the declaration list), target derivation (`deriveTargetInfo`, the synthesized `platform`
module, target-conditional file selection), and every link path (in-process LLD for macOS/wasm,
`clang++` for native, `zig c++` for cross-compilation). It also carries the `project.json` model, the
per-file `.o` cache hashing, and small filesystem helpers. `builder`, `tester`, `format`, `packages`,
and `scaffold` call into this module; nothing here calls back into them.

Note the division of labour: `pipeline.zig` does not contain `compileProgram` or `cmdBuild` (those are
in `builder.zig`). It provides the building blocks those drivers assemble.

**Key types & data structures:**
- **`CrossTarget = struct { zig: []const u8, static: bool }`**: a resolved cross-compilation target: the
  Zig target triple to pass to `zig c++` and whether to link `-static`.
- **`TargetInfo = struct { os, arch: []const u8, ptr_size: u8, is_posix: bool }`**: compile-target facts
  derived once per compilation from `--target`/triple (or the host). `os` is one of "darwin" | "linux" |
  "windows" | "wasm"; `arch` is "aarch64" | "x86_64" | "wasm32". Exposed to Kyte source as the
  synthesized `platform` module and used to select target-conditional files.
- **`ProjectJson = struct { name, version: []const u8, type: ?[]const u8 = null, dependencies:
  [][]const u8 }`**: the on-disk `project.json` model, parsed with `ignore_unknown_fields`. Shared by
  `packages`, `builder`, and `scaffold`.

**Module-level state / constants:**
- `extern fn kyte_lld_link_macho(...)` and `extern fn kyte_lld_link_wasm(...)`: the in-process LLVM LLD
  entry points (linked from the C++ side), used by the in-process link paths.
- `pie_flags: []const []const u8`: `&.{"-no-pie"}` on Linux, empty elsewhere. Codegen emits absolute
  `R_X86_64_32S` relocations (its target machine uses `Reloc::Static`), which a default `-pie` clang link
  on Ubuntu cannot hold, so the driver must tell clang `-no-pie`.
- `dead_strip_flag: []const u8`: `-Wl,-dead_strip` (macOS), `-Wl,/OPT:REF` (Windows, since clang there
  drives MSVC's link.exe which rejects `--gc-sections`), `-Wl,--gc-sections` otherwise.
- `CACHE_VERSION: u64 = 1`: bumped to invalidate the per-file `.o` build-hash cache.
- Reads env vars only indirectly (via callers passing `environ`/`home`); e.g. `SDKROOT` (in
  `macSdkPath`), `HOME`/`USERPROFILE` (in `getSharedAssetPath`, `resolveFromPackageCache`, `loadProgram`,
  `linkLibsStamp`).

**Functions (source order):**

- **`fn macSdkPath(environ: anytype, io: std.Io) []const u8`** (pub)
  - Returns the macOS SDK root: `SDKROOT` if set, else the Command Line Tools SDK
    (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) if it exists, else the Xcode SDK path.
  - Side effect: one `Io.Dir.access` probe. Returns a borrowed/literal string (no allocation).

- **`fn collectFfiLibs(allocator, program: ast.Program) ![]const []const u8`** (pub)
  - Walks `program.declarations` for `fn_decl`s with an `extern_lib`, dedupes them, and returns the owned
    slice of library names. Caller owns and frees the returned slice.
  - Used to build the `-l<lib>` link line for `extern("lib")` FFI declarations.

- **`fn appendFfiLib(args: *ArrayList, allocator, shared_kyte, io, lib) !void`** (pub)
  - Appends the right link tokens for one FFI library. Special-cases `"webview"`: links
    `<shared_kyte>/deps/webview/build/libwebview.a` (erroring `LinkFailed` if it is not built) plus the
    macOS `-framework WebKit -framework Cocoa`. On Windows, silently drops the POSIX names
    `c`/`m`/`pthread`/`dl`/`rt` (MSVC folds them into its CRT, and passing them is a hard LNK1181).
    Otherwise appends `-l<lib>`.
  - Side effects: one `Io.Dir.access` for webview; allocates strings into `args` (arena-owned).

- **`fn linkNativeInProcessMacho(allocator, environ, io, objs, output_path, shared_kyte, ffi_libs)
  !void`** (pub)
  - The in-process macOS link via `ld64.lld` (no `clang++` process spawn). Builds an argv:
    `-arch arm64`, `-platform_version macos 11.0 11.0`, `-syslibroot <sdk>`, `-lSystem`, `-lc++`,
    `-dead_strip`, the objects, `-L<shared_kyte>/lib -lkytecore -L/opt/homebrew/lib`, the (no-op) wolfSSL
    link, each FFI lib, and `-o <output>`. Duplicates each arg as a null-terminated C string and calls
    `kyte_lld_link_macho`. Non-zero return → `error.LinkFailed`.
  - Side effects: allocations into a local arraylist (freed); calls into the linked-in LLD.
  - Gotcha: hard-codes `arm64` and `macos 11.0`; this fast path is only taken on an arm64 macOS host with
    no cross target and ASAN off (see `builder.compileProgram`).

- **`fn mapCrossTarget(llvm_triple: []const u8) ?CrossTarget`** (pub)
  - Substring-matches an LLVM triple to a `zig c++` target. linux → `{aarch64|x86_64}-linux-musl`, static.
    windows/mingw/w64 → `{...}-windows-gnu`, non-static. darwin/apple → `{...}-macos` non-static, but only
    when the requested arch differs from the host arch (same-arch macOS returns null so the normal host
    link is used). Returns null for anything unrecognised.

- **`fn crossLinkViaZig(allocator, environ, io, llvm_triple, objs, output_path, shared_kyte, is_release)
  !bool`** (pub)
  - The cross-compile link. Resolves the target via `mapCrossTarget` (returns false if none). Ensures the
    C++ runtime object for that target exists at `<shared_kyte>/lib/kytecore_<zigtarget>.o`; if missing it
    one-time cross-compiles `<shared_kyte>/src/runtime/runtime.cpp` with `zig c++ -target <t> -std=c++20
    -O2 -DKYTE_DROP_ARENA -c` (spawned process; non-zero → `LinkFailed`). Then spawns `zig c++ -target <t>`
    (plus `-static` for musl targets, `-O3` for release), the objects, the runtime object, and for windows
    targets `-lws2_32 -lmswsock -lbcrypt`, producing `output_path`. Returns true on success.
  - Side effects: spawns up to two `zig c++` processes; reads/writes the cached runtime object under
    `~/.kyte/lib`. `environ` is unused (Boost include retired in M4).

- **`fn linkWasmInProcess(allocator, obj_path, output_path) !void`** (pub)
  - The in-process wasm link via `wasm-ld`: `--no-entry --export-all --export-memory --allow-undefined
    --initial-memory=134217728`, the object, `-o <output>`. Dupes to C strings and calls
    `kyte_lld_link_wasm`. Non-zero → `LinkFailed`.

- **`fn appendRuntimeLink(args: *ArrayList, allocator, shared_kyte, lib_name) !void`** (pub)
  - Appends the Kyte C++ runtime to a `clang++` link line. On Windows, links the COFF object
    `<shared_kyte>/lib/<lib_name>.o` directly (MSVC's link.exe cannot read the GNU archive llvm-ar writes),
    adds `-rtlib=compiler-rt` (for the 128-bit `__udivti3`/`__umodti3` helpers) and `-lws2_32 -lmswsock
    -lbcrypt`. Elsewhere, appends `-L<shared_kyte>/lib -l<lib_name> -L/opt/homebrew/lib`.
  - `lib_name` is `kytecore`, `kytecore_asan`, or `kytecore_tsan` depending on the sanitizer.

- **`fn appendWolfsslLink(args, allocator, shared_kyte, io) !void`** (pub)
  - A deliberate no-op. wolfSSL was retired in M13 (TLS is pure Kyte). Kept so the three link sites need no
    change. All parameters discarded.

- **`fn configureValueStructs(allocator, environ: anytype) void`** (pub)
  - Configures the M-1 value-type-struct codegen gate from the environment. `KYTE_VALUE_STRUCTS_OFF` set →
    return early (all-reference model, the escape hatch). `KYTE_VALUE_TYPES=A,B,C` → tokenise the list,
    build a `StringHashMap` of the named base types, set `codegen_arc.value_type_set` and
    `value_structs_enabled = true` (A/B narrowing). Otherwise the DEFAULT: `value_structs_enabled = true`
    and `value_structs_all = true` (every non-`class` struct is value-lowered unless escape analysis keeps
    it on the heap).
  - Side effect: mutates the global `codegen_arc` state. The duped type-name strings and the hashmap are
    allocator-owned (arena, so freed at command end).
  - Gotcha: the leading comment block calling the default "DEFAULT ON" is accurate here (the code sets both
    flags), unlike an earlier stale state noted in project memory.

- **`fn getSharedAssetPath(allocator, init, relative_path) ![]const u8`** (pub)
  - Resolves an asset by preferring the CWD-relative path if it exists, else falling back to
    `<home>/.kyte/<relative_path>`. Returns an owned path.

- **`fn hostOs() []const u8`** / **`fn hostArch() []const u8`** (pub): map `builtin.target` to Kyte's
  os/arch strings ("darwin"/"linux"/"windows"; "aarch64"/"x86_64"), defaulting to darwin/x86_64.

- **`fn deriveTargetInfo(target: []const u8, triple: ?[]const u8) TargetInfo`** (pub)
  - Produces the `TargetInfo` for a compilation. `--wasm` → wasm/wasm32/ptr 4/non-posix. Otherwise starts
    from the host os/arch and, if a `triple` is given, overrides os (linux / windows via
    windows|mingw|w64 / darwin via darwin|apple|macos) and arch (aarch64|arm64 / x86_64|x86-64|amd64), ptr
    size 8, `is_posix` true for darwin/linux.

- **`fn genPlatformSource(allocator, t: TargetInfo) ![]const u8`** (pub)
  - Generates the source of the compiler-synthesized `platform` module (never a file on disk): the `os`,
    `arch`, `pointerSize`, and the `isDarwin`/`isLinux`/`isWindows`/`isWasm`/`isPosix` booleans as Kyte
    `pub const`s. Returned owned string.

- **`fn suffixedFileExists(cand, allocator, io, home) bool`** (pub)
  - True if `cand` (a `.ky` path) exists in the CWD, or, for a `src/std/`-prefixed candidate, under the
    installed `<home>/.kyte/std/<sub>` fallback. Two `Io.Dir.access` probes.

- **`fn targetVariantPath(path, os_tag, arch, is_posix, allocator, io, home) ?[]const u8`** (pub)
  - Platform-axis variant selection. Given a resolved `dir/name.ky`, picks the most-specific existing
    target variant (first existing wins): `dir/<os>/<arch>/name.ky`, `dir/<os>/name.ky`, then (posix
    only) `dir/posix/<arch>/name.ky`, `dir/posix/name.ky`, then the legacy suffix
    `dir/name_<os>.ky`. Returns null when none exists (caller reads the flat base path). Special-cases
    the event-loop module: `src/std/net/eventloop` maps to `src/std/net/ev/<mechanism>.ky` where
    mechanism is kqueue (darwin), iocp (windows), or epoll (default; io_uring is runtime-dispatched inside
    the epoll unit). Module identity stays the base path regardless of which file's bytes are read.
  - Non-matching candidates are freed; the returned hit is owned.

- **`fn existingSource(kyte_candidate, allocator, io) ?[]const u8`** (pub)
  - Given a freshly allocated `.ky` candidate, returns whichever of `<path>.ky` or its `.nsx` sibling
    exists (as an owned path); `.ky` wins on a tie. Frees the candidate and returns null if neither
    exists. `.nsx` is the same language, filed apart for view/JSX code.

- **`fn resolveImportPath(base_path, module_name, allocator, io, home) ![]const u8`** (pub)
  - The central import resolver. Order: `platform` → the synthetic `src/std/platform.ky`; `std/<x>` →
    `src/std/<x>.ky`; a long hard-coded `std_modules` allow-list of bare std module names →
    `src/std/<name>.ky`; a handful of bare aliases (`list`/`map`/`set`/`string_builder`/`deque`/`heap`/
    `ordered_map` → `src/std/collections/...`, `db` → `src/std/data/db.ky`, `pool` →
    `src/std/data/sql/pool.ky`). Then importer-relative resolution, walking up from the importer's own
    directory and trying `<dir>/src/<module>.ky` and `<dir>/<module>.ky` at each level (this WINS over
    any global package match, which is what lets driver packages drop per-driver prefixes on their internal
    modules). Then `resolveFromLocalPackages`, then `src/<module>.ky`, then `resolveFromPackageCache`.
    Final fallback: `<dir>/<module>.ky` (or `<module>.ky` at root). Returns an owned path.

- **`fn resolveFromPackageCache(module_name, allocator, io, home) ?[]const u8`** (pub)
  - Scans `<home>/.kyte/cache/*/` (the git-fetched package cache) for `<pkg>/src/<module>.ky` or
    `<pkg>/<module>.ky`. Returns the first existing owned path, else null. Opens and iterates the cache
    directory.

- **`fn scanPackageRoot(root, module_name, allocator, io) ?[]const u8`** (pub)
  - Scans one `packages/` root: first `<root>/kyte-<module>/src/<module>.ky` (the package's own top
    module), then any `<root>/<pkg>/src/<module>.ky` (a flat module inside any package). Returns an owned
    path or null.

- **`fn resolveFromLocalPackages(module_name, importer_dir, allocator, io) ?[]const u8`** (pub)
  - Resolves from a sibling `packages/` directory. Probes CWD-relative roots (`packages`, `../packages`,
    up to five `../` levels) and a `packages/` directory at every ancestor of the importing file, so a
    cross-package import resolves regardless of process CWD. First package with the module wins.

- **`fn generateControllerRoutes(allocator, declarations: *ArrayList) !void`** (pub; codegen prelude)
  - For each struct that `impl Controller` but has no `registerRoutes` method, synthesizes one directly as
    AST nodes: `let ctrl = self;` then, for every method carrying a `@route` attribute, a
    `router.add(method, path, (req) => ctrl.<method>(req))` call. Appends the new method to the struct.
    Builds the AST by hand (allocating `Expression`/`Statement`/`Param` nodes into the arena).

- **`fn serdeIsInt(n) bool`** / **`fn serdeIsFloat(n) bool`** (pub): membership tests over the integer
  type names (i8..u64, byte/short/ushort/int/uint/long/ulong) and float names (f32/f64/float/double).

- **`fn serdeEnumPayloadless(e: ast.EnumDecl) bool`** (pub): true if every variant has no `type_name` and
  no `fields` (a plain C-style enum), the shape the serde binder can name-map.

- **`fn serdeAppendf(list: *ArrayList(u8), allocator, comptime fmt, args) !void`** (pub): `allocPrint`
  into a scratch string and append it to `list`; the small formatting primitive the serde/mediator
  generators use.

- **`fn generateSerdeBinders(allocator, declarations: *ArrayList, is_wasm) !void`** (pub; codegen prelude)
  - The big one. For every `@serializable` struct it generates Kyte source for a family of functions and
    parses it back into the declaration list. Builds sets of the serializable struct names and the
    payloadless enums, and detects whether the DB seam (a `Row` struct and a `colIndexOf` fn) is present.
    For each needed enum it emits `<E>__name`/`<E>__fromName`. For each struct it emits:
    - `<T>__bind(src: ValueSource): T`: name-based binder for JSON/YAML/web; every field is has-guarded so
      an absent key keeps the `init()` default (string→getString, `Str`→getStr zero-copy view, ints→getInt,
      bool→getBool, decimal→getDecimal, float→getFloat, nested serializable→recursive `__bind`, enum→
      `__fromName`, `List<T>` element binding). Handles the `.optional` and `.generic List` field shapes.
    - When the DB seam is present: `<T>__planFor(cols): List<int>` + `<T>__bindRow(row, plan): T` (Level A
      positional binder, one column-index lookup per result set, width-matched accessors asInt/asLong/etc);
      `<T>__bindAll(rs: ResultSet): List<T>` (Level B fused binder, indices resolved once into locals, a
      tight per-row loop matching a hand-rolled decode); and `<T>__bindWire(w: WireRows): List<T>` (the
      buffer-to-struct path reading column bytes straight from a shared buffer, no per-row objects).
    - Always: `<T>__toJson(obj): string` (manual JSON with `json.quote` for strings, optional and List
      handling), and `<T>__dump(obj, sink: ValueSink): void`.
    - Finally parses the generated source (parser file name `<serde-generated>`) and appends its
      declarations. On a parse failure it dumps the generated source and returns the error.
  - Returns early if there are no `@serializable` structs. The positional/DB binders are gated behind the
    DB seam so a hermetic non-DB program gains no undefined references.

- **`fn generateMediatorDispatch(allocator, declarations: *ArrayList, is_wasm) !void`** (pub; codegen
  prelude)
  - The legacy "baked" mediator dispatch. For every `impl RequestHandler<Q, R>` (or `R | E`) it generates
    an `async fn __mediator_dispatch_<Q>(src, __provider): Response` that binds the request via
    `<Q>__bind`, constructs the handler (with DI: each `init` param becomes
    `__provider.require("Dep") as Dep`), calls `handle` (awaiting only if the handler's `handle` is async),
    and serialises the result to a 200 JSON `Response` (or returns a `Response`-typed result verbatim, the
    raw-response escape hatch, or maps an error via `toResponse()`). Emits a `__mediator_dispatch_by_name`
    that switches on the request-type name. Parses the source back (`<mediator-generated>`) and appends.
    Emitted whenever there is at least one handler or a router present.

- **`fn generateRuntimeMediator(allocator, declarations: *ArrayList, is_wasm) !void`** (pub; codegen
  prelude)
  - The runtime mediator glue (pairs with `web/rmediator.ky`). Only requests that `impl Message` opt in
    (so it coexists with the legacy path during migration). For each such `impl RequestHandler<Q, R>` it
    emits a widen `<Q>__asMessage`, a `<Q>__Adapter impl HandlerAdapter` whose `execute` downcasts the
    erased request, builds the handler with DI from `ctx.scope`, runs it, and serialises R (with the same
    raw-response and error-union handling as the legacy pass). It records each request's marker traits
    (non-framework impls) for `ctx.requestIs`, auto-registers per-type `impl Validator<Q>` as
    `<V>__ValAdapter`, and accumulates a `__registerHandlers(m: Mediator)` plus an
    `__mediator_dispatch_runtime(__key, src, m)`. Both entry points are emitted whenever there is an App /
    router even with no Message handlers, so `App.init`/`App.dispatch` always resolve. Parses back
    (`<rmediator-generated>`) and appends.

- **`fn loadProgram(allocator, init, file_path, visited, visiting, merged, declarations, is_wasm,
  file_sources, tinfo) anyerror!void`** (pub; the import walk)
  - The recursive source loader and DFS import resolver. Guards against cycles (`visiting` set →
    `error.CyclicImport`) and re-visits (`visited` set → return). Adds `file_path` to `visiting`. Chooses
    the actual bytes to read via `targetVariantPath` (so a `foo_<os>.ky` or `os/<os>/...` variant is read
    while module identity stays `file_path`); the synthetic `src/std/platform.ky` is generated in-memory
    via `genPlatformSource`. For `src/std/` paths, reads the CWD copy and falls back to
    `<home>/.kyte/std/<sub>` on `FileNotFound`. Parses the source, and for every `import_decl` (skipping
    the builtin `bytes` pseudo-module) resolves the import via `resolveImportPath` and recurses. On the way
    back out it moves `file_path` from `visiting` to `visited`, appends the file's declarations to
    `declarations`, records the source in `file_sources`, and appends the source (plus a newline) to
    `merged`.
  - Side effects: reads source files (CWD and `~/.kyte/std`); populates `file_sources` (keys and the
    platform-generated value are allocator-owned; other values are the read buffers). This is the single
    place the whole import graph is materialised into one flat declaration list and one merged buffer.
  - Gotcha: module identity is always the base `file_path`, so `import foo` links no matter which
    target-conditional file supplied the bytes.

- **`fn basenameWithoutExtension(path, allocator) ![]const u8`** (pub): the file basename with its
  extension stripped; owned. Used to derive a default output name.

- **`fn findKyteFiles(allocator, io, root_dir, sub_path, list: *ArrayList) !void`** (pub)
  - Recursively collects `.ky` and `.nsx` files under `root_dir/sub_path` into `list`, skipping dotfiles,
    `zig-cache`, `zig-out`, `lang`, and the generated `merged.ky`. Each collected path is owned. Used by
    `tester` (project-wide test discovery) and `format` (format-all).

- **`fn getFileMtime(io, path) !i96`** (pub): the file's modification time in nanoseconds (via
  `statFile`). Used by the watch loop and the link-libs stamp.

- **`fn linkLibsStamp(allocator, init) u64`** (pub): XOR-folds the mtimes of the shared runtime archives
  (currently `~/.kyte/lib/libkytecore.a`) into a `u64`, so a runtime rebuild invalidates the `.o` cache.

- **`fn sourcesHash(file_sources, is_release, asan, link_stamp) u64`** (pub)
  - The content hash keying the `kyte build` incremental cache. Seeds with `CACHE_VERSION`, the
    `link_stamp`, and salts for the release and asan flags, then XOR-folds a Wyhash of each source file's
    (path, content). Order-independent (XOR fold), so it is stable across map iteration order.

**Cross-references:** codegen is `backend/codegen/llvm_codegen.zig` (invoked by the drivers, not here);
value-struct and ARC-elision gates live in `backend/codegen/arc.zig`; the optimiser emit flags live in
`backend/codegen/lir_emit.zig` and `optimiser/mir.zig`; the conformance harness (`conformance/run.sh`)
drives `kyte test` over `conformance/cases/`.

---

## `src/builder.zig` (591 lines)

**Role in the pipeline:** The driver for `kyte build [...]` and the bare `kyte <file> [...]` compile form.
It owns argument parsing for both forms, the profile/output-path layout for project builds, the per-file
`.o` cache gate, the `--watch` loop, and the actual end-to-end compile in `compileProgram`: load and merge
the program, run the codegen prelude, run alpha/ids/type-check/sema/mono, set the codegen and optimiser
emit flags, emit the object(s) via `llvm_codegen.compile`, and link (in-process LLD, `clang++`, or cross
via `zig c++`).

**Key types & data structures:** None of its own (uses `ast.Program`, `pipeline.ProjectJson`, and the
sema/codegen types).

**Module-level state / constants:** Imports the frontend/backend/sema modules plus `pipeline`,
`packages`, and the (dormant) `optimiser`. All tunables are read from `init.environ_map` at runtime.

**Functions:**
- **`fn compileProgram(allocator, init, file_path, target, output_path, is_release, target_triple_opt,
  visited, build_mode, build_obj_dir, build_hash_path) !void`** (private; the compile engine)
  - Sets up `visiting`, `merged`, `file_sources` (keys freed on exit), and `declarations`. Computes
    `is_wasm` and `tinfo = pipeline.deriveTargetInfo`.
  - **Sanitizer gating:** `asan = !is_wasm and (KYTE_ASAN != "0" if set, else !is_release)`. So debug
    native builds default to ASAN on, `--release` off, wasm never. `KYTE_ASAN_CODEGEN` (implies asan)
    additionally instruments Kyte-generated code (`codegen_arc.asan_codegen_enabled`).
  - **Load:** loads `src/std/collections/string_builder.ky` first (warn-only on failure), then the user
    `file_path`, via `pipeline.loadProgram`. `KYTE_DUMP_MERGED` writes the merged IR to `merged.ky`.
  - **Cache gate (build_mode only):** computes `src_hash = pipeline.sourcesHash(...,
    pipeline.linkLibsStamp(...))`; if `build_hash_path` holds the same hash and the output binary exists,
    prints "up to date" and returns without rebuilding.
  - **Prelude:** for `--wasm`/`--native` targets, parses and appends the `__log_i32`/`__log_bool`/
    `__read_string` helper functions. Then runs `generateControllerRoutes`, `generateSerdeBinders`,
    `generateMediatorDispatch`, `generateRuntimeMediator`.
  - **Frontend/sema:** builds `ast.Program` from the declaration list; runs `sema_alpha.run`,
    `sema_ids.Assigner`, `type_checker.TypeChecker.check`. Sets shadow/census flags from env
    (`KYTE_SEMA_SHADOW`, `KYTE_TID_CENSUS`), ARC elision default-on unless `KYTE_ARC_ELIDE_OFF`, then
    `pipeline.configureValueStructs`. Creates the owned `Sema`, runs `sema_shadow.run`, computes the mono
    worklist (`sema_mono.Worklist`), sets `sema_mono.live_instantiations`, and runs the instantiation
    dispatch passes (`inst_disp.run`/`runFreeFns`/`runMethods`).
  - **Escape/optimiser flags:** `KYTE_ESCAPE_REPORT` runs the report-only P7 escape gauge. Then the emit
    flags: `lir_emit.emit_enabled = (KYTE_OPT_EMIT != null)`, `lir_emit.emit_verbose =
    (KYTE_OPT_EMIT_VERBOSE != null)`, and `optimiser/mir.zig.type_store = &owned_sema.store` (so the
    optimiser's width-honest constfold can resolve TypeId widths). `KYTE_OPT` runs the shadow lowering
    (`optimiser.lowerProgramShadow`, report-only, does not emit).
  - **Codegen + link (wasm):** compiles to `<output>.o`, links in-process (`linkWasmInProcess`) if
    `build_options.inprocess_lld`, else spawns `clang -target wasm32 -nostdlib ...`. Deletes the object.
  - **Codegen + link (native):** picks the object path (`<build_obj_dir>/<basename>.o` in build mode, else
    `<output>.o`). T6 per-file split is default-on in build mode unless `KYTE_T6_NOSPLIT`, opt-in via
    `KYTE_T6_SPLIT` otherwise; `split_objs` collects the pieces. Calls `llvm_codegen.compile`, then reports
    the shadow diffs. Assembles the `clang++` line: `-std=c++20`, the dead-strip and PIE flags, an optional
    `-target <triple>`, `-O3 -DNDEBUG` (release) or `-g -O0` (debug), `-fsanitize=address` if asan,
    `-pthread -I.`, the shared `-I<home>/.kyte` include, the objects, the runtime link
    (`appendRuntimeLink` with `kytecore_asan` or `kytecore`), the FFI libs, and `-o <output>`.
    - If a cross triple is set, tries `pipeline.crossLinkViaZig` first (returns on success).
    - If `inprocess_lld` and arm64 macOS and no cross target and not asan, takes the in-process
      `linkNativeInProcessMacho` fast path.
    - Otherwise spawns `clang++`. Non-zero exit → `LinkFailed`.
    - Object cleanup: deletes the object unless `KYTE_KEEP_OBJ` (and never in build mode). In build mode,
      writes `src_hash` to `build_hash_path` on success.
  - Side effects: reads sources, writes objects and the final binary, spawns `clang`/`clang++`/`zig c++`,
    writes the build-hash and (optionally) `merged.ky`. Allocations are arena-scoped by the caller.
  - Gotchas: env access is always `init.environ_map.get`. The shared `~/.kyte` install supplies the
    runtime archives and the std fallback. ASAN forces the `clang` link path (it disables both in-process
    fast paths). The T6 split default differs between build mode (on) and bare-file mode (off).

- **`fn cmdBuild(allocator, init, args) !void`** (pub; the entry the CLI dispatches to)
  - First calls `packages.ensureDependencies` (auto-clone any missing `project.json` dependency so a fresh
    clone builds without a manual `kyte get`; silent when there is no `project.json`).
  - Parses args. Two arg grammars: `kyte build ...` (flags `--target <wasm|native|cross>`, `--file`, `-o`,
    `--release`/`-r`, `--debug`/`-d`, `--watch`/`-w`) and the bare `kyte <file> ...` form (positional file
    then `--wasm`/`--native`, `--release`/`--debug`, `--watch`, `--target`/`-t <cross>`, `-o`).
  - **Project layout (build_mode):** default `file_path = src/main.ky`; project name from `project.json`
    (falling back to the file stem). Creates `build/<profile>/bin` and `build/<profile>/obj`; default
    output is `build/<profile>/<name>`; the cache hash lives at `build/<profile>/.build-hash`. Profile is
    "release" or "debug".
  - Maps a `cross_target` switch (`linux-arm64`, `linux-x86_64`, `macos-arm64`, `macos-x86_64`,
    `windows-x86_64`, `windows-arm64`) to an LLVM triple; an unknown switch errors `UnsupportedTarget`.
  - Default output name for the bare form: the base name (with `.wasm` for wasm targets).
  - **Watch mode:** loops forever. Each pass uses a fresh page-allocator arena, calls `compileProgram`
    (catching and printing failures), then records the mtimes of every `visited` file, then polls every
    500 ms until any tracked file's mtime advances, and recompiles. The mtimes map (long-lived) is on the
    command arena; the compile itself runs on the per-pass arena.
  - Non-watch: a single `compileProgram` on the command arena (visited keys freed on exit).

**Cross-references:** codegen entry `llvm_codegen.compile`; the emit flags it sets are consumed by
`backend/codegen/lir_emit.zig` and `optimiser/mir.zig`; value-struct/ARC-elision flags in
`backend/codegen/arc.zig`; the `.o` cache hashing and link stamp live in `pipeline.zig`.

---

## `src/tester.zig` (389 lines)

**Role in the pipeline:** The driver for `kyte test`. It discovers `@test` functions across the target
file(s), generates a `main()` harness that runs each test and tallies pass/fail (and checks the ARC
audit), then compiles and links the harness the same way `builder` does and runs the produced
`__kyte_test` binary. It sets the same emit/sanitizer flags as the build path so the conformance gate run
via `kyte test` genuinely exercises them.

**Key types & data structures:** None of its own.

**Module-level state / constants:** Same import set as `builder`, minus the optimiser driver.

**Functions:**
- **`fn collectTestFunctions(declarations, allocator) ![][]const u8`** (private)
  - Returns the names of every top-level `fn_decl` carrying the `@test` attribute (owned slice).

- **`fn generateTestHarness(test_fn_names, allocator) ![]const u8`** (private)
  - Generates the Kyte source of a `main()` that, for each test: calls `kyte_test_reset()` /
    `kyte_test_begin(name)`, invokes the test, and prints `PASS`/`FAIL` (with the failure message from
    `kyte_test_fail_message()`), tallying passed/failed/total. After all tests it prints the summary,
    then `kyte_exit(1)` if `kyte_arc_audit_report() > 0` (ARC leaks) or any test failed. Returned owned
    source.

- **`fn cmdTest(allocator, init, args) !void`** (pub; the entry the CLI dispatches to)
  - Calls `packages.ensureDependencies` first (silent without a `project.json`).
  - Parses args: `--wasm`/`--native` set the target; any other positional is the file path.
  - **Discovery:** if no file is given, `pipeline.findKyteFiles` scans the CWD for all `.ky`/`.nsx`
    files (error if none); else uses the single given path (owned dup).
  - **Load:** loads `string_builder` first (warn-only), then each target file, via `pipeline.loadProgram`
    into the shared `visited`/`visiting`/`merged`/`file_sources`/`declarations`.
  - Collects the `@test` names; if none, prints a message and returns. Generates the harness source.
  - **main() replacement:** filters the loaded declarations to drop any existing `fn main` (so a project's
    own `main()` is skipped, a documented measurement trap), then appends the parsed harness declarations
    and the `__log_i32`/`__log_bool`/`__read_string` helpers.
  - Runs the codegen prelude (controller routes, serde binders, both mediator passes), then the same
    frontend/sema pipeline as `builder` (alpha, ids, type-check, shadow flags, ARC-elision default-on,
    `configureValueStructs`, sema, mono worklist + inst-dispatch passes, escape report).
  - **Emit flags:** sets `lir_emit.emit_enabled`/`emit_verbose` from `KYTE_OPT_EMIT`/`KYTE_OPT_EMIT_VERBOSE`
    and `optimiser/mir.zig.type_store`, exactly as the build path does, so the corpus gate exercises the
    LIR emit path rather than silently staying on the AST path.
  - **Codegen + link:** always emits to the hardcoded output `__kyte_test` (object `__kyte_test.o`). T6
    split is opt-in via `KYTE_T6_SPLIT`. `asan` is opt-in here (`KYTE_ASAN != "0"`, default off, unlike the
    build path); `tsan` via `KYTE_TSAN`. Assembles a `clang++` line (`-std=c++20 -g -O0 -pthread`,
    dead-strip + PIE flags, `-I.`, the `-I<home>/.kyte` include, the sanitizer flags, the objects, the
    runtime link picking `kytecore_asan`/`kytecore_tsan`/`kytecore`, the FFI libs, `-o __kyte_test`).
    Spawns `clang++`; non-zero → `LinkerFailed`. Deletes the object.
  - **Run:** spawns `./__kyte_test`. A non-zero exit (or abnormal termination) prints a failure line and
    the whole command `std.process.exit(1)`.
  - Gotchas: `kyte test` skips the project's `main()` and runs the imported `@test`s (a measurement trap
    noted in the memory: use `KYTE_ARC_DUMP`/`KYTE_ARC_AUDIT` to see survivors). The hardcoded
    `__kyte_test` output is why concurrent `kyte test` runs clobber each other, which the `conformance
    run.sh -j` mode works around by running each case in its own temp directory.

**Cross-references:** the harness relies on the runtime's `kyte_test_*` and `kyte_arc_audit_report`
symbols (C++ runtime); the emit flags feed `backend/codegen/lir_emit.zig`; `conformance/run.sh` invokes
this command per case.

---

## `src/format.zig` (244 lines)

**Role in the pipeline:** The driver for `kyte fmt`. It pretty-prints Kyte source via
`formatter.Formatter`, then re-injects the comments the pretty-printer drops, and writes the result back
only when a token-stream equivalence check proves the formatting did not alter the code. It never touches
sema or codegen.

**Key types & data structures:**
- **`TokenSpan = struct { start, end: usize }`**: a lexed token's byte range in the source.
- **`CommentIns = struct { offset: usize, text: []const u8, order: usize }`**: a pending comment
  re-insertion into the formatted text: where to splice, the rendered comment (owned), and a stable
  ordering key.

**Module-level state / constants:** Same import block as the other drivers (most unused here; only
`lexer`, `parser`, `formatter`, and `pipeline.findKyteFiles` are exercised).

**Functions:**
- **`fn sameTokenStream(a, b) bool`** (private): lexes both strings in lockstep and returns true only if
  every token's type and lexeme match through EOF. The safety check that formatting/comment-reinjection
  changed only whitespace and comments, never code.

- **`fn codeTokenSpans(allocator, text) ![]TokenSpan`** (private): lexes `text` and returns the byte span
  of every non-EOF token (owned). The scaffolding for locating the gaps where comments live.

- **`fn reinjectComments(allocator, source, formatted) ![]u8`** (private)
  - Re-inserts the source's comments into `formatted`. It computes token spans of both; if the token
    counts differ it gives up and returns a copy of `formatted` unchanged. Otherwise, for each gap between
    consecutive source tokens (and before the first / after the last), it scans for `//` line comments and
    `/* */` block comments, deciding trailing (same line as the previous token) vs leading, and records a
    `CommentIns` via `appendCommentInsert`. Finally it sorts the insertions by (offset, order) and splices
    them into the output. Returned owned buffer; the per-insert rendered strings are freed after splicing.

- **`fn appendCommentInsert(allocator, inserts, order, formatted, f_spans, i, n, text, trailing) !void`**
  (private): computes the actual splice offset and rendered text for one comment: a trailing comment
  goes at the end of the previous token's line (`" " ++ text`); a leading comment goes at the start of the
  next token's line, indented to match (`indent ++ text ++ "\n"`); a trailing-at-EOF comment appends
  `text ++ "\n"`. Bumps `order`.

- **`fn formatFile(allocator, init, file_path) !void`** (private)
  - Reads the file, parses it (`is_wasm=false`), runs `formatter.Formatter.formatProgram`. If the
    formatted output is not token-equivalent to the source, it skips the file (printing a message; and,
    under `KYTE_FMT_DEBUG`, the first differing token pair) rather than risk altering code. Otherwise it
    re-injects comments and re-checks equivalence; on mismatch it again skips. Only when both checks pass
    does it write the result back over `file_path`.
  - Side effects: reads and (conditionally) overwrites the file.

- **`fn cmdFmt(allocator, init, args) !void`** (pub; the entry the CLI dispatches to)
  - With a path argument (`args.len >= 3`), formats that one file (errors are printed, not fatal). With no
    path, uses `pipeline.findKyteFiles` to format every `.ky`/`.nsx` file under the CWD, counting
    successes and printing a summary.

**Cross-references:** relies on `frontend/lexer.zig`, `frontend/parser.zig`, `frontend/formatter.zig`;
uses `pipeline.findKyteFiles` for the format-all path. No codegen or optimiser interaction.

---

## `src/packages.zig` (179 lines)

**Role in the pipeline:** Dependency management. It clones package git repositories into the shared
`~/.kyte/cache`, auto-fetches missing `project.json` dependencies before a build/test, and implements
`kyte get <url>` (add a dependency and clone it) and the bare `kyte get` restore (clone every declared
dependency).

**Key types & data structures:** None of its own (uses `pipeline.ProjectJson`).

**Module-level state / constants:** Imports the full frontend/backend/sema set (mostly unused here) plus
`pipeline`. Reads `HOME`/`USERPROFILE` for the cache root.

**Functions:**
- **`fn repoNameFromUrl(git_url) ?[]const u8`** (private): extracts the repo name from a git URL: strips
  trailing slashes, takes the last path segment, drops a `.git` suffix. Null if empty. Borrowed slice into
  the input.

- **`fn cloneIntoCache(allocator, init, git_url) !bool`** (private)
  - Clones `git_url` into `<home>/.kyte/cache/<repo>`. Returns false (already cached) if the target dir
    exists; else spawns `git clone --depth 1 <url> <target>` and returns true on success. A non-zero or
    abnormal git exit is fatal (`GitCloneFailed`); an unparseable URL is `InvalidGitUrl`.
  - Side effects: spawns `git`; creates the cache directory tree.

- **`fn ensureDependencies(allocator, init) !void`** (pub): the pre-build/pre-test auto-fetch. Reads
  `project.json` (returns silently if absent, the bare-file case), parses it, and for every declared
  dependency not already in `~/.kyte/cache/<repo>` clones it (via `cloneIntoCache`). Deliberately quiet:
  no output when everything is cached; a clone failure IS fatal (the build would fail on the missing import
  anyway). Called at the top of `builder.cmdBuild` and `tester.cmdTest`.

- **`fn cmdRestore(allocator, init) !void`** (pub): the bare `kyte get` path. Reads and parses
  `project.json` (error message if absent), and clones every declared dependency, printing a
  "fetched / already cached" summary.

- **`fn cmdGet(allocator, init, args) !void`** (pub; the entry the CLI dispatches to): with no URL
  argument, delegates to `cmdRestore`. With a URL, clones it, then reads/parses `project.json`, appends the
  URL to `dependencies` if not already present, and rewrites `project.json` with the updated dependency
  list (via `std.json.Stringify`). Errors if there is no `project.json`.
  - Side effects: spawns `git`; reads and rewrites `project.json`.

**Cross-references:** shares `pipeline.ProjectJson`; the cloned repos are later resolved by
`pipeline.resolveFromPackageCache` during import resolution.

---

## `src/scaffold.zig` (214 lines)

**Role in the pipeline:** Project scaffolding for `kyte init <console|web|desktop> --name <name>` and
`kyte add feature <name>`. It writes template files (from `templates.zig`) into a new project directory
and creates the `project.json` and `.gitignore`.

**Key types & data structures:** A local anonymous `struct { rel, content: []const u8 }` inside
`scaffoldWeb` to pair each relative path with its template content.

**Module-level state / constants:** Imports `templates` and `pipeline` plus the (unused) frontend set.

**Functions:**
- **`fn scaffoldFile(allocator, io, project, rel, content) !void`** (private): writes `content` to
  `<project>/<rel>`, first creating the parent directory tree (tolerating `PathAlreadyExists`).

- **`fn scaffoldWeb(allocator, io, project) !void`** (private): writes the whole web-app template tree: the
  composition-root `src/main.ky`, the vertical-slice Features (CreateProduct command/response/validator/
  handler, GetProductById query/response/handler, the shared repository, an `.nsx` view), the domain
  entity, `wwwroot/index.html`, a feature test, and the Tailwind CLI pipeline files (`package.json`,
  `tailwind.config.js`, `styles/app.css`, `.gitignore`). All content comes from `templates.zig`.

- **`fn scaffoldDesktop(allocator, io, project) !void`** (private): writes just
  `src/main.ky` from `templates.desktop_main_sample` (a webview window binding a Kyte handler to a JS
  call).

- **`fn cmdInit(allocator, init, args) !void`** (pub; the entry the CLI dispatches to)
  - Validates the template type (`console`/`web`/`desktop`; `app` is accepted with a deprecation note and
    treated as `web`). Requires `--name`/`-n <name>`. Creates the project directory. For `console`, writes
    `src/main.ky` and `tests/main_test.ky`; for `web`, calls `scaffoldWeb`; for `desktop`, calls
    `scaffoldDesktop`. Then writes `project.json` (name, version 0.1.0, type, empty dependencies) and a
    `build/`-ignoring `.gitignore`.

- **`fn cmdAddFeature(allocator, init, name) !void`** (pub; the entry `cli.run` dispatches `add feature`
  to): creates `features/<name>/` with stub `model.ky`, `service.ky`, `view.ky`, and
  `<name>.ky`, then (if `project.json` exists) splices the feature name into a `"features": [ ... ]`
  array in the JSON text (string-level edit, not a full re-serialise). Prints a "not found, skipping" note
  if there is no `project.json`.

**Cross-references:** all file bodies live in `templates.zig`; `project.json` uses the same shape as
`pipeline.ProjectJson`.

---

## `src/templates.zig` (354 lines)

**Role in the pipeline:** A pure data module: the `pub const` string literals for every scaffold file
`scaffold.zig` writes. No functions or logic.

**Key types & data structures:** None. Every declaration is a `pub const <name> = \\...` multiline string.

**Module-level state / constants (the templates):**
- `console_main_sample`, `console_test_sample`: the console app's `main.ky` and a sample `@test`.
- `web_main_sample`: the web composition root (Program.cs-style): `configureServices`, `buildApp` with
  `app.post<CreateProduct>` / `app.get<GetProductById>` route registration, static files, `app.run(8080)`.
- `web_create_command_sample`, `web_create_response_sample`, `web_create_validator_sample`,
  `web_create_handler_sample`: the CreateProduct slice (a `@serializable` `impl Message` command, its
  response DTO, a validator fn, and a `RequestHandler<CreateProduct, CreateProductResponse | HttpError>`).
- `web_repository_sample`: a `ProductRepository impl Service` injected via DI.
- `web_get_query_sample`, `web_get_response_sample`, `web_get_handler_sample`: the GetProductById slice.
- `web_view_sample`: a per-feature NSX view returning an HTML string (with `response.escapeHtml`).
- `web_domain_entity_sample`: the `Product` domain entity.
- `web_index_html_sample`: `wwwroot/index.html`.
- `web_package_json_sample`, `web_tailwind_css_sample`, `web_tailwind_config_sample`,
  `web_gitignore_sample`: the Tailwind CLI styling pipeline files.
- `web_test_sample`: feature tests driving `App.dispatch` over synthetic requests.
- `desktop_main_sample`: the webview desktop `main.ky`.

**Functions:** none.

**Cross-references:** consumed solely by `scaffold.zig`. The web templates encode the framework
conventions that the codegen prelude in `pipeline.zig` depends on (`@serializable` structs →
`generateSerdeBinders`; `impl RequestHandler` / `impl Message` → `generateMediatorDispatch` /
`generateRuntimeMediator`; `impl Controller` with `@route` → `generateControllerRoutes`).
