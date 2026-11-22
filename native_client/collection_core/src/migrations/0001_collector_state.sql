CREATE TABLE archive_connection (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    archive_origin TEXT NOT NULL,
    credential_fingerprint TEXT NOT NULL,
    suspension_reason TEXT CHECK (suspension_reason IN ('credential_refused', 'credential_insufficient')),
    suspended_at INTEGER,
    CHECK ((suspension_reason IS NULL) = (suspended_at IS NULL))
);

CREATE TABLE watched_folders (
    folder_identifier INTEGER PRIMARY KEY,
    root_path BLOB NOT NULL UNIQUE,
    enrolled_at INTEGER NOT NULL,
    admission TEXT NOT NULL CHECK (admission IN ('surveying', 'awaiting_decision', 'collecting')),
    decided_at INTEGER,
    CHECK ((admission = 'collecting') = (decided_at IS NOT NULL))
);

CREATE TABLE contents (
    content_digest TEXT PRIMARY KEY CHECK (length(content_digest) = 64),
    archive_standing TEXT NOT NULL CHECK (archive_standing IN ('unresolved', 'absent', 'present', 'deleted', 'refused')),
    looked_up_at INTEGER,
    submission_failures INTEGER NOT NULL DEFAULT 0,
    retry_not_before INTEGER,
    document_identifier TEXT,
    document_status TEXT,
    failure_reason TEXT,
    status_read_at INTEGER,
    received_at INTEGER,
    refusal_reason TEXT CHECK (refusal_reason IN ('too_large', 'unaccepted_kind')),
    CHECK ((archive_standing = 'present') = (document_identifier IS NOT NULL)),
    CHECK ((archive_standing = 'refused') = (refusal_reason IS NOT NULL)),
    CHECK (archive_standing <> 'absent' OR looked_up_at IS NOT NULL)
);

CREATE TABLE path_observations (
    folder_identifier INTEGER NOT NULL REFERENCES watched_folders ON DELETE CASCADE,
    directory_key TEXT NOT NULL,
    entry_name BLOB NOT NULL,
    device INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    byte_size INTEGER NOT NULL,
    modification_nanoseconds INTEGER NOT NULL,
    status_change_nanoseconds INTEGER NOT NULL,
    dataless INTEGER NOT NULL CHECK (dataless IN (0, 1)),
    lifecycle TEXT NOT NULL CHECK (lifecycle IN ('stabilizing', 'stable', 'digested', 'excluded', 'unreadable')),
    observed_at INTEGER NOT NULL,
    first_observed_at INTEGER NOT NULL,
    content_digest TEXT REFERENCES contents,
    exclusion_reason TEXT CHECK (exclusion_reason IN ('empty_file', 'exceeds_size_limit', 'cloud_placeholder', 'unrecognized_content')),
    unreadable_since INTEGER,
    unreadable_cause TEXT,
    PRIMARY KEY (folder_identifier, directory_key, entry_name),
    CHECK ((lifecycle = 'digested') = (content_digest IS NOT NULL)),
    CHECK ((lifecycle = 'excluded') = (exclusion_reason IS NOT NULL)),
    CHECK ((lifecycle = 'unreadable') = (unreadable_cause IS NOT NULL)),
    CHECK ((lifecycle = 'unreadable') = (unreadable_since IS NOT NULL))
) WITHOUT ROWID;

CREATE TABLE content_sightings (
    content_digest TEXT NOT NULL REFERENCES contents,
    folder_identifier INTEGER NOT NULL REFERENCES watched_folders ON DELETE CASCADE,
    relative_path TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    withdrawn_at INTEGER,
    PRIMARY KEY (content_digest, folder_identifier, relative_path)
) WITHOUT ROWID;

CREATE INDEX path_observations_content_index ON path_observations (content_digest) WHERE content_digest IS NOT NULL;
CREATE INDEX path_observations_lifecycle_index ON path_observations (lifecycle, first_observed_at);
CREATE INDEX contents_standing_index ON contents (archive_standing, retry_not_before);
CREATE INDEX contents_received_index ON contents (received_at) WHERE received_at IS NOT NULL;
