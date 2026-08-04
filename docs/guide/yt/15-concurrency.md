# Video 15: Concurrency

- Chapter: [15-concurrency.md](../15-concurrency.md)
- Estimated length: ~11 minutes
- You will need: the `nova` compiler installed, a terminal, and the guide's `examples/` folder open

## Hook (0:00)

**Say:** In this video we will learn how Nova does concurrency. It has first-class `async` and `await`, compiled to real coroutines, so there is no callback soup and no green-thread library to import. By the end you will know how to launch work concurrently with `spawn`, join it with `await`, and hand values between tasks using channels. We will run two small programs that both finish cleanly.

## What we will cover (0:25)

- The small async vocabulary: `async fn`, `spawn`, and `await`
- Function colouring and the sync to async bridge
- Launching three computations concurrently and combining them
- Channels for passing values between tasks

## Segment: the async vocabulary (0:55)

**Say:** The vocabulary here is small, so let us go through it. An `async fn f` returning `T` is a function that may suspend. Its body can use `await` and `spawn`. Writing `spawn f(...)` launches `f` concurrently and returns a future immediately. The task runs on the async runtime, and you get its result later. Writing `await` on a future joins that spawned future and gives you its value. And you can also `await` a call to another `async fn` directly, which calls it and waits for it inline, with no separate task.

## Segment: function colouring and the bridge (2:15)

**Say:** There is one rule about where these keywords may appear, and it is called function colouring. `await` and `spawn` may appear only inside an `async fn`. That is what colours a function async. There is one deliberate exception at the boundary: a synchronous `fn main` may call an `async fn` directly. The runtime block-drives that call to completion. This is the sanctioned way to start an async program from a plain `main` without making `main` itself async.

## Segment: spawning concurrent work (3:15)

**Say:** Let us see it in action. This program has a couple of small async functions, then launches three computations concurrently and combines them.

**On screen:**
```nova
// examples/21_async.nova
// Nova has first-class async/await built on LLVM coroutines.
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
```

**Say:** `square` is a plain `async fn` that returns `n` times `n`. `sumOfSquares` shows inline awaiting: it calls `square` twice, awaiting each one in sequence, and adds the results. These two awaits happen one after the other, on the spot, no separate tasks yet.

**Say:** Now the interesting part, where we actually run things concurrently.

**On screen:**
```nova
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

**Say:** In `run`, the three `spawn` calls each launch a computation and return a future immediately, so all three are running concurrently. Then we `await` each future in turn to collect the results: 25 from squaring 5, 36 from squaring 6, and 5 from the sum of squares of 1 and 2. Add those and you get 66. And look at `main`: it is a plain synchronous function, but it calls the async `run` directly. That is the sync to async bridge in action, the runtime block-drives `run` to completion.

**Run it:**
```
nova examples/21_async.nova -o out && ./out
```

```
25 + 36 + 5 = 66
```

**Say:** There it is, 66, and the program terminates cleanly. One thing to hold onto: `spawn` is what makes those three calls actually concurrent. Awaiting them one by one only joins tasks that are already running, it does not serialize them.

## Segment: channels (7:30)

**Say:** Returning a result is one pattern. Sometimes tasks need to hand values to one another as they go. For that Nova has async channels, in the `concurrency.asyncchan` module. The key behaviour is that a `chanRecv` parks the receiving task until a value is available, and it is woken by a `chanSend`. So producer and consumer coordination is deterministic: no polling, no sleeps.

**On screen:**
```nova
// examples/22_channels.nova
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

**Say:** Walk through `consume` with me. First we make a channel with `chanNew`. Then we `spawn` the producer, which runs concurrently and sends two values, 40 and 2, into the channel. Back in the consumer, the first `chanRecv` parks until the producer sends 40, and the second parks until it sends 2. Then we `await h` to join the producer task, free the channel with `chanFree`, and return the sum, which is 42. And once again `main` is synchronous and calls `consume` directly across the bridge.

**Run it:**
```
nova examples/22_channels.nova -o out && ./out
```

```
received sum = 42
```

**Say:** 42, exactly as expected, and it terminates once both values are received. No timing assumptions anywhere: the receiver parks and the send wakes it.

## Segment: the same runtime powers the server (9:45)

**Say:** One last thing worth knowing. The same runtime underneath these examples powers Nova's HTTP server. Each connection is a coroutine, so a handler that `await`s some I/O yields the core to other connections instead of blocking a thread. The little vocabulary you just learned is the exact vocabulary that scales up to real servers.

## Recap (10:15)

**Say:** Quick recap:

- An `async fn` may suspend, and only inside one may you use `await` and `spawn`.
- `spawn f(...)` launches concurrently and returns a future straight away.
- `await` joins a future, or calls another `async fn` inline.
- A synchronous `main` may call an `async fn` directly, the sanctioned block-drive bridge.
- Channels hand values between tasks: `chanRecv` parks until a `chanSend`, deterministically.

## Outro (10:50)

**Say:** Next up we will look at serialization, turning Nova values into JSON and back. If this helped, a like or subscribe keeps the series going. See you in the next one.
