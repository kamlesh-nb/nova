-- Schema for the NovaDB-backed build of the web app (main_novadb.nova). `main_novadb` also runs a
-- CREATE TABLE IF NOT EXISTS at startup, so applying this file is optional; it is here so `run-live.sh`
-- can seed a few rows for the GET endpoint to return on a fresh server.
CREATE TABLE IF NOT EXISTS products (id INT PRIMARY KEY, name TEXT, price INT);

INSERT INTO products (id, name, price) VALUES (1, 'Keyboard', 4500);
INSERT INTO products (id, name, price) VALUES (2, 'Mouse', 1800);
INSERT INTO products (id, name, price) VALUES (3, 'Monitor', 22000);
