-- The schema of replica.sqlite, the local copy of one archive's records.
--
-- The file holds nothing that the archive does not hold. A file whose user_version is not the one
-- replica_store.rs writes, or that SQLite cannot read, is deleted and filled again. So this schema
-- has no migrations: a change to it is a new SCHEMA_VERSION in replica_store.rs and a new fill.

-- Which archive, journal, and scope the copy mirrors, and how far. One row once an archive is attached.
CREATE TABLE mirror (
	singleton               INTEGER PRIMARY KEY CHECK (singleton = 1),
	archive_origin          TEXT NOT NULL,
	-- Both from GET /api/v1/authorization. Another value of either empties the copy.
	journal_identifier      TEXT NOT NULL,
	scope_digest            TEXT NOT NULL,
	-- Lets a start know what the token may do before the archive answers.
	permission_level        TEXT NOT NULL,
	-- The SHA-256 of the token the authorization was read with. A start follows the archive only
	-- with that token, because another one may see another scope.
	credential_fingerprint  TEXT NOT NULL,
	-- The cursor of the last applied page, as the archive sent it. Null before the first page.
	journal_cursor          TEXT,
	-- 0 during the first fill, so a restart resumes the fill instead of calling the copy complete.
	fill_complete           INTEGER NOT NULL DEFAULT 0 CHECK (fill_complete IN (0, 1)),
	-- Milliseconds since 1970 of the last page that reached the journal's end.
	synchronized_at         INTEGER,
	-- Rises in every transaction that changes a record or a text.
	content_revision        INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE members (
	id            TEXT PRIMARY KEY,
	display_name  TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE senders (
	id    TEXT PRIMARY KEY,
	name  TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE categories (
	id               TEXT PRIMARY KEY,
	name             TEXT NOT NULL,
	-- A JSON array of field keys.
	expected_fields  TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE tags (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	color_hex  TEXT
) STRICT, WITHOUT ROWID;

-- A sender or a category that is removed leaves its documents without one, until the page that
-- delivers those documents again. A member is removed by replica_store.rs, which first gives its
-- documents the assignment the archive gives a document without a member.
CREATE TABLE documents (
	-- Stable for the life of the row, for tables that index a document by a row number.
	document_row       INTEGER PRIMARY KEY,
	id                 TEXT NOT NULL UNIQUE,
	-- No CHECK: a status that a newer archive adds is stored and shown as arriving.
	status             TEXT NOT NULL,
	failure_reason     TEXT,
	title              TEXT,
	document_date      TEXT,
	sender_id          TEXT REFERENCES senders (id) ON DELETE SET NULL,
	category_id        TEXT REFERENCES categories (id) ON DELETE SET NULL,
	person_assignment  TEXT NOT NULL CHECK (person_assignment IN ('household', 'member', 'unassigned')),
	member_id          TEXT REFERENCES members (id),
	summary            TEXT,
	media_type         TEXT NOT NULL,
	byte_size          INTEGER NOT NULL,
	page_count         INTEGER,
	original_sha256    TEXT,
	-- Milliseconds since 1970.
	arrived_at         INTEGER NOT NULL,
	-- The document's `amount` and `currency` fields once more, which a row of a list shows. A
	-- listing reads them here, because two lookups among the fields for every document took a
	-- third of its time.
	amount             REAL,
	currency           TEXT,
	-- The order of the archive's own listing: a document without a date takes the day it arrived.
	listing_date       TEXT GENERATED ALWAYS AS (coalesce(document_date, date(arrived_at / 1000, 'unixepoch'))) STORED,
	CHECK ((person_assignment = 'member') = (member_id IS NOT NULL)),
	CHECK ((status = 'failed') = (failure_reason IS NOT NULL))
) STRICT;

-- The removal of a sender, a category, or a member looks its documents up through these.
CREATE INDEX documents_sender_index ON documents (sender_id);
CREATE INDEX documents_category_index ON documents (category_id);
CREATE INDEX documents_member_index ON documents (member_id);
-- The documents in ingestion, which the synchronization counts after every page.
CREATE INDEX documents_arriving_index ON documents (status) WHERE status NOT IN ('archived', 'failed');

CREATE TABLE document_tags (
	document_id  TEXT NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
	tag_id       TEXT NOT NULL REFERENCES tags (id) ON DELETE CASCADE,
	PRIMARY KEY (document_id, tag_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX document_tags_tag_index ON document_tags (tag_id);

CREATE TABLE extracted_fields (
	document_id   TEXT NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
	field_key     TEXT NOT NULL,
	field_type    TEXT NOT NULL CHECK (field_type IN ('text', 'number', 'date')),
	-- The text, or the date as YYYY-MM-DD.
	value_text    TEXT,
	value_number  REAL,
	confidence    REAL,
	PRIMARY KEY (document_id, field_key),
	CHECK ((field_type = 'number') = (value_number IS NOT NULL)),
	CHECK ((field_type = 'number') = (value_text IS NULL))
) STRICT, WITHOUT ROWID;

-- The extracted Markdown of an archived document. An archived document without a row awaits its
-- text. A row without Markdown says that the archive holds none, so it is not asked again.
-- replica_store.rs removes the row when the document's original_sha256 changes.
CREATE TABLE extracted_texts (
	document_row  INTEGER PRIMARY KEY REFERENCES documents (document_row) ON DELETE CASCADE,
	markdown      TEXT
) STRICT;

-- The search index, one row per document under its document_row. Neither table keeps what it
-- indexes, and no trigger feeds them: replica_store.rs writes the rows with every record.
--
-- What a person sees of a document without opening it, by trigrams, so that a term is found
-- inside a word, as "versicherung" in "Haftpflichtversicherung". A trigram needs a term of at
-- least three characters.
CREATE VIRTUAL TABLE document_detail_search USING fts5 (
	title, sender, category, tags, person, fields, summary,
	content = '', contentless_delete = 1,
	tokenize = 'trigram remove_diacritics 1'
);

-- The extracted text by words and their beginnings, which keeps the index of 8,000 bytes per
-- document small. The prefix indexes answer a beginning of two or three characters as a person
-- types it.
CREATE VIRTUAL TABLE document_text_search USING fts5 (
	markdown,
	content = '', contentless_delete = 1,
	tokenize = 'unicode61 remove_diacritics 2',
	prefix = '2 3'
);
