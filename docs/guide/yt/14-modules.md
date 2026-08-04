# Video 14: Modules & visibility

- Chapter: [14-modules.md](../14-modules.md)
- Estimated length: ~9 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** In this video we will learn how Nova splits a program across files and controls what each file exposes. By the end you will know the three kinds of `import`, how to qualify each one, and how `pub` decides exactly what crosses a module boundary. It is a small, tidy system, and it is strict in a helpful way: referencing something private from another module is a hard compile error, not a warning.

## What we will cover (0:25)

- Every `.nova` file is a module
- The three kinds of import: sibling files, stdlib paths, and `platform`
- Visibility with `pub`, and why it is opt-in
- A worked example that uses all three imports together

## Segment: modules and the three imports (0:55)

**Say:** The rule to start with is simple: every `.nova` file is a module. You bring one module into another with `import`, and there are three kinds of import, all using the same syntax.

**Say:** First, sibling files. Writing `import geometry;` resolves `geometry.nova` in the same directory. Second, stdlib paths, which are dotted, like `import collections.list;`. And here is the key detail: you always qualify by the last segment. So `collections.list` is used as `list.List`, and `serde.json` is used as `json` and its members. Third, the `platform` module. Writing `import platform;` pulls in a module the compiler synthesises for your build target, giving you things like `platform.os`, `platform.arch`, `platform.pointerSize`, and booleans like `isDarwin`, `isLinux`, `isWindows`, `isWasm`, and `isPosix`.

## Segment: visibility is opt-in (2:30)

**Say:** Now visibility. A declaration is private to its module unless it is marked `pub`. A struct also marks its fields and methods `pub` individually. And referencing a non-`pub` declaration from another module is a hard compile error, not a warning. So a module's surface is exactly what it says `pub` on, nothing leaks by accident.

## Segment: the sibling module (3:15)

**Say:** Let us build a small sibling module first: a `geometry.nova` with one `pub struct` and a couple of `pub` functions, plus one private helper that importers cannot see.

**On screen:**
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
```

**Say:** `Point` is a `pub struct`, and it marks both fields `pub` too. `manhattan` and `perimeter` are `pub` functions, so importers can call them. But `double` has no `pub`, so it is usable inside this file and completely invisible to anyone importing the module. Notice `perimeter` calls `double` internally, which is fine, they are in the same module. The privacy only bites across a module boundary.

## Segment: importing it all together (5:30)

**Say:** Now the main program. It imports the sibling module, a stdlib module, and `platform`, and uses all three.

**On screen:**
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

**Say:** Look at how each import is qualified. The sibling module is qualified by its file name: `geometry.Point`, `geometry.manhattan`, `geometry.perimeter`. The stdlib import is qualified by its last path segment, so `collections.list` becomes just `list`, and we call `list.List<int>()`. And `platform` gives us compile-time facts about the build target: the operating system, the architecture, and those boolean flags.

**Run it:**
```
nova examples/20_modules.nova -o out && ./out
```

```
manhattan((0,0),(3,4)) = 7
perimeter             = 14
list size = 3, first = 10
os        = darwin
arch      = aarch64
isPosix   = true
isWindows = false
```

**Say:** The `platform` values reflect the machine this was built on, so here it is a darwin, aarch64 host. On a Linux or Windows build those last four lines would read differently.

## Segment: two things that follow (7:45)

**Say:** Two consequences are worth calling out. First, a stdlib import is qualified by its last segment, never its full path. `collections.list` gives you `list`, so writing `collections.List<int>()` with a wrong qualifier is a compile error. Second, `platform` is resolved at compile time for the current target, so `platform.isWindows` is a real constant you can branch on for target-conditional code. The values you just saw would differ on a Linux or Windows build.

## Recap (8:20)

**Say:** Quick recap:

- Every `.nova` file is a module, and `import` brings one into another.
- Three kinds of import: sibling files by name, dotted stdlib paths qualified by their last segment, and the compiler-synthesised `platform` module.
- Visibility is opt-in with `pub`, on structs, fields, methods, and functions.
- Referencing a non-`pub` declaration across a module boundary is a hard compile error.

## Outro (8:50)

**Say:** Next up we will look at concurrency, where Nova's `async`, `await`, and `spawn` come into play. If this helped, a like or subscribe keeps the series going. See you in the next one.
