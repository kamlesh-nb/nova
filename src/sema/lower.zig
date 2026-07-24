// lower.zig — F2 stage 2: the bridge from SYNTAX to the type system.
//
// `ast.TypeRef` carries names only (ast.zig:165) — no resolved info, no decl
// pointer, no symbol id. It is exactly what the parser saw. Codegen currently
// flattens it to TEXT with `typeRefToString` (codegen/types.zig:125) and then
// RE-PARSES that text with string surgery (`indexOfScalar(t, '<')`,
// `splitSequence(", ")`). The round-trip is not even self-consistent: generics are
// emitted with `", "` and tuples with `","`, while substituteGenericType splits on
// `", "`.
//
// This lowers a TypeRef to a `TypeId` ONCE, against the symbol table, and never
// looks at the spelling again.
//
// STAGE 2 IS SHADOW MODE. Nothing consumes this yet. It runs under
// NOVA_SEMA_SHADOW=1 and reports how much of a program's declared type surface can
// actually be typed — the honest measure of what F2 can carry today, and the input
// that decides stage 4's cutover. Same discipline as F1's three cutovers: build the
// truth alongside the lie, diff, then move.
//
// T4 is load-bearing here. When a TypeRef cannot be lowered, this returns
// `.unresolved` — a real, distinct type — NOT `int`. Today's inference returns the
// STRING "i32" on failure, and `i32` IS the universal machine word, so a failure is
// indistinguishable from a correct answer. That is the difference between a
// compiler that knows what it doesn't know and one that doesn't.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const symbols = @import("symbols.zig");

pub const TypeId = types.TypeId;

pub const Stats = struct {
    lowered: usize = 0,
    unresolved: usize = 0,
    /// Names that could not be lowered, for the shadow report. Not owned.
    unresolved_names: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.unresolved_names.deinit(allocator);
    }
};

/// A type-parameter scope: which declaration owns these names.
pub const ParamScope = struct {
    owner: types.SymbolId,
    names: []const []const u8,
};

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    store: *types.TypeStore,
    /// Type parameters visible in the current declaration, in order. `T` is looked
    /// up HERE, by position — never detected as "a string of length 1 that is an
    /// uppercase letter" (arc.zig:13, the only such test in codegen today).
    /// The type parameters in scope, OUTERMOST first.
    ///
    /// A method's params and its struct's are DIFFERENT declarations that merely
    /// nest: in `struct List<T> { fn map<U>(...) }` (list.nova:123), T is {List, 0}
    /// and U is {map, 0} — each index 0 of its own declaration. Merging them into
    /// one list under one owner made U into {List, 1}, an index List does not have,
    /// so it never substituted and stayed unresolved.
    ///
    /// A list rather than a single {owner, names}: one owner cannot describe two
    /// declarations, and lookup must go INNERMOST-first so an inner `T` shadows an
    /// outer one instead of silently resolving to it.
    ///
    /// Empty by default and there is no default owner: a param reached with no
    /// scope is `.unresolved` and counted in `orphan_params`, never quietly owned
    /// by symbol 0. That default is what collapsed every generic's T onto one
    /// TypeId, and it was invisible because symbol 0 looks like a real symbol.
    param_scopes: []const ParamScope = &.{},

    /// F1's symbol table. This is the F1<->F2 join: without it a named type has
    /// nothing to resolve AGAINST, and `.ident "Stats"` can only be `.unresolved`.
    /// Measured before wiring it (ycsb.nova): 83 of 563 declared types unresolved,
    /// and all 16 distinct names were struct types.
    symtab: ?*const symbols.SymbolTable = null,
    /// F1 module-scoped types: the module whose scope a bare type name is resolved in, so `Widget` in
    /// module a lowers to a's Widget (see findTypeInModule). Set by the inferer alongside its own
    /// current_module; null falls back to the global first-match.
    current_module: ?symbols.ModuleId = null,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, store: *types.TypeStore) Lowerer {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn deinit(self: *Lowerer) void {
        self.stats.deinit(self.allocator);
    }

    fn unresolved(self: *Lowerer, name: []const u8) !TypeId {
        self.stats.unresolved += 1;
        try self.stats.unresolved_names.append(self.allocator, name);
        return self.store.unresolvedT();
    }

    /// The primitive table. F3 §3.1 is the TARGET (`int` = 32 bits everywhere);
    /// this lowers to that target, so the widths here are honest even though
    /// codegen still maps them all onto one machine word. That gap is exactly what
    /// F3 closes, and having the honest table already expressed is what lets F3 be
    /// a change of *representation* rather than a change of meaning.
    fn prim(self: *Lowerer, name: []const u8) !?TypeId {
        const T = struct { n: []const u8, k: types.PrimKind, b: u16, s: bool };
        const table = [_]T{
            .{ .n = "bool", .k = .bool, .b = 1, .s = false },
            .{ .n = "byte", .k = .int, .b = 8, .s = false },
            .{ .n = "ubyte", .k = .int, .b = 8, .s = false },
            .{ .n = "u8", .k = .int, .b = 8, .s = false },
            .{ .n = "sbyte", .k = .int, .b = 8, .s = true },
            .{ .n = "i8", .k = .int, .b = 8, .s = true },
            .{ .n = "short", .k = .int, .b = 16, .s = true },
            .{ .n = "i16", .k = .int, .b = 16, .s = true },
            .{ .n = "ushort", .k = .int, .b = 16, .s = false },
            .{ .n = "u16", .k = .int, .b = 16, .s = false },
            .{ .n = "int", .k = .int, .b = 32, .s = true },
            .{ .n = "i32", .k = .int, .b = 32, .s = true },
            .{ .n = "uint", .k = .int, .b = 32, .s = false },
            .{ .n = "u32", .k = .int, .b = 32, .s = false },
            .{ .n = "long", .k = .int, .b = 64, .s = true },
            .{ .n = "i64", .k = .int, .b = 64, .s = true },
            .{ .n = "ulong", .k = .int, .b = 64, .s = false },
            .{ .n = "u64", .k = .int, .b = 64, .s = false },
            .{ .n = "float", .k = .float, .b = 32, .s = true },
            .{ .n = "f32", .k = .float, .b = 32, .s = true },
            .{ .n = "double", .k = .float, .b = 64, .s = true },
            .{ .n = "f64", .k = .float, .b = 64, .s = true },
            .{ .n = "void", .k = .void_, .b = 0, .s = false },
        };
        for (table) |e| {
            if (std.mem.eql(u8, name, e.n)) {
                return try self.store.intern(.{ .prim = .{ .kind = e.k, .bits = e.b, .signed = e.s } });
            }
        }
        return null;
    }

    /// Resolve a type-param name to {owner, index}, INNERMOST scope first so an
    /// inner declaration's `T` shadows an outer one rather than resolving to it.
    fn typeParamRef(self: *Lowerer, name: []const u8) ?types.TypeParam {
        var i = self.param_scopes.len;
        while (i > 0) {
            i -= 1;
            const sc = self.param_scopes[i];
            for (sc.names, 0..) |p, idx| {
                if (std.mem.eql(u8, p, name)) {
                    return .{ .owner = sc.owner, .index = @intCast(idx) };
                }
            }
        }
        return null;
    }

    pub fn lower(self: *Lowerer, tr: ast.TypeRef) anyerror!TypeId {
        switch (tr) {
            // specs §3.4b. `ok` may itself be `.optional` — that is `T | E | undefined`.
            .error_union => |eu| {
                const ok = try self.lower(eu.ok.*);
                const err = try self.lower(eu.err.*);
                self.stats.lowered += 1;
                return try self.store.intern(.{ .error_union = .{ .ok = ok, .err = err } });
            },
            .ident => |name| {
                if (try self.prim(name)) |p| {
                    self.stats.lowered += 1;
                    return p;
                }
                if (std.mem.eql(u8, name, "string")) {
                    self.stats.lowered += 1;
                    return self.store.stringT();
                }
                if (std.mem.eql(u8, name, "decimal")) {
                    self.stats.lowered += 1;
                    return self.store.decimalT();
                }
                if (std.mem.eql(u8, name, "ptr")) {
                    self.stats.lowered += 1;
                    return self.store.ptrT();
                }
                // A generic parameter — by POSITION in the declaration, not by
                // being a single uppercase letter.
                if (self.typeParamRef(name)) |tp| {
                    self.stats.lowered += 1;
                    return self.store.intern(.{ .type_param = tp });
                }
                // A named type: struct / enum / trait. Resolved against the symbol
                // table — a real decl identity, not a string that later gets
                // `getStructBaseName`'d back into a bare name at every lookup.
                if (self.symtab) |st| {
                    if (st.findTypeInModule(name, self.current_module)) |sid| {
                        self.stats.lowered += 1;
                        return switch (st.symbolAt(sid).kind) {
                            .enum_ => try self.store.intern(.{ .enum_ = sid }),
                            .trait_ => try self.store.intern(.{ .trait_ = sid }),
                            else => try self.store.intern(.{ .struct_ = .{ .decl = sid } }),
                        };
                    }
                }
                // `any` is the opaque, word-sized, dynamically-typed value (§3.5). Lower it to `.ptr`
                // — the honest "opaque, explicitly UNOWNED word" — NOT `.unresolved`. Two reasons:
                // (1) As `.unresolved` it could not be a CONTAINER ELEMENT: `Map<string, any>` →
                //     `Storage<any>` gave a `.unresolved` element, and the storage slot-release ownership
                //     decision (arc.zig `buildStorageSlotReleaseByTypeId` → isOwnedTypeId) hit the F2-5
                //     `.unresolved` tripwire and ABORTED the compile (even a bare construct+set did).
                // (2) The ownership answer is IDENTICAL either way — an opaque value is non-owned (a
                //     container can't ARC a value whose type it can't see; whoever downcasts it with
                //     `v as T` owns it). So `.ptr` (explicitly non-owned) matches the old `.unresolved`
                //     fallback exactly, while being a RESOLVED type the ownership tripwire accepts.
                // `.ptr` is NOT an int, so the original "not quietly an int" intent is preserved.
                if (std.mem.eql(u8, name, "any")) {
                    self.stats.lowered += 1;
                    return self.store.ptrT();
                }
                return self.unresolved(name);
            },
            .optional => |inner| {
                const id = try self.lower(inner.*);
                self.stats.lowered += 1;
                return self.store.intern(.{ .optional = id });
            },
            .func => |f| {
                const params = try self.allocator.alloc(TypeId, f.params.len);
                defer self.allocator.free(params);
                for (f.params, 0..) |p, i| params[i] = try self.lower(p);
                const ret = try self.lower(f.ret.*);
                self.stats.lowered += 1;
                // A function is a TYPE. `indexOf(name, "=>")` (arc.zig:19) is not
                // expressible against this.
                return self.store.intern(.{ .func = .{ .params = params, .ret = ret } });
            },
            .tuple => |items| {
                const elems = try self.allocator.alloc(TypeId, items.len);
                defer self.allocator.free(elems);
                for (items, 0..) |it, i| elems[i] = try self.lower(it);
                self.stats.lowered += 1;
                return self.store.intern(.{ .tuple = elems });
            },
            .fixed_array => |fa| {
                const elem = try self.lower(fa.element.*);
                self.stats.lowered += 1;
                return self.store.intern(.{ .array = .{ .elem = elem, .len = fa.length } });
            },
            .generic => |g| {
                const args = try self.allocator.alloc(TypeId, g.params.len);
                defer self.allocator.free(args);
                for (g.params, 0..) |p, i| args[i] = try self.lower(p);
                // `Storage<T>` is a PRIMITIVE (specs.md §3.8): it has no declaration
                // to resolve against, so it is lowered here rather than looked up.
                // Without this it resolves to nothing and every `self.data` is
                // untyped — which is exactly how it first failed.
                if (std.mem.eql(u8, g.name, "Storage") and args.len == 1) {
                    self.stats.lowered += 1;
                    return try self.store.intern(.{ .storage = args[0] });
                }
                // A1: `future<T>` is a PRIMITIVE type (specs §7.1) — the handle `go`/`spawn` yields.
                // No declaration to resolve against, so lower it here (like Storage). This makes it
                // first-class: storable in `List<future<T>>`, an explicit annotation, etc. The store
                // already knows `.future` is a bare i64 handle (non-owned), so ARC leaves it alone.
                if (std.mem.eql(u8, g.name, "future") and args.len == 1) {
                    self.stats.lowered += 1;
                    return try self.store.intern(.{ .future = args[0] });
                }
                // `List<string>` becomes `.struct_{decl, args}` — DISTINCT from
                // `List<int>`. That is F4's precondition, and the thing
                // getStructBaseName (codegen/types.zig:9) destroys today by
                // stripping `<...>` at every lookup, which is why every generic
                // instantiation collapses onto one body and one destructor.
                if (self.symtab) |st| {
                    if (st.findType(g.name)) |sid| {
                        self.stats.lowered += 1;
                        // A GENERIC TRAIT object (`Beh<int>`) is a `.trait_`, NOT a `.struct_` — the
                        // trait's vtable is SHARED across instantiations (constructTraitObject stores
                        // it under the base name `_vtable_Struct_Beh`), so dispatch erases the type
                        // arg. Interning it as `.struct_{decl: <trait>}` here (the old code, applied
                        // unconditionally) sent methodReturn down the struct-method path — which finds
                        // no method on a trait symbol — so `let r = obj.recv(x)` was left UNTYPED and
                        // `${r}` derefed the int as a string pointer (SIGSEGV). Mirror the `.ident`
                        // arm's kind switch. Enums are not generic today, but handle them uniformly.
                        return switch (st.symbolAt(sid).kind) {
                            .trait_ => try self.store.intern(.{ .trait_ = sid }),
                            .enum_ => try self.store.intern(.{ .enum_ = sid }),
                            else => try self.store.intern(.{ .struct_ = .{ .decl = sid, .args = args } }),
                        };
                    }
                }
                return self.unresolved(g.name);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests. See docs/design/README.md §2b — every bug fixed on 2026-07-15 lived in an
// untested pure function.
// ---------------------------------------------------------------------------
const testing = std.testing;

fn mk(store: *types.TypeStore) Lowerer {
    return Lowerer.init(testing.allocator, store);
}

test "lower: primitives carry their TARGET width and signedness" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    // int is 32 bits (F3's target), long is 64 — and they are DISTINCT, which the
    // current compiler cannot express: types.zig:42 maps i32/u32/int/uint all onto
    // one val_type that is i64 on native.
    try testing.expect(try l.lower(.{ .ident = "int" }) != try l.lower(.{ .ident = "long" }));
    // ...and `int` and `i32` are the same type, honestly this time.
    try testing.expectEqual(try l.lower(.{ .ident = "int" }), try l.lower(.{ .ident = "i32" }));
    // unsigned is unsigned
    try testing.expect(try l.lower(.{ .ident = "uint" }) != try l.lower(.{ .ident = "int" }));
    try testing.expect(try l.lower(.{ .ident = "u64" }) != try l.lower(.{ .ident = "i64" }));
    // float widths are distinct
    try testing.expect(try l.lower(.{ .ident = "float" }) != try l.lower(.{ .ident = "double" }));
    try testing.expectEqual(try l.lower(.{ .ident = "double" }), try l.lower(.{ .ident = "f64" }));
}

test "lower: string and ptr are distinct, and neither is an int" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    const str = try l.lower(.{ .ident = "string" });
    const p = try l.lower(.{ .ident = "ptr" });
    const int = try l.lower(.{ .ident = "int" });
    try testing.expect(str != p);
    try testing.expect(p != int); // `data: i32` is a lie this makes inexpressible
    try testing.expect(store.isOwned(str));
    try testing.expect(!store.isOwned(p)); // ptr is explicitly unowned (F5 O2)
}

test "T4: an unknown type lowers to unresolved — NOT to int" {
    // The bug: resolveExpressionTypeName returns "i32" on failure, and i32 IS the
    // machine word, so "I don't know" and "it's an int" are the same value.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    const unk = try l.lower(.{ .ident = "NoSuchType" });
    try testing.expect(store.get(unk) == .unresolved);
    try testing.expect(unk != try l.lower(.{ .ident = "int" }));
    try testing.expectEqual(@as(usize, 1), l.stats.unresolved);
}

test "lower: a type param resolves by POSITION, not by being one uppercase letter" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    // struct Foo<A, B> — the letters are arbitrary. substitutePlaceholders
    // (llvm_codegen.zig:2345) hardcodes T/K/V/U and gives Foo<A,B> NO substitution
    // at all; here A and B are simply params 0 and 1.
    // Params need a declaration to belong to.
    const foo = [_]ParamScope{.{ .owner = @enumFromInt(1), .names = &.{ "A", "B" } }};
    l.param_scopes = &foo;
    const a = try l.lower(.{ .ident = "A" });
    const b = try l.lower(.{ .ident = "B" });
    try testing.expect(a != b);
    try testing.expect(store.get(a).type_param.index == 0);
    try testing.expect(store.get(b).type_param.index == 1);
    // A name that is NOT a declared param is unresolved, even if it looks like one.
    const t = try l.lower(.{ .ident = "T" });
    try testing.expect(store.get(t) == .unresolved);
}

test "lower: a function type is structural — arity and return matter" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var int_ref = ast.TypeRef{ .ident = "int" };
    var str_ref = ast.TypeRef{ .ident = "string" };
    var one_param = [_]ast.TypeRef{.{ .ident = "int" }};
    const f1 = try l.lower(.{ .func = .{ .params = &one_param, .ret = &int_ref } });
    const f2 = try l.lower(.{ .func = .{ .params = &one_param, .ret = &str_ref } });
    try testing.expect(f1 != f2);
    // A closure box is OWNED — arc.zig:19-20 hardcodes false for anything whose
    // NAME contains "=>", which is §10 #15's ~46 B/closure leak.
    try testing.expect(store.isOwned(f1));
}

test "lower: optionals wrap, and ownership follows the inner type" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var str_ref = ast.TypeRef{ .ident = "string" };
    var int_ref = ast.TypeRef{ .ident = "int" };
    const opt_str = try l.lower(.{ .optional = &str_ref });
    const opt_int = try l.lower(.{ .optional = &int_ref });
    try testing.expect(opt_str != opt_int);
    try testing.expect(store.isOwned(opt_str));
    try testing.expect(!store.isOwned(opt_int));
}

test "lower: tuples and arrays are structural" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    var ab_items = [_]ast.TypeRef{ .{ .ident = "int" }, .{ .ident = "string" } };
    var ba_items = [_]ast.TypeRef{ .{ .ident = "string" }, .{ .ident = "int" } };
    const ab = try l.lower(.{ .tuple = &ab_items });
    const ba = try l.lower(.{ .tuple = &ba_items });
    try testing.expect(ab != ba); // (a,b) != (b,a)

    var elem = ast.TypeRef{ .ident = "int" };
    const a4 = try l.lower(.{ .fixed_array = .{ .element = &elem, .length = 4 } });
    const a8 = try l.lower(.{ .fixed_array = .{ .element = &elem, .length = 8 } });
    try testing.expect(a4 != a8); // length is part of the type
}

test "stats count what could NOT be typed — the honest F2 signal" {
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();
    _ = try l.lower(.{ .ident = "int" });
    _ = try l.lower(.{ .ident = "string" });
    _ = try l.lower(.{ .ident = "Mystery" });
    try testing.expectEqual(@as(usize, 2), l.stats.lowered);
    try testing.expectEqual(@as(usize, 1), l.stats.unresolved);
    try testing.expectEqualStrings("Mystery", l.stats.unresolved_names.items[0]);
}

// ---- the F1<->F2 join: named types resolve against the symbol table ---------

test "join: a named type resolves to a struct decl, not unresolved" {
    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var tab = symbols.SymbolTable.init(a);
    defer tab.deinit();

    // Two struct decls, as the symbol table would hold them.
    var decls = [_]ast.Declaration{
        .{ .struct_decl = .{
            .name = "Stats",
            .fields = &.{},
            .methods = &.{},
            .attributes = &.{},
            .impls = &.{},
            .is_public = true,
            .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "m.nova" },
        } },
        .{ .struct_decl = .{
            .name = "List",
            .fields = &.{},
            .methods = &.{},
            .attributes = &.{},
            .impls = &.{},
            .is_public = true,
            .span = .{ .start = 0, .end = 0, .line = 2, .col = 1, .file = "m.nova" },
        } },
    };
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "root.nova" } });

    var l = Lowerer.init(a, &store);
    defer l.deinit();
    l.symtab = &tab;

    const stats = try l.lower(.{ .ident = "Stats" });
    try testing.expect(store.get(stats) == .struct_);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);
    // ...and a struct IS owned, decided from the TYPE (F5 O2)
    try testing.expect(store.isOwned(stats));
    // an unknown name is still honestly unresolved
    const nope = try l.lower(.{ .ident = "NoSuchStruct" });
    try testing.expect(store.get(nope) == .unresolved);
}

test "join: F4's precondition holds on real decls — List<string> != List<int>" {
    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var tab = symbols.SymbolTable.init(a);
    defer tab.deinit();
    var decls = [_]ast.Declaration{.{ .struct_decl = .{
        .name = "List",
        .fields = &.{},
        .methods = &.{},
        .attributes = &.{},
        .impls = &.{},
        .is_public = true,
        .span = .{ .start = 0, .end = 0, .line = 1, .col = 1, .file = "m.nova" },
    } }};
    try tab.build(.{ .declarations = &decls, .span = .{ .start = 0, .end = 0, .line = 0, .col = 0, .file = "root.nova" } });

    var l = Lowerer.init(a, &store);
    defer l.deinit();
    l.symtab = &tab;

    var str_args = [_]ast.TypeRef{.{ .ident = "string" }};
    var int_args = [_]ast.TypeRef{.{ .ident = "int" }};
    const list_str = try l.lower(.{ .generic = .{ .name = "List", .params = &str_args } });
    const list_int = try l.lower(.{ .generic = .{ .name = "List", .params = &int_args } });

    // The distinction getStructBaseName (codegen/types.zig:9) destroys today by
    // stripping `<...>` at every lookup — which is why List<string> and List<int>
    // share one body, one layout and one __destruct_List (§10 #17's leak).
    try testing.expect(list_str != list_int);
    try testing.expect(store.get(list_str).struct_.args.len == 1);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);
}

test "join: a method sees the struct's type params AND its own" {
    // pub fn map<U>(self: List<T>, fn: (T) => U): List<U>
    // `T` from `struct List<T>`, `U` from the method. Using only the struct's
    // params left every `U` unresolved — measured as 6x"U" on ycsb before the fix,
    // and it was a gap in the shadow harness, not the compiler.
    const a = testing.allocator;
    var store = types.TypeStore.init(a);
    defer store.deinit();
    var l = Lowerer.init(a, &store);
    defer l.deinit();

    const su = [_]ParamScope{.{ .owner = @enumFromInt(1), .names = &.{ "T", "U" } }};
    l.param_scopes = &su; // struct params ++ method params
    const t = try l.lower(.{ .ident = "T" });
    const u = try l.lower(.{ .ident = "U" });
    try testing.expect(t != u);
    try testing.expect(store.get(t).type_param.index == 0);
    try testing.expect(store.get(u).type_param.index == 1);
    try testing.expectEqual(@as(usize, 0), l.stats.unresolved);
}

test "lower: two different generics' params are DIFFERENT types" {
    // `Map<K, V>`'s K and `List<T>`'s T are unrelated types that happen to sit at
    // index 0 of their own declarations. A type param's identity is {owner, index}
    // — so if `owner` is not set, EVERY param in the program interns as
    // {symbol#0, index}, and K, T, and A collapse onto one TypeId.
    //
    // That breaks the invariant the whole interning design rests on — TypeId
    // equality IS type equality — for every generic in the language. It surfaced
    // as a rendering oddity (`ident: 'K' -> 'T'`, 7x): the printer resolved
    // owner#0 and dutifully reported symbol 0's first param name for everything.
    // The render was the symptom; this is the disease.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const map_sym: types.SymbolId = @enumFromInt(1);
    const list_sym: types.SymbolId = @enumFromInt(2);

    const map_sc = [_]ParamScope{.{ .owner = map_sym, .names = &.{ "K", "V" } }};
    l.param_scopes = &map_sc;
    const k = try l.lower(.{ .ident = "K" });

    const list_sc = [_]ParamScope{.{ .owner = list_sym, .names = &.{"T"} }};
    l.param_scopes = &list_sc;
    const t = try l.lower(.{ .ident = "T" });

    // Both are index 0 of their own declaration...
    try testing.expect(store.get(k).type_param.index == 0);
    try testing.expect(store.get(t).type_param.index == 0);
    // ...and they are NOT the same type.
    try testing.expect(k != t);

    // The same param, asked for twice, IS the same type — interning still holds.
    l.param_scopes = &map_sc;
    try testing.expectEqual(k, try l.lower(.{ .ident = "K" }));
}

test "lower: with no scope, `T` is not a param at all — never symbol 0's" {
    // The old model was a {owner, type_params} pair whose owner DEFAULTED to
    // `@enumFromInt(0)` — indistinguishable from a real symbol. Every caller forgot
    // to set it, so every generic's param interned as {symbol#0, index} and K, T
    // and A collapsed onto one TypeId. That needed an explicit refusal to catch.
    //
    // Scopes make it unrepresentable instead of merely detected: with no enclosing
    // scope, `T` is simply not a type parameter and falls through to the named-type
    // path like any other unknown name. There is no default owner to be wrong.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const t = try l.lower(.{ .ident = "T" });
    try testing.expect(store.get(t) == .unresolved);
    try testing.expect(store.get(t) != .type_param);

    // Given a scope to belong to, the same name is a real param.
    const sc = [_]ParamScope{.{ .owner = @enumFromInt(3), .names = &.{"T"} }};
    l.param_scopes = &sc;
    try testing.expect(store.get(try l.lower(.{ .ident = "T" })) == .type_param);
}

test "lower: a method's own `U` belongs to the METHOD, not to the struct" {
    // `pub fn map<U>(self: List<T>, fn: (T) => U): List<U>` — std/collections/
    // list.nova:123, verbatim. T is List's parameter; U is map's. They live in
    // DIFFERENT declarations that happen to be lexically nested.
    //
    // Merging them into one list under one owner makes U into {List, 1} — an index
    // List does not have. Substituting List<string>'s args then leaves it alone
    // (arity), so `U` stays unresolved and every `List<U>` with it.
    //
    // Two scopes, innermost first, is the only thing that expresses this.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const list_sym: types.SymbolId = @enumFromInt(1);
    const map_sym: types.SymbolId = @enumFromInt(2);

    l.param_scopes = &.{
        .{ .owner = list_sym, .names = &.{"T"} }, // the struct's
        .{ .owner = map_sym, .names = &.{"U"} }, // the method's own
    };

    const t = try l.lower(.{ .ident = "T" });
    const u = try l.lower(.{ .ident = "U" });

    try testing.expect(store.get(t) == .type_param);
    try testing.expect(store.get(u) == .type_param);
    // Each is index 0 OF ITS OWN declaration — not 0 and 1 of a merged list.
    try testing.expectEqual(list_sym, store.get(t).type_param.owner);
    try testing.expectEqual(@as(u32, 0), store.get(t).type_param.index);
    try testing.expectEqual(map_sym, store.get(u).type_param.owner);
    try testing.expectEqual(@as(u32, 0), store.get(u).type_param.index);
    try testing.expect(t != u);
}

test "lower: an inner scope SHADOWS an outer one of the same name" {
    // `struct Box<T> { fn rewrap<T>(...) }` — legal, and the inner T wins. With one
    // merged list the first match wins, which is the OUTER one: exactly backwards.
    var store = types.TypeStore.init(testing.allocator);
    defer store.deinit();
    var l = mk(&store);
    defer l.deinit();

    const box: types.SymbolId = @enumFromInt(1);
    const rewrap: types.SymbolId = @enumFromInt(2);
    l.param_scopes = &.{
        .{ .owner = box, .names = &.{"T"} },
        .{ .owner = rewrap, .names = &.{"T"} },
    };
    const t = try l.lower(.{ .ident = "T" });
    try testing.expectEqual(rewrap, store.get(t).type_param.owner); // inner wins
}
