# 12. Decimal

`decimal` is **exact base-10 arithmetic**: IEEE 754-2008 decimal128 in BID encoding, a 16-byte heap
value. Use it for money and anywhere binary floating point would drift: with `float`, `0.1 + 0.2` is
`0.30000000000000004`; with `decimal` it is *exactly* `0.3`.

- **Literals** take an `m` (or `M`) suffix: `0.1m`, `9.99m`, `100m`, `-3.14m`, up to 34 significant
  digits.
- **All** of `+ - * / %` and the six comparisons (`< <= > >= == !=`) work, computed in base-10 with
  round-half-even.
- **No implicit conversion between `int` and `decimal`.** Mixing a bare `int` with a `decimal` is a *compile error*:
  always write the decimal literal (`2m`, not `2`). Convert an `int` explicitly when you need to.

```nova
// examples/18_decimal.nova
// `decimal` is exact base-10 arithmetic (IEEE 754-2008 decimal128, BID). Use it
// for money and anything where 0.1 + 0.2 must be EXACTLY 0.3. Literals take an
// `m` suffix: `0.1m`, `9.99m`, `100m`. All of `+ - * / %` and the six
// comparisons work. There is NO implicit int<->decimal conversion; a bare `2`
// mixed with a decimal is a compile error, so always write `2m`.
import list;

struct LineItem {
    pub name: string,
    pub price: decimal,
    pub qty: int,
    init(n: string, p: decimal, q: int) { self.name = n; self.price = p; self.qty = q; }
}

fn main(): void {
    // The classic binary-float trap: with float, 0.1 + 0.2 is 0.30000000000000004.
    // decimal is exact.
    let a: decimal = 0.1m;
    let b: decimal = 0.2m;
    console.log(`0.1m + 0.2m = ${a + b}`);
    console.log(`exact 0.3?  = ${a + b == 0.3m}`);

    // The full operator set.
    console.log(`9.99m * 3m  = ${9.99m * 3m}`);
    console.log(`10m / 4m    = ${10m / 4m}`);
    console.log(`10m % 3m    = ${10m % 3m}`);
    console.log(`1.50m - 0.25m = ${1.50m - 0.25m}`);

    // Comparisons.
    console.log(`0.1m < 0.2m  = ${a < b}`);
    console.log(`0.3m >= 0.3m = ${0.3m >= 0.3m}`);

    // A money sum over line items: no rounding drift.
    let cart = list.List<LineItem>();
    cart.push(LineItem("coffee", 4.75m, 2));
    cart.push(LineItem("bagel", 3.25m, 1));
    cart.push(LineItem("tip", 0.99m, 1));

    let total: decimal = 0m;
    let i = 0;
    while (i < cart.size()) {
        let item = cart.at(i);   // .at(i) returns a present LineItem (not optional)
        // qty is an int, so convert it to a decimal; there is no implicit cast.
        let line: decimal = item.price * intToDecimal(item.qty);
        total = total + line;
        i = i + 1;
    }
    console.log(`cart total = ${total}`);
}

// There is no implicit int->decimal conversion, so fold an int into a decimal by
// summing `1m` (kept tiny and honest for the guide). For real code the count
// would already be a decimal.
fn intToDecimal(n: int): decimal {
    let acc: decimal = 0m;
    let i = 0;
    while (i < n) {
        acc = acc + 1m;
        i = i + 1;
    }
    return acc;
}
```

Output:

```
0.1m + 0.2m = 0.3
exact 0.3?  = true
9.99m * 3m  = 29.97
10m / 4m    = 2.5
10m % 3m    = 1
1.50m - 0.25m = 1.25
0.1m < 0.2m  = true
0.3m >= 0.3m = true
cart total = 13.74
```

| Concept | Form |
|---------|------|
| Literal | `0.1m`, `100m`, `-3.14m` (`m`/`M` suffix, <= 34 sig. digits) |
| Arithmetic | `a + b`, `a - b`, `a * b`, `a / b`, `a % b` (exact base-10) |
| Comparison | `a < b`, `a <= b`, `a == b`, ... (all six) |
| No implicit conversion | `price * 2m` is allowed; `price * 2` is a **compile error** |
| Interpolation | `` `${myDecimal}` `` prints the exact value |

`0.1m + 0.2m == 0.3m` is `true` because the arithmetic is genuinely base-10, not a rounded binary
approximation. That exactness (plus BID being wire-identical to BSON's decimal128) is why `decimal` is
the right type for currency and for round-tripping money through the database.

Next: [Ownership & memory](13-ownership.md)
