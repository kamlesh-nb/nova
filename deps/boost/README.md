# Vendored Boost.Asio header subset

The Nova C++ runtime uses **only** `<boost/asio.hpp>` (header-only — no `-lboost_*`). Rather than
depend on Homebrew/apt/system Boost, `include/` holds the minimal transitive header closure of
`boost/asio.hpp` (~700 headers, ~7MB), extracted by `vendor-asio-subset.py`.

This makes the Boost dependency **uniform and package-manager-free on all OSes**: the build just
uses `-Ideps/boost/include` (synced to `~/.nova/deps/boost/include` at install; the cross-compile
path in main.zig points there). Override with `BOOST_PREFIX=<prefix>` to use a local full Boost.

Proven: compiles the runtime for macOS (host) AND Linux (`zig c++ -target x86_64-linux-musl`) with
zero Homebrew. Regenerate against a newer Boost with `BOOST_INC=<prefix> python3 vendor-asio-subset.py`.
