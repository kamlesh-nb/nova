# Designing High-Performance Database Drivers in Nova

> ## ⛔ STATUS 2026-07-17 — DEFERRED, AND NOT BUILDABLE AS WRITTEN. READ THIS FIRST.
>
> **Decision (user, 2026-07-17): DB drivers are deferred** until the compiler/runtime foundation is
> solid and demonstrably working. See `beta-readiness-plan.md` §R2 and P4-26.
>
> **This document is a vocabulary sketch, not a specification — roughly 5% of one.** It contains the
> easy, re-derivable part (framing, endianness, integer packing) and is **silent on ~95% of the work**:
> authentication (SCRAM-SHA-256, caching_sha2, NTLM/TDS), TLS, connection pooling, prepared
> statements/parameters, type mapping, NULL, transactions, cursors/streaming, and error codes. Every
> parser below is a stub — `parseFieldName` literally `return "column_name";`.
>
> Two things must be fixed **before** any parser is written:
> 1. ⚠️ **`Row.cells: List<string>` is a WRONG foundation, not an incomplete one.** It cannot represent
>    NULL vs `""`, binary, or types. Everything built on it gets rewritten. Redesign `Value`/`Row`
>    with a real type union + NULL first.
> 2. ⚠️ **The trait has no `params` — so the API as specified has NO SQL-injection-safe path.**
>    (The *btree* driver already has `execute(sql, params)`; this doc is behind the shipped code.)
>
> Also unconsidered: **FFI to libpq / libmysqlclient / FreeTDS / mongo-c**. The doc assumes hand-rolled
> wire protocols without ever weighing the alternative — yet TLS is *already* FFI (wolfSSL), so "no C
> bindings" is not a codebase principle. Four hand-rolled binary protocols is a multi-engineer-year
> commitment. Price FFI honestly for v1. When work starts: **spec ONE database end-to-end (Postgres —
> best-documented, and its framing already matches btree's), ship it, then generalize.**
>
> ### ⚠️ §0's constraint list is STALE — all three scares are FIXED (measured 2026-07-17)
> | §0 claim | Reality |
> |---|---|
> | "Nova Maps crash with a SIGBUS if they grow past their initial load factor" | **FIXED.** 5000 keys from a presize of 8, many resizes → clean. |
> | "`${value}` crashes with a SIGSEGV at runtime" for i64/f64 | **FIXED** (`5cf9a14`). Both fine. |
> | "`let f = self.hashFn; (f)(key) // CRASH!`" | **FIXED.** Bare fns and lambdas share one representation (specs §10 #18). |
>
> This matters beyond tidiness: a stale doc **sets the risk posture**. §0 reads as "the compiler is not
> ready for a 20k-line binary-protocol effort" — that inference was *drawn from bugs that no longer
> exist*. Do not plan against it. (The real blockers are the error model, raw-byte crypto for auth, and
> mid-stream TLS negotiation — see the plan.)

This document describes the architectural specifications and concrete designs for high-performance database drivers (**PostgreSQL**, **MySQL**, **MSSQL (TDS)**, and **MongoDB**) using the Nova programming language. 

Nova is a compiled, statically typed language featuring Automatic Reference Counting (ARC), explicit `self` struct method semantics, and a Boost.Asio-backed stackless coroutine scheduler (`async`/`await`/`go`). 

The driver designs here support both:
1. **Synchronous APIs** (built on top of `net.tcp.socket.TcpStream` for CLI tools, background jobs, and migrations).
2. **Asynchronous APIs** (built on top of `net.asyncio` for high-throughput, non-blocking network services).

---

## 0. Key Nova Constraints & Design Rules

To prevent runtime memory leaks, SIGSEGV crashes, and unexpected performance drops, all driver implementations must adhere to these language-level rules:

### 0.1 String Allocation and Byte Helpers
Under the hood, Nova's ARC memory allocator requires an 8-byte object header:
```text
[ptr-8] refcount (i64)   [ptr-4] length (i32)   [ptr..] data
```
Using `bytes.alloc(len) as string` directly without writing bytes returns a string containing **uninitialized garbage memory**. All binary serialization must allocate, write all bytes (including null terminators), and then cast.
Always use safe serialization helpers:
```nova
pub fn pg_byte1(b: int): string {
    let p = bytes.alloc(1);
    bytes.write_byte(p, 0, b & 255);
    return p as string;
}
```

### 0.2 Integer Width and Bitwise Safety
Nova's `int` is mapped directly to `i64` on native compilation. Local and parameter stack slots are always 64-bit wide. Avoid assumptions about byte truncation. Use bitwise operations (`& 255`, `>> 8`) rather than integer division/modulo to prevent sign-extension bugs during packet formatting.

### 0.3 The Bare-Function Local Call gotcha
In Nova, a bare function (e.g. `string.hash` or an unboxed struct method) is a raw code pointer. Calling a field directly works:
```nova
(self.hashFn)(key) // OK
```
However, copying it to a local first and then calling it will crash (SIGBUS/Hyperspace jump):
```nova
let f = self.hashFn;
(f)(key) // CRASH! Expects a closure box {fn_ptr, env}
```
**Rule:** When executing user-supplied callbacks, connection-handling delegates, or hash functions, always call the struct field directly without copying it to a local.

### 0.4 Template Formatting Restrictions
String interpolation using `${value}` compiles fine but **crashes with a SIGSEGV at runtime** for both `i64`/`long` and `f64`/`double`. 
* **Rule:** If formatting integers or doubles in queries/BSON/logs, manually cast them to `int` first (if safe), or write a custom string formatter. Never interpolate `f64` or `i64` directly in a template string.

### 0.5 Pre-sizing Collections
Nova Maps crash with a SIGBUS if they grow past their initial load factor.
* **Rule:** Pre-size all internal maps (such as parameter builders, command options, or BSON parsers) to their maximum expected capacity at initialization:
  ```nova
  let fields = Map<string, string>(256, string.hash);
  ```

### 0.6 Performance & Latency Tracking
To accurately profile queries without relying on low-resolution timers, utilize `datetime.nowNs()` (nanoseconds) instead of `datetime.now()` (seconds). Latency must be calculated in milliseconds as:
```nova
let latency_ms = ((end_ns - start_ns) as double) / 1000000.0;
```

---

## 1. Unified SQL Driver Trait

To allow SQL drivers to be interchangeable, we define a unified non-generic `DbConnection` trait.

```nova
// db_client.nova
import list;

pub struct Row {
    pub cells: List<string>,
    init() { self.cells = List<string>(); }
}

pub struct QueryResult {
    pub columns: List<string>,
    pub rows: List<Row>,
    pub affected_rows: int,
    pub last_insert_id: int,
    pub error: string,
    pub command_tag: string,
    pub latency_ms: double,

    init() {
        self.columns = List<string>();
        self.rows = List<Row>();
        self.affected_rows = 0;
        self.last_insert_id = 0;
        self.error = "";
        self.command_tag = "";
        self.latency_ms = 0.0;
    }
}

pub trait DbConnection {
    fn query(self: DbConnection, sql: string): QueryResult;
    fn close(self: DbConnection): void;
}
```

---

## 2. PostgreSQL Wire Protocol Driver (v3.0)

PostgreSQL implements a message-framed binary protocol. Front-end and back-end packets use the layout:
```text
[type: u8] [len: u32 BE (includes len field itself)] [payload]
```
*(Except the StartupMessage, which has no type prefix).*

### 2.1 Serialization & Helpers

```nova
// pg_helpers.nova
import bytes;

pub fn pg_byte1(b: int): string {
    let p = bytes.alloc(1);
    bytes.write_byte(p, 0, b & 255);
    return p as string;
}

pub fn pg_u16be(v: int): string {
    let p = bytes.alloc(2);
    bytes.write_byte(p, 0, (v >> 8) & 255);
    bytes.write_byte(p, 1, v & 255);
    return p as string;
}

pub fn pg_u32be(v: int): string {
    let p = bytes.alloc(4);
    bytes.write_byte(p, 0, (v >> 24) & 255);
    bytes.write_byte(p, 1, (v >> 16) & 255);
    bytes.write_byte(p, 2, (v >> 8) & 255);
    bytes.write_byte(p, 3, v & 255);
    return p as string;
}

pub fn pg_string_null(s: string): string {
    return s + pg_byte1(0); 
}

pub fn pg_frame(t: int, payload: string): string {
    return pg_byte1(t) + pg_u32be(4 + payload.length) + payload;
}
```

### 2.2 Connection & Driver Core

```nova
// pg_client.nova
import net.tcp.socket;
import net.asyncio;
import list;
import datetime;
import pg_helpers;
import db_client;

pub struct PgConn {
    pub fd: int,
    pub is_async: bool,

    init(fd: int, is_async: bool) {
        self.fd = fd;
        self.is_async = is_async;
    }

    // Synchronous execution path (DbConnection trait compliant)
    pub fn query(self: PgConn, sql: string): db_client.QueryResult {
        let start_time = datetime.nowNs();
        let stream = socket.TcpStream(self.fd as i32);
        let q_frame = pg_helpers.pg_frame(81, pg_helpers.pg_string_null(sql)); // 'Q'
        stream.write(q_frame);

        let res = db_client.QueryResult();
        var done = false;
        while (!done) {
            let header = stream.read(5);
            if (header.length < 5) { break; }
            let t = header[0];
            let len = ((header[1] << 24) & 4278190080) | ((header[2] << 16) & 16711680) | ((header[3] << 8) & 65280) | (header[4] & 255);
            let payload = stream.read(len - 4);

            switch (t) {
                case 84: // 'T' RowDescription
                    self.parseRowDesc(payload, res);
                case 68: // 'D' DataRow
                    self.parseDataRow(payload, res);
                case 67: // 'C' CommandComplete
                    res.command_tag = self.parseCommandTag(payload);
                case 69: // 'E' ErrorResponse
                    res.error = self.parseErrorMsg(payload);
                case 90: // 'Z' ReadyForQuery
                    done = true;
                default:
                    let dummy = 0;
            }
        }
        let end_time = datetime.nowNs();
        res.latency_ms = ((end_time - start_time) as double) / 1000000.0;
        return res;
    }

    // Scalable asynchronous execution path (coroutine-friendly)
    pub async fn queryAsync(self: PgConn, sql: string): db_client.QueryResult {
        let start_time = datetime.nowNs();
        let q_frame = pg_helpers.pg_frame(81, pg_helpers.pg_string_null(sql));
        let sent = await asyncio.asend(self.fd as i64, q_frame);
        
        let res = db_client.QueryResult();
        let buf = bytes.alloc(5);
        var done = false;
        while (!done) {
            let n = await asyncio.arecv(self.fd as i64, buf, 5);
            if (n < 5) { break; }
            let t = bytes.read_byte(buf, 0);
            let len = ((bytes.read_byte(buf, 1) << 24) & 4278190080) | ((bytes.read_byte(buf, 2) << 16) & 16711680) | ((bytes.read_byte(buf, 3) << 8) & 65280) | (bytes.read_byte(buf, 4) & 255);
            
            let plen = len - 4;
            let pbuf = bytes.alloc(plen);
            let pn = await asyncio.arecv(self.fd as i64, pbuf, plen);
            let payload = pbuf as string;

            switch (t) {
                case 84: // RowDescription
                    self.parseRowDesc(payload, res);
                case 68: // DataRow
                    self.parseDataRow(payload, res);
                case 67: // CommandComplete
                    res.command_tag = self.parseCommandTag(payload);
                case 69: // ErrorResponse
                    res.error = self.parseErrorMsg(payload);
                case 90: // ReadyForQuery
                    done = true;
                default:
                    let dummy = 0;
            }
            bytes.free(pbuf);
        }
        bytes.free(buf);
        let end_time = datetime.nowNs();
        res.latency_ms = ((end_time - start_time) as double) / 1000000.0;
        return res;
    }

    fn parseRowDesc(self: PgConn, payload: string, res: db_client.QueryResult): void { /* ... */ }
    fn parseDataRow(self: PgConn, payload: string, res: db_client.QueryResult): void { /* ... */ }
    fn parseCommandTag(self: PgConn, payload: string): string { return payload; }
    fn parseErrorMsg(self: PgConn, payload: string): string { return payload; }

    pub fn close(self: PgConn): void {
        if (self.fd != -1) {
            if (self.is_async) {
                asyncio.aclose(self.fd as i64);
            } else {
                nova_close(self.fd as i32);
            }
            self.fd = -1;
        }
    }
}
impl db_client.DbConnection for PgConn {
    fn query(self: PgConn, sql: string): db_client.QueryResult {
        return self.query(sql);
    }
    fn close(self: PgConn): void {
        self.close();
    }
}
```

---

## 3. MySQL Wire Protocol Driver

MySQL utilizes packet structures containing a 3-byte little-endian length and a 1-byte sequence ID:
```text
[len: u24 LE] [seq: u8] [payload]
```

### 3.1 Serialization & Helpers

```nova
// mysql_helpers.nova
import bytes;

pub fn my_byte1(b: int): string {
    let p = bytes.alloc(1);
    bytes.write_byte(p, 0, b & 255);
    return p as string;
}

pub fn my_u24le(v: int): string {
    let p = bytes.alloc(3);
    bytes.write_byte(p, 0, v & 255);
    bytes.write_byte(p, 1, (v >> 8) & 255);
    bytes.write_byte(p, 2, (v >> 16) & 255);
    return p as string;
}

pub fn my_u32le(v: int): string {
    let p = bytes.alloc(4);
    bytes.write_byte(p, 0, v & 255);
    bytes.write_byte(p, 1, (v >> 8) & 255);
    bytes.write_byte(p, 2, (v >> 16) & 255);
    bytes.write_byte(p, 3, (v >> 24) & 255);
    return p as string;
}

pub fn my_packet(payload: string, seq: int): string {
    return my_u24le(payload.length) + my_byte1(seq) + payload;
}
```

### 3.2 Driver Implementation

```nova
// mysql_client.nova
import net.tcp.socket;
import mysql_helpers;
import list;
import datetime;
import db_client;

pub struct MyField {
    pub name: string,
    pub type_id: int,
    init(name: string, type_id: int) {
        self.name = name;
        self.type_id = type_id;
    }
}

pub struct MyConn {
    pub stream: socket.TcpStream,
    pub seq: int,

    init(stream: socket.TcpStream) {
        self.stream = stream;
        self.seq = 0;
    }

    pub fn query(self: MyConn, sql: string): db_client.QueryResult {
        let start_time = datetime.nowNs();
        self.seq = 0;
        let payload = mysql_helpers.my_byte1(3) + sql; // COM_QUERY (0x03)
        self.stream.write(mysql_helpers.my_packet(payload, self.seq));
        self.seq = self.seq + 1;

        let res = db_client.QueryResult();
        let header = self.stream.read(4);
        if (header.length < 4) { return res; }
        
        let len = (header[0] & 255) | ((header[1] << 8) & 65280) | ((header[2] << 16) & 16711680);
        let response = self.stream.read(len);

        let packet_type = response[0];
        if (packet_type == 255) { // ERR Packet
            res.error = self.parseError(response);
            return res;
        }
        if (packet_type == 0) { // OK Packet
            self.parseOk(response, res);
            return res;
        }

        let col_count = response[0];
        var i = 0;
        while (i < col_count) {
            let col_hdr = self.stream.read(4);
            let col_len = (col_hdr[0] & 255) | ((col_hdr[1] << 8) & 65280) | ((col_hdr[2] << 16) & 16711680);
            let col_payload = self.stream.read(col_len);
            res.columns.push(self.parseFieldName(col_payload));
            i = i + 1;
        }

        // Consume first EOF packet
        let eof1 = self.stream.read(4);
        let eof1_len = (eof1[0] & 255) | ((eof1[1] << 8) & 65280) | ((eof1[2] << 16) & 16711680);
        let eof1_payload = self.stream.read(eof1_len);

        // Fetch Row Packets until EOF Packet (0xFE)
        while (true) {
            let row_hdr = self.stream.read(4);
            if (row_hdr.length < 4) { break; }
            let row_len = (row_hdr[0] & 255) | ((row_hdr[1] << 8) & 65280) | ((row_hdr[2] << 16) & 16711680);
            let row_payload = self.stream.read(row_len);
            
            if (row_payload[0] == 254) { // EOF Packet
                break;
            }
            res.rows.push(self.parseRow(row_payload, col_count));
        }

        let end_time = datetime.nowNs();
        res.latency_ms = ((end_time - start_time) as double) / 1000000.0;
        return res;
    }

    fn parseFieldName(self: MyConn, payload: string): string {
        // Unpack Length-Encoded string fields
        return "column_name";
    }

    fn parseRow(self: MyConn, payload: string, col_count: int): db_client.Row {
        let r = db_client.Row();
        // Parse individual cell strings
        return r;
    }

    fn parseOk(self: MyConn, payload: string, res: db_client.QueryResult): void {
        // affected_rows, last_insert_id parsed here
    }

    fn parseError(self: MyConn, payload: string): string {
        return "MySQL Query Error";
    }

    pub fn close(self: MyConn): void {
        self.stream.close();
    }
}
impl db_client.DbConnection for MyConn {
    fn query(self: MyConn, sql: string): db_client.QueryResult {
        return self.query(sql);
    }
    fn close(self: MyConn): void {
        self.close();
    }
}
```

---

## 4. Microsoft SQL Server Driver (TDS)

MSSQL utilizes Tabular Data Stream (TDS) packets featuring an 8-byte header:
```text
[type: u8] [status: u8] [len: u16 BE] [spid: u16 BE] [seq: u8] [win: u8 (0)]
```

### 4.1 Serialization & Helpers

```nova
// mssql_helpers.nova
import bytes;

pub fn tds_byte1(b: int): string {
    let p = bytes.alloc(1);
    bytes.write_byte(p, 0, b & 255);
    return p as string;
}

pub fn tds_u16be(v: int): string {
    let p = bytes.alloc(2);
    bytes.write_byte(p, 0, (v >> 8) & 255);
    bytes.write_byte(p, 1, v & 255);
    return p as string;
}

pub fn tds_u32le(v: int): string {
    let p = bytes.alloc(4);
    bytes.write_byte(p, 0, v & 255);
    bytes.write_byte(p, 1, (v >> 8) & 255);
    bytes.write_byte(p, 2, (v >> 16) & 255);
    bytes.write_byte(p, 3, (v >> 24) & 255);
    return p as string;
}

pub fn tds_header(type_id: int, status: int, len: int, seq: int): string {
    return tds_byte1(type_id) + tds_byte1(status) + tds_u16be(len) + tds_u16be(0) + tds_byte1(seq) + tds_byte1(0);
}

// Convert ASCII string to UCS-2 / UTF-16LE payload for TDS strings
pub fn to_utf16le(s: string): string {
    let p = bytes.alloc(s.length * 2);
    var i = 0;
    while (i < s.length) {
        bytes.write_byte(p, i * 2, s[i]);
        bytes.write_byte(p, i * 2 + 1, 0);
        i = i + 1;
    }
    return p as string;
}
```

### 4.2 Driver Implementation

```nova
// mssql_client.nova
import net.tcp.socket;
import mssql_helpers;
import list;
import datetime;
import db_client;

pub struct MsConn {
    pub stream: socket.TcpStream,
    pub seq: int,

    init(stream: socket.TcpStream) {
        self.stream = stream;
        self.seq = 1;
    }

    pub fn executeSql(self: MsConn, sql: string): db_client.QueryResult {
        let start_time = datetime.nowNs();
        let text_utf16 = mssql_helpers.to_utf16le(sql);
        let payload = text_utf16;
        let tot_len = payload.length + 8;
        let header = mssql_helpers.tds_header(1, 1, tot_len, self.seq); // SQL Batch (0x01)
        self.stream.write(header + payload);
        self.seq = (self.seq + 1) % 256;

        let res = db_client.QueryResult();
        let r_hdr = self.stream.read(8);
        if (r_hdr.length < 8) { return res; }
        
        let p_len = (r_hdr[2] * 256) + r_hdr[3];
        let p_payload = self.stream.read(p_len - 8);

        var pos = 0;
        while (pos < p_payload.length) {
            let token = p_payload[pos];
            pos = pos + 1;

            switch (token) {
                case 170: // COLMETADATA (0xAA)
                    pos = self.parseColMetadata(p_payload, pos, res);
                case 209: // ROW (0xD1)
                    pos = self.parseRow(p_payload, pos, res);
                case 253: // DONE (0xFD)
                    pos = self.parseDone(p_payload, pos);
                case 171: // ERROR (0xAB)
                    pos = self.parseError(p_payload, pos, res);
                default:
                    pos = p_payload.length; 
            }
        }

        let end_time = datetime.nowNs();
        res.latency_ms = ((end_time - start_time) as double) / 1000000.0;
        return res;
    }

    fn parseColMetadata(self: MsConn, p: string, start: int, res: db_client.QueryResult): int {
        let count = p[start] + p[start + 1] * 256;
        var pos = start + 2;
        var i = 0;
        while (i < count) {
            // skip metadata parameters and read name
            i = i + 1;
        }
        return pos;
    }

    fn parseRow(self: MsConn, p: string, start: int, res: db_client.QueryResult): int {
        let r = db_client.Row();
        res.rows.push(r);
        return start; 
    }

    fn parseDone(self: MsConn, p: string, start: int): int {
        return start + 12;
    }

    fn parseError(self: MsConn, p: string, start: int, res: db_client.QueryResult): int {
        res.error = "TDS SQL Execution Error";
        return p.length;
    }

    pub fn close(self: MsConn): void {
        self.stream.close();
    }
}
impl db_client.DbConnection for MsConn {
    fn query(self: MsConn, sql: string): db_client.QueryResult {
        return self.executeSql(sql);
    }
    fn close(self: MsConn): void {
        self.close();
    }
}
```

---

## 5. MongoDB Driver (OP_MSG Protocol & BSON)

MongoDB communicates via `OP_MSG` (Opcode 2013). High-performance data representation is handled by BSON.

### 5.1 OP_MSG Struct & BSON Serialization Design

```nova
// bson.nova
import bytes;
import list;
import string;

pub fn bson_byte1(b: int): string {
    let p = bytes.alloc(1);
    bytes.write_byte(p, 0, b & 255);
    return p as string;
}

pub fn bson_string(name: string, value: string): string {
    let type_prefix = bson_byte1(2); // 0x02 UTF-8 String
    let p_len = bytes.alloc(4);
    let l = value.length + 1;
    bytes.write_byte(p_len, 0, l & 255);
    bytes.write_byte(p_len, 1, (l >> 8) & 255);
    bytes.write_byte(p_len, 2, (l >> 16) & 255);
    bytes.write_byte(p_len, 3, (l >> 24) & 255);

    return type_prefix + name + bson_byte1(0) + (p_len as string) + value + bson_byte1(0);
}

// BSON Double: 0x01 type.
// Value is parsed as a double, reinterpreted to 64-bit integer bits, and serialized.
pub fn bson_double(name: string, value: double): string {
    let type_prefix = bson_byte1(1); // 0x01 Double
    let bits = value as int;        // Reinterprets double bits to 64-bit int slot in Nova
    
    let p = bytes.alloc(8);
    bytes.write_byte(p, 0, bits & 255);
    bytes.write_byte(p, 1, (bits >> 8) & 255);
    bytes.write_byte(p, 2, (bits >> 16) & 255);
    bytes.write_byte(p, 3, (bits >> 24) & 255);
    bytes.write_byte(p, 4, (bits >> 32) & 255);
    bytes.write_byte(p, 5, (bits >> 40) & 255);
    bytes.write_byte(p, 6, (bits >> 48) & 255);
    bytes.write_byte(p, 7, (bits >> 56) & 255);
    
    return type_prefix + name + bson_byte1(0) + (p as string);
}

pub fn bson_int32(name: string, value: int): string {
    let type_prefix = bson_byte1(16); // 0x10 Int32
    let val_bytes = bytes.alloc(4);
    bytes.write_byte(val_bytes, 0, value & 255);
    bytes.write_byte(val_bytes, 1, (value >> 8) & 255);
    bytes.write_byte(val_bytes, 2, (value >> 16) & 255);
    bytes.write_byte(val_bytes, 3, (value >> 24) & 255);
    
    return type_prefix + name + bson_byte1(0) + (val_bytes as string);
}

pub fn bson_document(payload: string): string {
    let doc_len = payload.length + 5; 
    let len_bytes = bytes.alloc(4);
    bytes.write_byte(len_bytes, 0, doc_len & 255);
    bytes.write_byte(len_bytes, 1, (doc_len >> 8) & 255);
    bytes.write_byte(len_bytes, 2, (doc_len >> 16) & 255);
    bytes.write_byte(len_bytes, 3, (doc_len >> 24) & 255);
    
    return (len_bytes as string) + payload + bson_byte1(0);
}
```

### 5.2 MongoDB Client

```nova
// mongo_client.nova
import net.tcp.socket;
import bson;
import bytes;
import datetime;

pub struct MongoConn {
    pub stream: socket.TcpStream,
    pub request_id: int,

    init(stream: socket.TcpStream) {
        self.stream = stream;
        self.request_id = 1;
    }

    pub fn command(self: MongoConn, db: string, cmd_payload: string): string {
        let full_cmd_payload = cmd_payload + bson.bson_string("$db", db);
        let cmd_doc = bson.bson_document(full_cmd_payload);

        let msg_body = bytes.alloc(5);
        bytes.write_byte(msg_body, 0, 0); 
        bytes.write_byte(msg_body, 1, 0); 
        bytes.write_byte(msg_body, 2, 0); 
        bytes.write_byte(msg_body, 3, 0); 
        bytes.write_byte(msg_body, 4, 0); // payloadType = 0

        let body_payload = (msg_body as string) + cmd_doc;
        let msg_len = body_payload.length + 16;

        let header = bytes.alloc(16);
        // messageLength (LE)
        bytes.write_byte(header, 0, msg_len & 255);
        bytes.write_byte(header, 1, (msg_len >> 8) & 255);
        bytes.write_byte(header, 2, (msg_len >> 16) & 255);
        bytes.write_byte(header, 3, (msg_len >> 24) & 255);
        // requestID (LE)
        bytes.write_byte(header, 4, self.request_id & 255);
        bytes.write_byte(header, 5, (self.request_id >> 8) & 255);
        bytes.write_byte(header, 6, (self.request_id >> 16) & 255);
        bytes.write_byte(header, 7, (self.request_id >> 24) & 255);
        // responseTo (0)
        bytes.write_byte(header, 8, 0);
        bytes.write_byte(header, 9, 0);
        bytes.write_byte(header, 10, 0);
        bytes.write_byte(header, 11, 0);
        // opCode (2013 LE)
        bytes.write_byte(header, 12, 221);
        bytes.write_byte(header, 13, 7);
        bytes.write_byte(header, 14, 0);
        bytes.write_byte(header, 15, 0);

        self.stream.write((header as string) + body_payload);
        self.request_id = self.request_id + 1;

        let r_hdr = self.stream.read(16);
        if (r_hdr.length < 16) { return ""; }
        
        let r_len = (r_hdr[0] & 255) | ((r_hdr[1] << 8) & 65280) | ((r_hdr[2] << 16) & 16711680) | ((r_hdr[3] << 24) & 4278190080);
        let r_body = self.stream.read(r_len - 16);

        let doc_payload = string.slice(r_body, 5, r_body.length);
        return doc_payload; // Returns BSON payload reply
    }

    pub fn close(self: MongoConn): void {
        self.stream.close();
    }
}
```

---

## 6. Comparison of Specifications

| Property / Feature | PostgreSQL | MySQL | Microsoft SQL Server (TDS) | MongoDB |
|---|---|---|---|---|
| **Framing Pattern** | `[type: u8] [len: u32 BE] [payload]` | `[len: u24 LE] [seq: u8] [payload]` | `[tds_hdr: 8B] [payload]` | `[msg_hdr: 16B] [msg_body]` |
| **Endianness** | Big-Endian (BE) | Little-Endian (LE) | Mixed / Big-Endian | Little-Endian (LE) |
| **Authentication Message** | StartupMessage (Type 0) | HandshakeResponse41 | Pre-Login (`0x02`), Login7 (`0x10`) | BSON Command `saslStart` |
| **String Terminology** | Null-terminated ASCII | Length-Encoded (VARINT prefix) | UCS-2 / UTF-16LE | BSON strings: `[len: i32 LE] [data] \x00` |
| **Floating-Point support** | String / Text Protocol | Text / Binary parameters | Numeric / Float TDS tokens | BSON `0x01` (64-bit IEEE-754 LE) |
