#!/usr/bin/env python3
# Extract the minimal Boost.Asio header subset the Nova runtime needs into deps/boost/include.
#
# The runtime includes ONLY <boost/asio.hpp>. bcp is the canonical tool for this but its b2
# bootstrap is flaky on macOS/arm64, so we do the same thing directly: a LEXICAL #include scan
# (follows every `#include <boost/...>` regardless of #ifdef, so it captures the kqueue AND epoll
# AND iocp platform paths — a compiler -M trace on one OS would miss the others). ~700 headers, ~7MB.
#
# Usage: BOOST_INC=/path/to/full/boost/include python3 vendor-asio-subset.py
import os, re, shutil
BOOST_INC = os.environ.get("BOOST_INC", "/opt/homebrew/opt/boost/include")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "include")
inc_re = re.compile(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]', re.M)
seen, queue, copied = set(), ["boost/asio.hpp"], 0
if os.path.isdir(OUT): shutil.rmtree(OUT)
while queue:
    rel = queue.pop()
    if rel in seen: continue
    seen.add(rel)
    src = os.path.join(BOOST_INC, rel)
    if not os.path.isfile(src): continue          # system headers are expected-absent
    dst = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst); copied += 1
    for m in inc_re.findall(open(src, errors="replace").read()):
        if m.startswith("boost/"): queue.append(m)
print(f"vendored {copied} boost headers into {OUT}")
