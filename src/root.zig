//! Root module of the Nova compiler crate: the single Zig import surface that
//! re-exports the frontend pipeline and anchors the test tree.
//!
//! In Zig, one file is the crate's root (its `root_source_file`), and every
//! other module in the compiler is reached transitively through the declarations
//! it re-exports. This file plays that role. It has two distinct jobs:
//!
//!   1. **Namespacing.** It gives the rest of the codebase (and any embedder
//!      that depends on the compiler as a library) a single stable place to
//!      reach the frontend passes by name: `root.parser`, `root.sema`,
//!      `root.mono`, and so on. The `pub const X = @import("…")` lines below are
//!      not just imports; because they are `pub`, they are the public API of the
//!      crate. Callers write `@import("root").sema` rather than reaching into the
//!      `frontend/sema/…` directory layout, so the on-disk structure can move
//!      without breaking dependents.
//!
//!   2. **Test aggregation.** The `test {}` block is what `zig build test`
//!      discovers and runs. `std.testing.refAllDecls(@This())` forces every
//!      declaration reachable from this file to be referenced (and thus
//!      semantically analysed and its `test` blocks collected), and the explicit
//!      `_ = @import(…)` lines pull in modules that are NOT re-exported above but
//!      still carry tests we want run, most notably the backend codegen passes
//!      (`backend/codegen/*`) and the OSSA ownership-IR passes
//!      (`frontend/sema/ossa/*`). Without an explicit reference a module with no
//!      dependents would never be analysed, so its tests would silently not run.
//!
//! The ordering of the re-exports mirrors the compilation pipeline: lexing and
//! parsing produce the [`ast`], the [`types`] module defines the type
//! representation, and the [`sema`] passes (symbol resolution, inference,
//! monomorphisation, ownership) lower that AST into the authoritative typed IR
//! the backend consumes. Keeping them in pipeline order here is documentation in
//! itself.

const std = @import("std");
/// Alias for `std.Io`, the standard library's I/O abstraction namespace.
///
/// Present so that declarations in this crate can refer to the I/O interfaces
/// through a short local name; it does not itself pull in any compiler module.
const Io = std.Io;

/// The Nova source parser: turns a token stream into the [`ast`] tree.
///
/// Re-exported here as part of the frontend surface; the parser is the second
/// pipeline stage after [`lexer`].
pub const parser = @import("frontend/parser.zig");
/// The source formatter (`nova fmt`): pretty-prints an [`ast`] back to canonical
/// Nova source, so it is the inverse direction of [`parser`].
pub const formatter = @import("frontend/formatter.zig");
/// Abstract syntax tree node definitions produced by [`parser`] and consumed by
/// the [`sema`] passes and the [`formatter`].
pub const ast = @import("frontend/ast.zig");
/// The lexer: the first pipeline stage, tokenising raw Nova source text for
/// [`parser`].
pub const lexer = @import("frontend/lexer.zig");
/// The legacy/standalone type checker.
///
/// The authoritative typed-IR path now lives under the [`sema`] passes, but this
/// checker is still part of the public surface and cross-checked against them
/// (see [`shadow`]).
pub const type_checker = @import("frontend/type_checker.zig");

/// The type representation shared across the frontend: how Nova types are modelled
/// in the compiler, consumed by [`infer`], [`mono`], and code generation.
pub const types = @import("frontend/types.zig");

/// Symbol tables and name resolution: binds identifiers to their declarations,
/// the first of the [`sema`] passes.
pub const symbols = @import("frontend/sema/symbols.zig");
/// Lowering from the surface [`ast`] into the typed intermediate representation
/// the later sema passes and the backend operate on.
pub const lower = @import("frontend/sema/lower.zig");
/// Type inference: assigns concrete types to expressions, filling in what the
/// programmer left implicit.
pub const infer = @import("frontend/sema/infer.zig");
/// Definitions of the compiler's built-in functions and types, made visible to
/// [`infer`] and name resolution.
pub const builtins = @import("frontend/sema/builtins.zig");
/// Alpha-renaming: gives bindings module-unique names so that same-named
/// declarations across modules (and shadowed locals) never collide downstream.
pub const alpha = @import("frontend/sema/alpha.zig");
/// Stable identifier allocation used across the sema passes (node/type/symbol
/// ids), keeping references compact and comparable.
pub const ids = @import("frontend/sema/ids.zig");
/// Type substitution: applies a type-variable → type mapping, the mechanism
/// generic instantiation and inference unification rely on.
pub const subst = @import("frontend/sema/subst.zig");
/// The semantic-analysis driver that sequences the individual sema passes into
/// the authoritative typed-IR result.
pub const sema = @import("frontend/sema/sema.zig");
/// Monomorphisation: instantiates generics into concrete specialisations
/// (`List<int>` → `List_int_*`) rather than erasing them; mandatory in this
/// compiler, see the crate design notes.
pub const mono = @import("frontend/sema/mono.zig");
/// The shadow-typing harness: runs an alternate type engine alongside the
/// primary one and diffs the results (enabled via `NOVA_SEMA_SHADOW`) to catch
/// divergences between the two.
pub const shadow = @import("frontend/sema/shadow.zig");

// Root test aggregator: the entry point `zig build test` executes.
//
// [`std.testing.refAllDecls`] forces every declaration re-exported above to be
// analysed so their `test` blocks are collected. The explicit `_ = @import(…)`
// lines then pull in modules that are NOT part of the public surface above but
// whose tests must still run, chiefly the backend codegen passes and the OSSA
// ownership-IR passes; an unreferenced module would never be analysed and its
// tests would silently be skipped. Some frontend modules are listed both here
// and above, which is harmless: a module analysed twice is deduplicated.
test {
    std.testing.refAllDecls(@This());

    _ = @import("frontend/types.zig");

    _ = @import("backend/codegen/types.zig");
    _ = @import("backend/codegen/arc.zig");

    _ = @import("frontend/sema/symbols.zig");
    _ = @import("frontend/sema/lower.zig");
    _ = @import("frontend/sema/infer.zig");
    _ = @import("frontend/sema/builtins.zig");
    _ = @import("frontend/sema/alpha.zig");
    _ = @import("frontend/sema/ids.zig");
    _ = @import("frontend/sema/subst.zig");
    _ = @import("frontend/sema/sema.zig");
    _ = @import("frontend/sema/mono.zig");
    _ = @import("frontend/sema/shadow.zig");
    _ = @import("frontend/sema/ossa/ir.zig");
    _ = @import("frontend/sema/ossa/verify.zig");
    _ = @import("frontend/sema/ossa/lower.zig");
    _ = @import("frontend/sema/ossa/forward.zig");

    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/ast.zig");
    _ = @import("frontend/formatter.zig");

    _ = @import("semver.zig");
    _ = @import("registry.zig");

}
