# 11. Error handling

Kyte has no thrown exceptions in the traditional sense. A function that can fail returns `T | E`, where
`E` is a user-defined error type, and the natural error type is an `exception`. Errors are ordinary
values you return, and the error carries its reason to the caller. Nothing unwinds the stack. Every
failure is a branch on a value, which is why it is safe under coroutines and never leaks.

This one idea replaces the try, throw, and catch machinery from other languages. Because the error is a
value with a type, the compiler forces you to deal with it: you cannot silently ignore the failure
channel, and the reason (the payload) survives the whole trip to the caller intact.

This chapter covers the whole feature set: defining an `exception`, the `try` and `catch` operators,
propagating errors across layers, and the two cleanup tools, `defer` and `errdefer`. Plain enums and
structs can also stand on the error side of `T | E`, and we show that too, but `exception` is the one
you reach for first.

## Defining an error type and reading the reason

The natural error type is an **`exception`**: a tagged union whose variants each carry a payload
explaining what went wrong, plus a `message(self): string` method that the compiler requires. That
method turns any variant into text, so every caller reads the reason back the same way, with
`e.message()`, and never has to `switch` on the error itself.

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

Omitting the `message` method is a compile error, so the guarantee is real: given any exception value
you can always call `e.message()`. Plain enums and structs also work on the error side of `T | E` when
you do not need that guaranteed message, and both appear later in this chapter (`TxError` and
`OpenError`).

## The three core operators

| Form | What it does |
|------|--------------|
| `try f()` | If `f()` returned the error side, return that same error from the enclosing function. Otherwise unwrap and yield the ok value. This is how an error propagates up the call chain. |
| `f() catch d` | On the error side, evaluate the expression `d` and use it. The ok value passes through unchanged. |
| `f() catch (e) g(e)` | The same, but bind the error value as `e` so `g` can inspect its reason. |

Two rules to keep in mind:

- Both sides of a `catch` must have the same type. If the ok value is an `int`, the default after
  `catch` must also be an `int`.
- `catch` takes an expression, not a block. `f() catch (e) { ... }` is a parse error. The reason is
  what `catch` *is*: it produces the replacement value to use when the call failed, so its right-hand
  side is that value, not a sequence of statements. There is no thrown exception to run a block of
  recovery code around, the error is already a value in your hand. When recovery genuinely needs several
  steps, put them in a small named function or method that returns what you want and call it on the
  error side (`f() catch (e) recover(e)`), which keeps the failure path a value like everything else.
- The enclosing function of a `try` must itself return an error union, because `try` may return the
  error from it. At the top, `main` returns `void`, so you finish an error union there with `catch`.

> `try { ... }` as a statement block is also a parse error. There is no such thing, because there are
> no exceptions to wrap. `try` is a unary operator you put in front of a fallible call.

## A worked example: parsing and propagating

`parsePort` really parses the digits of a string, and returns a different typed error for each way the
input can be wrong. `buildUrl` then uses `try parsePort(...)`: on success it gets the unwrapped port,
and on failure it stops and hands the very same error back to its own caller.

> It parses the digits by hand on purpose, so the error paths are visible. In real code you would reach
> for the stdlib's `string.parseI64` for the number and add just the range check; the point here is the
> `T | E` and `try` mechanics, not a hand-rolled integer parser.

```kyte
// examples/17_errors.ky
import string;

// An `exception` is Kyte's error type: a tagged union whose variants carry the
// reason, plus a compiler-required `message(self): string` that turns any variant
// into text. Leaving out `message` is a compile error. Every caller then reports a
// failure with a single `catch (e) e.message()`, whichever variant occurred.
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

// `try` propagates parsePort's error to OUR caller and unwraps on success. Because
// buildUrl also returns `... | ConfigError`, one bad value short-circuits the rest.
fn buildUrl(host: string, portText: string): string | ConfigError {
    let port = try parsePort(portText);
    return `http://${host}:${port}`;
}

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

Output:

```
parsePort("8080")  = 8080
parsePort("70000") = -1
url ok    = http://localhost:8080
url empty = value is empty
url text  = not a number: 12ab
url range = port out of range: 70000
```

Two things to notice. First, `parsePort("70000")` returns `OutOfRange(70000)`, and the `catch -1` turns
it into `-1`, while `parsePort("8080")` passes its ok value straight through. Second, every `buildUrl`
call that fails reports the exact reason, because the payload rides along with the error value:
`NotANumber("12ab")` prints `not a number: 12ab`, not an address or a generic message. That is the whole
point of the model, the reason is never lost.

## Cleanup: `defer` and `errdefer`

A function often acquires something (a lock, a connection, a file) and then does work that might fail.
Kyte gives you two cleanup hooks:

- `defer expr` runs `expr` at every exit from the scope, on success or on failure.
- `errdefer expr` runs `expr` only when the function leaves on the error path: an explicit error-side
  return, or a `try` that propagates a failure.

Both run in last-registered-first (LIFO) order. On the error path the `errdefer`s run first, then the
`defer`s, so a rollback happens before the resource it depended on is released. This pairing is the
common case: always release the lock, but only roll back the transaction if something went wrong.

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

fn printLog(label: string, log: List<string>): void {
    let i = 0;
    while (i < log.size()) {
        console.log(`  ${label}: ${log.at(i)}`);
        i = i + 1;
    }
}

fn main(): void {
    let ok = list.List<string>();
    let r1 = transfer(false, ok) catch -1;
    console.log(`success -> result ${r1}`);
    printLog("ok  ", ok);

    let bad = list.List<string>();
    let r2 = transfer(true, bad) catch -1;
    console.log(`conflict -> result ${r2}`);
    printLog("fail", bad);
}
```

Output:

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

On success the lock is released and nothing is rolled back. On failure the transaction is rolled back
first, then the lock is released. You wrote no manual cleanup branch and no `finally`; the two hooks
handle both paths for you.

## Rolling back several resources in order

When you hold more than one resource, each gets its own `errdefer`, and because they run LIFO they roll
back in the reverse of the order they were acquired. This example uses a struct error type to show that
the error side of `T | E` is not limited to exceptions.

```kyte
// examples/25_errdefer.ky
import list;

// A struct error type. Its fields carry the reason to the caller.
struct OpenError {
    pub resource: string,
    pub reason: string,
    init(resource: string, reason: string) {
        self.resource = resource;
        self.reason = reason;
    }
}

// A tiny stand-in for a real resource. Opening it records the fact in a shared log
// so we can see exactly what ran, and in what order.
fn open(name: string, log: List<string>): int | OpenError {
    log.push("opened " + name);
    return 1;
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

fn printLog(label: string, log: List<string>): void {
    let i = 0;
    while (i < log.size()) {
        console.log(`  ${label}: ${log.at(i)}`);
        i = i + 1;
    }
}

fn main(): void {
    // Success: both resources open, nothing is rolled back.
    let ok = list.List<string>();
    let r1 = connectBoth(false, ok) catch -1;
    console.log(`both ok -> result ${r1}`);
    printLog("ok  ", ok);

    // Failure after both are held: the errdefers run last-registered first, so the
    // log shows "closed cache" then "closed db".
    let bad = list.List<string>();
    let r2 = connectBoth(true, bad) catch -1;
    console.log(`final step fails -> result ${r2}`);
    printLog("fail", bad);
}
```

Output:

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

`connectBoth` reads like ordinary straight-line code, yet it is exception-safe. The `errdefer`s only
exist to undo work, they never fire on success, and when the final step fails they unwind in the exact
reverse order.

## Choosing an error type

Reach for an **`exception`** by default: it fails several ways, every caller handles it uniformly with
`catch (e) e.message()`, and the compiler guarantees the `message()` method exists. Fall back to a
plain **enum** when the error is a fixed set of tags you always `switch` on and you do not want a
message contract (`TxError` above is one tag). Fall back to a **struct**, like `OpenError`, when the
error is really one kind of thing carrying a few fields (a code, a message, the resource name). All
three are ordinary types on the error side of `T | E`, and all three let the reason travel to the
caller.

## A second exception: uniform handling of several failure modes

Here is the pattern in its own right. `LookupError` can fail two ways, and because the ok side is a
`string`, the single `catch (e) e.message()` both handles the error and unifies the two arms of the
`catch` (see the same-type rule above). The caller never switches on the error itself, the exception
describes itself.

```kyte
// examples/27_exception.ky
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

Output:

```
count = 42
not found: missing
access denied for guest
```

`lookup` returns a `LookupError`, whose variant records which failure happened. The single
`catch (e) e.message()` dispatches to the matching case, so the caller never switches on the error
itself. Leaving out the `message` method is a compile error:

```
exception 'LookupError' must define a `message(self): string` method
```

The `exception` module also gives you `stackTrace(): string`, the current call stack as text (one
frame per line, works on macOS, Linux, and Windows), which you can log or fold into a `message()`:

```kyte
import exception;
// inside a handler or a message() method:
let trace = exception.stackTrace();
```

`stackTrace()` is not free, so treat it as a diagnostic, not something to call on the hot path. It walks
the live call frames and turns their return addresses into text, and the quality of that text depends on
what symbol information the binary carries: an unstripped build names the functions, while a stripped
release build may give you addresses without names. Because Kyte is compiled and optimised, frames that
were inlined do not appear as separate lines, an aggressively optimised build shows a shorter, flatter
trace than the source would suggest. It is exactly what you want when logging a genuine failure, and not
something to put in a tight loop.

`exception` is a contextual keyword: it is special only at the start of a declaration, so
`import exception;` and ordinary identifiers named `exception` still work. The usual `catch` rule
applies, both arms must have the same type, so an exception reads best with a string ok side since
`message()` returns a string.

## Reference

| Form | Meaning |
|------|---------|
| `fn f(): T \| E` | A fallible function: returns an ok `T` or an error `E` |
| `return E.Variant(x)` | Produce the error side of an enum error (with a reason payload) |
| `return SomeError(...)` | Produce the error side of a struct error |
| `exception E { ...; fn message(self): string {...} }` | A union error type; the compiler requires the `message()` method |
| `f() catch (e) e.message()` | Handle an exception uniformly; dispatches to the failing variant's `message()` |
| `exception.stackTrace()` | The current call stack as a string, one frame per line (macOS, Linux, Windows) |
| `try f()` | Propagate `f`'s error to the caller, unwrap on success |
| `f() catch d` | On error use the expression `d`, ok passes through |
| `f() catch (e) g(e)` | The same, binding the error value as `e` |
| `defer cleanup()` | Run `cleanup()` at every exit from the scope, LIFO |
| `errdefer cleanup()` | Run `cleanup()` only on the error path, LIFO, before the `defer`s |

The rule underneath all of this is simple: an error is a value with a type, so the compiler tracks it,
the caller must handle it, and its reason is preserved from the point of failure all the way up.

Next: [Decimal](12-decimal.md)
