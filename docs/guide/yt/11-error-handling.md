# Video 11: Error handling

- Chapter: [11-error-handling.md](../11-error-handling.md)
- Estimated length: ~14 minutes
- You will need: the `kyte` compiler on your PATH, and the guide examples `17_errors.ky`, `25_errdefer.ky`, `26_defer.ky`, and `27_exception.ky`

## Hook (0:00)

**Say:** Most languages handle failure by throwing something that unwinds the stack, and hoping somebody up the chain catches it. Kyte does not do that. In Kyte a function that can fail simply returns its error as a value, and the natural error type is an `exception`, a tagged union that always knows how to describe itself. By the end of this video you will define an exception, propagate errors with `try`, handle them with `catch`, and clean up safely with `defer` and `errdefer`.

## What we will cover (0:30)

- Why errors are values, not thrown things
- Defining an `exception` with its required `message` method
- The three core operators: `try`, `catch d`, and `catch (e) e.message()`
- A worked parse-and-propagate example
- Cleanup with `defer` and `errdefer`
- Enums and structs as fallback error types
- A second exception showing uniform handling

## Segment: Errors are values (1:00)

**Say:** Here is the whole mental model in one sentence. A function that can fail returns `T | E`, where `T` is the good value and `E` is a user-defined error type. Nothing unwinds the stack. Every failure is just a branch on a value, which is exactly why it is safe under coroutines and never leaks. And because the error is a value with a type, the compiler forces you to deal with it. You cannot silently drop the failure channel, and the reason inside the error survives the whole trip up to the caller.

## Segment: Defining an exception (2:00)

**Say:** The error type you reach for first is an `exception`. It is a tagged union whose variants each carry a payload explaining what went wrong, plus a `message` method that the compiler requires. That method turns any variant into text, so every caller reads the reason back the same way, with `e.message()`, and never has to switch on the error itself.

**On screen:**
```kyte
exception ConfigError {
    Empty,
    NotANumber(string),
    OutOfRange(int),
    fn message(self: ConfigError): string {
        switch (self) {
            case ConfigError.Empty:         { return "value is empty"; }
            case ConfigError.NotANumber(s): { return "not a number: " + s; }
            case ConfigError.OutOfRange(n): { return "port out of range: " + `${n}`; }
        }
        return "unknown error";
    }
}
```

**Say:** Three variants. `Empty` carries nothing. `NotANumber` carries the offending string. `OutOfRange` carries the bad number. The `message` method switches over the variants and produces a clear line for each. And here is the guarantee: leaving out that `message` method is a compile error. So given any exception value at all, you can always call `e.message()` and get text back. Plain enums and structs also work on the error side of `T | E` when you do not need that guaranteed message, and we will see both later.

## Segment: The three core operators (3:30)

**Say:** There are exactly three operators to learn. First, `try f()`. If `f()` returned the error side, `try` returns that same error from the enclosing function, otherwise it unwraps and gives you the good value. That is how an error propagates up the call chain. Second, `f() catch d`. On the error side it evaluates the expression `d` and uses that, and the good value passes through unchanged. Third, `f() catch (e) g(e)`, the same thing but it binds the error as `e` so you can inspect its reason.

**Say:** Two rules to keep in mind. Both sides of a `catch` must have the same type: if the ok value is an int, the default after `catch` must also be an int. And `catch` takes an expression, not a block. Writing `catch (e) { ... }` with braces is a parse error. To turn the error into a value, you call a method or function that returns what you want, which is exactly what `e.message()` does. One more: the enclosing function of a `try` must itself return an error union, because `try` may hand that error back out. At the very top, `main` returns `void`, so you finish an error union there with a `catch`, not a `try`.

## Segment: Parse and propagate (5:00)

**Say:** Let us make this concrete. `parsePort` really parses the digits of a string and returns a different typed error for each way the input can be wrong. This is the same `ConfigError` we just defined.

**On screen:**
```kyte
// A fallible function: parse a port number out of a string. It really parses the
// digits, and returns a typed error variant for each way the input can be wrong.
fn parsePort(s: string): int | ConfigError {
    if (s.length == 0) { return ConfigError.Empty; }
    let n = 0;
    let i = 0;
    while (i < s.length) {
        let c = s[i];
        if (c < 48 || c > 57) { return ConfigError.NotANumber(s); }
        n = n * 10 + (c - 48);
        i = i + 1;
    }
    if (n < 1 || n > 65535) { return ConfigError.OutOfRange(n); }
    return n;
}
```

**Say:** Empty string returns `Empty`. A non-digit byte returns `NotANumber` carrying the whole string. A number outside the valid port range returns `OutOfRange` carrying that number. Otherwise it returns the port as a plain int. Now watch how `buildUrl` uses it.

**On screen:**
```kyte
// `try` propagates parsePort's error to OUR caller and unwraps on success. Because
// buildUrl also returns `... | ConfigError`, one bad value short-circuits the rest.
fn buildUrl(host: string, portText: string): string | ConfigError {
    let port = try parsePort(portText);
    return `http://${host}:${port}`;
}
```

**Say:** `try parsePort(portText)`. On success, `port` is the unwrapped int and we build the URL. On failure, `buildUrl` stops right there and hands the very same error back to its own caller. Notice `buildUrl` also returns `string | ConfigError`, which is what lets `try` live inside it. Now `main`.

**On screen:**
```kyte
fn main(): void {
    // `catch d`: the ok value passes through, an error becomes the default d.
    console.log(`parsePort("8080")  = ${parsePort("8080") catch -1}`);
    console.log(`parsePort("70000") = ${parsePort("70000") catch -1}`);

    // `catch (e) e.message()`: bind the error and let the exception describe itself.
    // The four calls below each fail in a different way, and the reason survives.
    console.log(`url ok    = ${buildUrl("localhost", "8080") catch (e) e.message()}`);
    console.log(`url empty = ${buildUrl("localhost", "") catch (e) e.message()}`);
    console.log(`url text  = ${buildUrl("localhost", "12ab") catch (e) e.message()}`);
    console.log(`url range = ${buildUrl("localhost", "70000") catch (e) e.message()}`);
}
```

**Say:** The first two lines use `catch -1` to turn a failure into minus one. The next four use `catch (e) e.message()` to let the exception describe itself, and each of the four fails in a different way. Let us run it.

**Run it:** `kyte examples/17_errors.ky -o out && ./out`

```
parsePort("8080")  = 8080
parsePort("70000") = -1
url ok    = http://localhost:8080
url empty = value is empty
url text  = not a number: 12ab
url range = port out of range: 70000
```

**Say:** Two things to notice. `parsePort("70000")` returns `OutOfRange(70000)` and the `catch -1` turns it into minus one, while `parsePort("8080")` passes its value straight through. And every failing `buildUrl` call reports the exact reason, because the payload rides along with the error. `NotANumber("12ab")` prints "not a number: 12ab", not a generic message. The reason is never lost. That is the whole point of the model.

## Segment: Cleanup with defer and errdefer (8:00)

**Say:** A function often grabs something, a lock, a connection, a file, and then does work that might fail. Kyte gives you two cleanup hooks. `defer expr` runs at every exit from the scope, on success or failure. `errdefer expr` runs only when the function leaves on the error path, either an explicit error-side return or a `try` that propagates a failure. Both run last-registered-first, LIFO. On the error path the `errdefer`s run first, then the `defer`s, so a rollback happens before the resource it depended on is released.

**Say:** This example uses a plain enum, `TxError`, as its error type. That is our first fallback: an enum sits on the error side of `T | E` just fine when you do not need the guaranteed message.

**On screen:**
```kyte
// examples/26_defer.ky
import list;

enum TxError { Conflict }

fn transfer(fail: bool, log: List<string>): int | TxError {
    log.push("acquire lock");
    defer log.push("release lock");        // ALWAYS runs, on both paths
    errdefer log.push("rollback txn");     // only runs if we fail below

    if (fail) { return TxError.Conflict; } // error path: errdefer then defer
    log.push("commit txn");
    return 1;                              // success path: only the defer runs
}
```

**Say:** We acquire the lock, register a `defer` to release it, which always runs, and an `errdefer` to roll back, which only runs on failure. If `fail` is true we return the error, and both the errdefer and the defer fire. If not, we commit and return 1, and only the defer fires. Let us run the whole file.

**Run it:** `kyte examples/26_defer.ky -o out && ./out`

```
success -> result 1
  ok  : acquire lock
  ok  : commit txn
  ok  : release lock
conflict -> result -1
  fail: acquire lock
  fail: rollback txn
  fail: release lock
```

**Say:** On success the log shows acquire, commit, release. No rollback. On failure it shows acquire, then rollback, then release, in that order: the transaction is undone first, then the lock is let go. You wrote no manual cleanup branch and no `finally`. The two hooks handled both paths.

## Segment: Rolling back several resources (10:00)

**Say:** When you hold more than one resource, each gets its own `errdefer`, and because they run LIFO they roll back in the reverse of the order you acquired them. This example uses a struct error type, `OpenError`, which is our second fallback. A struct is the right choice when the error is really one kind of thing carrying a few fields.

**On screen:**
```kyte
// A struct error type. Its fields carry the reason to the caller.
struct OpenError {
    pub resource: string,
    pub reason: string,
    init(resource: string, reason: string) {
        self.resource = resource;
        self.reason = reason;
    }
}

// Acquire two resources, then run a final step that may fail. If it fails, both
// errdefers fire in LIFO order (cache first, then db), rolling back everything we
// had acquired. On success no errdefer runs.
fn connectBoth(failFinal: bool, log: List<string>): int | OpenError {
    let a = try open("db", log);
    errdefer log.push("closed db");        // registered once db is open

    let b = try open("cache", log);
    errdefer log.push("closed cache");     // registered once cache is open

    if (failFinal) { return OpenError("session", "handshake failed"); }
    return a + b;                          // success path: no errdefer runs
}
```

**Say:** We open db, then register its rollback. We open cache, then register its rollback. If the final step fails, both errdefers fire, but LIFO means cache closes first, then db, the reverse of how we opened them. On success neither errdefer runs. Let us see it.

**Run it:** `kyte examples/25_errdefer.ky -o out && ./out`

```
both ok -> result 2
  ok  : opened db
  ok  : opened cache
final step fails -> result -1
  fail: opened db
  fail: opened cache
  fail: closed cache
  fail: closed db
```

**Say:** On success: opened db, opened cache, result 2, and nothing closed. On failure: opened db, opened cache, then closed cache, then closed db. The reverse order, exactly. The function reads like ordinary straight-line code, yet it is exception-safe, and the errdefers only ever exist to undo work.

## Segment: Choosing an error type (12:00)

**Say:** So which one do you pick? Reach for an `exception` by default: it fails several ways, every caller handles it uniformly with `catch (e) e.message()`, and the compiler guarantees the message method exists. Fall back to a plain enum when the error is a fixed set of tags you always switch on and you do not want a message contract, like `TxError`. Fall back to a struct like `OpenError` when the error is really one thing carrying a few fields. All three are ordinary types on the error side of `T | E`, and all three carry the reason to the caller.

## Segment: A second exception (12:45)

**Say:** Here is the exception pattern in its own right. `LookupError` can fail two ways, and because the ok side is a string, a single `catch (e) e.message()` both handles the error and unifies the two arms, since both sides are strings.

**On screen:**
```kyte
exception LookupError {
    NotFound(string),
    Forbidden(string),
    fn message(self: LookupError): string {
        switch (self) {
            case LookupError.NotFound(k):  { return "not found: " + k; }
            case LookupError.Forbidden(w): { return `access denied for ${w}`; }
        }
        return "unknown";
    }
}

// LookupError is the error side, so lookup may fail in more than one way. The ok side is a string,
// so `catch (e) e.message()` unifies (both sides are strings).
fn lookup(user: string, key: string): string | LookupError {
    if (user == "guest") { return LookupError.Forbidden(user); }
    if (key == "missing") { return LookupError.NotFound(key); }
    return `${key} = 42`;
}

fn main(): void {
    console.log(lookup("admin", "count")   catch (e) e.message());
    console.log(lookup("admin", "missing") catch (e) e.message());
    console.log(lookup("guest", "count")   catch (e) e.message());
}
```

**Say:** The single `catch (e) e.message()` dispatches to whichever variant occurred, so the caller never switches on the error itself. Run it.

**Run it:** `kyte examples/27_exception.ky -o out && ./out`

```
count = 42
not found: missing
access denied for guest
```

**Say:** First call succeeds and prints the value. Second call hits `NotFound` and prints its message. Third hits `Forbidden` and prints its message. One handler, three outcomes. And one last tool: the `exception` module also gives you `stackTrace()`, the current call stack as text, one frame per line, on macOS, Linux, and Windows, which you can log or fold into a `message()`.

**On screen:**
```kyte
import exception;
// inside a handler or a message() method:
let trace = exception.stackTrace();
```

**Say:** By the way, `exception` is a contextual keyword. It is special only at the start of a declaration, so `import exception;` and ordinary identifiers named `exception` still work fine.

## Recap (13:45)

**Say:** Quick recap:

- An error is a value with a type: a function that can fail returns `T | E`, and nothing unwinds the stack.
- The natural error type is an `exception`, a tagged union whose compiler-required `message` method describes any variant.
- `try f()` propagates the error and unwraps on success; `f() catch d` supplies a default; `f() catch (e) e.message()` binds the error and lets it describe itself.
- `defer` runs at every exit, `errdefer` runs only on the error path, both LIFO, so rollbacks happen before releases.
- Enums and structs are fine fallback error types, but reach for `exception` first.

## Outro (14:15)

**Say:** Errors are handled, cleanly and safely. Next up we look at `decimal`, exact base-10 arithmetic, the type you want the moment real money is involved. If this was useful, a like and a subscribe help a lot.
