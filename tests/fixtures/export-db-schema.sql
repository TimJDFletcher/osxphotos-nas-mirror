-- The tables of osxphotos' export database that the metrics read, as
-- osxphotos/export_db.py at the pinned commit creates them (export_data:
-- _migrate_5_0_to_6_0, then the timestamp, error and date_modified columns;
-- history_path and history: _migrate_8_0_to_9_0 and the indexes after it).
-- osxphotos sets journal_mode=WAL; the fixture does too.
PRAGMA journal_mode=WAL;
CREATE TABLE export_data(
    id INTEGER PRIMARY KEY,
    filepath_normalized TEXT NOT NULL,
    filepath TEXT NOT NULL,
    uuid TEXT NOT NULL,
    src_mode INTEGER,
    src_size INTEGER,
    src_mtime REAL,
    dest_mode INTEGER,
    dest_size INTEGER,
    dest_mtime REAL,
    digest TEXT,
    exifdata JSON,
    export_options INTEGER,
    timestamp DATETIME,
    error JSON,
    date_modified DATETIME,
    UNIQUE(filepath_normalized)
);
CREATE UNIQUE INDEX idx_export_data_filepath_normalized ON export_data (filepath_normalized);
CREATE INDEX idx_export_data_uuid ON export_data (uuid);
CREATE TRIGGER insert_timestamp_trigger
AFTER INSERT ON export_data
BEGIN
    UPDATE export_data SET timestamp = STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW') WHERE id = NEW.id;
END;
CREATE TRIGGER update_timestamp_trigger
AFTER UPDATE ON export_data
BEGIN
    UPDATE export_data SET timestamp = STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW') WHERE id = NEW.id;
END;
CREATE TABLE history_path (
    id INTEGER PRIMARY KEY,
    filepath_normalized TEXT NOT NULL,
    uuid TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_history_path_filepath_normalized ON history_path (filepath_normalized);
CREATE INDEX idx_history_path_uuid ON history_path (uuid);
CREATE TABLE history (
    id INTEGER PRIMARY KEY,
    filepath_id INTEGER,
    datetime DATETIME,
    action TEXT,
    diff JSON
);
CREATE INDEX idx_history_filepath_id ON history (filepath_id);
CREATE TRIGGER insert_history_datetime_trigger
AFTER INSERT ON history
BEGIN
    UPDATE history SET datetime = STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW') WHERE id = NEW.id;
END;
