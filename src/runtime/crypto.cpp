// M11 stage B completed the crypto migration: SHA-1/256/384/512, MD5, HMAC-SHA256, PBKDF2, the
// CSPRNG, the MySQL auth-scrambles, and RSA-OAEP encryption are all implemented in pure Nova
// (crypto/hash/*, crypto/mac/hmac, crypto/kdf/pbkdf2, crypto/random over /dev/urandom, crypto/rsa,
// and the MySQL driver). No wolfCrypt symbol remains here. The only wolfSSL surface left in the
// runtime is the TLS memory-BIO in io.cpp (nova_mtls_*), retired in stage C.
