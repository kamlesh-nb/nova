# `List<string>` leaks ~138 B per element pair — the failure F4 G3 unblocks

## Measured (2026-07-15)

Dose-response on the TEST BINARY, compile verified PASS each time:

| N (iterations) | peak RSS |
|---:|---:|
| 5,000 | 7.2 MB |
| 20,000 | 8.9 MB |
| 80,000 | 16.9 MB |
| 320,000 | 50.1 MB |

**Linear in N** ⇒ a leak, not high-water/fragmentation. ~138 B per iteration
(each iteration builds a `List<string>` with two heap strings and drops it).

## Repro

```nova
fn churn(n: int): int {
    var i = 0; var total = 0;
    while (i < n) {
        let xs = List<string>();
        xs.push(string.concat("elem", "ent"));
        xs.push(string.concat("more", "data"));
        total = total + xs.size();
        i = i + 1;
    }
    return total;
}
```

## Cause

Erasure. There is **one** `__destruct_List` body for every `List<T>`:

```
$ grep -c '^define .*__destruct_List' __nova_test.ll
1
```

`List<string>` must release its elements; `List<int>` must not. One body cannot do
both, because it does not know what T is — F4 §2.1. So it does neither, and the
strings leak.

## Why this is F4's problem and F5's fix

F4 §4 is explicit: *"F4 alone fixes nothing at runtime; that is expected."* G3 makes
the element type **known at destruction**, which is the precondition F5 needs. This
number does not move until F5 uses it. It is recorded now so that F5 has a
before-figure that was measured rather than remembered.

## Measurement traps hit while getting this number

1. **`/usr/bin/time -l ./zig-out/bin/nova test x.nova` measures the COMPILER.**
   `nova test` compiles and then spawns `./__nova_test` as a child; the parent's
   peak RSS is the compiler's. Measure the test binary directly.
2. **A `sed` that rewrote `fn test_churn()` into `fn test_churn(400000)`** made every
   run after the first compile-fail, so four "measurements" timed one stale binary.
   They read 8.7 / 8.6 / 8.7 / 8.6 MB — *identically* flat, which is the tell. A
   leak measurement that does not verify the compile measures whatever ran last.
