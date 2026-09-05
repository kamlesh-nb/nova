-- Schema for the PostgreSQL-backed build of the web app (main_postgres.nova). `run-live.sh` applies
-- this file so the GET endpoint has a few rows to return on a fresh database.
CREATE TABLE IF NOT EXISTS products (id INT PRIMARY KEY, name TEXT, price INT);

INSERT INTO products (id, name, price) VALUES (1, 'Keyboard', 4500);
INSERT INTO products (id, name, price) VALUES (2, 'Mouse', 1800);
INSERT INTO products (id, name, price) VALUES (3, 'Monitor', 22000);
