// webview_nova.cc — Nova <-> webview glue, linked into libwebview.a (so it only
// enters programs that use webview, never the general runtime). Bridges JS -> Nova
// callbacks (webview_bind) and UI-thread tasks (webview_dispatch) by invoking a Nova
// closure from a C trampoline via the exported nova_invoke_*_closure primitives.
#include "webview.h"
#include <cstdlib>

extern "C" {
// Nova runtime ABI (real exported symbols in libnova_runtime.a).
long long nova_invoke_str_closure(long long box, long long arg);
void nova_invoke_void_closure(long long box);
const char *nova_ffi_from_cstr(const char *c);
char *nova_ffi_to_cstr(const char *s);
void nova_ffi_free_cstr(const char *nova_str, char *c);
void nova_retain(long long ptr_val);
void nova_release(long long ptr_val, void (*destructor)(long long));
}

// A plain Nova string owns no sub-fields, so it is released with a null destructor
// ("just free" once the refcount hits zero).
static inline void nova_release_string(long long s) {
  if (s)
    nova_release(s, nullptr);
}

// ---- webview_bind: JS window.<name>(args) -> Nova (string)->string handler -----
struct NovaBindCtx {
  webview_t w;
  long long closure; // Nova closure box handle {fn_ptr, env}
};

static void nova_bind_tramp(const char *seq, const char *req, void *arg) {
  NovaBindCtx *ctx = static_cast<NovaBindCtx *>(arg);
  // req is a JSON array of the JS call arguments; hand it to Nova as a string.
  long long req_nv = (long long)nova_ffi_from_cstr(req ? req : "[]");
  long long res_nv = nova_invoke_str_closure(ctx->closure, req_nv);
  char *res_c = nova_ffi_to_cstr(reinterpret_cast<const char *>(res_nv));
  // status 0 => result is a valid JSON value returned to the JS promise.
  webview_return(ctx->w, seq, 0, res_c ? res_c : "null");
  nova_ffi_free_cstr(reinterpret_cast<const char *>(res_nv), res_c);
  // ARC: we created req_nv (+1) and the closure returned res_nv (+1); the handler param
  // is borrowed, so release both here or every JS call leaks two strings.
  nova_release_string(res_nv);
  nova_release_string(req_nv);
}

// `name` arrives NUL-terminated (FFI string marshalling); webview copies it. The
// closure is retained so it outlives this call and survives until the window closes.
extern "C" void nova_webview_bind(webview_t w, const char *name, void *closure_box) {
  nova_retain(reinterpret_cast<long long>(closure_box));
  NovaBindCtx *ctx = new NovaBindCtx{w, reinterpret_cast<long long>(closure_box)};
  webview_bind(w, name, nova_bind_tramp, ctx);
}

// ---- webview_dispatch: run a Nova ()->void task on the UI thread ---------------
struct NovaDispatchCtx {
  long long closure;
};

static void nova_dispatch_tramp(webview_t /*w*/, void *arg) {
  NovaDispatchCtx *ctx = static_cast<NovaDispatchCtx *>(arg);
  nova_invoke_void_closure(ctx->closure);
  delete ctx; // one-shot
}

extern "C" void nova_webview_dispatch(webview_t w, void *closure_box) {
  nova_retain(reinterpret_cast<long long>(closure_box));
  NovaDispatchCtx *ctx = new NovaDispatchCtx{reinterpret_cast<long long>(closure_box)};
  webview_dispatch(w, nova_dispatch_tramp, ctx);
}
