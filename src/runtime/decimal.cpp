
#include <cstring>

extern "C" {
long long nova_bytes_alloc(long long size);
const char *nova_from_bytes(const char *c, long long len);
void nova_panic_cstr(const char *msg);
}

typedef unsigned __int128 nova_u128;

static const int NOVA_DEC128_BIAS = 6176;
static const int NOVA_DEC128_MAX_DIGITS = 34;
static const int NOVA_DEC128_MAX_BIASED = 12287;

static void nova_dec128_pack(unsigned char *out, int sign, nova_u128 coeff, int exp) {
  int biased = exp + NOVA_DEC128_BIAS;
  if (biased < 0) biased = 0;
  if (biased > NOVA_DEC128_MAX_BIASED) biased = NOVA_DEC128_MAX_BIASED;
  nova_u128 v = coeff & ((((nova_u128)1) << 113) - 1);
  v |= ((nova_u128)(biased & 0x3FFF)) << 113;
  if (sign) v |= ((nova_u128)1) << 127;
  std::memcpy(out, &v, 16);
}

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
  int digits = 0;
  int frac = 0;
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

      frac--;
    }

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

extern "C" long long nova_decimal_from_string(const char *s) {
  return dec_parse_bounded(s, s ? (long long)std::strlen(s) : 0);
}

extern "C" long long nova_decimal_from_string_n(const char *s, long long len) {
  return dec_parse_bounded(s, len);
}

extern "C" const char *nova_decimal_to_string(long long ptr) {
  unsigned char *buf = (unsigned char *)ptr;
  nova_u128 v;
  std::memcpy(&v, buf, 16);
  int sign = (int)(v >> 127);
  if (((v >> 125) & 3) == 3) return nova_from_bytes("0", 1);
  int biased = (int)((v >> 113) & 0x3FFF);
  nova_u128 coeff = v & ((((nova_u128)1) << 113) - 1);
  int exp = biased - NOVA_DEC128_BIAS;

  char digs[40];
  int nd = 0;
  if (coeff == 0) {
    digs[nd++] = '0';
  } else {
    while (coeff > 0) { digs[nd++] = (char)('0' + (int)(coeff % 10)); coeff /= 10; }
  }

  char out[80];
  int oi = 0;
  if (sign && !(nd == 1 && digs[0] == '0')) out[oi++] = '-';
  if (exp >= 0) {
    for (int i = nd - 1; i >= 0; i--) out[oi++] = digs[i];
    for (int i = 0; i < exp; i++) out[oi++] = '0';
  } else {
    int point = nd + exp;
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

struct NovaDec {
  int sign;
  nova_u128 coeff;
  int exp;
  bool special;
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

static nova_u128 dec_round_drop(nova_u128 coeff, int k) {
  if (k <= 0) return coeff;
  if (k >= 39) return 0;
  nova_u128 div = dec_pow10(k);
  nova_u128 q = coeff / div;
  nova_u128 r = coeff % div;
  nova_u128 half = div / 2;
  if (r > half) q += 1;
  else if (r == half && (q & 1)) q += 1;
  return q;
}

static long long dec_encode(NovaDec d) {
  int nd = dec_num_digits(d.coeff);
  if (nd > NOVA_DEC128_MAX_DIGITS) {
    int drop = nd - NOVA_DEC128_MAX_DIGITS;
    d.coeff = dec_round_drop(d.coeff, drop);
    d.exp += drop;
    if (dec_num_digits(d.coeff) > NOVA_DEC128_MAX_DIGITS) {
      d.coeff = dec_round_drop(d.coeff, 1);
      d.exp += 1;
    }
  }
  if (d.coeff == 0) d.sign = 0;
  long long ptr = nova_bytes_alloc(16);
  nova_dec128_pack((unsigned char *)ptr, d.sign, d.coeff, d.exp);
  return ptr;
}

static long long dec_zero() {
  long long ptr = nova_bytes_alloc(16);
  nova_dec128_pack((unsigned char *)ptr, 0, 0, 0);
  return ptr;
}

static void dec_strip_to(NovaDec *d, int pref_exp) {
  while (d->exp < pref_exp && d->coeff != 0 && d->coeff % 10 == 0) {
    d->coeff /= 10;
    d->exp += 1;
  }
}

static void dec_align(NovaDec *a, NovaDec *b) {
  int E = a->exp < b->exp ? a->exp : b->exp;
  int amsd = a->exp + dec_num_digits(a->coeff);
  int bmsd = b->exp + dec_num_digits(b->coeff);
  int msd = amsd > bmsd ? amsd : bmsd;
  int minE = msd - 37;
  if (E < minE) E = minE;

  if (a->exp > E) { a->coeff *= dec_pow10(a->exp - E); a->exp = E; }
  else if (a->exp < E) { a->coeff = dec_round_drop(a->coeff, E - a->exp); a->exp = E; }
  if (b->exp > E) { b->coeff *= dec_pow10(b->exp - E); b->exp = E; }
  else if (b->exp < E) { b->coeff = dec_round_drop(b->coeff, E - b->exp); b->exp = E; }
}

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
  bb.sign ^= 1;
  return dec_add_signed(dec_decode(a), bb);
}

extern "C" long long nova_decimal_mul(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return dec_zero();

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

  if (y.coeff == 0) nova_panic_cstr("decimal divide by zero");
  if (x.coeff == 0) return dec_zero();

  int P = NOVA_DEC128_MAX_DIGITS + 1 - dec_num_digits(x.coeff);
  int maxP = 38 - dec_num_digits(x.coeff);
  if (P < 0) P = 0;
  if (P > maxP) P = maxP;
  nova_u128 num = x.coeff * dec_pow10(P);
  nova_u128 q = num / y.coeff;
  nova_u128 rem = num % y.coeff;
  nova_u128 twice = rem * 2;
  if (twice > y.coeff) q += 1;
  else if (twice == y.coeff && (q & 1)) q += 1;
  NovaDec r{x.sign ^ y.sign, q, x.exp - y.exp - P, false};
  dec_strip_to(&r, x.exp - y.exp);
  return dec_encode(r);
}

extern "C" long long nova_decimal_mod(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return dec_zero();
  if (y.coeff == 0) nova_panic_cstr("decimal modulo by zero");
  dec_align(&x, &y);
  NovaDec r{x.sign, x.coeff % y.coeff, x.exp, false};
  return dec_encode(r);
}

extern "C" long long nova_decimal_from_int(long long n) {
  int sign = 0;
  unsigned long long mag;
  if (n < 0) { sign = 1; mag = (unsigned long long)(-(n + 1)) + 1ULL; }
  else mag = (unsigned long long)n;
  NovaDec d{sign, (nova_u128)mag, 0, false};
  return dec_encode(d);
}

extern "C" long long nova_decimal_to_int(long long ptr) {
  NovaDec d = dec_decode(ptr);
  if (d.special) return 0;
  nova_u128 mag = d.coeff;
  const nova_u128 imax = (nova_u128)9223372036854775807ULL;
  const nova_u128 imin_mag = (nova_u128)9223372036854775808ULL;
  if (d.exp > 0) {
    for (int i = 0; i < d.exp; i++) {
      if (mag > imin_mag) nova_panic_cstr("decimal to int overflow");
      mag *= 10;
    }
  } else if (d.exp < 0) {
    int k = -d.exp;
    mag = (k >= 39) ? (nova_u128)0 : mag / dec_pow10(k);
  }
  if (d.sign) {
    if (mag > imin_mag) nova_panic_cstr("decimal to int overflow");
    if (mag == imin_mag) return (long long)(-9223372036854775807LL - 1);
    return -(long long)mag;
  }
  if (mag > imax) nova_panic_cstr("decimal to int overflow");
  return (long long)mag;
}

extern "C" long long nova_decimal_cmp(long long a, long long b) {
  NovaDec x = dec_decode(a), y = dec_decode(b);
  if (x.special || y.special) return 0;
  bool xz = (x.coeff == 0), yz = (y.coeff == 0);
  if (xz && yz) return 0;
  int xs = xz ? 0 : (x.sign ? -1 : 1);
  int ys = yz ? 0 : (y.sign ? -1 : 1);
  if (xs != ys) return xs < ys ? -1 : 1;
  dec_align(&x, &y);
  int mag = (x.coeff < y.coeff) ? -1 : (x.coeff > y.coeff ? 1 : 0);
  return (xs < 0) ? -mag : mag;
}
