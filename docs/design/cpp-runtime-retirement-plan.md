# Retiring the C++ Runtime: A Structured Migration Plan

## Tracker

Statuses: DONE, WIP (in progress or partially landed), TODO. Update this table as the single source of
truth for progress; the phase details are below.

| Phase | What it retires or builds | Prereq | Status | Notes |
|-------|---------------------------|--------|--------|-------|
| Foundation | Event loop, buffers, HTTP parser, poll and socket layer, multi-core | none | DONE | `self-hosted-runtime.md` phases 1 to 5; race-free under `--tsan` |
| M0 | Tooling: file-based runtime trace, symbol audit | none | DONE | `NOVA_TRACE=<file>` trace (surfaces reliably), `tools/runtime-symbol-audit.sh` (221 exported / 203 referenced) |
| M1 | Async scheduler migration (per-reactor run queue) | M0 | DONE | Nested/multi-level `await` and `spawn`+`await` drain on the reactor (corpus 199, trace-proven); Asio-backed awaits on the reactor now fail fast via `nova_reactor_io_violation` instead of silently orphaning (their migration is M2) |
| M2 | Async socket I/O on the reactor | M1 | DONE | `net/reactorio` = reactor-native recv/send/connect/accept/resolve in Nova over `os/sys`; a thread-local current reactor; `asyncio.AsyncStream` dual-mode; `web/app.serveReactorConn`/`runReactor` run a whole request on the reactor. Corpus 200 to 204 (socketpair, loopback connect/accept, the AsyncStream seam, connect-by-name, and a full App request), all TSan clean. Remaining before flagship-DB-on-reactor (M3): multi-core reactor server (the `runReactors` worker cannot yet carry the App) and async DNS |
| M3 | Database drivers on the reactor | M2 | DONE (mock) | The drivers connect via `asyncConnect` and do I/O through `AsyncStream`, both reactor-native from M2, so they run on the reactor with no driver change. Corpus 205: an App handler makes a per-request DB call (mock DB on the same reactor) end to end, no Asio, closing the PH6 deadlock. A live-driver run needs a reachable database; the driver code is unchanged |
| M4 | Retire Boost.Asio | M1 to M3 | DONE | The async runtime is reactor-native end to end: `nova_sched_schedule` is just the run queue, timers/deadlines/TLS/sockets are reactor-native, `nova_run_root` drives async on the reactor, and the multi-core server uses the share-nothing reactor. The Asio `io_context`/strands/thread-pool/`CoroState` and socket primitives are deleted (the latter kept as loud abort stubs for the dead codegen branch); the `<boost/asio.hpp>` include, the Boost build flags, and the vendored `deps/boost` (~7MB) are gone. Native 198, ASAN 365, TSan 215, no Boost |
| M5 | File and directory I/O in Nova | M4 (soft) | DONE | `io/file.nova` + `io/dir.nova` over `os/sys` (open/read/write/lseek/close, mkdir/rmdir/rename, stat/access, opendir/readdir/closedir); `nova_file_*`/`nova_dir_*` deleted; only the variadic `nova_open` shim stays. `io.cpp` 1116 to 950. Native 199, ASAN 367, TSan 216 |
| M6 | Process and primitive shims | none | DONE | `reuseport` (pure Nova `setsockopt`) and env `get`/`set` (`os/sys` `getenv`/`setenv`) moved to Nova; their C deleted. The honest-primitive floor stays: `errno` (a macro), `set_nonblock` (variadic), `close` (the tcp stack cannot import `os/sys`: its `socket` export collides by name with the `socket` module; the reactor path already uses `sys.close`), `exit` (`_Exit`), args (argv capture), atomics, mutex/condvar/rwlock/spinlock |
| M7 | Channels and actors in Nova | M1, M6 | DONE | Actors (`Mailbox<M>`, `ActorCell<M>`) are already Nova over the reactor. The async channel (`nova_chan_*`) is reclassified as part of the reactor scheduler ABI-CORE seam: codegen emits `nova_chan_recv` directly around `llvm.coro.suspend`, and `nova_chan_send` wakes waiters via `nova_sched_schedule`, so it stays in the minimal C core. The vestigial blocking `Channel<T>` is deferred pending generic-container ARC ownership |
| M8 | Allocator backing in Nova | none | DONE | The bump arena under `nova_bytes_alloc` is backed by `mmap` anonymous pages, not libc `malloc`; `os/sys` exposes `mmap`/`munmap` so a Nova arena can do the same. ABI-CORE entry points and heap header unchanged. Native 200, ASAN 369; alloc microbench not regressed |
| M9 | TLS 1.2 and 1.3 protocol in Nova | M2 | WIP | NO external package: implement the crypto PRIMITIVES and the TLS 1.2/1.3 protocol in Nova, retire wolfSSL. Refs: Zig `std.crypto` + the `plancksystems/tls` package. Slices: 9.0 primitives (SHA/HMAC/HKDF, ChaCha20/Poly1305, AES/GHASH/GCM, X25519/P-256, RSA/ECDSA), 9.1 record, 9.2 key schedule, 9.3 handshake, 9.4 integration+retire wolfSSL, 9.5 TLS 1.2. Done: hex/binary/octal literals (case 214). Phase A COMPLETE (hashes + KDF in Nova): SHA-256 (215), SHA-384/512 (216), SHA-1 + HMAC-SHA256/384/512 (217), HKDF + TLS 1.3 Expand-Label/Derive-Secret (218); NIST, RFC 4231, RFC 5869, RFC 8448 KATs. Phase B: ChaCha20 + Poly1305 + ChaCha20-Poly1305 AEAD (cases 219, 220); constant-time bitsliced AES-128/256 (case 221, BearSSL aes_ct port); GHASH (case 222); AES-GCM (case 223, GCM Test Cases 3/4). Phase B (symmetric ciphers) COMPLETE in Nova, all constant-time (also AES-CTR case 224). Phase C STARTED: X25519 (case 225, RFC 7748), constant-time Montgomery ladder over the ref10 field; P-256 ECDH (case 226), Montgomery CIOS field + BearSSL Jacobian point formulas + the qz-flag constant-time 2-bit-window ladder, verified against OpenSSL-generated key pairs and shared secret; P-256 ECDSA verify (case 227), a mod-n Montgomery scalar layer (same CIOS with n's constants, n0'=0xee00bc4f) + u1*G+u2*Q via two ladders and a full-case affine add + R.x mod n == r, verified against a real OpenSSL ECDSA-SHA256 signature plus tamper rejections (verify handles only public data, so it is not constant-time by design). RSA verify (crypto/rsa.nova, case 228): RSASSA-PKCS1-v1_5 and RSASSA-PSS (MGF1, salt=hashLen) over a runtime-sized modulus, the CIOS montmul generalised to a runtime N + n0' (Newton), s^e mod N with the small public exponent, verified against real OpenSSL RSA-2048 SHA-256 signatures of both schemes plus tamper and cross-scheme rejections. Phase C (public-key) COMPLETE for the TLS-1.3-required set. Phase D STARTED: X.509 (crypto/x509.nova, case 229) - a DER/ASN.1 TLV reader + certificate field extraction (raw TBS, subject public key RSA/EC, sig alg OID, signature value) + verifySignedBy that hashes the TBS and checks the signature with the issuer's key via the Nova ECDSA/RSA verifiers; verified against OpenSSL-generated EC and RSA chains (leaf-by-CA, self-signed CA, wrong-issuer + tampered rejections) plus DER issuer/subject name matching. Next in D: chain building + validity dates + basic-constraints + hostname/SAN matching + a trust store. Phase E STARTED: TLS 1.3 key schedule + record protection (crypto/tls13.nova, case 230) - the RFC 8446 s7.1 key schedule composed over the existing HKDF-Expand-Label/Derive-Secret (early -> derived -> handshake secret -> traffic secrets -> per-direction key/IV) + the s5.2 record AEAD (per-record nonce = IV XOR seq, AAD = record header, AES-GCM/ChaCha20-Poly1305 dispatch); verified end to end against the RFC 8448 "Simple 1-RTT Handshake" trace (X25519 ECDHE, every key-schedule secret, the server write key/IV, and decrypt/re-encrypt of the server's first protected record to the exact wire bytes). TLS 1.3 handshake authentication (crypto/tls13hs.nova, case 231): the running transcript hash, the Finished MAC (finished_key -> HMAC over the transcript), the CertificateVerify signature check (build the 64-space + context + 0x00 + transcript-hash content, then verify via the Nova X.509 + RSA-PSS/PKCS1/ECDSA verifiers), the master secret + application traffic secrets, and ServerHello parsing (cipher suite + key_share); verified against RFC 8448 (transcript CH..SH and CH..serverFinished, the server Finished verify_data, the RSA-PSS CertificateVerify over the real server cert, the c/s ap traffic secrets), with tamper rejections. TLS 1.3 client state machine (crypto/tls13client.nova, case 232): the I/O-agnostic driver - addClientHello, processServerHello (ECDHE + handshake secrets/keys), processFlight (decrypt the server flight, verify CertificateVerify + Finished), clientFinished (app secrets + client verify_data), clientFinishedRecord + encryptApp/decryptApp; verified by replaying the full RFC 8448 handshake (server traffic secret, flight verification, client Finished a8ec436d, c/s application secrets, sequence-number reset), with a tampered-flight rejection. LIVE TLS 1.3 HANDSHAKE WORKING: added buildClientHello (server-acceptable ClientHello: x25519 + AES-128-GCM-SHA256, supported_versions/groups/signature_algorithms/key_share) and feedHandshake (fragment-tolerant flight reassembly across records) to crypto/tls13client.nova, plus examples/tls13_client.nova (blocking-socket client over os/sys). Verified against a real openssl s_server -tls1_3: the Nova ClientHello is accepted, the client verifies the server's CertificateVerify (RSA-PSS against an RSA server AND ECDSA-P256 against an EC server) and the Finished MAC, sends its own Finished, and decrypts the server's HTTP/1.0 200 response. A complete interoperable TLS 1.3 client in pure Nova with no external crypto library. Certificate-chain trust policy (crypto/x509.nova extended, case 233): parseCert now captures the validity Times, the BasicConstraints cA flag, and the SubjectAltName; added checkValidity (UTCTIME/GeneralizedTime -> YYYYMMDDHHMMSS compare), isCA, matchHostname (dNSName with leftmost-wildcard), verifyLink (issuer is a CA + names chain + both valid + signature verifies), and verifyChain2/verifyChain3 to a trusted self-signed root; verified against an OpenSSL 3-level EC chain (root -> intermediate -> leaf with SAN) - full-chain accept, CA constraints, wildcard SAN, wrong-host/expired/broken-chain rejections. Reactor-async wiring (net/tls13async.nova + examples/tls13_async_client.nova): a TlsIO buffered record-framing view over a non-blocking reactor socket (reactorio.ReactorStream recvInto/sendBuf) + async handshake/read/write that drive the tls13client state machine, so the handshake and application I/O run on a Nova reactor coroutine with no thread held while waiting on the network; verified live against openssl s_server -tls1_3 (reactor.Reactor + coroStart + the poll/nova_reactor_resume loop) - connect, verified handshake, encrypted GET, decrypted HTTP/1.0 200. This backs an async HTTPS client. ECDSA-P256 signing (crypto/p256.nova, case 234): RFC 6979 deterministic nonce (HMAC-SHA256), reusing the constant-time scalar multiply + mod-n inverse/mul; verified against the RFC 6979 A.2.5 P-256/SHA-256 vectors ("sample"/"test") exactly, plus a sign/verify round trip. Server-side handshake (crypto/tls13server.nova + examples/tls13_server.nova): the accept side - processClientHello (extract client key_share + session id), buildServerHello (echo session id, our key_share, key schedule from ECDHE), buildFlight (EncryptedExtensions + Certificate + a CertificateVerify SIGNED with the Nova ECDSA signer + Finished, encrypted), processClientFinished, and encryptApp/decryptApp; verified LIVE against openssl s_client -tls1_3 - OpenSSL completes the handshake with the Nova server (it verifies Nova's CertificateVerify signature and Finished) and receives an HTTP/1.0 200 response over the encrypted channel. TLS 1.3 now works in pure Nova as both client and server, interoperating with OpenSSL both directions. Trust-store integration (crypto/x509.nova verifyCertList + crypto/tls13client.nova verifyServerChain, case 233 extended): the client captures the server's certificate_list during the handshake (certListOff/certListLen) and verifyServerChain runs the already-tested chain policy (verifyChain2/verifyChain3 with hostname + validity + CA constraints) against a caller-supplied trusted root; verifyCertList parses the TLS CertificateEntry list (leaf or leaf+intermediate) and is gated against the OpenSSL 3-level chain. PHASE E COMPLETE: a pure-Nova TLS 1.3 stack - client and server, reactor-async, with certificate-chain trust decisions - interoperating with OpenSSL both directions. PHASE F STARTED - retire wolfSSL. F-slice-1 DONE: retired the wolfCrypt AEAD differential oracle (the Nova AES-GCM and ChaCha20-Poly1305 are verified directly against NIST/RFC vectors, so the oracle is redundant) - deleted crypto/aead.nova, case 213, the nova_aead_* seal/open functions from src/runtime/crypto.cpp, the wolfcrypt cross-checks in cases 220/223, and unregistered crypto/aead. Remaining F: rewire net/asynctls (the wolfSSL memory-BIO, nova_mtls_* in io.cpp; used by web/app for HTTPS) onto the Nova TLS stack (tls13async), then delete nova_mtls_* from io.cpp and drop deps/wolfssl + -DNOVA_HAVE_WOLFSSL from build.zig. References: Zig std.crypto + local `deps/wolfssl` and `deps/BearSSL`. wolfCrypt AEAD binding (case 213) kept as a temporary dev oracle, retired in Phase F |
| M10 | Crypto namespace reorganization | M9 (soft) | DONE | The `src/std/crypto/` flat namespace (~25 modules) is reorganized Zig/Go-style: `crypto/hash/{sha256,sha512,sha1,md5,sha}`, `crypto/mac/{hmac,ghash,poly1305}`, `crypto/kdf/hkdf`, `crypto/aead/{aesgcm,chachapoly}`, `crypto/cipher/{aes,aesctr,chacha20}`, `crypto/ecc/{p256,x25519}`, `crypto/{rsa,x509,base64,random,scram}` (flat), and the TLS stack under a version directory: `crypto/tls/13/{tls,handshake,tlsClient,tlsServer}` (with `crypto/tls/12/{tlsClient}` reserved for M13). Modules are qualified by their last path segment (`tls.*`, `handshake.*`, `tlsClient.*`, `tlsServer.*`). The version directory required one small language change: the import parser now accepts a bare integer as a path segment (`import crypto.tls.13.tls;`), documented in the language spec section 8. Files moved via `git mv`, every `import crypto.X` rewritten, `src/main.zig` std_modules re-registered, conformance-case + example imports updated; stale `~/.nova/std/crypto/` copies cleared before rebuild (rsync no-delete). Native 221/221, ASAN gated. Reference: Zig `lib/std/crypto/*` and Go `crypto/*` layout |
| M11 | TlsMemBio + wolfCrypt retirement (wolfSSL deletion deferred to M13) | M9, M10 | DONE (deletion pending M13) | Done in three gated stages. **A** (crypto surface): SHA-1/256/512, MD5, HMAC-SHA256, PBKDF2, and the CSPRNG moved to pure Nova (`crypto/hash/md5` real MD5, new `crypto/kdf/pbkdf2`, `crypto/hash/sha` facade over the ptr-based primitives, `crypto/random` over `/dev/urandom` via `nova_open`/`read`/`close`); `randomBytes` now returns raw bytes (entropy fix). **B** (auth): MySQL native/sha2 scrambles reimplemented over `crypto/hash/sha`, and RSA-OAEP-SHA1 encryption added to `crypto/rsa` (`oaepEncryptSha1`, verified LIVE by OpenSSL decrypting a Nova-produced ciphertext). After A+B, `crypto.cpp` no longer references wolfSSL - deleted `nova_sha*/md5/hmac/pbkdf2/random_hex/mysql_scramble/sha2_scramble/rsa_oaep_encrypt`. **C** (transport): pure-Nova TLS 1.3 memory-BIO `net/tlsmembio` (a `TlsBio` trait with `ClientBio`/`ServerBio` over `feed`/`pull`/`pendingOut`/`step`/`writeApp`/`readApp`, plus PEM cert + EC-key parsing); `net/asynctls` rewired onto it, live-verified BOTH directions vs OpenSSL (Nova client <-> `s_server`, Nova server <-> `s_client`) plus an in-memory loopback gate (case 235). **Deferred**: the MSSQL/TDS path needs TLS 1.2 (SQL Server), so its wolfSSL memory-BIO was moved intact into `net/wolftls` (`WolfTlsStream`, renamed to dodge the `TlsStream_init` codegen-symbol collision) and mssql points at it. `nova_mtls_*` + `deps/wolfssl` + `-DNOVA_HAVE_WOLFSSL` stay until M13 gives TDS a pure-Nova TLS 1.2 client bio, then get deleted. GOTCHAs hit: `struct Tlv` collided with `x509.Tlv` transitively (renamed `MbTlv`); `zig build` rsync-no-delete leaves stale synced modules. Native 222, ASAN 413 |
| M12 | Full-spec TLS 1.3 (client + server) | M11 | TODO | Harden the pure-Nova TLS 1.3 stack to full RFC 8446: ALPN (application_layer_protocol_negotiation), Alert protocol (send/parse close_notify + fatal alerts), KeyUpdate (post-handshake key rotation), multiple named groups (secp256r1 + x25519 + secp384r1) and cipher suites (AES-128/256-GCM-SHA256/384 + ChaCha20-Poly1305) with real negotiation, HelloRetryRequest handling (currently only rejected), server NewSessionTicket + session resumption / 0-RTT PSK, proper record-size limits, and the full extension set. Mandatory. Already done (spec-compliance slice): SNI, psk_key_exchange_modes, middlebox-compat ChangeCipherSpec, HRR/downgrade rejection |
| M13 | TLS 1.2 client (full spec) + wolfSSL DELETED | M11 | DONE | Pure-Nova TLS 1.2 CLIENT (RFC 5246), and with it wolfSSL is fully removed from the tree. `crypto/tls/12/prf` = the TLS 1.2 PRF (P_SHA256/P_SHA384, verified vs the IETF vector). `crypto/tls/12/client12` = the handshake state machine + RFC 5288 AES-GCM record layer (4-byte implicit salt + 8-byte explicit nonce, AAD seq/type/version/len). Handshake: ClientHello (SNI, supported_groups, sig_algs, extended_master_secret, renegotiation_info) -> ServerHello + Certificate + ServerKeyExchange + ServerHelloDone -> ClientKeyExchange + CCS + Finished, verify server Finished. ECDHE over secp256r1 / x25519; server authenticated by verifying the ServerKeyExchange signature (RSA PKCS#1 v1.5 or ECDSA-P256) over client_random||server_random||ecdh_params against the leaf cert key; extended master secret (RFC 7627) when offered; key schedule + Finished use the suite PRF hash. Cipher suites: ECDHE-RSA / ECDHE-ECDSA x AES-128/256-GCM (SHA-256/384). Verified LIVE vs openssl s_server -tls1_2 across that whole matrix. `net/tls12bio` wraps it as a `Client12Bio` on the `TlsBio` trait. **wolfSSL deletion**: the TDS driver moved onto Client12Bio (over TDS-PRELOGIN framing); the blocking HTTPS client (`web/client`) moved onto the TLS 1.3 ClientBio driven over the raw socket - verified live (OpenSSL s_server 1.3, and a Python HTTPS server). To keep `crypto/random` from dragging the `os.sys` module (whose `pub extern socket` etc. pollute every consumer's namespace), entropy moved to a tiny honest kernel primitive `nova_getrandom` (getentropy(2), libc, NOT a crypto lib). Then deleted: `nova_tls_*`/`nova_tds_tls_*`/`nova_mtls_*` from io.cpp + nova_abi.h + the codegen/sema registrations, `net/wolftls` + the dead `net/tls` stub, `deps/wolfssl` (3625 files), and all `-DNOVA_HAVE_WOLFSSL`/`libwolfssl.a` wiring in build.zig + main.zig. NO wolfSSL symbol remains anywhere. Native 222/222, ASAN 413/413. Not done (follow-ons): TLS 1.2 CBC+HMAC suites (GCM-only today), RSA-kx (ECDHE-only), TLS 1.2 for web/client's HTTPS (1.3-only), and a system CA trust store (handshake authenticates the peer; chain-to-root is still a separate policy layer) |

## Purpose

This is the plan of record for replacing the C++ runtime (`src/runtime/`) with Nova code over a thin
foreign-function surface, so that Nova stands on itself. It exists because the runtime work must stop
being piecemeal: a scheduler migration attempt that got single-level async working but hung on
multi-level (see `self-hosted-runtime.md`, phase 6) showed that this rewrite needs an agreed order,
firm rules, and a gate at every step, not opportunistic edits to a subsystem the whole language
depends on.

The companion document `self-hosted-runtime.md` is the design of the new Nova-native I/O stack (the
event loop, buffers, parser, poll layer) and the record of what is already built. This document is
narrower and more operational: it inventories what is in C++ today, classifies every piece by whether
it leaves or stays, and sequences the removal.

## The inventory (`src/runtime/`, 3772 lines)

| File | Lines | Responsibility | Classification |
|------|------:|----------------|----------------|
| `io.cpp` | 950 | Blocking socket send and receive and connect, the wolfSSL memory-BIO TLS pump (file and directory operations retired to Nova in M5) | MIGRATE (socket, and the TLS protocol in M9) + STAY-FFI (crypto primitives under TLS) |
| `concurrency.cpp` | 833 | Boost.Asio reactors, the coroutine scheduler (`nova_sched_schedule`), async I/O (`nova_aaccept`/`aconnect`/`arecv`/`asend`/`aserver_listen`), channels, actors, `when_all`, timers, the `CoroState` machinery | MIGRATE (the core of the whole effort) |
| `core.cpp` | 438 | FFI helpers (errno, cstr marshalling), process args, exit, `f64_bits`, atomics, condition variables, mutexes, coverage, stack traces, `close`, `set_nonblock`, `reuseport` | MIGRATE (most) + a tiny atomics FFI |
| `alloc.cpp` | 426 | The ARC allocator, the 8-byte heap header, `nova_retain`/`nova_release`, `nova_bytes_alloc`/`free`, coroutine frame allocation, valopt and `any` boxing | ABI-CORE (stays; bump-arena page source is now `mmap` kernel pages, not libc `malloc`, per M8) |
| `decimal.cpp` | 328 | decimal128 BID arithmetic and codec | STAY-FFI (portable later, not blocking) |
| `crypto.cpp` | 279 | SHA, MD5, base64, CSPRNG over wolfCrypt | STAY-FFI (never reimplement crypto) |
| `compress.cpp` | 74 | gzip over zlib | STAY-FFI |
| `nova_abi.h`, `runtime_str.h` | 267 | The ABI header and string helpers | ABI-CORE |

## Classification legend

- **MIGRATE.** To be rewritten in Nova over the thin syscall FFI (`os/sys`, `os/kqueue`, `os/epoll`)
  and retired from C++. This is the bulk of the work.
- **STAY-FFI.** To remain as a thin C shim over a library that we must not reimplement (crypto, TLS,
  zlib) or that is not worth reimplementing yet (decimal BID). These are small, stable, and honest to
  keep behind FFI.
- **ABI-CORE.** The irreducible runtime seam that the compiler's code generation emits calls to
  directly: the ARC operations, the allocator entry points, the coroutine-frame glue, the heap header
  layout, the reactor scheduler entry points (`nova_sched_schedule`, `nova_reactor_resume`), and the
  async-channel primitives (`nova_chan_recv`/`send`/`new`/`free`), which the code generator emits inside
  the `llvm.coro.suspend` seam to park and wake coroutine waiters (see M7). These stay in a minimal C
  core for the foreseeable future because moving them into Nova would require the code generator to call
  Nova from contexts that do not yet have a Nova frame. Their backing (for example, the page source
  under the allocator) may become Nova; their entry points and the ABI they present may not change
  without a coordinated code-generation change.

## Target end state

A minimal C core plus a thin FFI surface, with everything else in Nova:

```
+-------------------------------------------------------------+
|  Nova runtime, written in Nova                              |
|  event loop, buffers, HTTP parser, poll and socket layer,   |
|  scheduler, channels, actors, file and directory I/O        |
+-------------------------------------------------------------+
|  Thin FFI shims (STAY-FFI): crypto primitives, zlib, decimal |
|  (TLS protocol in Nova after M9; primitives stay behind FFI) |
+-------------------------------------------------------------+
|  Minimal C core (ABI-CORE): ARC ops, allocator entry,       |
|  coroutine-frame glue, heap header                          |
+-------------------------------------------------------------+
|  Kernel: syscalls via os/sys, os/kqueue, os/epoll           |
+-------------------------------------------------------------+
```

Boost.Asio is removed entirely. The C line count drops from about 3772 to the ABI core plus the FFI
shims, on the order of a few hundred lines, with the crypto and TLS libraries linked but not written
by us.

## Rules that govern every step

1. **Never reimplement the crypto primitives; the TLS protocol may be built in Nova.** This rule has
   two halves that must not be confused. The cryptographic PRIMITIVES, that is, the block ciphers,
   hashes, curves, and their constant-time arithmetic (AES-GCM, ChaCha20-Poly1305, SHA-2, X25519,
   P-256, RSA), are never hand-rolled; they stay behind a vetted library. The TLS PROTOCOL, that is,
   the handshake state machine, the record layer, key schedule wiring, and the framing, is ordinary
   state-machine code and MAY be written in Nova, driving vetted primitives underneath. Building the
   protocol in Nova (phase M9) with a reference implementation is legitimate; reimplementing AES is
   not. Until M9 lands, TLS stays behind the wolfSSL memory-BIO pump.
2. **Additive and reversible.** Each migration keeps the C path working until the Nova path passes the
   gates, then removes the C path in a separate, revertable commit. No step leaves the tree in a state
   where the corpus is red.
3. **Gated at every step.** A step is done only when `conformance/run.sh` (native), `--asan`, and
   `--tsan` are green, plus a feature test for the thing that moved. Concurrency steps must be verified
   under `--tsan`, without exception, because the corpus alone cannot see a race.
4. **The ABI seam is sacred.** The symbols and layout in the ABI-CORE row do not change except through
   a deliberate, code-generation-coordinated change with its own review. Everything else is free to
   move.
5. **Measure where it matters.** I/O and scheduler changes carry a benchmark (the reactor servers in
   `flagship/bench/headtohead/nova-reactor/`), so a regression in throughput is caught, not discovered
   later.

## Tooling that must exist first

The scheduler attempt failed to be root-caused because runtime `fprintf` to standard error did not
surface in this environment (a binary-caching layer). Before the next concurrency step:

- **A file-based runtime trace.** A compile-time-guarded trace that writes to a file with an explicit
  flush, so the coroutine completion and requeue sequence is visible regardless of how the binary is
  built or cached. This is the single most important unblocker for the scheduler migration.
- **A runtime-symbol audit.** A small script that lists every `nova_*` symbol the C++ runtime exports
  and every symbol the code generator and the standard library reference, so that "what still depends
  on C++" is a fact, not a guess, and so that a retired symbol is proven unreferenced before deletion.

**M0 delivered (2026-07-28).** Both tools are built. The trace is a file-based, per-line-flushed
facility gated on `NOVA_TRACE=<file>`, callable from Nova (`nova_trace_msg`, `nova_trace_kv`) and from
C++ (the `NOVA_TRACE(...)` macro in `nova_abi.h`); it is a no-op with near-zero cost when unset,
verified to surface reliably where stderr did not. The audit is `tools/runtime-symbol-audit.sh`,
which reports 221 exported `nova_*` symbols, 203 referenced by the compiler or standard library, and
the current removal candidates; pass a symbol name to see exactly where it is referenced.

**Diagnostics workflow for the concurrency phases.** To trace runtime-internal code (for example the
scheduler in M1), add `NOVA_TRACE("sched pump h=%lld done=%d", h, done)` calls in the runtime, and run
with `NOVA_TRACE=/tmp/trace.log`. Because a compiled binary is cached by Nova-source hash, a
runtime-only change may not reach an unchanged test binary; run against a fresh or uncached test file
(or clear the build cache) so the updated runtime is linked. The trace file then contains the exact
sequence, flushed per line, regardless of how the binary is run.

## The phased migration

Each phase names its prerequisite, its deliverable, and its gate. The order is chosen so that each
phase removes a real dependency and is independently verifiable.

- **M0. Tooling.** The file-based trace and the symbol audit above. Gate: the trace shows the
  scheduler sequence on the failing multi-level-await case.
- **M1. Async scheduler migration. DONE.** The per-reactor run queue (`g_rq`, thread-local, entered
  by `nova_reactor_resume`) drives nested `await` and `spawn` on the reactor thread instead of Asio.
  When a reactor-driven coroutine schedules a child (nested await) or a spawn, `nova_sched_schedule`
  pushes onto `g_rq`; `reactor_pump` drains it to quiescence, running `reactor_finish` (release held
  args, hand completion to the awaiter, or reap a detached top-level coroutine) on each completion.
  Off reactor threads (`g_reactor_mode` false) the Asio path is unchanged, so the existing
  `NOVA_THREADS` deployment does not regress. Verified with `NOVA_TRACE`: the earlier "multi-level
  hangs" report was a conflation. Multi-level await (`top -> await middle -> await leaf`) and
  two-`spawn`+`await` both drain correctly and synchronously through the queue (corpus case 199).
  The genuine boundary the trace pinned down is different: an `await` that suspends on an
  **Asio-backed** primitive (`sleep`/timer, `arecv`, `asend`, `aconnect`, `aaccept`) can never
  complete on the reactor, because the reactor thread runs its own poll loop and never runs the Asio
  `io_context`, so the completion is orphaned. That is not a scheduler bug; it is exactly what M2
  removes. Until then those primitives fail fast on a reactor thread via `nova_reactor_io_violation`
  (a clear diagnostic naming the primitive, then `abort`), so the unsupported combination is loud
  instead of a silent hang or wrong value. Gate: corpus (incl. 199) and ASAN green; the Asio-abort
  path is proven out-of-corpus (a corpus case cannot abort). This unblocks M2.
- **M2. Async socket I/O onto the reactor. WIP.** Reimplement the async socket seam in Nova over
  `os/sys` non-blocking sockets driven by the reactor, retiring the Asio versions in `concurrency.cpp`.
  Prereq: M1.
  - **Done (this step): the reactor-native stream.** `src/std/net/reactorio.nova` (`ReactorStream` =
    a raw fd plus the kqueue it is registered on) provides `recvInto` / `sendBuf` / `sendStr` as
    `async fn`s that try a non-blocking `read`/`write` inline and, on `EAGAIN`, register readiness
    (`EVFILT_READ`, or one-shot `EVFILT_WRITE`) with the reactor carrying `currentCoro()` as the
    token, then `coroSuspend`; the reactor resumes them when the fd is ready. No Asio, no thread held
    while blocked. Reactor write-interest (`addWrite`/`delWrite`) was added to `net/reactor`. Proven
    by corpus case 200: two coroutines on one reactor complete a send and receive round trip over a
    socketpair, trace-confirmed to park on `EAGAIN` and resume on readiness. Native 193, ASAN 355,
    TSan 201 (200 tsan clean).
  - **Done: connect and accept.** `net/reactorio.reactorConnect` (non-blocking `connect` + await
    writability + `SO_ERROR` via a new `getsockopt` binding) and `reactorAccept` (accept loop
    awaiting readability), with `parseIPv4` for numeric hosts. Found and fixed a real portability
    bug: `SOL_SOCKET` was the Linux value (1); on macOS/BSD it is `0xffff`, so `getsockopt(SO_ERROR)`
    was failing (surfaced via `NOVA_TRACE`). Corpus case 201 does a loopback TCP client and server
    round trip on one reactor.
  - **Done: the current-reactor thread-local.** `nova_reactor_set_current`/`nova_reactor_current`
    (share-nothing per reactor thread), exposed as `reactor.setCurrent`/`currentKq`; a worker sets it
    once so a stream can be built deep in driver code without the reactor being threaded through.
  - **Done: the `AsyncStream` cutover.** `asyncio.AsyncStream` is dual-mode: `kq == 0` is the Asio
    stream (unchanged); `kq > 0` is reactor-native (`sock` is a raw fd, recv/send/close delegate to
    `net/reactorio`). `asyncConnect` picks the reactor path when `reactor.currentKq() > 0`, else Asio.
    Corpus case 202 runs a TCP round trip where the client goes entirely through the `AsyncStream`
    seam on the reactor; the M1 `nova_reactor_io_violation` guard proves the reactor path was taken
    (an Asio fallback on the reactor thread would have aborted). Backward compatible, Asio deployment
    untouched.
  - **Done: hostname resolution.** `net/reactorio.resolveHost4` parses numeric IPv4 directly and
    resolves a name via `getaddrinfo` (new `os/sys` bindings). `reactorConnect` takes a host name, so
    a driver reaches a named database host on the reactor. `getaddrinfo` is a blocking DNS lookup done
    once per connection (pooled), not per request; async DNS is a later step. Corpus case 203.
  - **Done: a whole request on the reactor.** `web/app.serveReactorConn` wraps an accepted fd in a
    reactor-native `AsyncStream` and runs the same `handleConn` pipeline (parse, route, mediator,
    handler, response) as the Asio path; `App.runReactor` is the opt-in single-reactor server (the
    default `run()` keeps Asio). Corpus case 204 serves a real App request (typed route plus handler)
    over a reactor-native stream on one reactor; the M1 io-violation guard confirms the reactor path
    (0 violations). So the request and any per-request database call now run on the reactor.
  - **Done: the multi-core reactor server.** `web/app.runReactorMC(port, workers)` serves
    share-nothing across N reactor threads, one reactor plus a `SO_REUSEPORT` listener per thread.
    The worker closure captures only the `App` (a lambda passed to `runReactors` resolves just its
    first capture, a real compiler limit; the port rides on a new `App.serverPort` field). Corpus
    case 206 proves each worker receives the `App` with its config intact, read concurrently, TSan
    clean; `server_app_mc.nova` is a load-tested multi-core App server. Note: a captured local named
    `app` shadowed the `app` module alias in other files (lambda capture tracking is name-based),
    which broke a static-content case until the local was renamed; a captured name matching a module
    alias is a latent cross-file hazard.
  - **Remaining before M3:** async DNS (`getaddrinfo` currently blocks the reactor briefly per
    connection).
  - Gate (M2): client and server round trip on the reactor, connect-by-name, and a full App request,
    all reactor-native (200 to 204); the Asio deployment does not regress. Native 197, ASAN 363,
    TSan 209.
- **M3. Database drivers onto the reactor. DONE (mock).** The drivers connect via
  `asyncio.asyncConnect` and do their I/O through `asyncio.AsyncStream` (`io.recvInto` / `io.sendStr`),
  both made reactor-native in M2, so on a reactor thread the whole driver runs reactor-native with no
  driver change. Corpus case 205 proves the flagship pattern end to end: a real App (typed route plus
  handler) served on one reactor, whose handler does `await asyncio.asyncConnect(host, port)` then a
  query round trip against a mock database server on the SAME reactor (standing in for a live BTreeDB,
  which uses the identical seam). Inbound accept, request parse, mediator dispatch, the handler's DB
  connect and query, and the response all run in one poll loop, no Asio. This closes the original PH6
  blocker (a handler's nested async DB call used to deadlock on the reactor). The M1 io-violation
  guard confirms the reactor path (0 violations; an Asio fallback for the DB I/O would have aborted),
  and the three coroutines complete with no ASAN leak. Prereq: M2. Gate: the flagship per-request
  database path works on the reactor (done, mock); a live-driver round trip additionally needs a
  reachable database, with the driver code unchanged. Native 198, ASAN 365, TSan 211.
- **M4. Retire Boost.Asio. DONE.** With the scheduler (M1), async I/O (M2), and databases (M3) on the
  reactor, remove the Asio reactors, strands, the `g_io` context, and the Asio socket/timer code from
  `concurrency.cpp`, and drop the vendored Boost from the build. Prereq: M1 to M3. Progress this far:
  - **Done: the reactor is the default server path.** `App.run` routes through `runReactorMC` (the
    share-nothing multi-core reactor) for plain HTTP; it falls back to the Asio server only for TLS
    (not yet on the reactor) or when `NOVA_ASIO=1` forces it. So a `nova init` app runs on the
    self-hosted runtime by default. Verified live (plain app served on the reactor; `NOVA_ASIO=1`
    falls back to Asio).
  - **Done: reactor-native timers.** `nova_await_timer` arms an `EVFILT_TIMER` on the current
    reactor's kqueue when on a reactor thread (the Asio `steady_timer` only off the reactor), so
    `await sleep` and, next, read deadlines no longer need Asio on the reactor. Corpus case 207.
    This also restores the timer capability that defaulting to the reactor had dropped.
  - **Done: read deadlines on the reactor.** `reactorio.recvIntoDeadline` bounds a read by a deadline
    against the monotonic clock (`nova_mono_ms`): a reactor timer only wakes the coroutine to re-check
    the clock, cancelled on any exit; on timeout it returns -2 and the server closes the connection.
    `AsyncStream.recvInto` routes to it when a timeout is set, so `handleConn`'s `readTimeoutMs` is
    enforced on the reactor. A batch-safe resume guard (`batchBegin` per poll batch, armed only while
    a deadline is active) stops a stale deadline-timer event from resuming a coroutine reaped earlier
    in the same batch. Corpus case 208 (times out, and data-arrives-first).
  - **Done: inbound TLS on the reactor.** No TLS-code change was needed: `asynctls.TlsStream` already
    does its socket I/O through `asyncio.AsyncStream` (`self.base.recvInto` / `sendStr`), and the
    wolfSSL memory-BIO pump (`nova_mtls_*`) is pure protocol state with no Asio, so wrapping a
    reactor-native `AsyncStream` in `tlsAccept` runs the whole handshake and data path on the reactor.
    `serveReactorConn` tlsAccepts when `app.tlsEnabled`; the `run()` TLS-to-Asio fallback is removed
    (only `NOVA_ASIO=1` selects Asio now). Corpus case 209 (in-Nova TLS handshake plus HTTP on one
    reactor, 0 io-violations) and a live `curl -k https://` / TLSv1.3 smoke test. Crypto primitives
    stay in wolfSSL.
  - **Done: the `NOVA_ASIO` fallback is retired.** `App.run` is reactor-only; the Asio server plumbing
    (`runServer`/`acceptLoop`/`handleConnPlain`/`handleConnTls`) is deleted from `app.nova`. The web
    framework no longer references the Asio async socket seam.
  - **Remaining to actually drop Boost (a real refactor, not a deletion).** Boost still backs two
    things the corpus depends on, and both must move off Asio first:
    1. **`nova_run_root`**, the driver for every async `@test` and standalone async `main`. It runs the
       Asio `io_context` across a **thread pool** (TSan exercises it at 4 threads). The share-nothing
       reactor is thread-local and has **no cross-thread coroutine wakeup**, which is exactly what
       Asio's `post`-to-another-strand gives channels and actors (a `send` on one thread waking a
       waiter on another). So dropping Boost needs a new primitive first: cross-reactor wakeup
       (an `eventfd`/self-pipe registered on each reactor's poll set), then `nova_run_root` rewritten
       as N reactor threads driven to root completion.
    2. **Five corpus tests use the raw Asio primitives directly** (`113` async-stream, `114`
       async-tls, `115` async-timeout, `184` null-socket, `186` inbound-TLS) via `aaccept`,
       `async_read`/`async_write`, `serverListen`. Their behaviour is now covered by the reactor tests
       `200` to `209`, so they are retired or converted as part of removing the primitives.
    Order: **(a) cross-reactor wakeup. DONE.** `reactor.registerWake`/`post`/`drainWake` over an
    `EVFILT_USER` trigger plus a per-index thread-safe inbox (a coroutine posted from another thread
    wakes the owning reactor's blocking poll and is drained on the `EVFILT_USER` event). Corpus case
    210, TSan clean cross-thread at 4 threads. Linux plugs an `eventfd` behind the same shape.
    **(b) `nova_run_root` on the reactor. DONE.** The driver for async `@test`s and standalone async
    `main` runs single-threaded on the reactor (resume the root, poll the kqueue for timers and
    reactor-native I/O until done); single-threaded is sufficient (every channel/actor/select/compute
    async test passes under `NOVA_THREADS=1`). Fresh scheduler state per drive; `g_reactor_mode`
    cleared at the end so the caller's next `nova_sched_schedule(root)` does not double-drive.
    `nova_when_any_deadline` is reactor-native (monotonic deadline + one-shot `EVFILT_TIMER`). The 5
    Asio-primitive tests (113/114/115/184/186) are retired (coverage in 200/201/208/209). Native 198,
    ASAN 365, TSan 215. So nothing on the running paths drives via Asio.
    **(c)+(d) remaining:** delete the now-dead Asio surface (`nova_arecv`/`asend`/`aconnect`/
    `aaccept`/`aserver_listen`, the Asio branches of `nova_sched_schedule`/`nova_await_timer`/
    `nova_when_any_deadline`, `nova_run`/`nova_hold_all_reactors`, the `io_context` reactors/strands/
    `g_io`), and drop vendored Boost from `build.zig` (Boost is confined to `concurrency.cpp`, so the
    final deletion is local). The one live Asio touch left is `nova_sched_schedule`'s Asio branch,
    which the caller hits once per root before `nova_run_root` (a harmless never-run strand post); make
    it reactor-native or route it through the run queue, then the include and Boost drop. Gate each
    step on corpus, ASAN, and TSan.
  - Gate (full M4): the runtime builds and links with no Boost include; corpus, ASAN, TSan, and the
    head-to-head all green.
- **M5. File and directory I/O. DONE.** `src/std/io/file.nova` and `src/std/io/dir.nova` are
  reimplemented in Nova over the raw POSIX syscalls in `os/sys`: a `File` holds an open file
  descriptor and uses `open`/`read`/`write`/`lseek`/`close`/`fsync` directly with no C stdio; a `Dir`
  holds a `DIR*` from `opendir` and walks it with `readdir`, reading the entry name out of `struct
  dirent`; `mkdir`/`rmdir`/`rename`/`access`/`stat`/`getcwd`/`chdir` bind libc directly. `struct stat`
  and `struct dirent` are read as raw byte buffers at fixed macOS and BSD offsets (`st_mode` u16 at
  offset 4, `d_name` at offset 21), the same systems idiom `os/sys` already uses for `sockaddr` and
  `kevent`. The one C shim left is `nova_open`, because `open(2)` is variadic and a non-variadic FFI
  declaration mispasses its mode argument on arm64 (varargs go on the stack), exactly like the
  existing `fcntl` shim; it is two lines in `core.cpp`. The whole `nova_file_*` and `nova_dir_*` C
  surface (about 165 lines) is deleted from `io.cpp`, along with its codegen declarations
  (`declarations.zig`), its bare-builtin registrations (`builtins.zig`), and its ABI header
  declarations, so `io.cpp` drops from 1116 to 950 lines and now holds only the blocking socket
  connect and the wolfSSL memory-BIO TLS pump. Conformance case 211 exercises the whole surface (text
  round trip, the fd handle API, seek and tell, directory create and list and rename, cwd). Gate:
  native 199, ASAN 367, TSan 216, all green with the file and directory C gone. The Linux plug is the
  same syscalls with the Linux `struct stat`/`struct dirent` offsets and `O_*` values, behind the
  same `os/sys` shape.
- **M6. Process and primitive shims. DONE.** The migratable shims are now Nova over `os/sys`, and the
  line under them is drawn at the genuinely-primitive floor. Moved to Nova (their C deleted): `reuseport`
  is `sys.setReusePort`, pure Nova over `setsockopt(SO_REUSEPORT)` with no runtime shim (setsockopt is
  not variadic), so `nova_set_reuseport` is gone from `concurrency.cpp`; env `get`/`set` read and write
  through new `getenv`/`setenv` bindings in `os/sys` with the string marshalling in `std/env.nova`, so
  `nova_getenv`/`nova_setenv` are gone from `core.cpp`. Each deletion also removed the codegen
  declarations (`declarations.zig`) and, where present, the bare-builtin registrations (`builtins.zig`)
  and the ABI header declarations. What stays is the honest primitive floor, exactly as the plan intends:
  `errno` (`nova_ffi_errno`, because errno is a per-thread macro with no address to bind from Nova),
  `set_nonblock` (variadic `fcntl`, the same reason `nova_open` exists), `exit` (`std::_Exit`, chosen
  precisely to skip the `atexit` handler that coverage registers, so it cannot become a plain libc `exit`
  binding), process args (`nova_arg_count`/`nova_arg_at`, because the generated `main` captures `argv`
  and no `os/sys` binding can reach it), and the concurrency primitives (atomics, `mutex`, `condvar`,
  `rwlock`, `spinlock`), which are the "tiny, honest FFI" the plan calls out. One named target,
  `close`, is a special case: `os/sys` already binds libc `close` and the reactor path uses `sys.close`,
  but the legacy tcp socket stack (`net/tcp/socket`, `net/tcp/server`, `web/client`) cannot import
  `os/sys`, because `os/sys` exports a `socket` function that collides by name with the `socket` module
  alias those files use (a name-based-resolution limit in the current module scoping, surfaced exactly
  by this change). So the tcp stack keeps `nova_close` (via a `closeFd` helper in `net/tcp/socket`), and
  a clean migration is deferred to splitting the socket-family bindings into an `os.socket` module, or
  adding an extern link-name so the binding need not be named `socket`. Gate: the env conformance path
  and the multi-core reactor cases (which exercise `setReusePort`) pass; native, ASAN, TSan green.
- **M7. Channels and actors. DONE.** The actor layer is already Nova and the channel that the actors
  and every concurrency conformance case use is scheduler infrastructure that belongs in the ABI-CORE
  seam, so M7 is a reclassification rather than a rewrite.
  - **Actors are already in Nova.** `std/concurrency/actor.nova` implements the `Actor<M>` trait, the
    `Mailbox<M>` (a signal channel plus a Nova message queue), and `ActorCell<M>.run` as an `async fn`
    that `await`s the mailbox on the reactor. There is no actor C code to retire; the mailbox runs on
    the reactor over the M1 scheduler and the M3/M4 coroutine primitives. The `10_async_go`, `11_channels`,
    `116_select`, and `118_actor` cases exercise this and are green natively and under `--tsan`.
  - **The async channel is the reactor scheduler seam (ABI-CORE), not userspace.** `nova_chan_recv`,
    `nova_chan_send`, `nova_chan_new`, and `nova_chan_free` are not an ordinary container: the code
    generator emits `nova_chan_recv(ch, self, out)` directly, in a poll-and-suspend loop built around
    `llvm.coro.suspend` (see `buildChanRecv` in `codegen/expressions.zig`), and `nova_chan_send` wakes a
    parked coroutine through `nova_sched_schedule`, the reactor run queue. That is exactly the "scheduler
    entry points" the ABI-CORE row keeps: the primitive schedules coroutine waiters and is part of the
    coroutine-frame convention the code generator depends on. Moving it into Nova would mean the code
    generator calling a mangled Nova symbol from the suspend seam that hung during the first scheduler
    migration; it stays in the minimal C core alongside `nova_sched_schedule` and `nova_reactor_resume`.
  - **The blocking `Channel<T>` is deferred.** `nova_channel_*` (a `mutex`/`condvar`/queue) backs a
    `Channel<T>` that only its own self-test uses (no conformance case, not gated). Reimplementing it in
    Nova over the M6 `mutex`/`condvar` is otherwise clean, but it stores a generic `T` as a raw `long`,
    which needs TypeId-aware retain and release to be ARC-correct: that is the open generic-container
    ownership question (see `nova-any-ownership-model`), not an M7 deliverable. It is deferred to that
    work rather than shipped with an ARC hazard the `--asan` gate would reject.
  Gate: the channel, select, and actor conformance cases pass natively and under `--tsan` (unchanged;
  M7 moved no code).
- **M8. Allocator backing. DONE.** The allocator's page source is now raw kernel pages, not the libc
  heap. `nova_bytes_alloc` serves the common case from a per-thread 32 MB bump arena; that arena's
  backing is acquired with `mmap` of anonymous, zero-filled, read/write private memory
  (`arena_page_alloc` in `alloc.cpp`) instead of `std::malloc`. The arena is a leaked-forever bump
  region (arena objects are never individually freed, so `nova_bytes_free` no-ops on them), which is
  exactly the shape a single anonymous mapping wants; individual overflow and persistent objects keep
  using `malloc`, because they are freed one at a time and mapping each would round every small object
  up to a whole page. The ABI-CORE surface is untouched: `nova_bytes_alloc`/`free`,
  `nova_retain`/`release`, and the 8-byte header (refcount at minus 8, length at minus 4) are
  byte-for-byte unchanged, so no code-generation change was needed. `os/sys` also gains `mmap`/`munmap`
  bindings plus `mapAnon`/`unmap` helpers, so a Nova arena (for example the `io/slab` and `io/arena`
  pools) can back itself with kernel pages the same way; conformance case 212 maps, writes, reads, and
  unmaps anonymous memory from Nova. Under `--asan` and `--tsan` the arena is bypassed entirely
  (`NOVA_DROP_ARENA` makes every object an individually tracked `malloc`), so those gates test the
  honestly-refcounted path and the arena change is covered by the native corpus and the microbenchmark.
  Prereq: none. Gate: native 200, ASAN 369, and the allocation microbenchmark (20 million 24-byte
  allocations) unchanged versus the `malloc`-backed arena, within run-to-run noise, because the bump
  hot path is identical and only the one-time page acquisition changed.

- **M9. TLS 1.2 and 1.3 protocol in Nova. WIP.** Write the TLS handshake state machine, the record
  layer, the key schedule, and the alert and framing logic in Nova, over the async socket seam (M2) and
  over vetted crypto primitives (AES-GCM, ChaCha20-Poly1305, SHA-2, ECDHE, RSA) that remain behind a
  library and are never hand-rolled (rule 1). Reference implementation: the Zig standard library's
  `std.crypto.tls` (a TLS 1.3 client) and `std.crypto` primitives, a clean, readable model for the
  protocol and a source of the primitive set to bind. This retires the wolfSSL memory-BIO pump in
  `io.cpp` and, with the crypto-primitive question, is the last large piece of I/O in C++. Prereq: M2.
  Because this is the largest phase, it is split into ordered slices, each independently gated:
  - **9.0 Vetted crypto primitives (bindings). STARTED.** Bind, never reimplement, the primitive set
    TLS 1.3 drives, from the vendored wolfCrypt (which enables AES-GCM, ChaCha20-Poly1305, ECC for
    P-256 ECDHE and ECDSA, HKDF, and SHA-256 and SHA-384; note this build has no X25519, so the Nova
    handshake uses P-256, which RFC 8446 mandates). Done so far: the AEAD ciphers. `crypto/aead.nova`
    binds `nova_aead_aesgcm_seal`/`open` and `nova_aead_chacha20poly1305_seal`/`open` (thin wrappers in
    `crypto.cpp` over wolfCrypt `wc_AesGcm*` and `wc_ChaCha20Poly1305_*`), on raw buffers with explicit
    lengths, returning success or an authentication failure the caller must treat as fatal. Verified
    against published known-answer vectors (NIST GCM cases 1 and 13, the RFC 8439 section 2.8.2
    ChaCha20-Poly1305 vector) plus a round trip and tamper detection (conformance case 213). Remaining
    9.0: HKDF-Extract and HKDF-Expand-Label (built in Nova from HMAC, which is protocol composition, not
    a primitive), SHA-256 and SHA-384 transcript hashing exposed as an incremental interface, P-256
    ECDHE key generation and shared-secret, X.509 chain parse and validation, and signature
    verification (RSA-PSS, ECDSA-P256).
  - **9.1 Record layer (Nova).** TLS record framing (content type, legacy version, length), the
    per-record nonce from the sequence number XOR the write IV, the additional-data construction, and
    record seal and open over the 9.0 AEAD. Gate: RFC 8448 record vectors.
  - **9.2 Key schedule (Nova).** The HKDF key schedule of RFC 8446 section 7 (early, handshake, and
    master secrets, traffic keys, and finished keys). Gate: RFC 8448 key vectors.
  - **9.3 Handshake state machine (Nova).** ClientHello and ServerHello with the key_share,
    supported_versions, signature_algorithms, and server_name extensions, EncryptedExtensions,
    Certificate, CertificateVerify, and Finished, with the transcript hash, certificate validation, and
    signature verification through 9.0.
  - **9.4 Reactor integration.** Drive the Nova TLS engine over `asyncio.AsyncStream` in place of the
    wolfSSL memory-BIO pump (`nova_mtls_*`), then a live handshake against `curl` and `openssl
    s_client`. This retires the `nova_mtls_*` C.
  - **9.5 TLS 1.2.** The 1.2 handshake and record layer, scheduled after 1.3 is live.
  Gate for the whole phase: a real TLS 1.3 handshake and, separately, a TLS 1.2 handshake against a
  standard server and client, the inbound and outbound TLS conformance cases green on the Nova path,
  and no timing-sensitive primitive written by us.

The decimal, crypto-primitive, and compress shims (STAY-FFI) are not phases; they remain as they are.
decimal may be ported to Nova later as pure-compute work, outside this plan's critical path. The
crypto primitives stay behind a vetted library permanently; only the TLS protocol on top of them moves
to Nova in M9.

## What must never break (the ABI seam)

These are the three contracts from the runtime ABI note that hold the whole thing together and that no
step in this plan may change without a coordinated code-generation change:

1. **The extern C symbol names and signatures** that the code generator emits: `nova_retain`,
   `nova_release`, `nova_bytes_alloc`, `nova_bytes_free`, the coroutine intrinsic glue, and the
   scheduler entry points during their migration.
2. **The ARC discipline:** every heap object carries an 8-byte header (refcount at offset minus 8,
   length at offset minus 4); ownership is decided in the semantic and code-generation passes.
3. **The coroutine-frame convention:** the resume function at frame offset 0, the destroy function at
   offset 1, done detected by a null resume slot. The reactor scheduler drives coroutines through
   exactly this convention.

## Risks

- **The scheduler completion path (M1). Resolved.** The run queue drains nested await and spawn on
  the reactor (corpus 199, trace-proven). The reactor-vs-Asio I/O boundary it exposed is guarded by
  a loud abort (`nova_reactor_io_violation`) and closed by M2.
- **The ABI seam.** A careless change to a code-generation-emitted symbol corrupts memory in a way
  that lands far from the cause. Mitigated by rule 4 and by the ASAN gate, which is the authority on
  ownership changes.
- **Cross-platform.** The Linux epoll backend compiles but is not yet verified on Linux; Windows IOCP
  is out of scope for now. Mitigated by keeping the poll layer behind the `Reactor` shape.
- **Calling Nova from a runtime thread.** Already proven by `nova_run_reactors`, but every migrated
  service must be reachable from a reactor thread without a hidden Asio dependency.

## Status snapshot (2026-07-29)

Already in Nova: the event loop (`net/reactor`), the buffer pools (`io/slab`, `io/arena`), the HTTP
parser (`web/httpparser`), the poll and socket layer (`os/sys`, `os/kqueue`, `os/epoll`), and the
share-nothing multi-core driver. Verified: a single reactor on one core out-throughputs the tuned
frameworks' eight-core numbers; the reactor is race-free under `--tsan`. Done: M0 (trace tooling),
M1 (the scheduler migration), M2 (async socket I/O on the reactor), and M3 (database drivers on the
reactor, proven with a mock) all landed. The reactor drives nested `await` and `spawn`; recv, send,
connect, accept, and resolve are reactor-native in Nova over `os/sys`; `AsyncStream` is dual-mode; a
whole App request runs on the reactor; the flagship pattern (a handler's per-request database call)
runs end to end on the reactor with no Asio, closing the PH6 deadlock; and the App serves share-nothing
multi-core (`runReactorMC`, `SO_REUSEPORT`). M4 is DONE: the async runtime is reactor-native end to end and Boost.Asio is gone. `nova_sched_schedule` is just the reactor run queue; timers, read deadlines, whole-operation deadlines, inbound TLS, and sockets are reactor-native; `nova_run_root` drives async  and standalone async on a single-threaded reactor; and the multi-core server is share-nothing. The Asio io_context/strands/thread-pool/CoroState and the async socket primitives are deleted (the primitives kept as loud abort stubs for the now-dead AsyncStream codegen branch), the `<boost/asio.hpp>` include and Boost build flags are removed, and vendored `deps/boost` (~7MB) is deleted. Native 198, ASAN 365, TSan 215, all with no Boost. M5 is DONE: file and directory I/O is now Nova
over `os/sys` (`io/file.nova`, `io/dir.nova`), the `nova_file_*`/`nova_dir_*` C surface is deleted from
`io.cpp` (1116 to 950 lines) along with its codegen and ABI declarations, and only the variadic
`nova_open` shim remains; `io.cpp` now holds just the socket connect and the wolfSSL TLS pump. Native
199, ASAN 367, TSan 216. M6 is DONE: the movable process shims are Nova over `os/sys` (`reuseport` via
pure-Nova `setsockopt`, env `get`/`set` via new `getenv`/`setenv` bindings, their C deleted), and the
honest-primitive floor is drawn (errno, variadic `set_nonblock`, `exit`'s `_Exit`, argv-capturing args,
atomics, and the sync primitives stay; `close` stays for the tcp stack pending an `os.socket` split,
because `os/sys`'s `socket` export collides by name with the `socket` module). M7 is DONE by
reclassification: the actor mailbox is already Nova over the reactor, and the async channel
(`nova_chan_*`) is part of the reactor scheduler ABI-CORE seam (the code generator emits it around
`llvm.coro.suspend`), so it stays in the minimal C core; the vestigial blocking `Channel<T>` is deferred
to the generic-container ARC work. M8 is DONE: the bump arena under `nova_bytes_alloc` is backed by
`mmap` anonymous pages instead of libc `malloc` (`os/sys` also exposes `mmap`/`munmap` so a Nova arena
can do the same), with the ARC entry points and heap header unchanged and the allocation microbenchmark
not regressed. Remaining follow-ons (not blocking): a live-driver round trip against a reachable
database (driver code unchanged), async DNS, the Linux epoll reactor driver for `nova_run_root`, and the
`os.socket` split; then M9 (the TLS 1.2 and 1.3 protocol in Nova over vetted crypto primitives), the
last large piece.
