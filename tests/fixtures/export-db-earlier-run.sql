-- An export database after an earlier run: five files exported, each with a
-- "new" history row. gone.heic has since been deleted from the library, so the
-- next run's cleanup deletes it from the share, but osxphotos never deletes
-- its export_data row.
INSERT INTO export_data (filepath_normalized, filepath, uuid, dest_size) VALUES
    ('2026/10/17/a.heic', '2026/10/17/A.HEIC', 'uuid-a', 1000),
    ('2026/10/17/b.heic', '2026/10/17/B.HEIC', 'uuid-b', 2000),
    ('2026/10/17/e.heic', '2026/10/17/E.HEIC', 'uuid-e', 500),
    ('2026/10/17/e.mov', '2026/10/17/E.MOV', 'uuid-e', 700),
    ('2026/10/17/gone.heic', '2026/10/17/GONE.HEIC', 'uuid-gone', 4000);
INSERT INTO history_path (filepath_normalized, uuid)
    SELECT filepath_normalized, uuid FROM export_data;
INSERT INTO history (filepath_id, action)
    SELECT id, 'new' FROM history_path;
