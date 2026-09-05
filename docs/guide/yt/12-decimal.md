# Video 12: Decimal

- Chapter: [12-decimal.md](../12-decimal.md)
- Estimated length: ~9 minutes
- You will need: the `kyte` compiler on your PATH, and the guide example `examples/18_decimal.ky`

## Hook (0:00)

**Say:** Here is a classic trap. In almost every language, `0.1 + 0.2` does not equal `0.3`. It equals `0.30000000000000004`, because binary floating point cannot represent those numbers exactly. That is fine for physics, but it is a disaster for money. Kyte has a type that fixes it: `decimal`, exact base-10 arithmetic. By the end of this video you will use it for prices, totals, and comparisons, with no drift at all.

## What we will cover (0:30)

- What `decimal` is and why it exists
- Literals with the `m` suffix
- The full operator set and comparisons
- The no-implicit-conversion rule between `int` and `decimal`
- A money sum over line items
- Running the example and reading the output

## Segment: What decimal is (1:00)

**Say:** `decimal` is exact base-10 arithmetic. Under the hood it is IEEE 754-2008 decimal128 in BID encoding, a 16-byte heap value, giving you up to 34 significant digits. You use it for money, and for anywhere binary floating point would drift. With `float`, `0.1 + 0.2` is `0.30000000000000004`. With `decimal` it is exactly `0.3`. That exactness is the entire selling point.

**On screen:**
```kyte
// examples/18_decimal.ky
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
```

**Say:** We import list, and define a `LineItem` for a shopping cart: a name, a price which is a `decimal`, and a quantity which is a plain `int`. That mix of decimal price and int quantity matters later, when we have to multiply them.

## Segment: Literals and the exactness proof (2:15)

**Say:** Decimal literals take an `m` suffix, or a capital `M`. So `0.1m`, `9.99m`, `100m`, `-3.14m`. Let us prove the exactness claim directly.

**On screen:**
```kyte
    // The classic binary-float trap: with float, 0.1 + 0.2 is 0.30000000000000004.
    // decimal is exact.
    let a: decimal = 0.1m;
    let b: decimal = 0.2m;
    console.log(`0.1m + 0.2m = ${a + b}`);
    console.log(`exact 0.3?  = ${a + b == 0.3m}`);
```

**Say:** We add `0.1m` and `0.2m`, print the result, and then compare it to `0.3m` directly. In floating point that equality would be false. Here it is genuinely true, because the arithmetic is base-10, not a rounded binary approximation.

## Segment: The full operator set (3:15)

**Say:** All five arithmetic operators work on decimals: plus, minus, times, divide, and modulo, all computed in base-10 with round-half-even. And all six comparisons work too.

**On screen:**
```kyte
    // The full operator set.
    console.log(`9.99m * 3m  = ${9.99m * 3m}`);
    console.log(`10m / 4m    = ${10m / 4m}`);
    console.log(`10m % 3m    = ${10m % 3m}`);
    console.log(`1.50m - 0.25m = ${1.50m - 0.25m}`);

    // Comparisons.
    console.log(`0.1m < 0.2m  = ${a < b}`);
    console.log(`0.3m >= 0.3m = ${0.3m >= 0.3m}`);
```

**Say:** Multiply, divide, modulo, subtract, all exact. Then a less-than and a greater-than-or-equal comparison. Nothing surprising here, and that is the point: it behaves the way base-10 arithmetic should, with no hidden rounding.

## Segment: No implicit conversion (4:30)

**Say:** Here is the one rule that will catch you if you are not ready for it. There is no implicit conversion between `int` and `decimal`. Mixing a bare `int` with a `decimal` is a compile error, not a silent cast. So you always write the decimal literal, `2m` not `2`. If you genuinely have an int and need a decimal, you convert it explicitly. In our cart, quantity is an int, so to multiply price by quantity we have to fold that int into a decimal first.

**On screen:**
```kyte
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
```

**Say:** We build a cart with three items, start the total at `0m`, and loop with `cart.at(i)`, which returns a present `LineItem`, not an optional, because we have already bounded the index. For each line we multiply the price by the quantity, but the quantity is an int, so we pass it through `intToDecimal` first. Then we accumulate into `total`. Here is that helper.

**On screen:**
```kyte
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

**Say:** It simply sums `1m` n times. It is deliberately tiny and honest for the guide. In real code the count would already be a decimal, so you would not need this at all, but it shows the explicit-conversion rule clearly.

## Segment: Run it (6:15)

**Say:** Let us compile and run the whole example and read every line.

**Run it:** `kyte examples/18_decimal.ky -o out && ./out`

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

**Say:** There it is. `0.1m + 0.2m` prints exactly `0.3`, and the equality to `0.3m` is `true`. The operators all give clean results. And the cart total is `13.74`: coffee at 4.75 times two is 9.50, bagel 3.25, tip 0.99, which sums to exactly 13.74, with no rounding drift anywhere in the loop.

## Segment: Why it matters (7:45)

**Say:** So why care about all this? Because `0.1m + 0.2m == 0.3m` being `true` is exactly the property you need for currency. Money must be exact, and every cent has to add up. There is a bonus too: BID encoding is wire-identical to BSON's decimal128, so a decimal round-trips through the database without changing a single digit. That is why `decimal` is the right type for money and for storing it.

## Recap (8:15)

**Say:** Quick recap:

- `decimal` is exact base-10 arithmetic, decimal128 in BID, up to 34 significant digits.
- Literals take an `m` or `M` suffix: `0.1m`, `100m`, `-3.14m`.
- All of plus, minus, times, divide, modulo, and the six comparisons work, in base-10 with round-half-even.
- There is no implicit conversion between `int` and `decimal`; mixing a bare int with a decimal is a compile error, so write `2m` and convert ints explicitly.
- `0.1m + 0.2m == 0.3m` is `true`, which is why decimal is the type for money.

## Outro (8:45)

**Say:** That wraps up decimal, and with it the core value types. Next we move on to ownership and memory, where we look at how Kyte manages heap values without a garbage collector. If this helped, a like and a subscribe are much appreciated.
