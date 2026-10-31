-- What this run's export adds to export-db-earlier-run.sql, as osxphotos
-- (photoexporter.py at the pinned commit) writes it:
--   a.heic: unchanged, "skip"; its export_data row is rewritten, which
--     bumps its timestamp.
--   b.heic: changed, rewritten, "update: DEST_SIG_DIFFERENT", new dest_size.
--   c.heic and its c.aae: new, "new" and "AAE: new".
--   e.heic and e.mov: unchanged, but the original isn't on the Mac, so the
--     fork skips them without a download: a "skip" history row each and no
--     export_data write, so their timestamps stay old.
--   d.heic: missing from the library's files, "missing", no export_data row.
--   gone.heic: no longer in the library: no history row; cleanup deletes it.
UPDATE export_data SET dest_size = 1000 WHERE filepath_normalized = '2026/10/17/a.heic';
UPDATE export_data SET dest_size = 2500 WHERE filepath_normalized = '2026/10/17/b.heic';
INSERT INTO export_data (filepath_normalized, filepath, uuid, dest_size) VALUES
    ('2026/10/18/c.heic', '2026/10/18/C.HEIC', 'uuid-c', 3000),
    ('2026/10/18/c.aae', '2026/10/18/C.AAE', 'uuid-c', 100);
INSERT OR IGNORE INTO history_path (filepath_normalized, uuid) VALUES
    ('2026/10/18/c.heic', 'uuid-c'),
    ('2026/10/18/c.aae', 'uuid-c'),
    ('2026/10/18/d.heic', 'uuid-d');
INSERT INTO history (filepath_id, action)
    SELECT id, CASE filepath_normalized
        WHEN '2026/10/17/a.heic' THEN 'skip'
        WHEN '2026/10/17/b.heic' THEN 'update: DEST_SIG_DIFFERENT'
        WHEN '2026/10/18/c.heic' THEN 'new'
        WHEN '2026/10/18/c.aae' THEN 'AAE: new'
        WHEN '2026/10/17/e.heic' THEN 'skip'
        WHEN '2026/10/17/e.mov' THEN 'skip'
        WHEN '2026/10/18/d.heic' THEN 'missing'
        END
    FROM history_path WHERE filepath_normalized != '2026/10/17/gone.heic';
