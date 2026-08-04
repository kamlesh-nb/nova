# 14. Modules & visibility

Every `.nova` file is a **module**. You bring one module into another with `import`, and you control
what crosses a module boundary with `pub`. There are three kinds of import, all using the same syntax:

- **Sibling files:** `import geometry;` resolves `geometry.nova` in the same directory.
- **Stdlib paths:** dotted, e.g. `import collections.list;`. You always **qualify by the last
  segment**, so `collections.list` is used as `list.List`, `serde.json` as `json.*`, and so on.
- **The `platform` module:** `import platform;` pulls in a module the **compiler synthesises** for the
  build target: `platform.os`, `platform.arch`, `platform.pointerSize`, and the booleans `isDarwin`,
  `isLinux`, `isWindows`, `isWasm`, `isPosix`.

Visibility is opt-in. A declaration is private to its module unless it is marked `pub`. A struct also
marks its fields and methods `pub` individually. Referencing a non-`pub` declaration from another module
is a **hard compile error**, not a warning, so a module's surface is exactly what it says `pub` on.

First, the sibling module, a small `geometry.nova` with one `pub struct` and two `pub fn`s (plus a
private helper that importers can't see):

```nova
// examples/geometry.nova
// A tiny sibling module imported by 20_modules.nova. Only `pub` declarations are
// visible to other modules; a non-pub struct/fn referenced from another file is a
// hard compile error. Both the struct and the free function below are `pub`.

pub struct Point {
    pub x: int,
    pub y: int,
    init(x: int, y: int) {
        self.x = x;
        self.y = y;
    }
}

// Manhattan (taxicab) distance between two points.
pub fn manhattan(a: Point, b: Point): int {
    let dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
    let dy = if (a.y > b.y) a.y - b.y else b.y - a.y;
    return dx + dy;
}

// A non-pub helper: usable inside this module, invisible to importers.
fn double(n: int): int { return n + n; }

pub fn perimeter(a: Point, b: Point): int {
    return double(manhattan(a, b));
}

// A @test so the guide's run_all.sh exercises this module directly (it has no
// `main`). Importers ignore @test functions; they run only under `nova test`.
import assert;

@test
fn t_geometry(): void {
    let a = Point(0, 0);
    let b = Point(3, 4);
    assert.equalInt(manhattan(a, b), 7);
    assert.equalInt(perimeter(a, b), 14);
}
```

Now the program that imports it, plus a stdlib module and `platform`:

```nova
// examples/20_modules.nova
// A Nova program is a set of MODULES that `import` one another.
//
//   * `import geometry;`         : a SIBLING file (geometry.nova in this dir).
//   * `import collections.list;` : a dotted stdlib path; you qualify by the LAST
//                                  segment, so `collections.list` becomes `list.List`.
//   * `import platform;`         : a module the COMPILER synthesises for the build
//                                  target (os / arch / isPosix / ...).
//
// Cross-module visibility is opt-in: only `pub` declarations are reachable from
// another module. `geometry.Point` and `geometry.manhattan` are `pub`; a non-pub
// decl referenced across a module boundary is a hard compile error.
import geometry;
import collections.list;
import platform;

fn main(): void {
    // Use the sibling module's pub struct + pub functions, qualified by file name.
    let a = geometry.Point(0, 0);
    let b = geometry.Point(3, 4);
    console.log(`manhattan((0,0),(3,4)) = ${geometry.manhattan(a, b)}`);
    console.log(`perimeter             = ${geometry.perimeter(a, b)}`);

    // A stdlib module, qualified by its last path segment: collections.list becomes list.
    let xs = list.List<int>();
    xs.push(10);
    xs.push(20);
    xs.push(30);
    console.log(`list size = ${xs.size()}, first = ${xs.at(0)}`);

    // The compiler-synthesised `platform` module describes the build target.
    console.log(`os        = ${platform.os}`);
    console.log(`arch      = ${platform.arch}`);
    console.log(`isPosix   = ${platform.isPosix}`);
    console.log(`isWindows = ${platform.isWindows}`);
}
```

Output (the `platform.*` values reflect the machine this was built on):

```
manhattan((0,0),(3,4)) = 7
perimeter             = 14
list size = 3, first = 10
os        = darwin
arch      = aarch64
isPosix   = true
isWindows = false
```

| Import | Written | Used as |
|--------|---------|---------|
| Sibling file | `import geometry;` | `geometry.Point`, `geometry.manhattan` |
| Stdlib path | `import collections.list;` | `list.List<int>()` |
| Platform (synthesised) | `import platform;` | `platform.os`, `platform.isPosix`, ... |
| Visibility | `pub struct`, `pub fn`, `pub x: ...` | reachable across modules; omit `pub` for private |

Two things follow from this design. First, a stdlib import is qualified by its **last** segment, never
its full path: `collections.list` gives you `list`, so a wrong qualifier (`collections.List<int>()`) is
a compile error. Second, `platform` is resolved at compile time for the current target, so
`platform.isWindows` is a real constant you can branch on for target-conditional code; the values above
would differ on a Linux or Windows build.

Next: [Concurrency](15-concurrency.md)
