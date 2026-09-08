-- A SEPARATE database for keyv scene blobs, with the keyv table pre-created.
-- Two measured failure modes, defused together:
--
--   1. @keyv/postgres lazily CREATEs its table on connect and the api opens
--      four keyv connections at boot; on a missing table they race and the
--      losers stay broken until the next restart. Pre-creating makes the
--      CREATE a deterministic no-op.
--   2. But pre-creating it in PRISMA'S database makes `prisma migrate deploy`
--      fail P3005 on every boot, so the entrypoint falls back to
--      `prisma db push --accept-data-loss`, which DROPS the keyv table with
--      every stored scene in it.
--
-- Hence the split: Prisma's `excalidraw` db is empty at first migrate, and
-- nothing Prisma does can reach `excalidraw_storage`.
--
-- The DDL matches @keyv/postgres 1.4.11's defaults byte-for-byte; a bump that
-- changes them brings the race back, and the suite's zero-"Connection Error"
-- assertion across a restart is the tripwire. STORAGE_URI in .sops.env must
-- point at THIS database.
CREATE DATABASE excalidraw_storage OWNER excalidraw;

\connect excalidraw_storage

CREATE TABLE IF NOT EXISTS public.keyv (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT
);
ALTER TABLE public.keyv OWNER TO excalidraw;
