// decimal.cpp — IEEE 754-2008 decimal128 (BID encoding), BSON-wire-compatible.
//
// Nova's `decimal` is a 16-byte HEAP object (like `string`): the value in a slot is a pointer to a
// standard ARC-managed heap allocation whose 16-byte payload is the decimal128 in BID (Binary Integer
// Decimal) form — the exact encoding MongoDB's BSON decimal128 uses, so the driver can hand the 16
// bytes straight to the wire with no conversion.
//
// Stage 1: from_string / to_string. Stage 3: BSON hooks (bytes.write_decimal/read_decimal — a straight
// memcpy of the 16 payload bytes). Stage 2 (below): arithmetic (+ - * / %) and compare, done in base-10
// on the decoded (sign, coefficient, exponent) triple with round-half-even to 34 significant digits.
//
// BID128 layout (a 128-bit value, stored little-endian in the 16 payload bytes). For any value with
// <= 34 significant digits the coefficient fits in 113 bits (10^34 < 2^113), giving the "small
// coefficient" form:
//   bit 127      : sign
//   bits 126..113: biased exponent (14 bits, bias 6176)   — its top 2 bits are never "11" here
//   bits 112..0  : coefficient (a 113-bit binary integer)
// number = (-1)^sign * coefficient * 10^(biasedExponent - 6176).

#include <cstring>

extern "C" {
long long nova_bytes_alloc(long long size);
const char *nova_from_bytes(const char *c, long long len);
void nova_panic_cstr(const char *msg); // loud abort on divide-by-zero (core.cpp)
}

typedef unsigned __int128 nova_u128;

static const int NOVA_DEC128_BIAS = 6176;
static const int NOVA_DEC128_MAX_DIGITS = 34;
static const int NOVA_DEC128_MAX_BIASED = 12287; // 2*bias - 1

// Pack sign/coefficient/exponent into the 16 BID bytes (little-endian).
static void nova_dec128_pack(unsigned char *out, int sign, nova_u128 coeff, int exp) {
  int biased = exp + NOVA_DEC128_BIAS;
  if (biased < 0) biased = 0;
  if (biased > NOVA_DEC128_MAX_BIASED) biased = NOVA_DEC128_MAX_BIASED;
  nova_u128 v = coeff & ((((nova_u128)1) << 113) - 1);
  v |= ((nova_u128)(biased & 0x3FFF)) << 113;
  if (sign) v |= ((nova_u128)1) << 127;
  std::memcpy(out, &v, 16);
}

// Parse the first `len` bytes of a decimal string ("10.5", "-3", "1.23e4", "0.001") into a fresh
// 16-byte heap decimal. LENGTH-BOUNDED — never reads past `end`, so it is safe on a Nova string
// that is NOT NUL-terminated (a runtime `string.slice` produces exactly-`len` bytes with no NUL).
static long long dec_parse_bounded(const char *s, long long len) {
  long long ptr = nova_bytes_alloc(16);
  unsigned char *buf = (unsigned char *)ptr;
  if (!s || len <= 0) {
    std::memset(buf, 0, 16);
    nova_dec128_pack(buf, 0, 0, 0);
    return ptr;
  }
  const char *p = s;
  const char *e_end = s + len;
  while (p < e_end && *p == ' ') p++;
  int sign = 0;
  if (p < e_end && *p == '+') p++;
  else if (p < e_end && *p == '-') { sign = 1; p++; }

  nova_u128 coeff = 0;
  int digits = 0;   // significant digits captured (capped at 34)
  int frac = 0;     // fraction digits captured
  bool seen_dot = false;
  for (; p < e_end; p++) {
    char c = *p;
    if (c == '.') { if (seen_dot) break; seen_dot = true; continue; }
    if (c == 'e' || c == 'E') break;
    if (c < '0' || c > '9') break;
    if (digits < NOVA_DEC128_MAX_DIGITS) {
      coeff = coeff * 10 + (nova_u128)(c - '0');
      digits++;
      if (seen_dot) frac++;
    } else if (!seen_dot) {
      // Dropped an INTEGER digit past 34 significant: value scales up by 10 (raise the exponent).
      frac--;
    }
    // Dropped FRACTION digits past 34 are simply truncated (Stage 1 has no rounding).
  }
  int exp = -frac;
  if (p < e_end && (*p == 'e' || *p == 'E')) {
    p++;
    int esign = 1;
    if (p < e_end && *p == '+') p++;
    else if (p < e_end && *p == '-') { esign = -1; p++; }
    int ev = 0;
    for (; p < e_end && *p >= '0' && *p <= '9'; p++) ev = ev * 10 + (*p - '0');
    exp += esign * ev;
  }
  nova_dec128_pack(buf, sign, coeff, exp);
  return ptr;
}

// The literal path hands a NUL-terminated C string (LLVM global) — length = strlen.
extern "C" long long nova_decimal_from_string(const char *s) {
  return dec_parse_bounded(s, s ? (long long)std::strlen(s) : 0);
}

// S4/S1: a RUNTIME Nova string may NOT be NUL-terminated — parse exactly `len` bytes (the caller
// reads `len` from the string's header). This is what `decimal.fromString` routes to.
extern "C" long long nova_decimal_from_string_n(const char *s, long long len) {
  return dec_parse_bounded(s, len);
}

// Format a 16-byte heap decimal back to a Nova string, placing the decimal point by the exponent.
extern "C" const char *nova_decimal_to_string(long long ptr) {
  unsigned char *buf = (unsigned char *)ptr;
  nova_u128 v;
  std::memcpy(&v, buf, 16);
  int sign = (int)(v >> 127);
  if (((v >> 125) & 3) == 3) return nova_from_bytes("0", 1); // special (inf/nan/large) — Stage 1 stub
  int biased = (int)((v >> 113) & 0x3FFF);
  nova_u128 coeff = v & ((((nova_u128)1) << 113) - 1);
  int exp = biased - NOVA_DEC128_BIAS;

  // Coefficient digits, least-significant first.
  char digs[40];
  int nd = 0;
  if (coeff == 0) {
    digs[nd++] = '0';
  } else {
    while (coeff > 0) { digs[nd++] = (char)('0' + (int)(coeff % 10)); coeff /= 10; }
  }

  char out[80];
  int oi = 0;
  if (sign && !(nd == 1 && digs[0] == '0')) out[oi++] = '-'; // no "-0"
  if (exp >= 0) {
    for (int i = nd - 1; i >= 0; i--) out[oi++] = digs[i];
    for (int i = 0; i < exp; i++) out[oi++] = '0';
  } else {
    int point = nd + exp; // number of digits before the decimal point
    if (point <= 0) {
      out[oi++] = '0';
      out[oi++] = '.';
      for (int i = 0; i < -point; i++) out[oi++] = '0';
      for (int i = nd - 1; i >= 0; i--) out[oi++] = digs[i];
    } else {
      int emitted = 0;
      for (int i = nd - 1; i >= 0; i--) {
        out[oi++] = digs[i];
        emitted++;
        if (emitted == point && i > 0) out[oi++] = '.';
      }
    }
  }
  out[oi] = 0;
  return nova_from_bytes(out, oi);
}

// ── Stage 2: arithmetic + compare (BID base-10) ─────────────────────────────────────────
//
// All ops decode both operands to a (sign, coefficient, exponent) triple, do exact base-10
// integer arithmetic on the coefficients after aligning exponents, then re-encode — rounding
// to decimal128's 34 significant digits with round-half-even. `unsigned __int128` (~38 decimal
// digits) is the working width; alignment/products are bounded to stay inside it (rounding the
// less-significant operand away when they would not fit — exactly what a 34-digit result permits).

struct NovaDec {
  int sign;        // 0 = +, 1 = -
  nova_u128 coeff; // magnitude
  int exp;         // value = (-1)^sign * coeff * 10^exp
  bool special;    // inf/NaN (Stage-2 stub: treated as 0)
};

static NovaDec dec_decode(long long ptr) {
  NovaDec d{0, 0, 0, false};
  nova_u128 v;
  std::memcpy(&v, (unsigned char *)ptr, 16);
  d.sign = (int)(v >> 127);
  if (((v >> 125) & 3) == 3) { d.special = true; return d; }
  int biased = (int)((v >> 113) & 0x3FFF);
  d.coeff = v & ((((nova_u128)1) << 113) - 1);
  d.exp = biased - NOVA_DEC128_BIAS;
  return d;
}

static int dec_num_digits(nova_u128 v) {
  int n = 0;
  do { n++; v /= 10; } while (v > 0);
  return n;
}

static nova_u128 dec_pow10(int k) {
  nova_u128 r = 1;
  while (k-- > 0) r *= 10;
  return r;
}

// Drop the low `k` decimal digits of `coeff` with round-half-even. Caller adjusts the exponent by +k.
static nova_u128 dec_round_drop(nova_u128 coeff, int k) {
  if (k <= 0) return coeff;
  if (k >= 39) return 0; // more digits than fit in u128 -> everything rounds away
  nova_u128 div = dec_pow10(k);
  nova_u128 q = coeff / div;
  nova_u128 r = coeff % div;
  nova_u128 half = div / 2;
  if (r > half) q += 1;
  else if (r == half && (q & 1)) q += 1; // exactly half -> round to even
  return q;
}

// Normalize to <= 34 significant digits (round-half-even), allocate a fresh 16-byte heap decimal, pack.
static long long dec_encode(NovaDec d) {
  int nd = dec_num_digits(d.coeff);
  if (nd > NOVA_DEC128_MAX_DIGITS) {
    int drop = nd - NOVA_DEC128_MAX_DIGITS;
    d.coeff = dec_round_drop(d.coeff, drop);
    d.exp += drop;
    if (dec_num_digits(d.coeff) > NOVA_DEC128_MAX_DIGITS) { // 999..9 -> 1000..0 carried a digit
      d.coeff = dec_round_drop(d.coeff, 1);
      d.exp += 1;
    }
  }
  if (d.coeff == 0) d.sign = 0; // canonical zero has no sign
  long long ptr = nova_bytes_alloc(16);
  nova_dec128_pack((unsigned char *)ptr, d.sign, d.coeff, d.exp);
  return ptr;
}

static long long dec_zero() {
  long long ptr = nova_bytes_alloc(16);
  nova_dec128_pack((unsigned char *)ptr, 0, 0, 0);
  return ptr;
}

// Remove trailing zero digits (raising the exponent) but not past `pref_exp`. This gives an operation
// its IEEE 754 "preferred exponent": e.g. an exact `1m / 4m` becomes `0.25` (coeff 25, exp -2) rather
// than `0.2500…0` (the wide quotient the division loop produced), while `1.5m * 2m` keeps its `3.0`.
static void dec_strip_to(NovaDec *d, int pref_exp) {
  while (d->exp < pref_exp && d->coeff != 0 && d->coeff % 10 == 0) {
    d->coeff /= 10;
    d->exp += 1;
  }
}

// Bring a and b to a common exponent, rounding the finer operand if exact alignment would overflow
// u128. The chosen exponent keeps at most ~37 digits above it — enough for a 34-digit result plus
// guard, and provably inside u128 (see the digit-count bound below).
static void dec_align(NovaDec *a, NovaDec *b) {
  int E = a->exp < b->exp ? a->exp : b->exp;
  int amsd = a->exp + dec_num_digits(a->coeff); // position just past a's most-significant digit
  int bmsd = b->exp + dec_num_digits(b->coeff);
  int msd = amsd > bmsd ? amsd : bmsd;
  int minE = msd - 37;
  if (E < minE) E = minE;
  // a -> E : scale up (exact, <=37 digits => fits u128) or round down (drops sub-precision digits).
  if (a->exp > E) { a->coeff *= dec_pow10(a->exp - E); a->exp = E; }
  else if (a->exp < E) { a->coeff = dec_round_drop(a->coeff, E - a->exp); a->exp = E; }
  if (b->exp > E) { b->coeff *= dec_pow10(b->exp - E); b->exp = E; }
  else if (b->exp < E) { b->coeff = dec_round_drop(b->coeff, E - b->exp); b->exp = E; }
}

// Signed base-10 add of two aligned-or-not operands (subtraction flips b's sign before calling).
static long long dec_add_signed(NovaDec a, NovaDec b) {
  if (a.special || b.special) return dec_zero();
  dec_align(&a, &b);
  NovaDec r{0, 0, a.exp, false};
  if (a.sign == b.sign) {
    r.coeff = a.coeff + b.coeff;
    r.sign = a.sign;
  } else if (a.coeff >= b.coeff) {
    r.coeff = a.coeff - b.coeff;
    r.sign = a.sign;
  } else {
    r.coeff = b.coeff - a.coeff;
    r.sign = b.sign;
  }
  return dec_encode(r);
}

extern "C" long long nova_decimal_add(long long a, long long b) {
  return dec_add_signed(dec_decode(a), dec_decode(b));
}

extern "C" long long nova_decimal_sub(long long a, long long b) {
  NovaDec bb = dec_decode(b);
  bb.sign ^= 1; // a - b = a + (-b)
  return dec_add_signed(dec_decode(a), bb);
}

extern "C" long long nova_decimal_mul(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return dec_zero();
  // Keep the product inside u128: round the wider operand down until the digit counts sum to <= 34
  // (a 34-digit product is < 10^34 < 2^113). Loses only sub-34-digit precision, which the result
  // could not hold anyway.
  while (x.coeff != 0 && y.coeff != 0 &&
         dec_num_digits(x.coeff) + dec_num_digits(y.coeff) > NOVA_DEC128_MAX_DIGITS) {
    if (dec_num_digits(x.coeff) >= dec_num_digits(y.coeff)) { x.coeff = dec_round_drop(x.coeff, 1); x.exp += 1; }
    else { y.coeff = dec_round_drop(y.coeff, 1); y.exp += 1; }
  }
  NovaDec r{x.sign ^ y.sign, x.coeff * y.coeff, x.exp + y.exp, false};
  return dec_encode(r);
}

extern "C" long long nova_decimal_div(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return dec_zero();
  // S3: divide-by-zero is a programmer error — TRAP loudly instead of the silent 0-stub that
  // returned a wrong answer. `y` is a real (non-special) zero here.
  if (y.coeff == 0) nova_panic_cstr("decimal divide by zero");
  if (x.coeff == 0) return dec_zero();
  // Scale the numerator up so the quotient carries ~34 significant digits, staying inside u128.
  int P = NOVA_DEC128_MAX_DIGITS + 1 - dec_num_digits(x.coeff);
  int maxP = 38 - dec_num_digits(x.coeff);
  if (P < 0) P = 0;
  if (P > maxP) P = maxP;
  nova_u128 num = x.coeff * dec_pow10(P);
  nova_u128 q = num / y.coeff;
  nova_u128 rem = num % y.coeff;
  nova_u128 twice = rem * 2; // round-half-even on the division remainder
  if (twice > y.coeff) q += 1;
  else if (twice == y.coeff && (q & 1)) q += 1;
  NovaDec r{x.sign ^ y.sign, q, x.exp - y.exp - P, false};
  dec_strip_to(&r, x.exp - y.exp); // exact quotients get their preferred exponent (0.25, not 0.2500…0)
  return dec_encode(r);
}

extern "C" long long nova_decimal_mod(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return dec_zero();
  if (y.coeff == 0) nova_panic_cstr("decimal modulo by zero"); // S3: trap, not silent 0
  dec_align(&x, &y);
  NovaDec r{x.sign, x.coeff % y.coeff, x.exp, false}; // remainder takes the dividend's sign
  return dec_encode(r);
}

// S3: EXPLICIT int <-> decimal conversions (Nova has no implicit numeric coercion). Exposed as
// `decimal.fromInt(n)` / `decimal.toInt(d)`.

// A 64-bit signed int -> an exact decimal (coefficient = |n|, exponent 0). Fresh 16-byte heap (+1).
extern "C" long long nova_decimal_from_int(long long n) {
  int sign = 0;
  unsigned long long mag;
  if (n < 0) { sign = 1; mag = (unsigned long long)(-(n + 1)) + 1ULL; } // no UB at LLONG_MIN
  else mag = (unsigned long long)n;
  NovaDec d{sign, (nova_u128)mag, 0, false};
  return dec_encode(d);
}

// A decimal -> a 64-bit signed int, TRUNCATING toward zero (drops the fractional digits, like a C cast).
// Traps loudly if the truncated value does not fit in i64 — a wrong answer is never returned silently.
extern "C" long long nova_decimal_to_int(long long ptr) {
  NovaDec d = dec_decode(ptr);
  if (d.special) return 0;
  nova_u128 mag = d.coeff;
  const nova_u128 imax = (nova_u128)9223372036854775807ULL;     // i64 max = 2^63 - 1
  const nova_u128 imin_mag = (nova_u128)9223372036854775808ULL; // |i64 min| = 2^63
  if (d.exp > 0) {
    for (int i = 0; i < d.exp; i++) {
      if (mag > imin_mag) nova_panic_cstr("decimal to int overflow"); // can only grow from here
      mag *= 10;
    }
  } else if (d.exp < 0) {
    int k = -d.exp;
    mag = (k >= 39) ? (nova_u128)0 : mag / dec_pow10(k); // truncate toward zero
  }
  if (d.sign) {
    if (mag > imin_mag) nova_panic_cstr("decimal to int overflow");
    if (mag == imin_mag) return (long long)(-9223372036854775807LL - 1); // i64 min
    return -(long long)mag;
  }
  if (mag > imax) nova_panic_cstr("decimal to int overflow");
  return (long long)mag;
}

// Three-way compare: -1 if a<b, 0 if equal, 1 if a>b.
extern "C" long long nova_decimal_cmp(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return 0;
  bool xz = (x.coeff == 0), yz = (y.coeff == 0);
  if (xz && yz) return 0;
  int xs = xz ? 0 : (x.sign ? -1 : 1);
  int ys = yz ? 0 : (y.sign ? -1 : 1);
  if (xs != ys) return xs < ys ? -1 : 1;
  dec_align(&x, &y); // same sign (or one is zero) -> compare magnitudes at a common exponent
  int mag = (x.coeff < y.coeff) ? -1 : (x.coeff > y.coeff ? 1 : 0);
  return (xs < 0) ? -mag : mag; // for negatives, larger magnitude is smaller
}
