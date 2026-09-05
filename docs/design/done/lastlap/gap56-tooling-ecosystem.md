# Gap 56: Tooling and Ecosystem -- Deep, Honest Analysis

Assessed from the actual code on 2026-08-15. Umbrella root `/Users/kamlesh/kyte-lang`.

## What I actually inspected vs could not access

INSPECTED (all present locally, all read from source, not from README claims):

- LSP server: `nls/src/` (server.zig 2146 lines, analysis.zig 315, main.zig 27, root.zig 12).
- Formatter: `lang/src/format.zig` (244) + `lang/src/frontend/formatter.zig` (1031).
- Package manager: `lang/src/packages.zig` (179) + `lang/src/scaffold.zig` (214) + `lang/src/templates.zig` (354).
- Debugger: searched `lang/`, `nls/`, `extension/` for any DAP/DWARF/debug-info. Confirmed absent (details below).
- VS Code extension: `extension/` (extension.ts 102 lines, package.json, grammars, snippets).
- DB drivers: `packages/kyte-{postgres,mysql,mssql,mongodb,novadb,btreedb,orchestrator}` -- Kyte source, line-counted and structure-sampled.
- Web framework: `lang/src/lib/std/web/` (24 files, 3747 lines) + DB seam `lang/src/lib/std/data/` (db.ky 677, orm.ky 225, sql/pool.ky 291).
- Orchestrator: `packages/nova-orchestrator/` (src 4817 lines + bin/tests/webui = 9364 total).
- NovaDB: `novadb/` IS present locally as a sibling-style dir inside the umbrella (59,513 Zig lines total, 25,552 in `src/`). It is a separate project/repo but the tree is here, so I could inspect its structure.

COULD NOT fully access / NOT VERIFIED:

- I did not build or run any of these; all maturity reads are from static inspection and line counts, not from executing test suites. Where behaviour depends on a live DB/runtime I mark it NOT VERIFIED.
- NovaDB internals were only structurally sampled (file/line breakdown), not audited for correctness. It is a separate project with its own CLAUDE.md and gate; a deep design for it needs its own analysis pass.
- The orchestrator `webui/` is noted in project memory as untracked and not building; I did not verify its state beyond the file listing.
- `~/.kyte/cache` (the package cache) does not exist on this machine (the `ls` failed), so I could not see resolved/fetched dependency copies; I assessed the fetch logic from `packages.zig` instead.

---

## PART A -- TOOLING

### A.1 LSP server (`nls/`) -- GAP: moderate. The best-built tool of the set.

LOCATED: `nls/src/server.zig` + `nls/src/analysis.zig`. Standalone Zig binary, stdio transport, reuses the compiler's parser/type_checker as a `compiler` module (build.zig pulls `../lang/src/root.zig`).

WHAT EXISTS (each handler cited by line in `server.zig`):

- `textDocument/didOpen` (147), `didChange` (169), `didClose` (187) -- document sync. NOTE: `didChange` full-document replace; sync mode is Full, not incremental (see below).
- `textDocument/publishDiagnostics` (234) driven by `runDiagnostics` (197). This is the strongest part: on a clean parse it hands the buffer to the SAME `type_checker.TypeChecker` the compiler runs (`collectSemanticDiagnostics`, 239-256) and surfaces every span-carrying structured error, not just the first token. On a parse failure it falls back to a single syntax-error diagnostic (215-227). Caveat stated in-code (207-211): single-file mode, imports are not resolved, so cross-module checks are best-effort but decl-guarded to stay low-false-positive.
- `textDocument/formatting` (299) -- delegates to the compiler formatter.
- `textDocument/completion` (344) -- trigger chars `.` and `:` (server capability line 91). AST-based with a lightweight best-effort type environment (analysis.zig docstring, lines 9-14: "There is no full type checker in the loop"); degrades to a global set when it cannot resolve the receiver.
- `textDocument/hover` (640), `signatureHelp` (865, trigger `(` `,`), `definition` (788), `documentSymbol` (1000), `references` (1089), `prepareRename` (1127) + `rename` (1139), `codeAction` (1182), `semanticTokens/full` (1259), `workspace/symbol` (1346).
- Server capabilities registered at 78-110: completionProvider, hoverProvider, definitionProvider, signatureHelpProvider, renameProvider(prepareProvider=true), codeActionProvider, semanticTokensProvider, documentSymbol, references, workspace/symbol.

Quality reads from the code:

- `definition` (788-829): first tries locals in the enclosing function (accurate), else a whole-open-file scan matching a declaration by NAME via `declSpanFor` (831-851). `declSpanFor` matches on name string only -- so two same-named symbols in different scopes resolve to the first found. Not binding-accurate for globals.
- `references`/`rename`: per the nls CLAUDE, binding-accurate for function-locals (brace-matched extent), whole-word string/comment-aware fallback for globals/types/fields. That is honest and reasonable but not a real symbol-graph rename.
- `codeAction` (1182): only two actions, keyed on checker message substrings -- the async await/spawn fix and the 128-bit-integer removal. Extensible but tiny.
- Diagnostics reparse + retypecheck the whole file on every change with a fresh arena; no incremental parse, no caching, no cross-file project model.

WHAT IS MISSING (measured against a beta-grade LSP):

- No incremental text sync (Full-document only) -- fine for small files, wasteful for large.
- No `textDocument/typeDefinition`, `implementation`, `documentHighlight`, `foldingRange`, `selectionRange`, `inlayHint`, `callHierarchy`, `codeLens`, `documentLink`, `semanticTokens/range` or `/delta`, `completionItem/resolve`, `formatting/rangeFormatting`, `onTypeFormatting`.
- No project/workspace model: definition/references only search OPEN files, not the whole project or resolved imports. Cross-module go-to-def to an unopened file will miss.
- Completion has no real type inference, so member completion on anything the light env cannot resolve degrades to globals.
- No import resolution in diagnostics, so whole classes of real errors (undefined cross-module symbol, wrong import) are invisible in-editor.

ROOT CAUSE: deliberately AST-and-lightweight-env based to avoid running the full sema/mono pipeline (which pulls in codegen/LLVM) inside the editor loop. That keeps nls a pure-Zig, cross-compilable binary but caps semantic precision at "single file, no imports, no inference".

### A.2 Formatter (`lang/src/format.zig` + `frontend/formatter.zig`) -- GAP: small. Genuinely solid for its scope.

LOCATED and read both files.

WHAT EXISTS:

- `formatter.zig` (1031 lines): a `Formatter` struct that pretty-prints the AST with 4-space indent (`writeIndent`, 24-29). AST-driven, so it fully normalises layout.
- `format.zig` (244 lines) is the `kyte fmt` driver and does two things a naive AST printer does not: (1) `sameTokenStream` (23-33) verifies the formatted output lexes to the IDENTICAL token stream as the input -- a real safety net against the formatter changing meaning; (2) it reinjects comments the AST printer drops (the file header comment says "reinjecting comments the pretty-printer drops"), tracked via `codeTokenSpans`/`TokenSpan`.
- Has a self-test: "formatter: every operator round-trips through the lexer" (formatter.zig 1019).

WHAT IS MISSING / WEAKER:

- Idempotency is not asserted in-code (I found no `fmt(fmt(x)) == fmt(x)` test); the token-stream check guarantees safety, not stability.
- Comment reinjection by token-span reconciliation is inherently heuristic; edge cases (comments inside expressions, trailing comments after removed syntax) can drift. NOT VERIFIED against a stress corpus.
- No configurable style (line width, quote style, trailing commas), no range formatting, no "format on type".

Overall the formatter is the most mature single piece of tooling after the LSP diagnostics path.

### A.3 Package manager (`lang/src/packages.zig`) -- GAP: LARGE. This is the weakest tool.

LOCATED and read fully (179 lines).

WHAT EXISTS:

- `kyte get <git-url>` (`cmdGet`, 128): `git clone --depth 1 <url>` into `~/.kyte/cache/<repo-name>` (`cloneIntoCache`, 35-65), then appends the raw git URL to `project.json`'s `dependencies` array (166-178).
- `kyte get` with no arg / `kyte restore` (`cmdRestore`, 100) and `ensureDependencies` (73) auto-clone any declared dep not already in the cache before build/test.
- Dedup is by exact URL string match (155-160). Repo name is derived by string-munging the URL (`repoNameFromUrl`, 24-33).

WHAT IS MISSING (versus any real package manager -- cargo/npm/go):

- NO VERSIONING. A dependency is a bare git URL. No semver, no version constraints, no tags/branches/commits pinned -- `--depth 1` clones whatever HEAD is today. Two machines cloning the same manifest can get different code.
- NO LOCKFILE. Nothing records the resolved commit SHA. "Locked in project.json" (message at 178) only means the URL string was written; there is no reproducibility.
- NO REGISTRY / no namespacing / no discovery. It is git-URL-only.
- NO TRANSITIVE DEPENDENCY RESOLUTION. `ensureDependencies` reads the ROOT `project.json` only; a fetched dependency's own `project.json` deps are not walked. No dependency graph, no conflict resolution, no dedup across versions.
- NO INTEGRITY (no checksum/hash verification), no cache invalidation/update command (a cached repo is never re-pulled -- line 44-47 short-circuits if the dir exists), no uninstall, no `outdated`/`update`.
- Cache key is the repo NAME, so two different URLs ending in the same repo name collide in `~/.kyte/cache`.

ROOT CAUSE: it is a git-clone convenience wrapper, not a package manager. It was built to make `git clone <app> && kyte build` resolve the driver packages, and stops there. Memory note `kyte-db-decimal-and-multidriver-import` also flags "stale repo packages/* shadow ~/.kyte/cache", i.e. resolution order between the in-repo `packages/` and the cache is itself a known hazard.

### A.4 Debugger -- GAP: TOTAL. Does not exist.

CONFIRMED absent:

- No DAP implementation anywhere. `grep -ril debugAdapter|DebugSession|vscode-debugadapter|breakpoint` over `lang/`, `nls/`, `extension/` returns only a design doc filename (`bug-async-owned-struct-uaf.md`) -- no code.
- No source-level debug info emitted by codegen: `grep -rl DIBuilder|createCompileUnit|LLVMDIBuilder|dwarf` over `lang/src/backend` returns NOTHING. The compiler lowers to LLVM IR and links native binaries but emits no DWARF/line tables, so even attaching `lldb`/`gdb` gives no Kyte-source line mapping -- you would be debugging optimised machine code with no symbols back to `.ky`.
- The VS Code extension declares no `debuggers` contribution (package.json has languages, grammars, snippets, one command `kyte.runFile`; no debug config).

IMPLICATION: there is no way to set a breakpoint, step, or inspect a Kyte variable at runtime. Debugging today is print-statements + the runtime's opt-in facilities (`KYTE_CRASH_TRACE`, `KYTE_IO_WATCHDOG`, `KYTE_ARC_AUDIT`) which are for compiler/runtime authors, not app developers.

### A.5 VS Code extension (`extension/`) -- GAP: moderate. Syntax + launch only.

LOCATED. `extension.ts` is 102 lines. Contributes: language registration, a TextMate grammar (syntax highlighting), snippets (`snippets/kyte.json`), and exactly ONE command `kyte.runFile` ("Kyte: Run Current File"). Packaged as `kyte-vscode-0.2.0.vsix`.

It presumably launches `~/.kyte/bin/nls` for LSP features (per nls CLAUDE), so IDE intelligence rides on the LSP above. No debug integration, no build tasks, no test explorer, no `.nsx` rich support beyond grammar. This is a "basic syntax highlighter + LSP client + run button", which matches the CLAUDE.md self-description.

---

## PART B -- ECOSYSTEM

### B.1 DB drivers (`packages/kyte-*`) -- GAP: moderate. Substantial code, single-request-proven.

LOCATED in `packages/` at the umbrella root (NOT `lang/packages/`, which does not exist). Line counts (Kyte source):

- nova-postgres 1739, nova-mysql 2017, nova-mssql 2138, nova-mongodb 2767, nova-novadb 1105. (nova-btreedb present but 0 counted `.ky` -- likely a thin shim/rename of novadb.)

The abstraction seam lives in std (`lang/src/lib/std/data/db.ky`, 677 lines): `DbValue` tagged union with typed accessors (`asInt/asLong/asDecimal/asText/asUuid/asJson/asArray`, null-coalescing `asXxxOr`), plus `orm.ky` (225, `queryAs<T>`) and `sql/pool.ky` (291, connection pool). Per project memory the drivers are "prod-ready single-request", the pool + streaming cursor (X4/X5) exist, and the four SQL drivers + mongo are feature-complete for the common path.

WHAT IS MISSING / ROUGH (from memory notes cross-checked against structure, several NOT VERIFIED without a live DB):

- Concurrency: memory flags "mongo c>1 crash open" and that the perf story needed a connection POOL to survive c=50. Multi-connection robustness is not uniformly proven.
- These are hand-rolled wire protocol implementations per DB; breadth of type coverage, TLS, auth methods, prepared-statement edge cases, and error mapping are as complete as one author had time for -- not battle-tested against the full server matrix. NOT VERIFIED.
- The conformance corpus explicitly cannot run the driver cases from a bare clone (they need `packages/` + sometimes a live DB), so CI coverage of drivers is weak.

### B.2 Web framework (`lang/src/lib/std/web/`) -- GAP: moderate. Surprisingly broad for its age.

LOCATED: 24 files, 3747 lines, flat (no subdirectories). Highlights by size: app.ky (547), request.ky (480), client.ky (435, an HTTP client), response.ky (370), routing.ky (223), mediator.ky (213, MediatR-style), di.ky (160), httpparser.ky (160), multipart.ky (128). Middleware present as discrete files: cors, csrf, session, cookie, rate_limit, circuit_breaker, body_limit, request_id, logger, redact, static_content, mime, methods.

This is a real, ASP.NET-flavoured framework: routing + DI + mediator + a middleware pipeline + an HTTP client + multipart + sessions + common security middleware. For a language this young it is broad.

WHAT IS MISSING / ROUGH:

- It is single-reactor-per-process by design (memory `nova-web-single-reactor-only`); in-process multi-core was removed. Scale is "instances behind a proxy", which pushes load onto the orchestrator.
- Known dogfood bugs in memory (`nova-datastar-sse-morph-binding`: data-on-click not bound on SSE-morph; stored multi-arg closure SIGSEGV) indicate the hypermedia/reactive path is rough.
- No obvious templating engine beyond `.nsx` hypermedia attrs; no built-in migrations/auth framework; middleware set is decent but not exhaustive (no built-in compression middleware surfaced here, though runtime has gzip).

### B.3 Orchestrator (`packages/nova-orchestrator/`) -- GAP: moderate-to-large, in active flux.

LOCATED: 9364 Kyte lines total (src 4817, plus bin/, tests/, webui/, examples/). Structure: `bin/{orchd,orchctl,service}.ky`; `src/orch/{supervisor(392),nativelet(513),manifest(381),spec,lease(194),asynclease,autoscaler,rollout,health,alerts,controlplane,isolation}`; `src/net/{proxy(977),service,netns,autoscale}`; `src/store/{config,sqlconfig}`. ~28 test files (178-201 series) + live tests.

This is a genuine control-plane attempt: proxy/load-balancer, supervisor, manifest reconciliation, leader lease, autoscaler, rollout, health checks, YAML declarative manifest, SQL-backed config store. Real breadth.

WHAT IS MISSING / ROUGH (from PLATFORM-PLAN.md + memory, the authoritative direction docs):

- Zero-downtime deploy (rolling/readiness/drain/backpressure -- Workstream C Tier 1) is IN PROGRESS, not done; the acceptance slice (`acceptance/slice.sh`, 7 checks) was mid-flight (3/7 at last pause).
- CRITICAL known defect (memory): live CAS is not atomic → split-brain risk; mitigated only by running a SINGLE orchd (off the critical path). That is a correctness gap, not a polish gap.
- `webui/` untracked and does not build (memory). HA across multiple orchd is not real yet.

### B.4 NovaDB (`novadb/`) -- GAP: separate project; substantial engine, integration is the soft edge.

LOCATED locally (though a separate project with its own CLAUDE.md/gate). 59,513 Zig lines total, 25,552 in `src/`. The engine is real: `storage/btree.zig` (1108) + `storage/page.zig` + `storage/pool.zig` (segmented pool), `durability/write_ahead_log.zig` (636), `query/query_executor.zig` (3295), `query/iterator.zig` (1228), `query/replication.zig` (1585), `sql/{lexer,parser(1213),ast}`, `schema/{database(3144),table,row,types}`, `proto/{wire,session,protocol}` (binary protocol), `concurrency/security.zig`. Memory confirms MVCC, per-tree structure lock, per-table group lock, and a fixed kill-9 recovery bug.

I did NOT audit correctness. From memory + the CLAUDE binary-protocol note, the honest reads:

- The binary wire protocol is self-described as "naive"; the driver on the Kyte side (`nova-novadb`, 1105 lines) is likewise "too naive" per project notes.
- SQL92 coverage has known defects (PLATFORM-PLAN Workstream B: SQL92 defects + expression engine); e.g. no SQL `IN` historically (memory `btree-d-rows-progress`).
- End-to-end Kyte-app-on-NovaDB-relational is the whole point of the PLATFORM-PLAN slice and was not yet certified.

DEEP DESIGN FOR NOVADB NEEDS ITS OWN REPO/PASS. I only structurally surveyed it.

---

## PART C -- DESIGN TO CLOSE

### In-repo, concrete plans

LSP (confidence: HIGH for the additive features, MEDIUM for precision):

1. Add the cheap missing capabilities first -- `documentHighlight`, `foldingRange`, `selectionRange`, `semanticTokens/range` -- these are pure AST walks, low risk, high perceived polish.
2. Build a workspace/project index: on init, scan the project's `.ky` files (respecting `project.json` + resolved imports from `~/.kyte/cache`), parse once, keep a symbol table keyed by module. This unlocks cross-file go-to-def/references/rename and turns diagnostics import-aware. MEDIUM effort; the main unknown is running import resolution without pulling codegen in.
3. Incremental sync + reparse caching to stop re-typechecking the whole file per keystroke.
4. Precision: reuse more of `sema/` (infer only, not mono/codegen) inside completion to replace the lightweight env. HIGHEST risk (that is exactly what nls avoided); gate behind a flag.

Formatter (confidence: HIGH): add an explicit idempotency test to the corpus, a stress comment-reinjection corpus, and optional style config (line width). Low risk; the token-stream guard already protects meaning.

Package manager (confidence: MEDIUM -- this is real design work):

1. Add version pinning: allow `{url, ref}` (tag/branch/commit) in `dependencies`, clone that ref (drop blind `--depth 1` HEAD).
2. Write a lockfile (`project.lock.json`) recording the resolved commit SHA + a content hash per dependency; `restore` honours the lock, `update` re-resolves.
3. Walk transitive deps (read each fetched dep's `project.json`), build a dependency graph, detect conflicts. UNKNOWN: conflict policy without semver (git URLs alone can't express "compatible range") -- may need to introduce version tags as the constraint language.
4. Fix the cache key (hash the full URL, not the repo name) to remove collisions, and reconcile the `packages/` vs `~/.kyte/cache` shadowing (memory-flagged).
   This is genuinely multi-day and is the single highest-leverage tooling investment for "beta-adequate".

Debugger (confidence: MEDIUM-LOW, LARGE effort): the pragmatic path is DWARF, not a bespoke DAP. Step 1: emit debug info from codegen via LLVM's DIBuilder (compile units, subprograms, line tables, local variable locations). That alone makes `lldb`/`gdb` work at source level. Step 2: a thin DAP shim (or lean on VS Code's C/C++/CodeLLDB adapter over the emitted DWARF). UNKNOWN: ARC and coroutine-split frames make variable/lifetime mapping hard -- stepping through `async` will be confusing without extra work. A "beta-adequate" first cut is line-level stepping + backtraces via DWARF; full variable inspection is a follow-on.

### Separate-repo pieces -- HIGH-LEVEL plan only (deep design needs those repos' own passes)

- DB drivers: harden multi-connection/pool concurrency (close the mongo c>1 crash), widen type/auth/TLS coverage, and get driver cases into a CI that can spin ephemeral DBs (testcontainers-style) so they stop being un-runnable from a bare clone. NOTE: deep per-driver design needs each driver's wire-protocol audit.
- Orchestrator: finish Workstream C Tier 1 (rolling/readiness/drain/backpressure) to pass `acceptance/slice.sh` 7/7; then fix the non-atomic CAS split-brain before allowing >1 orchd. NOTE: this is tracked in `PLATFORM-PLAN.md`; deep design lives there.
- NovaDB: replace the "naive" binary protocol + driver with a versioned, framed protocol; close SQL92 defects + finish the expression engine; certify the app-on-NovaDB-relational slice. NOTE: NovaDB is a separate project -- deep design needs a dedicated pass in `novadb/` with its own execution-plan.

---

## PART D -- RISK + EFFORT (labelled GUESSES)

| Piece | Maturity now | Effort to beta-adequate | Risk |
|---|---|---|---|
| LSP additive features | 65% | ~1 week | LOW |
| LSP project/precision | 65% | ~2-3 weeks | MEDIUM (codegen coupling) |
| Formatter | 80% | ~2-3 days | LOW |
| Package manager | 30% | ~1-2 weeks (lockfile+versions+transitive) | MEDIUM (constraint language) |
| Debugger | 0% | multi-week (DWARF), months (full DAP + async) | HIGH |
| VS Code extension | 50% | rides on LSP + debugger | LOW |
| DB drivers | 60% | days-to-weeks per hardening item | MEDIUM (concurrency, live-DB CI) |
| Web framework | 65% | weeks (fix dogfood bugs, breadth) | MEDIUM |
| Orchestrator | 55% | weeks (Tier 1 + CAS) | HIGH (split-brain) |
| NovaDB | separate | months (protocol + SQL + integration) | HIGH |

All effort figures are single-developer guesses from code size and known-defect lists, not measured.

---

## PART E -- VERIFY: what "beta-adequate tooling/ecosystem" is measured by

Tooling:

- LSP: go-to-def and find-references work ACROSS files (not just open buffers), on a real multi-module project; diagnostics match `kyte build` errors including import errors; completion offers correct members after `.` on a typed receiver. Measure by scripting LSP stdio requests over the flagship app and diffing against compiler output.
- Formatter: `kyte fmt` is idempotent on the whole conformance corpus (`fmt(fmt(x)) == fmt(x)`), never changes the token stream, and preserves every comment. Measure by a corpus gate.
- Package manager: a lockfile makes two clean machines resolve byte-identical dependency trees from the same manifest; transitive deps resolve; `kyte get` pins a version. Measure by a reproducibility test (clone → build → compare SHAs) in CI.
- Debugger: a breakpoint in a `.ky` file is hit, the call stack shows Kyte frames with source lines, and a local variable can be inspected. Measure by a scripted lldb/DAP session on a sample app.

Ecosystem:

- Drivers: each driver passes an integration suite against a live server in CI (ephemeral container), including concurrency (c=50) and a prepared-statement/type-coverage matrix, with zero crashes.
- Web framework: the flagship app builds and serves under load (the existing oha throughput gate) with the middleware pipeline exercised, and the known dogfood bugs (SSE-morph binding, stored-closure SIGSEGV) are closed with regression tests.
- Orchestrator: `acceptance/slice.sh` passes 7/7 -- zero-downtime rolling deploy of the web-app-on-NovaDB slice, N single-threaded replicas, verified by the harness; no split-brain under the single-orchd model.
- NovaDB: the app-on-NovaDB-relational slice is certified end-to-end (the PLATFORM-PLAN acceptance bar), with a versioned binary protocol and the SQL92 defect list closed.

Headline: tooling is a well-built LSP + formatter sitting next to a git-clone-wrapper "package manager" and a complete absence of any debugger or debug info; ecosystem is broad-but-rough (real drivers, a real web framework, a real orchestrator, a real DB engine) with the integration seams (protocol maturity, zero-downtime deploy, cross-machine reproducibility, multi-connection robustness) being the honest soft edges.
