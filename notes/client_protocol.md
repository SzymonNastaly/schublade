# Client protocol

The routes under `/api/v1` that a native client reaches with a bearer token, agreed on 2026-11-22. `src/client_protocol/` serves them in the Worker, and `archive_access`, `archive_replica`, and `collection_core` in `native_client/` speak them. `notes/native_client_design.md` explains the design this protocol serves. Cloudflare Access bypasses the prefix `/api/v1` through the application "schublade &lt;worker&gt;: token ingestion", so no Access application changes.

## Routes

| Method | Path                                   | Level  | Success           | Other answers of the route  |
| ------ | -------------------------------------- | ------ | ----------------- | --------------------------- |
| GET    | `/api/v1/authorization`                | ingest | 200               | 400                         |
| GET    | `/api/v1/changes`                      | read   | 200               | 400, 403, 410               |
| GET    | `/api/v1/documents/{id}/original`      | read   | 200, 304          | 400, 404, 409               |
| GET    | `/api/v1/documents/{id}/text`          | read   | 200, 304          | 400, 404                    |
| GET    | `/api/v1/documents/{id}/thumbnail`     | read   | 200, 304          | 400, 404                    |
| POST   | `/api/v1/contents/lookup`              | ingest | 200               | 400, 413, 503               |
| PUT    | `/api/v1/contents/{sha256}`            | ingest | 200, 202          | 400, 409, 411, 413, 415, 422, 503 |
| PUT    | `/api/v1/submitted_documents/{sha256}` | ingest | 200, 202          | 400, 411, 413, 415, 422     |
| PUT    | `/api/v1/collected_documents/{sha256}` | ingest | 200, 202          | 400, 409, 411, 413, 415, 422, 503 |
| GET    | `/api/v1/documents/{id}`               | ingest | 200               | 404                         |

Every route also answers 401, 403 for a token below its level, 405, and 500, and each route from the lookup on answers 403 to a token with a restricted scope. `{id}` is a lowercase UUID, `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`. `{sha256}` is 64 lowercase hexadecimal digits, `[0-9a-f]{64}`. The lookup, `contents`, `collected_documents`, and the document status are the collector's routes, and `submitted_documents` is a person's. [Receiving a document](#receiving-a-document) describes the three PUT routes. A member's browser reaches the reception of `submitted_documents` at `PUT /api/submitted_documents/{sha256}`, behind Access.

`src/client_protocol/client_paths.ts` holds the one route table. Each route has an anchored pattern, its method, and its level, so a route cannot exist without a level. No route requires a level above `read` yet. `ingest` is the lowest level, so the authorization route admits every token, and the four routes that read the archive refuse a token that only adds documents. `request_dispatch.ts` admits a request without Access only when its pathname matches one pattern exactly. A trailing slash, uppercase hexadecimal, another case, and any other path under `/api/v1` stay behind `requireAccess`.

## The wire fixtures

`test_fixtures/client_protocol/authorization.json` and `changes_page.json` hold one answer of each route, the wire format for both implementations. `client_requests.workerd.test.ts` seeds an archive with their identifiers and times and compares the Worker's answers with them, the page's entries as a map keyed by record kind and identifier, because no order is promised. The native client parses the same files.

## Rules every route shares

### Order of checks

One gate in `src/client_protocol/client_requests.ts` answers every route in this order. No handler checks a level or reads the `Authorization` header.

1. **Method.** Another method on a matched path answers 405 with `Allow: <method>` and the detail "Send this request with GET".
2. **Token.** `Authorization: Bearer schublade_…`. A missing, malformed, unknown, or revoked token answers 401 with `WWW-Authenticate: Bearer` and the detail "Send a valid API token in the Authorization header". The answer is the same for all four, so it reveals no token.
3. **Level.** The levels are ordered `ingest`, `read`, `modify`, `administer`, and each grants every permission of the levels before it (`permits` in `src/authorization/caller_authorization.ts`). A token below the route's level answers 403 with "The API token does not permit reading the archive". No token is below `ingest`. [What a token of each level can do](#what-a-token-of-each-level-can-do) has the table.
4. **Scope.** The route table says of each route whether it applies a restricted scope or refuses it, and with which sentence. The authorization, the changes, and the representations apply it. A collector must see every content, or it would archive one a second time, so the collector's routes cannot apply a scope. They answer a token whose scope holds any list 403 with "This API token is restricted to a part of the archive. A collector needs an unrestricted token." `submitted_documents` answers the document that holds the bytes whether or not the scope admits it, so it refuses such a token with "This API token is restricted to a part of the archive. Adding documents needs an unrestricted token."
5. **The route.** A handler that throws answers 500 with "The archive could not complete the request. Send it again." and logs the error.

### What a token of each level can do

The order follows how much of the household's papers a level exposes. Adding a document exposes nothing, so `ingest` is the lowest level, and reading is a grant a member makes on purpose.

| Level    | Settings calls it                              | Routes it reaches                                                                                          |
| -------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `ingest` | "Scanner, script, or Shortcut: adds documents" | `GET /api/v1/authorization`, the collector's routes, `submitted_documents`, and `POST /api/documents/ingest` |
| `read`   | "Schublade app: reads and adds documents"      | Every route of `ingest`, and `GET /api/v1/changes`, `/original`, `/text`, and `/thumbnail` of a document  |

A token of level `ingest` never reads a title, a summary, a text, or an original. The document status route and the lookup answer it only an identifier, a status, and a failure reason. Settings issues both kinds, and the form starts with `ingest`. No route for a token needs `modify` or `administer`, and Settings issues neither.

A token issued before 2026-11-22 has the level `ingest`. It keeps uploading and cannot read, so a native application that shows the library needs a new token of the level `read`.

### Problems

Every answer that is not a route's success is an RFC 9457 problem document with `Content-Type: application/problem+json`:

```json
{
	"type": "about:blank",
	"title": "Gone",
	"status": 410,
	"detail": "This archive holds no such position. Read the journal from the start."
}
```

`title` is the reason phrase of the status. A client reads the status code and shows `detail` only in diagnostics.

An archive deployed before a route lacks it. Its path then falls through to `requireAccess`, which answers 403 with a plain text body. A 403 whose content type is not `application/problem+json` therefore means "this archive does not offer this route", and a client reports the condition `RouteUnknown`, never a refused token.

### Requests and answers

- Field names use lower case with underscores.
- A query parameter or a body member the route does not define answers 400. The detail is "This request takes no parameters, not &lt;names&gt;" on the authorization and the representations. The collector's three routes keep their behaviour and do not check query parameters.
- A client ignores a response member it does not know.
- Every answer of the gate carries `Cache-Control: no-store`, a problem document and a 304 included, because each answer is for the token that asked. The gate sets the header in one place, after the route answered.

## GET /api/v1/authorization

What the token may do in which archive. A client sends it before it stores anything, for the library and the collector alike. The route needs only `ingest`, the lowest level, so every token can ask. A client reads `permission_level` before it requests anything else: with `ingest` it connects the collector alone and never requests the changes or a representation, and with `read` or a level above it connects the library as well. It replaces the collector's former credential check, a lookup of the all-zero digest, which needs the ingest level and answers 503 during the digest backfill.

```http
GET /api/v1/authorization HTTP/1.1
Authorization: Bearer schublade_…
```

`200`:

```json
{
	"journal_identifier": "fc26a0aaf01faa9625397c1e4322b36c",
	"token": {
		"description": "MacBook of Jonas",
		"permission_level": "read",
		"restricted": false,
		"scope_digest": "6cd8cec706fa11110d83fb46f97df1f9be43b4c570f3390e7c7f6a5173f595e6"
	}
}
```

| Member                     | Type    | Meaning                                                                                                                |
| -------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------- |
| `journal_identifier`       | string  | 32 lowercase hexadecimal digits that name the change journal of this database                                          |
| `token.description`        | string  | The description the member gave the token in Settings                                                                  |
| `token.permission_level`   | string  | `ingest`, `read`, `modify`, or `administer`, in ascending order                                                        |
| `token.restricted`         | boolean | True when the token's scope holds any of `allowedCategories`, `allowedTags`, `deniedTags`, or `allowedSenders`          |
| `token.scope_digest`       | string  | The SHA-256, as 64 lowercase hexadecimal digits, of what the token may see                                             |

`scope_digest` is the SHA-256 of the JSON text of an array of the four lists in the order `allowedCategories`, `allowedTags`, `deniedTags`, `allowedSenders`. Each list is deduplicated and sorted, and an absent list is `null`. The level takes no part. An unrestricted token's digest is the digest of `[null,null,null,null]`, which is `6cd8cec706fa11110d83fb46f97df1f9be43b4c570f3390e7c7f6a5173f595e6`. Two tokens with equal digests see the same records, so a client keeps its copy when a person replaces one with the other.

## GET /api/v1/changes

The records that changed after a cursor, as their state now. The same route fills an empty copy and keeps a full one current.

| Parameter | Required | Value                                                                                        |
| --------- | -------- | -------------------------------------------------------------------------------------------- |
| `after`   | no       | The `cursor` of the last page the client applied. Without it, the page starts at the journal's beginning |

```http
GET /api/v1/changes?after=fc26a0aaf01faa9625397c1e4322b36c.1042 HTTP/1.1
Authorization: Bearer schublade_…
```

`200`:

```json
{
	"changes": [
		{
			"record": "document",
			"id": "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11",
			"change": "upsert",
			"document": {
				"status": "archived",
				"failure_reason": null,
				"title": "Stadtwerke Talbrück Electricity Annual Statement 2025-2026",
				"document_date": "2026-09-22",
				"sender_id": "3e4f5061-7283-4d94-bea5-f60718293a4b",
				"category_id": "0b1c2d3e-4f50-4a61-8b72-c3d4e5f60718",
				"person": { "kind": "household" },
				"summary": "Annual electricity statement with an additional payment of 72.09 euros.",
				"media_type": "application/pdf",
				"byte_size": 184233,
				"page_count": 1,
				"original_sha256": "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
				"arrived_at": "2026-09-23T08:14:02Z",
				"tag_ids": ["4f506172-8394-4ea5-8fb6-0718293a4b5c"],
				"fields": [
					{ "key": "amount", "type": "number", "value": 72.09, "confidence": 0.94 },
					{ "key": "currency", "type": "text", "value": "EUR", "confidence": 0.99 },
					{ "key": "due_date", "type": "date", "value": "2026-10-06", "confidence": null }
				]
			}
		},
		{
			"record": "sender",
			"id": "3e4f5061-7283-4d94-bea5-f60718293a4b",
			"change": "upsert",
			"sender": { "name": "Stadtwerke Talbrück GmbH" }
		},
		{
			"record": "category",
			"id": "0b1c2d3e-4f50-4a61-8b72-c3d4e5f60718",
			"change": "upsert",
			"category": { "name": "Invoice", "expected_fields": ["amount", "currency", "due_date", "iban", "invoice_number"] }
		},
		{
			"record": "tag",
			"id": "4f506172-8394-4ea5-8fb6-0718293a4b5c",
			"change": "upsert",
			"tag": { "name": "strom", "color_hex": null }
		},
		{
			"record": "household_member",
			"id": "50617283-94a5-4fb6-90c7-18293a4b5c6d",
			"change": "upsert",
			"household_member": { "display_name": "Mira Wiśniewska" }
		},
		{ "record": "sender", "id": "2d3e4f50-6172-4839-a4b5-c6d7e8f90a1b", "change": "removal" },
		{ "record": "document", "id": "61728394-a5b6-4c7d-8e9f-0a1b2c3d4e5f", "change": "removal" }
	],
	"cursor": "fc26a0aaf01faa9625397c1e4322b36c.1291",
	"complete": true,
	"remaining": 0
}
```

### The page

| Member     | Type    | Meaning                                                                                                                         |
| ---------- | ------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `changes`  | array   | The entries of the page, described below                                                                                        |
| `cursor`   | string  | What the client sends as `after` next, opaque to the client. It is the sequence number of the page's last journal entry, or the request's own cursor when the page is empty |
| `complete` | boolean | True when the journal held no entry after this page when the archive read it. A client requests the next page at once while it is false |
| `remaining`| integer | The journal entries after this page when the archive read it, 0 when `complete` is true. It counts removals and records the scope hides, so it is an upper bound, for a progress display |

- The page size is the server's choice and not a parameter, 250 journal entries today. A client must not assume it.
- `changes` holds one entry for each record of the page's journal entries, and one `upsert` for each member, sender, category, and tag that an admitted document of the page refers to, whether or not that record changed. After a client applies a page, every reference of every document in it resolves locally.
- A record appears at most once in a page.
- The order of the entries carries no meaning, and a client must not rely on the order an archive happens to send. Each entry is a whole state, so a client applies a page as one transaction in any order that satisfies its own constraints.
- A page without `after` holds removals too, for records deleted or hidden by the scope, because a fill and a catch-up read the journal by one path. A client that holds no such record has nothing to remove.

### An entry

| Member   | Type   | Meaning                                                                                                                         |
| -------- | ------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `record` | string | `document`, `household_member`, `sender`, `category`, or `tag`. A client skips an entry of a kind it does not know and still advances its cursor |
| `id`     | string | The record's identifier, a lowercase UUID                                                                                       |
| `change` | string | `upsert`, with the record under the member named by `record`, or `removal`. A removal means the record no longer exists or the token no longer sees it. A client treats both the same |

The records of an `upsert`:

| Record             | Member            | Type             | Meaning                                                       |
| ------------------ | ----------------- | ---------------- | ------------------------------------------------------------- |
| `household_member` | `display_name`    | string           | The member's name                                             |
| `sender`           | `name`            | string           | The sender's name                                             |
| `category`         | `name`            | string           | The category's name                                           |
| `category`         | `expected_fields` | array of strings | The field keys classification expects for the category       |
| `tag`              | `name`            | string           | The tag's name                                                |
| `tag`              | `color_hex`       | string or null   | The tag's colour as hexadecimal                               |

A `document`:

| Member            | Type                     | Meaning                                                                                                                            |
| ----------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `status`          | string                   | `awaiting_rendering`, `processing`, `extracting`, `recognizing_text`, `classifying`, `archived`, or `failed`. A client maps a status it does not know to arriving |
| `failure_reason`  | string or null           | `unreadable_file`, `page_limit_exceeded`, `unreadable_page`, or `processing_error` when `status` is `failed`, otherwise null          |
| `title`           | string or null           | Null until classification                                                                                                          |
| `document_date`   | string or null           | The date printed on the document, `YYYY-MM-DD`                                                                                     |
| `sender_id`       | string or null           | A sender of the same page                                                                                                          |
| `category_id`     | string or null           | A category of the same page                                                                                                        |
| `person`          | object                   | `{"kind":"household"}`, `{"kind":"member","member_id":"<id>"}` with a member of the same page, or `{"kind":"unassigned"}`         |
| `summary`         | string or null           | Null until classification                                                                                                          |
| `media_type`      | string                   | The original's media type, such as `application/pdf`, or `message/rfc822` for an email not yet printed                             |
| `byte_size`       | integer                  | The original's size in bytes                                                                                                       |
| `page_count`      | integer or null          | The number of pages, when known                                                                                                    |
| `original_sha256` | string or null           | The SHA-256 of the original, null until the archive recorded it                                                                    |
| `arrived_at`      | string                   | `documents.created_at` as ISO 8601 in UTC, such as `2026-09-23T08:14:02Z`                                                          |
| `tag_ids`         | array of strings         | Tags of the same page                                                                                                              |
| `fields`          | array of objects         | The extracted fields                                                                                                               |

`person` follows the rule of `queryDocumentListing`. An archived document without a member concerns the whole household (`household`). A document with a member names it (`member`). Any other document is not yet classified (`unassigned`).

A field:

| Member       | Type           | Meaning                                                                                           |
| ------------ | -------------- | ------------------------------------------------------------------------------------------------- |
| `key`        | string         | The archive's key, such as `amount`, `iban`, or `due_date`                                        |
| `type`       | string         | `number`, `text`, or `date`                                                                       |
| `value`      | number or string | A number for `number`, a string for `text`, and `YYYY-MM-DD` for `date`                         |
| `confidence` | number or null | The classifier's confidence between 0 and 1, when it gave one                                     |

### Other answers

| Status | When                                                                                                    | Detail                                                                                           |
| ------ | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 400    | A parameter other than `after`                                                                          | "The journal takes only the parameter after, not &lt;names&gt;"                                    |
| 400    | A cursor that does not parse, or `after` given more than once                                           | "The cursor is not one this archive answered. Send the cursor of the last page as it came."      |
| 403    | The token's scope denies a tag that no longer exists                                                    | "A tag this token excludes no longer exists. Issue a new token."                                 |
| 410    | The cursor names another journal identifier, or a sequence number above the highest the journal issued | "This archive holds no such position. Read the journal from the start."                          |

## The cursor

A cursor is `<journal identifier>.<sequence number>`, which is 32 lowercase hexadecimal digits, a full stop, and a decimal number of at most 15 digits without leading zeros, so it stays below 2^53. Its pattern is `^[0-9a-f]{32}\.(0|[1-9][0-9]{0,14})$`. A client stores it as it came and sends it back. It reads nothing from it.

A cursor says "the client holds the state of every record whose latest change has a sequence number up to this one, as of some moment at or after that change". The first page of an empty journal answers the cursor `<journal identifier>.0`.

The archive answers 410 for a cursor whose identifier differs from `change_journal_identity.journal_identifier`, or whose number exceeds the highest number the journal issued. The page's batch reads that number as `max(sequence_number)` of `change_journal`. A trigger deletes an entry and inserts it again in one statement, so the newest number always has its entry, and the maximum equals what `sqlite_sequence` holds.

## The journal

### Tables

Migration `0008_record_change_journal.sql` is generated by `pnpm database:generate` from `src/database/schema.ts`:

```sql
CREATE TABLE `change_journal` (
	`sequence_number` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`record_kind` text NOT NULL,
	`record_identifier` text NOT NULL
);
CREATE UNIQUE INDEX `change_journal_record_index` ON `change_journal` (`record_kind`,`record_identifier`);
CREATE TABLE `change_journal_identity` (
	`single_row` integer PRIMARY KEY NOT NULL,
	`journal_identifier` text NOT NULL,
	CONSTRAINT "change_journal_identity_single_row_check" CHECK("change_journal_identity"."single_row" = 1)
);
```

- `change_journal` holds one entry per record that ever existed: the record's kind, its identifier, and the sequence number of its latest change. A deleted record keeps its entry, which is the record of its deletion.
- `AUTOINCREMENT` takes the next number from `sqlite_sequence`, not from the largest row present, so no number is issued twice.
- `change_journal_identity` holds one row with a random identifier. It is named for the journal, not the archive, so replacing it never makes a collector think it faces another archive.

### Triggers

Migration `0009_journal_record_changes.sql` is written with `drizzle-kit generate --custom`. It holds 21 triggers, an `AFTER INSERT`, an `AFTER UPDATE`, and an `AFTER DELETE` trigger on each of the seven tables a client copies:

| Table               | Record kind whose entry moves |
| ------------------- | ----------------------------- |
| `documents`         | `document`                    |
| `document_tags`     | `document`, of the link       |
| `extracted_fields`  | `document`, of the field      |
| `household_members` | `household_member`            |
| `senders`           | `sender`                      |
| `categories`        | `category`                    |
| `tags`              | `tag`                         |

Every trigger deletes the record's entry and inserts it again, which gives it the next number, inside the statement that fired it:

```sql
CREATE TRIGGER `senders_journal_revision` AFTER UPDATE ON `senders` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'sender' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('sender', NEW.`id`);
END;
```

The update trigger of `document_tags` and of `extracted_fields` moves the entry of the document the row left (`OLD.document_id`) and of the document it belongs to (`NEW.document_id`). No trigger names a column, so every write to a row moves its entry, including a write that changes nothing a client reads, such as `indexed_at`.

The migration then writes the identity row with `lower(hex(randomblob(16)))` and one entry for every existing record. Documents come first, newest first in the archive's listing order (`coalesce(document_date, date(created_at, 'unixepoch'))` descending, then `created_at` and `id` descending), and then household members, senders, categories, and tags. A fill reads the journal upwards from its start, so the first pages of a fill hold the documents a person looks for first, with the records they refer to.

Nothing in the Worker's TypeScript writes the journal. `pnpm run provision`, which inserts household members with `cf d1`, is journaled as well.

### The lists in the schema

`src/database/schema.ts` holds `journaledTables`, which maps each of the seven tables to its record kind, and `tablesNotReplicated`: `contents`, `api_tokens`, `authorization_grants`, `change_journal`, and `change_journal_identity`. `change_journal.workerd.test.ts` applies every migration, reads `sqlite_master`, and fails when a table of the database is in neither list, or when a journaled table lacks one of its three triggers. A migration that recreates a table drops its triggers without a word, and that migration must create them again.

### Reading a page

`readJournalPage` in `src/client_protocol/change_journal.ts` reads one page in one `database.batch`, which D1 runs as one transaction. Each statement of the batch derives the same page with the same common table expression and joins it with one table, so the page and the state of its records come from one snapshot:

```sql
WITH page AS (
	SELECT sequence_number, record_kind, record_identifier
	FROM change_journal WHERE sequence_number > ?1 ORDER BY sequence_number LIMIT 250
)
```

The batch reads the identity with `max(sequence_number)` and the count of entries after the page's last entry, a count over the primary key's range, then the page's entries, the documents with their admission by the scope, their tag links, their fields, the four kinds of taxonomy record in the page or referred to by an admitted document of the page, and the count of entries after the page. A list of identifiers that a statement binds, such as a scope's lists, binds as one JSON parameter through `json_each`, because D1 allows 100 bound parameters per statement. No statement binds an `inArray` list over a page. An entry whose record no statement returned is a removal.

## Why no change is missed

1. **Every write is journaled in its own transaction.** A trigger runs inside the statement that fires it. A write that commits has moved its entry, and a write that rolls back has not. Measured in workerd's local D1 on 2026-11-22 for insert, update, delete, `INSERT … ON CONFLICT DO UPDATE`, `INSERT OR REPLACE`, the cascade from a deleted tag or document to its links, and a batch whose later statement failed, which left no entry and no change.
2. **A moved entry gets a number above every number ever issued.** `AUTOINCREMENT` never reuses a number (<https://www.sqlite.org/autoinc.html>). Measured on 2026-11-22 in SQLite, after the newest row was deleted and inserted again, a plain `INTEGER PRIMARY KEY` issued the same number a second time, and the `AUTOINCREMENT` column issued the next one. Without it, a client whose cursor is that number would never read the second change.
3. **Sequence order is commit order.** SQLite admits one write transaction at a time (<https://www.sqlite.org/lang_transaction.html>), and a trigger takes its number inside the transaction that commits it. A D1 database is one SQLite database on one primary, and without the Sessions API every query runs on the primary (<https://developers.cloudflare.com/d1/best-practices/read-replication/>). So no transaction with a smaller number commits after a transaction with a larger number became visible. If the Worker ever reads through `withSession`, this route must read with `withSession("first-primary")`.
4. **A page is a snapshot.** A change that commits after the snapshot has a number above every number in the page, so a later page delivers it. A change that committed before the snapshot is at or below the client's cursor, in which case the client holds a state at least that new, or inside the page, or after it.
5. **A record changed several times is delivered in its latest state.** Its entry moved each time. A client can miss an intermediate state and never the final one. A record that changes while a client pages moves ahead of the client's cursor and is delivered again.
6. **A page carries what its documents refer to.** Every member, sender, category, and tag that an admitted document of the page refers to is in the page, read in the same snapshot. A client never holds a document whose sender it lacks.

## Why none applies out of order

A client writes a page's records and the page's cursor in one local transaction, and only while its stored cursor equals the `after` it requested the page with. Pages therefore apply in the order of their cursors, whatever the network repeats or reorders. A crash before the commit leaves the old cursor, and the next request answers a state at least as new. Within a page, every entry is a whole state, not a delta, so the order of entries inside it does not matter.

## Why a deleted record never returns

A deletion moves the record's entry and leaves no row. The page's read finds no row and answers `removal`. The entry never leaves the journal, so no client misses it, however long it was away. A later page can hold the record again only when the archive holds it again, which is a new write and a new entry.

## Why a replayed page changes nothing

A page applied a second time finds the stored cursor already moved past its `after` and is dropped unread. Applied by another path, it writes the same whole states again. Either way the copy is the same.

## What a restricted token sees

A token whose scope holds any list is restricted. One function, `scopeAdmission` in `src/archive/document_listing.ts` (the former `authorizationScopeConditions`), returns the SQL condition "this scope admits this document". The listing, the facets, the `/mcp` tools, and this protocol all use it.

- **Documents.** A restricted scope admits only archived documents, because classification assigns what a scope reads. A document of the page that the scope does not admit is a `removal`, exactly as a deleted one, so a restricted client receives removals for documents it never held. A document that leaves the scope was written, because its category, sender, or tags changed, so its entry moved and the client learns of it. A document that enters the scope is delivered whole for the same reason.
- **Members, senders, categories, and tags.** A restricted token receives such a record when its scope admits at least one document that refers to it, anywhere in the archive, and a `removal` for a record of the page that no admitted document refers to. Measured in workerd with 50,000 documents and a tag on every document: one page of tag entries read up to 400,000 rows for a restricted scope (834 ms), bounded by the links of the page's tags, and an unrestricted page read at most 2,901 rows per statement. So a sender renamed while only an admitted document outside the page refers to it is sent. A record whose last admitted document left stays in the client's copy, where no document refers to it, until its own entry next moves.
- **A denied tag that no longer exists** makes the scope admit nothing. The changes route asks `deniedTagsAllExist` in `src/archive/document_listing.ts`, as `/mcp` does, then answers 403, and the client keeps its copy and stops requesting.
- **Representations** apply the same condition to the one document. A document outside the scope answers 404 on every representation route, as one that does not exist.
- **The collector's routes** refuse a restricted token with 403, as the order of checks says. Before 2026-11-22 the document status route answered such a token the status of a document outside its scope, and the lookup answered `present` with its identifier. `POST /api/documents/ingest` refuses a restricted token with 403 as well, because an upload answers the identifier of the document that holds the bytes already.
- An unrestricted token receives every document in every status and every record.

`token.scope_digest` changes exactly when what the token sees changes. A client empties its copy when the journal's identifier or the scope digest differs from the one its copy was filled under.

Members can issue only unrestricted tokens in Settings today, and the gate accepts API tokens only. The rules above hold for any token with lists, and the restricted-scope workerd test exercises them.

## The representations

```http
GET /api/v1/documents/4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11/original HTTP/1.1
Authorization: Bearer schublade_…
If-None-Match: "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
```

| Route                                 | 200 body                                                                                                                          | `ETag`                                                                       | Other answers                                                                                      |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `/api/v1/documents/{id}/original`     | The stored file, with its stored `Content-Type` and `Content-Length`, the size R2 records                                         | `"<original_sha256>"`, or R2's entity tag before the digest is recorded     | 304. 404 for no such document, one outside the scope, or a file R2 lacks. 409 for a stored email not yet printed |
| `/api/v1/documents/{id}/text`         | The extracted Markdown, `text/markdown; charset=utf-8`                                                                            | R2's entity tag                                                              | 304. 404 for no such document, one outside the scope, or a text not stored yet                     |
| `/api/v1/documents/{id}/thumbnail`    | A JPEG or a PNG of the first page: the JPEG its client sent, or else a PNG at 40 dots per inch, rendered on the first request and stored. An image original without a sent JPEG is its own thumbnail      | R2's entity tag                                                              | 304. 404 for no such document, one outside the scope, an email not yet printed, or a page that cannot be drawn |

- All three answer 304 with the entity tag to an `If-None-Match` that names the current one. `If-None-Match` is the one condition a client can make. The archive ignores `If-Match`, `If-Modified-Since`, `If-Unmodified-Since`, and `Range`, and answers such a request 200 with the whole body, so an answer without a body always means "not modified".
- The archive compares the digest of an original itself, strong or weak, and then asks R2 only whether the file exists, without reading it. An original that R2 lacks answers 404 "The original of this document is not stored", never 304. `If-None-Match: *` does not name the digest, so an original with a recorded digest answers it 200 with the body.
- For every other entity tag the archive passes the `If-None-Match` header alone to R2, which compares it.
- A PDF whose first page cannot be drawn gets an empty object with the metadata `thumbnail: unrenderable` where its thumbnail would be. Until that mark is a day old, a request for the thumbnail reads the mark and answers 404 without reading the original. After a day the archive draws the page again.
- The 409 detail is "The archive has not printed this email as a PDF yet. Request the original again later." A 404 for a document outside the scope has the detail of one that does not exist, and a 404 for a representation not stored yet names the representation.
- `src/client_protocol/representation_requests.ts` reads through `readStoredRepresentation` in `src/archive/document_representation.ts`, which the browser's route uses as well.
- All three set `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, the headers of `src/archive/document_representation.ts`, and carry the gate's `Cache-Control: no-store`.
- An original is at most 25,000,000 bytes, the upload limit.
- The archive never changes the bytes of a content, and the text of a document is written once, in the step before `classifying`, while `archived` has no transition out. A client keeps an original under its `original_sha256` and its text until the record's `original_sha256` changes.
- A client reads at most 1 MB of a thumbnail and treats a larger one as absent, because an image original can be several megabytes.

## The collector's routes

A token with a restricted scope gets 403 on each, and every answer carries `Cache-Control: no-store`. The lookup and the document status sit in `src/client_protocol/collection_requests.ts` behind the shared gate. `PUT /api/v1/contents/{sha256}` and `collected_documents` reach `receiveDocument` in `src/ingestion/document_reception.ts`, which [Receiving a document](#receiving-a-document) describes.

While a document of an accepted kind lacks its `original_sha256`, the lookup and both PUT routes answer 503 with `Retry-After: 900` and "The archive is still recording the digests of its documents. Send the request again later.", because the lookup would call archived bytes absent. The document status route never answers it.

### POST /api/v1/contents/lookup

The state of each content, in the order asked. The body is at most 128,000 bytes and lists 1 to 1000 digests.

```json
{ "sha256": ["a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"] }
```

`200`:

```json
{
	"contents": [
		{
			"sha256": "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
			"state": "present",
			"document_id": "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11"
		}
	]
}
```

`state` is `present` with `document_id`, `absent`, or `deleted` for a content whose document the owner deleted. 400 answers a body that is not JSON or does not match, and 413 a body over the limit.

### GET /api/v1/documents/{id}

`200`, with `Location: /api/v1/documents/<id>`:

```json
{ "document_id": "4d1f0c9e-2a6b-4c3e-9a51-0b7f6e2d8c11", "status": "processing", "failure_reason": null }
```

404 answers an identifier no document has.

## Receiving a document

Three PUT routes receive one document named by the SHA-256 of its original, and one function, `receiveDocument` in `src/ingestion/document_reception.ts`, answers all three. `notes/client_preprocessing_design.md` explains the design.

| Path | Sent by | A deleted content | While a digest is missing | Derived representations |
| --- | --- | --- | --- | --- |
| `/api/v1/submitted_documents/{sha256}` | A person: the iPhone application, its share extension, a script, and the browser at `/api/submitted_documents/{sha256}` | Archived again | Received | Accepted |
| `/api/v1/collected_documents/{sha256}` | A collector | 409 | 503 | Accepted |
| `/api/v1/contents/{sha256}` | Collector builds before derived representations | 409 | 503 | 400 |

The body is the client's Markdown text, then its JPEG thumbnail, then the original, with no separator. `Schublade-Text-Byte-Count` and `Schublade-Thumbnail-Byte-Count` give the byte counts of the first two and default to 0, so a body without them is the original alone, as `curl -T scan.pdf` sends it. `Schublade-Page-Count` gives the number of pages the client read, 1 for a picture. The original is `Content-Length` minus both counts. `Content-Type` is not read: the archive identifies the original by its leading bytes.

The text is UTF-8 Markdown with one `## Page N` heading per page in page order, a page without text keeping its heading. Each page's text follows its heading after a blank line without its surrounding white space, a blank line separates the pages, and the text ends with a line break. `test_fixtures/client_protocol/submitted_document_text.md` is one such text: `compose_document_text` in `archive_access` writes it from three page texts, and the Worker's reception test sends it. The thumbnail is a JPEG of the first page, at most 480 pixels on its longer side.

A client learns whether an archive offers the reception without sending a document: `GET /api/v1/submitted_documents/<64 zeros>` answers 405 on an archive that offers it, because the gate checks the method first, and the plain 403 of `RouteUnknown` on an older one. A client holds its documents for an archive without the reception and says "Update your archive", and never falls back to the multipart route.

The checks run in this order:

| Status | When |
| --- | --- |
| 503 | A collector's route only: a document still awaits its digest. `Retry-After: 900` |
| 409 | A collector's route only: the owner deleted the document of this content |
| 400 | A query parameter, a count or page count that is no decimal number, a page count of 0, no byte left for the original, a derived header on `contents`, or a body shorter than its `Content-Length` |
| 411 | No `Content-Length` |
| 413 | A text above 2,000,000 bytes, a thumbnail above 200,000 bytes, or an original above 25,000,000 bytes |
| 200 | A document holds the content. The body is not read and nothing is written |
| 415 | The thumbnail does not start with `FF D8 FF`, or the original is no PDF, JPEG, PNG, or WebP file |
| 422 | R2 received other bytes than the digest in the path names. Nothing is stored |
| 202 | The content became a new document |

A 202 and a 200 carry the body of the document status route and `Location: /api/v1/documents/<id>`. The Worker reads only the counted bytes and the 12 leading bytes of the original, and pipes the rest into R2 through a `FixedLengthStream`, so R2 checks the digest. The text goes to `documents/<id>/submitted_text.md` and the thumbnail to `documents/<id>/thumbnail.jpg`. Each arrival on these routes and on the multipart uploads logs one line `Document reception: route=<name> text=<submitted|absent> thumbnail=<submitted|absent>`.

## What a client does on each answer

| Answer                                          | The replica                                                                                                          | The collector                                       |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| 401                                             | Suspends with a refused credential and requests nothing until a new token connects                                   | Suspends, as today                                  |
| 403 with `application/problem+json`             | Suspends with an insufficient credential, keeps its copy, and requests nothing until a new token connects. A token of level `ingest` gets this answer on every reading route, so a client that read the authorization never causes it | Suspends, as today                                  |
| 403 without `application/problem+json`          | `RouteUnknown`, because the archive is older than the route. The library says "Update your archive" and asks again hourly    | On the reception, holds its uploads, says "Update your archive", and asks again hourly. On the lookup and the status, a protocol violation |
| 404 on a representation                         | Refuses the representation. The document's removal, when it is one, arrives with the next page                       | Not applicable                                      |
| 409 on an original                              | Refuses with "not available yet", because the archive has not printed the email                                               | On a PUT, records the content as deleted, as today  |
| 410 on the changes                              | Discards its copy and requests the first page without `after`                                                        | Not applicable                                      |
| 503                                             | Waits for `Retry-After`, then requests again                                                                         | Defers, as today                                    |
| 500, a timeout, or a failed connection          | Retries after 5 seconds, tripled per attempt, at most 5 minutes. A person's wake retries at once                      | Unreachable, as today                               |

## How the protocol grows

- `/api/v1` is the major version. Within it the server only adds: a route, an optional request parameter or member, a response member, a record kind, a document status.
- A client ignores a response member it does not know, skips an entry of a record kind it does not know while it still advances its cursor, and maps a document status it does not know to arriving. So a newer archive never stops an older client.
- The server refuses a request parameter or member it does not know with 400, so a client that sends something new learns it at once.
- A client learns that a route is missing from the plain 403 of `requireAccess`. No capability list exists to keep in step with the route table.
- The cursor is opaque, records are whole states, and the page size is the server's, so none of them is fixed by a client.
- A change that a version 1 client cannot read needs `/api/v2`. That prefix needs an Access destination of its own, and so the owner.

## Restoring the database

A database restored with D1 Time Travel keeps its journal identifier and loses its newest sequence numbers. A client whose cursor lies above the restored journal gets 410, but a client whose cursor lies below the restore point would keep records the restore removed. Every restore therefore ends by replacing the identifier:

1. Restore the database with D1 Time Travel.
2. Replace the journal's identifier in the restored database:

	```bash
	cf d1 raw <database identifier> --sql "UPDATE change_journal_identity SET journal_identifier = lower(hex(randomblob(16)))"
	```

3. Read `GET /api/v1/authorization` with a token and check that `journal_identifier` changed.

The archive then answers each client's next request for changes with 410, and the client discards its copy and fills it again. The collector keeps its records, because it belongs to the archive's origin, not to the journal. The restore is assumed to bring `sqlite_sequence` back with the data, and the identifier's replacement makes every cursor of the old journal answer 410 regardless.
