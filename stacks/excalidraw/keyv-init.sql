-- Create a SEPARATE database for keyv scene-blob storage, with the keyv
-- table pre-created. Two failure modes are being defused at once, and the
-- separate database is what lets both fixes coexist — both MEASURED against
-- the pinned images, not inferred:
--
--   1. THE KEYV CREATE RACE. @keyv/postgres 1.4.11 lazily runs CREATE TABLE
--      IF NOT EXISTS on connect, and the api opens FOUR keyv connections at
--      boot. On a missing table they race, the losers' connections reject
--      (duplicate pg_type key) and stay broken until the next restart —
--      boots coin-flip between healthy and 500-on-every-scene-read.
--      Pre-creating the table makes the CREATE a deterministic no-op.
--
--   2. PRISMA P3005 + THE db-push DATA SHREDDER. The api entrypoint runs
--      `prisma migrate deploy` and falls back to `prisma db push
--      --accept-data-loss` on failure. Pre-creating the keyv table in
--      PRISMA'S OWN database makes migrate deploy fail P3005 ("schema is
--      not empty") on EVERY boot, so every boot reaches db push, and db
--      push DROPS any table not in schema.prisma — i.e. the keyv table,
--      WITH every stored scene in it. Measured: that exact chain shredded
--      the blob table on each restart. Hence a second database: Prisma's
--      `excalidraw` db is empty at first migrate (P3005 impossible, history
--      recorded, db push never runs), and nothing Prisma does can ever
--      touch `excalidraw_storage`.
--
-- The DDL matches @keyv/postgres 1.4.11's own defaults byte-for-byte
-- (schema 'public', table 'keyv', keySize 255 — read out of the pinned
-- image at node_modules/@keyv/postgres/dist/index.js). If a bump changes
-- those defaults the race returns; the suite's zero-"Connection Error"
-- assertion across a restart is the tripwire.
--
-- Runs from /docker-entrypoint-initdb.d, i.e. exactly once, when initdb
-- first creates the cluster — during which postgres accepts no TCP, so the
-- api cannot connect before this exists. STORAGE_URI in .sops.env must
-- point at THIS database (see .sops.env.example).
CREATE DATABASE excalidraw_storage OWNER excalidraw;

\connect excalidraw_storage

CREATE TABLE IF NOT EXISTS public.keyv (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT
);
ALTER TABLE public.keyv OWNER TO excalidraw;
