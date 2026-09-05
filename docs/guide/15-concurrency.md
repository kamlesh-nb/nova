# 15. Concurrency

Kyte has first-class `async`/`await`, compiled to real coroutines (there is no callback soup and no
green-thread library to import). The vocabulary is small:

- **`async fn f(): T`**: a function that may *suspend*. Its body can use `await` and `spawn`.
- **`spawn f(...)`**: launch `f` **concurrently**, returning a **future** immediately. The task runs on
  the async runtime; you get its result later with `await`.
- **`await <future>`**: join a spawned future and get its value.
- **`await g(...)`**: call another `async fn` and wait for it inline (no separate task).

## Function colouring, and the sync to async bridge

`await` and `spawn` may appear **only inside an `async fn`**, that is what "colours" a function async.
The one deliberate exception is the boundary: a **synchronous `fn main` may call an `async fn`
directly**. The runtime *block-drives* that call to completion, which is the sanctioned way to start an
async program from a plain `main` without making `main` itself async.

The example launches three async computations concurrently with `spawn`, awaits all three, and combines
them, and it terminates:

```kyte
// examples/21_async.ky
// Kyte has first-class async/await built on LLVM coroutines.
//
//   * `async fn f(): T`   : a function that may suspend; calling it yields a value
//                           when awaited (or block-driven from a sync caller).
//   * `spawn f(...)`      : launch f CONCURRENTLY; returns a future immediately.
//   * `await <future>`    : join a spawned future and get its result.
//   * `await g(...)`      : call another async fn and wait for it inline.
//
// FUNCTION COLOURING: `await` and `spawn` may appear ONLY inside an `async fn`.
// A synchronous `fn main` MAY call an async fn directly: that is the sanctioned
// sync to async bridge (the runtime block-drives the coroutine to completion), so
// `main` can launch the whole async program without being async itself.

async fn square(n: int): int {
    return n * n;
}

// Awaits two child async calls in sequence.
async fn sumOfSquares(a: int, b: int): int {
    let x = await square(a);
    let y = await square(b);
    return x + y;
}

// Launch three async computations CONCURRENTLY with `spawn`, then await all three
// and combine the results.
async fn run(): int {
    let h1 = spawn square(5);          // 25
    let h2 = spawn square(6);          // 36
    let h3 = spawn sumOfSquares(1, 2); // 1 + 4 = 5

    let r1 = await h1;
    let r2 = await h2;
    let r3 = await h3;
    return r1 + r2 + r3;               // 66
}

fn main(): void {
    // Sync to async bridge: a plain main drives the async entry point.
    let total = run();
    console.log(`25 + 36 + 5 = ${total}`);
}
```

Output:

```
25 + 36 + 5 = 66
```

## Channels

For tasks that need to *hand values to one another* rather than just return a result, Kyte has async
channels (`concurrency.asyncchan`). A `chanRecv` **parks** the receiving task until a value is available
and is woken by a `chanSend`, so producer/consumer coordination is deterministic, with no polling and
no sleeps:

```kyte
// examples/22_channels.ky
// Channels let concurrent tasks hand values to one another. A producer task
// `chanSend`s into the channel; a consumer `await chanRecv`s, parking until a
// value is available and being woken by the send. This is deterministic: no
// timing assumptions, and it TERMINATES once both values are received.
import concurrency.asyncchan;

// Runs concurrently; pushes two values into the channel, then returns.
async fn producer(ch: long): int {
    asyncchan.chanSend(ch, 40);
    asyncchan.chanSend(ch, 2);
    return 0;
}

async fn consume(): int {
    let ch = asyncchan.chanNew();
    let h = spawn producer(ch);            // launch the producer concurrently
    let a = await asyncchan.chanRecv(ch);  // parks until producer sends 40
    let b = await asyncchan.chanRecv(ch);  // parks until producer sends 2
    let done = await h;                    // join the producer task
    asyncchan.chanFree(ch);
    return a + b;                          // 42
}

fn main(): void {
    console.log(`received sum = ${consume()}`);
}
```

Output:

```
received sum = 42
```

| Construct | Meaning |
|-----------|---------|
| `async fn f(): T` | A suspendable function; may use `await`/`spawn` |
| `spawn f(...)` | Launch concurrently, returns a future |
| `await fut` / `await g(...)` | Join a future / call another async fn inline |
| sync `main` calls `async fn` | The sanctioned block-drive bridge into async |
| `asyncchan.chanNew/Send/Recv/Free` | Async channel: `chanRecv` parks until sent to |

`spawn` is what makes the three `square`/`sumOfSquares` calls actually *concurrent*: awaiting them one
by one only joins already-running tasks, it does not serialize them. The same runtime underneath powers
Kyte's HTTP server: each connection is a coroutine, so a handler that `await`s I/O yields the core to
other connections instead of blocking a thread.

Next: [Serialization](16-serialization.md)
