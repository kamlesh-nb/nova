# Design Specification: Nova Data Studio

> ## ⚠️ BLOCKED / REWRITE PENDING (2026-07-17)
>
> This spec is written **entirely against features that do not exist**, and it imports modules that
> were never written (`mysql_client`, `mongo_client`, …). Its dependency, `db-drivers.md`, is a 5%
> sketch and is now **deferred by decision** — so this design is blocked behind it.
>
> ⚠️ **§3.1 encodes a FIXED bug as a design constraint**: `// Pre-size session map to avoid resize
> SIGBUS crashes`. That crash **no longer exists** (measured: 5000 keys from a presize of 8, many
> resizes, clean). Do not carry the workaround — or the fear — forward.
>
> Also note `studio/` in the repo root is currently a **Node.js** app (`server.js`, `node_modules`),
> not Nova. **Rewrite this document after the foundation and drivers land** (plan P4-28).


This document specifies the design, user interface layout, and backend integration for **Nova Data Studio** (an Azure Data Studio-like desktop and web application) powered by a high-performance **Nova language** backend and the low-level database drivers designed in `db-drivers.md`.

---

## 1. Look & Feel (Visual Design System)

Nova Data Studio adopts the precise dark theme design system of **Azure Data Studio / VS Code**, built using HTML5, vanilla CSS/Variables, and Monaco Editor.

### 1.1 Color Palette (CSS Custom Properties)
```css
:root {
  --activity-bar-bg: #333333;
  --activity-bar-fg: #d7d7d7;
  --activity-bar-active-border: #007acc;
  
  --sidebar-bg: #252526;
  --sidebar-fg: #cccccc;
  
  --editor-bg: #1e1e1e;
  --editor-fg: #d4d4d4;
  
  --panel-bg: #1e1e1e;
  --panel-border: #80808050;
  
  --tab-active-bg: #1e1e1e;
  --tab-inactive-bg: #2d2d2d;
  --tab-border: #252526;
  
  --status-bar-bg: #007acc;
  --status-bar-fg: #ffffff;
  
  --accent-color: #007acc;
  --button-hover: #0062a3;
  --input-bg: #3c3c3c;
  --input-fg: #cccccc;
  --grid-border: #3c3c3c;
  --grid-row-even: #1e1e1e;
  --grid-row-odd: #252526;
}
```

### 1.2 Layout Structure
The interface utilizes a grid-based multi-pane layout:
```text
+-------------------------------------------------------------------------+
| Activity | Sidebar Pane     | Tab Bar (Query1.sql | Query2.sql)         |
| Bar      | (Connections)    +-------------------------------------------+
|          |                  |                                           |
| (Plug)   | - Server Group   | Monaco Editor                             |
|          |   - localhost    |                                           |
| (Search) |     - Databases  |                                           |
|          |       - pg_db    |                                           |
| (Files)  |         - Tables |                                           |
|          |           - users+-------------------------------------------+
| (Gear)   |                  | Grid Results Panel (Rows/Cols)            |
+----------+------------------+-------------------------------------------+
| Status Bar (Connected to localhost | PostgreSQL | Latency: 4.2ms)       |
+-------------------------------------------------------------------------+
```

---

## 2. Component Design Specifications

### 2.1 Left Activity Bar
* **Icon List:** Connections (Plug), Search (Magnifying Glass), Notebooks (Journal), Settings (Gear).
* **Behavior:** Clicking an icon toggles the visibility of the primary Sidebar Pane orelse switches active tabs.

### 2.2 Connections Side Pane (Object Explorer)
* **Connection Tree View:** Displays active and saved server connections grouped by server type (PostgreSQL, MySQL, MSSQL, MongoDB).
* **Hierarchical Tree Nodes:**
  * `Server Connection (Host)`
    * `Databases`
      * `Database Name`
        * `Tables` (lists user tables, expandable to show columns)
        * `Views`
        * `Programmability` (stored procedures, triggers)
* **Actions:** Right-click context menu supporting "New Query", "Disconnect", and "Refresh".

### 2.3 Tabbed Query Editor
* **Monaco Editor Integration:** Embedded via loader script to provide SQL syntax highlighting, auto-complete, and indentation rules.
* **Toolbar Actions:**
  * **Run (F5):** Sends selected text orelse full buffer to backend.
  * **Cancel:** Disconnects/cancels the active query coroutine thread.
  * **Database Selector:** Dropdown listing databases in the active connection.

### 2.4 Results Grid and Output Panel
* **Data Grid:** Virtualized scrolling table rendering query response rows.
* **Export Actions:** CSV, JSON, and XML format downloaders.
* **Messages Tab:** Displays affected row count, execution logs, and detailed timing metrics (latency).

---

## 3. Backend Integration (Nova Language API Server)

The desktop shell (Tauri/Electron) communicates with a lightweight, multi-threaded Nova backend server compiled with `--native`. The server maintains database pools using asynchronous coroutines (`net/asyncio` and `go`).

### 3.1 Session Manager Design
The server uses a pre-allocated registry map (`g_sessions`) to map connection IDs to open socket streams.

```nova
// session_manager.nova
import pg_client;
import mysql_client;
import mssql_client;
import mongo_client;
import db_client;

pub struct DbSession {
    pub id: string,
    pub db_type: string, // "postgres" | "mysql" | "mssql" | "mongo"
    pub pg_conn: pg_client.PgConn | undefined,
    pub my_conn: mysql_client.MyConn | undefined,
    pub ms_conn: mssql_client.MsConn | undefined,
    pub mongo_conn: mongo_client.MongoConn | undefined,
}

// Pre-size session map to avoid resize SIGBUS crashes
const g_sessions = Map<string, DbSession>(1024, string.hash);
```

### 3.2 Asynchronous Endpoint Routing
The Nova web server uses coroutine routes to handle requests concurrently without holding threads.

#### 3.2.1 Route: `/api/connect` (POST)
Initializes connection streams and logs the state in the session manager.
```nova
async fn handleConnect(req: Request): Response {
    let body = req.json();
    let db_type = body.get("type");
    let host = body.get("host");
    let port = body.get("port") as int;
    let user = body.get("username");
    let pwd = body.get("password");
    let db = body.get("database");

    let session_id = generateSessionId();

    if (db_type == "postgres") {
        let raw_fd = connectSocket(host, port); // low level fd
        let pg_conn = pg_client.PgConn(raw_fd, true);
        // Execute handshake sequence asynchronously ...
        let sess = DbSession{ id: session_id, db_type: "postgres", pg_conn: pg_conn, ... };
        g_sessions.set(session_id, sess);
    }
    // Handle MySQL, MSSQL, Mongo ...

    return Response.json(`{"status":"success", "sessionId":"${session_id}"}`);
}
```

#### 3.2.2 Route: `/api/query` (POST)
Executes a SQL command asynchronously, returning results, error messages, and execution latency.
```nova
async fn handleQuery(req: Request): Response {
    let body = req.json();
    let session_id = body.get("sessionId");
    let sql = body.get("sql");

    let sess = g_sessions.get(session_id);
    if (sess == undefined) {
        return Response.error(404, "Session not found");
    }

    let start_ns = datetime.nowNs();
    var result = db_client.QueryResult();

    if (sess.db_type == "postgres") {
        // Await the asynchronous database execution path (strand-safe)
        result = await (sess.pg_conn).queryAsync(sql);
    }
    // Route MySQL, MSSQL ...

    let json_resp = formatResultToJson(result);
    return Response.json(json_resp);
}
```

#### 3.2.3 Route: `/api/schema` (GET)
Returns database object hierarchies to populate the connection explorer tree view.
```nova
async fn handleSchema(req: Request): Response {
    let session_id = req.query("sessionId");
    let sess = g_sessions.get(session_id);
    if (sess == undefined) {
        return Response.error(404, "Session not found");
    }

    var schema_query = "";
    if (sess.db_type == "postgres") {
        schema_query = "SELECT table_name FROM information_schema.tables WHERE table_schema='public'";
    } else if (sess.db_type == "mysql") {
        schema_query = "SHOW TABLES";
    }

    // Execute query and format to structured JSON tree nodes ...
    return Response.json(schema_data);
}
```

---

## 4. Specific UX Behaviors to Match Azure Data Studio

To ensure an authentic experience, the client layer (HTML/CSS) implements the following features:

### 4.1 Connection Dialog Modal
* Pre-populates default ports (5432 for PG, 3306 for MySQL, 1433 for MSSQL, 27017 for MongoDB).
* Validates connection parameters before closing the overlay.
* Saves connection metadata into a local JSON store.

### 4.2 Tab Lifecycle & Split Panels
* Tabs can be dragged to create side-by-side split editors.
* Double-clicking a tab keeps it pinned; single-clicking opens files in preview mode (italic title).

### 4.3 Results/Messages Splitter
* Splitter controls allow users to adjust the vertical boundary height between the Monaco SQL text input and the query result grid.
* Supports keyboard toggles (e.g. `Ctrl + ~` to focus output console).

---

## 5. Hypermedia Reactivity using Datastar

Datastar enables real-time, ultra-lightweight reactivity using declarative HTML5 attributes (`data-model`, `data-on-click`, `data-sse`) powered by a Server-Sent Events (SSE) streaming backend. It provides a native, desktop-app feel with near-zero JavaScript bundle sizes.

### 5.1 Declarative State and Connection Binding
Connection configurations are managed using Datastar client-side signals. Form elements are bound directly to reactive variables:

```html
<div id="connection-form" 
     data-signals="{type: 'postgres', host: '127.0.0.1', port: 5432, username: '', password: '', database: ''}">
  
  <select data-model="type" class="selector">
    <option value="postgres">PostgreSQL</option>
    <option value="mysql">MySQL</option>
    <option value="mssql">SQL Server</option>
    <option value="mongo">MongoDB</option>
  </select>

  <input type="text" data-model="host" placeholder="Host" />
  <input type="number" data-model="port" placeholder="Port" />
  <input type="text" data-model="username" placeholder="Username" />
  <input type="password" data-model="password" placeholder="Password" />
  <input type="text" data-model="database" placeholder="Database" />

  <!-- Action posts signals to backend -->
  <button data-on-click="$$post('/api/connect')">Connect</button>
</div>
```

On a successful connection, the Nova backend streams back an SSE event containing the compiled Object Explorer sidebar HTML fragment, which Datastar automatically merges into the sidebar DOM without a page refresh.

### 5.2 Real-time Query Row Streaming
When executing query batches that return hundreds of thousands of rows, compiling a single massive JSON response causes memory spikes and UI lag. Datastar's Server-Sent Events structure enables the Nova coroutines to stream query rows **chunk-by-chunk orelse row-by-row** to the frontend as they are parsed from the socket.

#### 5.2.1 Nova SSE Streaming Endpoint (Conceptual)
```nova
async fn handleQueryStream(req: Request, client_fd: int): void {
    let sql = req.body().get("sql");
    
    // Write HTTP response headers for SSE
    let sse_headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    await asyncio.asend(client_fd as i64, sse_headers);
    
    // Write initial results grid frame
    let initial_frame = "event: datastar-merge-fragments\ndata: fragments <table id='results-grid'><thead><tr><th>ID</th><th>Data</th></tr></thead><tbody></tbody></table>\n\n";
    await asyncio.asend(client_fd as i64, initial_frame);

    // Stream rows as they arrive from socket
    let stream = socket.TcpStream(pg_fd);
    while (has_more_rows) {
        let row = read_single_row_from_socket(stream);
        let row_fragment = `event: datastar-merge-fragments\ndata: fragments <tr class='grid-row'><td>${row.id}</td><td>${row.data}</td></tr>\ndata: selector #results-grid tbody\ndata: mergeMode append\n\n`;
        await asyncio.asend(client_fd as i64, row_fragment);
    }
}
```

This streaming hypermedia approach provides **sub-millisecond Largest Contentful Paint (LCP)** for data tables, matching the streaming performance of native query grids.

### 5.3 Dynamic Explorer Tree Navigation
Expanding directory nodes triggers lazy-loading signals. Clicking on a tables directory requests nested lists dynamically:

```html
<div class="tree-node parent-node"
     data-on-click="$$get('/api/schema/tables?sessionId=' + sessionId)">
  📁 Tables
  <!-- The child nodes are dynamically injected here by Datastar -->
  <div id="tables-list"></div>
</div>
```
The backend processes the metadata call and returns the formatted table list nodes:
```text
event: datastar-merge-fragments
data: fragments <div id="tables-list"><div class="tree-node child-node">📄 users</div><div class="tree-node child-node">📄 accounts</div></div>
data: selector #tables-list
data: mergeMode outer
```
This keeps Object Explorer state memory-efficient, pulling database structure maps only as the user requests them.

