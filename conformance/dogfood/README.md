# Dogfood suite

Realistic, whole-program feature COMBINATIONS (generics + closures + traits + optionals + error-unions +
async, in combination), each `main()`-driven and expected to compile and exit 0. Unlike `../cases/` (which
are `@test` suites checking behaviour), this suite is the "can I build a real program without hitting a
compiler bug" net: it catches crashes and miscompiles that only appear when features are stacked.

Run:

    conformance/run.sh --dogfood                 # crash net (a hard SEGV exits non-zero)
    KYTE_ASAN=1 conformance/run.sh --dogfood      # + use-after-free detection (needs KYTE_ASAN=1 zig build)

It is part of `gate.sh`. Grown from the last-lap crash hunt (2026-08-15): 44 programs, all green.
**When a new crash class is found and fixed, add a program here so it can never silently return.**
