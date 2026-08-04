# 1. Getting started

Every Nova program starts at `fn main(): void`. Printing is done with the built-in `console.log`
(no import required).

```nova
// examples/01_hello.nova
fn main(): void {
    console.log("Hello, Nova!");
}
```

Compile it to a native executable and run it:

```sh
nova docs/guide/examples/01_hello.nova -o /tmp/hello
/tmp/hello
```

```
Hello, Nova!
```

## The toolchain

| Command | What it does |
|---------|--------------|
| `nova <file>.nova -o <out>` | Compile one file to a native executable. |
| `nova build` | Build a project (reads `project.json`). Add `--release` for optimizations. |
| `nova test <file>.nova` | Compile and run the `@test` functions in a file. |
| `nova fmt` | Format source. |
| `nova init web\|desktop --name X` | Scaffold a new app. |
| `nova add` / `nova get` | Manage dependencies (packages). |

Nova compiles through LLVM to a real native binary; there is no interpreter and no VM. The default
target is your host platform; cross-compilation and WASM are opt-in via `--target`.

## A note on `console`

`console.log`, `console.info`, `console.err`, and `console.debug` are built-ins that print a line. They
accept a string, so use a **template literal** (next chapters) to format other values:

```nova
let n = 42;
console.log(`the answer is ${n}`);
```

Next: [Values & types](02-values-and-types.md)
