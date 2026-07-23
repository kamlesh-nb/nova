// Builds the webview 0.10.0 C-ABI symbols into libwebview.a for Nova FFI (extern("webview")).
// macOS backend = Cocoa/WKWebView (Objective-C++); link needs -framework WebKit -framework Cocoa.
#define WEBVIEW_IMPLEMENTATION
#include "webview.h"
