// webview_kyte.cc — Kyte <-> webview glue, linked into libwebview.a (so it only
// enters programs that use webview, never the general runtime). Bridges JS -> Kyte
// callbacks (webview_bind) and UI-thread tasks (webview_dispatch) by invoking a Kyte
// closure from a C trampoline via the exported kyte_invoke_*_closure primitives.
#include "webview.h"
#include <cstdlib>

extern "C" {
// Kyte runtime ABI (real exported symbols in libkyte_runtime.a).
long long kyte_invoke_str_closure(long long box, long long arg);
void kyte_invoke_void_closure(long long box);
const char *kyte_ffi_from_cstr(const char *c);
char *kyte_ffi_to_cstr(const char *s);
void kyte_ffi_free_cstr(const char *kyte_str, char *c);
void kyte_retain(long long ptr_val);
void kyte_release(long long ptr_val, void (*destructor)(long long));
}

// A plain Kyte string owns no sub-fields, so it is released with a null destructor
// ("just free" once the refcount hits zero).
static inline void kyte_release_string(long long s) {
  if (s)
    kyte_release(s, nullptr);
}

// ---- webview_bind: JS window.<name>(args) -> Kyte (string)->string handler -----
struct KyteBindCtx {
  webview_t w;
  long long closure; // Kyte closure box handle {fn_ptr, env}
};

static void kyte_bind_tramp(const char *seq, const char *req, void *arg) {
  KyteBindCtx *ctx = static_cast<KyteBindCtx *>(arg);
  // req is a JSON array of the JS call arguments; hand it to Kyte as a string.
  long long req_nv = (long long)kyte_ffi_from_cstr(req ? req : "[]");
  long long res_nv = kyte_invoke_str_closure(ctx->closure, req_nv);
  char *res_c = kyte_ffi_to_cstr(reinterpret_cast<const char *>(res_nv));
  // status 0 => result is a valid JSON value returned to the JS promise.
  webview_return(ctx->w, seq, 0, res_c ? res_c : "null");
  kyte_ffi_free_cstr(reinterpret_cast<const char *>(res_nv), res_c);
  // ARC: we created req_nv (+1) and the closure returned res_nv (+1); the handler param
  // is borrowed, so release both here or every JS call leaks two strings.
  kyte_release_string(res_nv);
  kyte_release_string(req_nv);
}

// `name` arrives NUL-terminated (FFI string marshalling); webview copies it. The
// closure is retained so it outlives this call and survives until the window closes.
extern "C" void kyte_webview_bind(webview_t w, const char *name, void *closure_box) {
  kyte_retain(reinterpret_cast<long long>(closure_box));
  KyteBindCtx *ctx = new KyteBindCtx{w, reinterpret_cast<long long>(closure_box)};
  webview_bind(w, name, kyte_bind_tramp, ctx);
}

// ---- webview_dispatch: run a Kyte ()->void task on the UI thread ---------------
struct KyteDispatchCtx {
  long long closure;
};

static void kyte_dispatch_tramp(webview_t /*w*/, void *arg) {
  KyteDispatchCtx *ctx = static_cast<KyteDispatchCtx *>(arg);
  kyte_invoke_void_closure(ctx->closure);
  delete ctx; // one-shot
}

extern "C" void kyte_webview_dispatch(webview_t w, void *closure_box) {
  kyte_retain(reinterpret_cast<long long>(closure_box));
  KyteDispatchCtx *ctx = new KyteDispatchCtx{reinterpret_cast<long long>(closure_box)};
  webview_dispatch(w, kyte_dispatch_tramp, ctx);
}
