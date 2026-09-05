//! Process entry point for the `kyte` compiler driver.
//!
//! This file is deliberately tiny: it is nothing but the `main` shim that Zig's
//! runtime calls, and every ounce of real work lives in [`cli.run`] (argument
//! parsing, sub-command dispatch, compilation, and linking). Keeping `main`
//! this thin means the driver logic stays testable and reusable, since
//! [`cli.run`] takes an explicit `std.process.Init` rather than reaching for
//! process globals.
//!
//! The only behaviour this file owns is the top-level error presentation. A
//! Kyte program that fails to compile should exit with a clean, red `error:`
//! line and status 1, NOT a Zig stack trace with an internal error tag. So
//! `main` catches whatever [`cli.run`] propagates and asks
//! [`cli.userErrorHint`] whether that error is a recognised user-facing
//! compilation failure. If it is, we print the hint (or nothing, for errors
//! that already emitted their own diagnostics) and exit 1. If it is not a
//! recognised user error, we re-`return` it, letting the Zig runtime surface it
//! as the genuine internal bug it represents. This split is what separates
//! "your code is wrong" from "the compiler is wrong" in the exit behaviour.

/// Zig standard library, used here only for `std.process.Init`, `std.debug.print`
/// and `std.process.exit`.
const std = @import("std");
/// The compiler driver proper: see [`cli.run`] for dispatch and
/// [`cli.userErrorHint`] for the user-facing error wording.
const cli = @import("cli.zig");

/// Process entry point invoked by the Zig runtime.
///
/// Delegates all work to [`cli.run`] and shapes how a failure is reported. On a
/// recognised user-facing error (one for which [`cli.userErrorHint`] returns
/// non-`null`), it prints a bold red `error:` line with the hint, suffixed
/// "(compilation failed)", and exits with status 1. A non-empty hint is
/// printed; an empty hint (the error already printed its own detailed
/// diagnostics, e.g. type-check or parser errors) is suppressed but still exits
/// 1. Any error [`cli.userErrorHint`] does not recognise is re-returned so the
/// Zig runtime reports it as an internal compiler fault rather than
/// masquerading as user error.
///
/// Takes `init` by value so the entire driver can run against an explicit
/// process environment instead of hidden globals; it is threaded straight
/// through to [`cli.run`].
pub fn main(init: std.process.Init) !void {
    cli.run(init) catch |e| {
        if (cli.userErrorHint(e)) |hint| {
            if (hint.len > 0) {
                std.debug.print("\x1b[1m\x1b[31merror:\x1b[0m\x1b[1m {s}\x1b[0m (compilation failed)\n", .{hint});
            }
            std.process.exit(1);
        }
        return e;
    };
}
