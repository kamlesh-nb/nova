# Video 01: Getting started

- Chapter: [01-getting-started.md](../01-getting-started.md)
- Estimated length: ~6 minutes
- You will need: Kyte installed on your machine, and a terminal open.

## Hook (0:00)

**Say:** Welcome to Kyte. In the next few minutes you are going to write your very first Kyte program, compile it into a real native executable, and run it. No interpreter, no VM, just a proper binary you can run straight away. By the end of this video you will know where a Kyte program starts, how to print output, and the handful of commands the toolchain gives you.

## What we will cover (0:20)

- The smallest possible Kyte program
- Compiling and running it
- A quick tour of the `kyte` toolchain
- How `console` printing works

## Segment: Your first program (0:35)

**Say:** Every Kyte program starts at one function called `main`. Let me show you the smallest program you can write.

**On screen:**
```kyte
// examples/01_hello.ky
fn main(): void {
    console.log("Hello, Kyte!");
}
```

**Say:** That is the whole thing. `fn main(): void` is the entry point. Every Kyte program begins execution here. The `void` after the colon is the return type, it just means this function does not return a value. Inside, we call `console.log` with a string. `console.log` is a built-in, so you do not need to import anything to use it. It prints a line to the console.

## Segment: Compile and run (1:30)

**Say:** Kyte compiles through LLVM into a real native binary. There is no interpreter and no VM. Let us compile our file into an executable and then run it.

**Run it:** `kyte docs/guide/examples/01_hello.ky -o /tmp/hello` then `/tmp/hello`

```
Hello, Kyte!
```

**Say:** The `-o` flag names the output file. We compiled the source into a binary at `/tmp/hello`, then ran that binary directly, and it printed `Hello, Kyte!`. That is compile then run, two separate steps, exactly like you would expect from a compiled language.

## Segment: The toolchain (2:45)

**Say:** The `kyte` command does more than compile single files. Here are the commands you will reach for most often.

**On screen:**
```
kyte <file>.ky -o <out>        Compile one file to a native executable.
kyte build                       Build a project (reads project.json). Add --release for optimizations.
kyte test <file>.ky            Compile and run the @test functions in a file.
kyte fmt                         Format source.
kyte init web|desktop --name X   Scaffold a new app.
kyte add / kyte get              Manage dependencies (packages).
```

**Say:** For a single file you use the compile form we just saw. For a full project you use `kyte build`, which reads a `project.json`, and you can add `--release` to turn on optimisations. `kyte test` runs the test functions in a file. `kyte fmt` formats your source. `kyte init` scaffolds a new web or desktop app. And `kyte add` and `kyte get` manage your dependencies. The default target is your host platform, and cross-compilation and WebAssembly are opt-in through the `--target` flag.

## Segment: Printing with console (4:15)

**Say:** A quick note on printing. There are four console built-ins: `console.log`, `console.info`, `console.err`, and `console.debug`. They each print a line, and they accept a string. If you want to print a number or some other value, wrap it in a template literal, which we will cover properly in the next couple of videos. Here is a taste.

**On screen:**
```kyte
let n = 42;
console.log(`the answer is ${n}`);
```

**Say:** Those backticks make a template literal, and the `${n}` slots the value of `n` into the string. So this prints `the answer is 42`. We will dig into values, types, and strings next.

## Recap (5:15)

**Say:** Let us recap what we learned.

- Every Kyte program starts at `fn main(): void`.
- `console.log` prints a line and needs no import.
- Compile a single file with `kyte <file>.ky -o <out>`, then run the output binary.
- Kyte compiles through LLVM to a real native binary, no interpreter or VM.
- The toolchain also gives you `kyte build`, `kyte test`, `kyte fmt`, `kyte init`, and package commands.

## Outro (5:45)

**Say:** That is your first Kyte program done. In the next video we look at values and types: integers, floats, booleans, and how variables work. If this was useful, a like and a subscribe genuinely helps. See you in the next one.
