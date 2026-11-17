//! The one SQLite file, and the only module with SQL. Rows hold resting states only; the
//! coordinator turns them into the machines' states and back. `PRAGMA user_version` names the
//! schema version, and the embedded migrations run in order at open.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension, Row, named_params, params};

use crate::archive_connection::SuspensionReason;
use crate::candidate_classification::{ExclusionReason, ReadableSignature, classify_signature};
use crate::content_synchronization::{
    ArchiveStanding, ContentRecord, PresentDocument, RefusalReason, SubmissionFailures,
};
use crate::domain_types::{
    ContentDigest, DirectoryKey, DocumentIdentifier, DocumentStatus, EntryName, FileSignature, FolderIdentifier,
    PathKey, Timestamp, TimingPolicy,
};
use crate::folder_admission::{FolderAdmission, SurveyProgress};
use crate::path_lifecycle::{PathState, PathTransition};
use crate::status_report::{BacklogSummary, ContentAttention, Receipt, StateCounts};
use crate::work_planning::{
    Lane, LaneCapacity, MAXIMUM_FOLLOWED_DOCUMENTS, MAXIMUM_LOOKUP_DIGESTS, Reservations, WorkCandidates,
};

/// Migration n is `MIGRATIONS[n - 1]`, applied in one transaction while `PRAGMA user_version` is
/// below n.
pub const MIGRATIONS: &[&str] = &[include_str!("migrations/0001_collector_state.sql")];

/// The only owner of the SQLite connection, used only on the coordinator thread.
#[derive(Debug)]
pub struct StateStore {
    connection: Connection,
}

#[derive(Debug)]
pub enum StoreOpenFailure {
    /// The file failed `PRAGMA quick_check` and was renamed aside to this path; a fresh store was
    /// not created, so the caller decides whether to start over.
    Unreadable {
        renamed_to: PathBuf,
    },
    Inaccessible(std::io::Error),
    NewerSchema {
        found: u32,
        supported: u32,
    },
    Database(rusqlite::Error),
}

impl From<rusqlite::Error> for StoreOpenFailure {
    fn from(error: rusqlite::Error) -> StoreOpenFailure {
        StoreOpenFailure::Database(error)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectionRecord {
    pub archive_origin: String,
    pub credential_fingerprint: String,
    pub suspension: Option<(SuspensionReason, Timestamp)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderRecord {
    pub folder: FolderIdentifier,
    pub root: PathBuf,
    pub enrolled_at: Timestamp,
    pub admission: FolderAdmission,
}

/// What the store holds for one directory: the rows of exactly that directory, and the keys of
/// the child directories that have rows below them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectoryContents {
    pub files: Vec<(EntryName, PathState)>,
    pub subdirectories: Vec<DirectoryKey>,
}

/// One write transaction. Every transition of a batch goes through one of these, so the status
/// read after the batch sees all of it or none.
pub struct StoreTransaction<'store> {
    transaction: rusqlite::Transaction<'store>,
}

const STORED_SUSPENSION_REASONS: &[(SuspensionReason, &str)] = &[
    (SuspensionReason::CredentialRefused, "credential_refused"),
    (SuspensionReason::CredentialInsufficient, "credential_insufficient"),
];

const STORED_EXCLUSION_REASONS: &[(ExclusionReason, &str)] = &[
    (ExclusionReason::EmptyFile, "empty_file"),
    (ExclusionReason::ExceedsSizeLimit, "exceeds_size_limit"),
    (ExclusionReason::CloudPlaceholder, "cloud_placeholder"),
    (ExclusionReason::UnrecognizedContent, "unrecognized_content"),
];

const STORED_REFUSAL_REASONS: &[(RefusalReason, &str)] = &[
    (RefusalReason::TooLarge, "too_large"),
    (RefusalReason::UnacceptedKind, "unaccepted_kind"),
];

#[cfg(test)]
const STORED_ADMISSIONS: &[&str] = &["surveying", "awaiting_decision", "collecting"];
#[cfg(test)]
const STORED_STANDINGS: &[&str] = &["unresolved", "absent", "present", "deleted", "refused"];
#[cfg(test)]
const STORED_LIFECYCLES: &[&str] = &["stabilizing", "stable", "digested", "excluded", "unreadable"];

fn admission_name(admission: &FolderAdmission) -> &'static str {
    match admission {
        FolderAdmission::Surveying => "surveying",
        FolderAdmission::AwaitingDecision => "awaiting_decision",
        FolderAdmission::Collecting { .. } => "collecting",
    }
}

fn standing_name(standing: &ArchiveStanding) -> &'static str {
    match standing {
        ArchiveStanding::Unresolved => "unresolved",
        ArchiveStanding::Absent { .. } => "absent",
        ArchiveStanding::Present(_) => "present",
        ArchiveStanding::Deleted => "deleted",
        ArchiveStanding::Refused(_) => "refused",
    }
}

fn lifecycle_name(state: &PathState) -> &'static str {
    match state {
        PathState::Stabilizing { .. } => "stabilizing",
        PathState::Stable { .. } => "stable",
        PathState::Digested { .. } => "digested",
        PathState::Excluded { .. } => "excluded",
        PathState::Unreadable { .. } => "unreadable",
    }
}

fn stored_name<Variant: PartialEq + Copy>(table: &[(Variant, &'static str)], variant: Variant) -> &'static str {
    table
        .iter()
        .find(|(candidate, _)| *candidate == variant)
        .map(|(_, name)| *name)
        .unwrap_or_default()
}

fn stored_variant<Variant: Copy>(table: &[(Variant, &'static str)], name: &str) -> rusqlite::Result<Variant> {
    table
        .iter()
        .find(|(_, candidate)| *candidate == name)
        .map(|(variant, _)| *variant)
        .ok_or_else(|| invalid_row(format!("unknown stored value {name}")))
}

#[derive(Debug)]
struct RowShapeError(String);

impl std::fmt::Display for RowShapeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for RowShapeError {}

fn invalid_row(detail: String) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(RowShapeError(detail)))
}

fn milliseconds(duration: std::time::Duration) -> i64 {
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

fn folder_list(folders: &[FolderIdentifier]) -> String {
    serde_json::to_string(&folders.iter().map(|folder| folder.value()).collect::<Vec<_>>()).unwrap_or_default()
}

fn digest_from_row(row: &Row<'_>, column: &str) -> rusqlite::Result<ContentDigest> {
    let text: String = row.get(column)?;
    ContentDigest::parse_hexadecimal(&text).ok_or_else(|| invalid_row(format!("malformed content digest {text}")))
}

fn optional_timestamp(row: &Row<'_>, column: &str) -> rusqlite::Result<Option<Timestamp>> {
    Ok(row.get::<_, Option<i64>>(column)?.map(Timestamp))
}

fn signature_from_row(row: &Row<'_>) -> rusqlite::Result<FileSignature> {
    Ok(FileSignature {
        device: row.get::<_, i64>("device")? as u64,
        inode: row.get::<_, i64>("inode")? as u64,
        byte_size: row.get::<_, i64>("byte_size")? as u64,
        modification_nanoseconds: row.get("modification_nanoseconds")?,
        status_change_nanoseconds: row.get("status_change_nanoseconds")?,
        dataless: row.get::<_, i64>("dataless")? != 0,
    })
}

fn readable_from_row(row: &Row<'_>) -> rusqlite::Result<ReadableSignature> {
    classify_signature(signature_from_row(row)?).map_err(|reason| {
        invalid_row(format!(
            "a {} row holds an unreadable signature: {reason:?}",
            lifecycle_name_of_row(row)
        ))
    })
}

fn lifecycle_name_of_row(row: &Row<'_>) -> String {
    row.get("lifecycle").unwrap_or_default()
}

const PATH_COLUMNS: &str = "folder_identifier, directory_key, entry_name, device, inode, byte_size, \
    modification_nanoseconds, status_change_nanoseconds, dataless, lifecycle, observed_at, content_digest, \
    exclusion_reason, unreadable_since, unreadable_cause";

fn path_state_from_row(row: &Row<'_>) -> rusqlite::Result<PathState> {
    let lifecycle: String = row.get("lifecycle")?;
    Ok(match lifecycle.as_str() {
        "stabilizing" => PathState::Stabilizing {
            signature: signature_from_row(row)?,
            observed_at: Timestamp(row.get("observed_at")?),
        },
        "stable" => PathState::Stable {
            signature: readable_from_row(row)?,
        },
        "digested" => PathState::Digested {
            signature: readable_from_row(row)?,
            content: digest_from_row(row, "content_digest")?,
        },
        "excluded" => PathState::Excluded {
            signature: signature_from_row(row)?,
            reason: stored_variant(STORED_EXCLUSION_REASONS, &row.get::<_, String>("exclusion_reason")?)?,
        },
        "unreadable" => PathState::Unreadable {
            signature: readable_from_row(row)?,
            since: Timestamp(row.get("unreadable_since")?),
            cause: row.get("unreadable_cause")?,
        },
        other => return Err(invalid_row(format!("unknown lifecycle {other}"))),
    })
}

fn path_key_from_row(row: &Row<'_>) -> rusqlite::Result<PathKey> {
    Ok(PathKey {
        folder: FolderIdentifier::new(row.get("folder_identifier")?),
        directory: DirectoryKey::from_stored_text(row.get("directory_key")?),
        name: EntryName::from_bytes(row.get("entry_name")?),
    })
}

const CONTENT_COLUMNS: &str = "content_digest, archive_standing, looked_up_at, submission_failures, retry_not_before, \
    document_identifier, document_status, failure_reason, status_read_at, received_at, refusal_reason";

fn standing_from_row(row: &Row<'_>) -> rusqlite::Result<ArchiveStanding> {
    let standing: String = row.get("archive_standing")?;
    Ok(match standing.as_str() {
        "unresolved" => ArchiveStanding::Unresolved,
        "absent" => ArchiveStanding::Absent {
            looked_up_at: Timestamp(row.get("looked_up_at")?),
            failures: SubmissionFailures {
                count: row.get::<_, i64>("submission_failures")?.try_into().unwrap_or(u32::MAX),
                retry_not_before: optional_timestamp(row, "retry_not_before")?,
            },
        },
        "present" => {
            let identifier: String = row.get("document_identifier")?;
            let status = match row.get::<_, Option<String>>("document_status")? {
                Some(name) => Some(
                    DocumentStatus::parse(&name, row.get("failure_reason")?)
                        .ok_or_else(|| invalid_row(format!("unknown document status {name}")))?,
                ),
                None => None,
            };
            ArchiveStanding::Present(PresentDocument {
                document: DocumentIdentifier::parse(&identifier)
                    .ok_or_else(|| invalid_row(format!("malformed document identifier {identifier}")))?,
                status,
                status_read_at: optional_timestamp(row, "status_read_at")?,
                received_at: optional_timestamp(row, "received_at")?,
            })
        }
        "deleted" => ArchiveStanding::Deleted,
        "refused" => ArchiveStanding::Refused(stored_variant(
            STORED_REFUSAL_REASONS,
            &row.get::<_, String>("refusal_reason")?,
        )?),
        other => return Err(invalid_row(format!("unknown archive standing {other}"))),
    })
}

fn content_record_from_row(row: &Row<'_>) -> rusqlite::Result<ContentRecord> {
    Ok(ContentRecord {
        digest: digest_from_row(row, "content_digest")?,
        standing: standing_from_row(row)?,
    })
}

/// Zero while the folder has no decision, so a surveyed folder's paths are all backlog. Arrivals
/// after the decision sort first, then the backlog in discovery order.
const ARRIVAL_ORDER: &str = "CASE WHEN w.decided_at IS NOT NULL AND p.first_observed_at > w.decided_at THEN 0 ELSE 1 END, \
    p.first_observed_at";

impl StateStore {
    /// WAL journal, `foreign_keys = ON`, migrations applied. A file that fails `PRAGMA quick_check`
    /// is renamed to `<name>.unreadable-<seconds>` and reported.
    pub fn open(path: &Path) -> Result<StateStore, StoreOpenFailure> {
        let connection = Connection::open(path)?;
        let check: rusqlite::Result<String> = connection.query_row("PRAGMA quick_check", [], |row| row.get(0));
        if check.as_deref().ok() != Some("ok") {
            drop(connection);
            let seconds = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_secs())
                .unwrap_or(0);
            let mut renamed_to = path.as_os_str().to_owned();
            renamed_to.push(format!(".unreadable-{seconds}"));
            let renamed_to = PathBuf::from(renamed_to);
            std::fs::rename(path, &renamed_to).map_err(StoreOpenFailure::Inaccessible)?;
            return Err(StoreOpenFailure::Unreadable { renamed_to });
        }
        connection.pragma_update(None, "journal_mode", "WAL")?;
        StateStore::prepare(connection)
    }

    /// A store that lives in memory, for tests.
    pub fn open_in_memory() -> Result<StateStore, StoreOpenFailure> {
        StateStore::prepare(Connection::open_in_memory()?)
    }

    fn prepare(connection: Connection) -> Result<StateStore, StoreOpenFailure> {
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let found: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let supported = u32::try_from(MIGRATIONS.len()).unwrap_or(u32::MAX);
        if found > supported {
            return Err(StoreOpenFailure::NewerSchema { found, supported });
        }
        let mut store = StateStore { connection };
        for (index, migration) in MIGRATIONS.iter().enumerate().skip(found as usize) {
            let transaction = store.connection.transaction()?;
            transaction.execute_batch(migration)?;
            transaction.pragma_update(None, "user_version", i64::try_from(index + 1).unwrap_or(i64::MAX))?;
            transaction.commit()?;
        }
        Ok(store)
    }

    pub fn schema_version(&self) -> rusqlite::Result<u32> {
        self.connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
    }

    /// One transaction at a time; the coordinator, the only caller, opens one per batch. The
    /// store's reads stay callable while it is open and see its uncommitted writes.
    pub fn begin(&self) -> rusqlite::Result<StoreTransaction<'_>> {
        Ok(StoreTransaction {
            transaction: self.connection.unchecked_transaction()?,
        })
    }

    pub fn connection_record(&self) -> rusqlite::Result<Option<ConnectionRecord>> {
        self.connection
            .query_row(
                "SELECT archive_origin, credential_fingerprint, suspension_reason, suspended_at FROM archive_connection",
                [],
                |row| {
                    let suspension = match row.get::<_, Option<String>>("suspension_reason")? {
                        Some(reason) => Some((
                            stored_variant(STORED_SUSPENSION_REASONS, &reason)?,
                            Timestamp(row.get("suspended_at")?),
                        )),
                        None => None,
                    };
                    Ok(ConnectionRecord {
                        archive_origin: row.get("archive_origin")?,
                        credential_fingerprint: row.get("credential_fingerprint")?,
                        suspension,
                    })
                },
            )
            .optional()
    }

    pub fn folders(&self) -> rusqlite::Result<Vec<FolderRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT folder_identifier, root_path, enrolled_at, admission, decided_at FROM watched_folders \
             ORDER BY folder_identifier",
        )?;
        let folders = statement.query_map([], |row| {
            let admission = match row.get::<_, String>("admission")?.as_str() {
                "surveying" => FolderAdmission::Surveying,
                "awaiting_decision" => FolderAdmission::AwaitingDecision,
                "collecting" => FolderAdmission::Collecting {
                    decided_at: Timestamp(row.get("decided_at")?),
                },
                other => return Err(invalid_row(format!("unknown admission {other}"))),
            };
            Ok(FolderRecord {
                folder: FolderIdentifier::new(row.get("folder_identifier")?),
                root: PathBuf::from(EntryName::from_bytes(row.get("root_path")?).as_os_str()),
                enrolled_at: Timestamp(row.get("enrolled_at")?),
                admission,
            })
        })?;
        folders.collect()
    }

    /// Rows of exactly this directory, and the keys of child directories that have rows below them.
    pub fn directory_contents(
        &self,
        folder: FolderIdentifier,
        directory: &DirectoryKey,
    ) -> rusqlite::Result<DirectoryContents> {
        let mut rows = self.connection.prepare(&format!(
            "SELECT {PATH_COLUMNS} FROM path_observations WHERE folder_identifier = ?1 AND directory_key = ?2 \
             ORDER BY entry_name"
        ))?;
        let files = rows
            .query_map(params![folder.value(), directory.as_str()], |row| {
                Ok((EntryName::from_bytes(row.get("entry_name")?), path_state_from_row(row)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut keys = self.connection.prepare(
            "SELECT DISTINCT directory_key FROM path_observations WHERE folder_identifier = ?1 AND directory_key <> ?2 \
             AND substr(directory_key, 1, length(?3)) = ?3",
        )?;
        let prefix = if directory.is_root() {
            String::new()
        } else {
            format!("{}/", directory.as_str())
        };
        let children = keys
            .query_map(params![folder.value(), directory.as_str(), prefix], |row| {
                row.get::<_, String>(0)
            })?
            .map(|key| {
                let key = key?;
                let remainder = &key[prefix.len()..];
                let child = remainder.split('/').next().unwrap_or_default();
                Ok(DirectoryKey::from_stored_text(format!("{prefix}{child}")))
            })
            .collect::<rusqlite::Result<BTreeSet<_>>>()?;
        Ok(DirectoryContents {
            files,
            subdirectories: children.into_iter().collect(),
        })
    }

    pub fn path_state(&self, path: &PathKey) -> rusqlite::Result<Option<PathState>> {
        self.connection
            .query_row(
                &format!(
                    "SELECT {PATH_COLUMNS} FROM path_observations \
                     WHERE folder_identifier = ?1 AND directory_key = ?2 AND entry_name = ?3"
                ),
                params![path.folder.value(), path.directory.as_str(), path.name.to_bytes()],
                path_state_from_row,
            )
            .optional()
    }

    pub fn content_record(&self, digest: &ContentDigest) -> rusqlite::Result<Option<ContentRecord>> {
        self.connection
            .query_row(
                &format!("SELECT {CONTENT_COLUMNS} FROM contents WHERE content_digest = ?1"),
                params![digest.hexadecimal()],
                content_record_from_row,
            )
            .optional()
    }

    /// Limited by free capacity plus reservations, in planning order (see `WorkCandidates`). Only
    /// available folders take part: a listing below a missing root would read as vanished and
    /// delete rows, and a missing folder admits no source.
    pub fn work_candidates(
        &self,
        reservations: &Reservations,
        capacity: &LaneCapacity,
        available_folders: &[FolderIdentifier],
        now: Timestamp,
        timing: &TimingPolicy,
    ) -> rusqlite::Result<WorkCandidates> {
        let limit = |lane: Lane| i64::try_from(capacity.of(lane) + reservations.occupancy(lane)).unwrap_or(i64::MAX);
        let available = folder_list(available_folders);

        let mut due = self.connection.prepare(
            "SELECT DISTINCT folder_identifier, directory_key FROM path_observations \
             WHERE folder_identifier IN (SELECT value FROM json_each(:available)) \
             AND ((lifecycle = 'stabilizing' AND observed_at + :stabilization <= :now) \
                  OR (lifecycle = 'unreadable' AND unreadable_since + :retry <= :now)) \
             ORDER BY folder_identifier, directory_key LIMIT :limit",
        )?;
        let due_directories = due
            .query_map(
                named_params! {
                    ":available": available,
                    ":stabilization": milliseconds(timing.stabilization_interval),
                    ":retry": milliseconds(timing.unreadable_retry_interval),
                    ":now": now.0,
                    ":limit": limit(Lane::Listing),
                },
                |row| {
                    Ok((
                        FolderIdentifier::new(row.get("folder_identifier")?),
                        DirectoryKey::from_stored_text(row.get("directory_key")?),
                        false,
                    ))
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let mut stable = self.connection.prepare(&format!(
            "SELECT {PATH_COLUMNS} FROM path_observations p JOIN watched_folders w USING (folder_identifier) \
             WHERE p.lifecycle = 'stable' AND p.folder_identifier IN (SELECT value FROM json_each(:available)) \
             ORDER BY {ARRIVAL_ORDER} LIMIT :limit"
        ))?;
        let stable_paths = stable
            .query_map(
                named_params! { ":available": available, ":limit": limit(Lane::Digest) },
                |row| Ok((path_key_from_row(row)?, readable_from_row(row)?)),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let mut look_up = self.connection.prepare(
            "WITH digested AS (\
                SELECT p.content_digest, \
                       MIN(CASE WHEN w.decided_at IS NOT NULL AND p.first_observed_at > w.decided_at THEN 0 ELSE 1 END) AS backlog, \
                       MIN(p.first_observed_at) AS first_observed_at, \
                       MAX(w.admission = 'collecting') AS admitted \
                FROM path_observations p JOIN watched_folders w USING (folder_identifier) \
                WHERE p.lifecycle = 'digested' AND p.folder_identifier IN (SELECT value FROM json_each(:available)) \
                GROUP BY p.content_digest) \
             SELECT c.content_digest FROM contents c JOIN digested d USING (content_digest) \
             WHERE c.archive_standing = 'unresolved' \
                OR (c.archive_standing = 'absent' AND d.admitted AND c.looked_up_at + :validity <= :now \
                    AND (c.retry_not_before IS NULL OR c.retry_not_before <= :now)) \
             ORDER BY d.backlog, d.first_observed_at LIMIT :limit",
        )?;
        let lookup_limit = i64::try_from(MAXIMUM_LOOKUP_DIGESTS)
            .unwrap_or(i64::MAX)
            .saturating_mul(limit(Lane::Lookup));
        let contents_to_look_up = look_up
            .query_map(
                named_params! {
                    ":available": available,
                    ":validity": milliseconds(timing.lookup_validity),
                    ":now": now.0,
                    ":limit": lookup_limit,
                },
                |row| digest_from_row(row, "content_digest"),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let mut submit = self.connection.prepare(&format!(
            "WITH digested AS (\
                SELECT p.content_digest, \
                       MIN(CASE WHEN w.decided_at IS NOT NULL AND p.first_observed_at > w.decided_at THEN 0 ELSE 1 END) AS backlog, \
                       MIN(p.first_observed_at) AS first_observed_at \
                FROM path_observations p JOIN watched_folders w USING (folder_identifier) \
                WHERE p.lifecycle = 'digested' AND w.admission = 'collecting' \
                  AND p.folder_identifier IN (SELECT value FROM json_each(:available)) \
                GROUP BY p.content_digest) \
             SELECT {CONTENT_COLUMNS} FROM contents c JOIN digested d USING (content_digest) \
             WHERE c.archive_standing = 'absent' AND c.looked_up_at + :validity > :now \
               AND (c.retry_not_before IS NULL OR c.retry_not_before <= :now) \
             ORDER BY d.backlog, d.first_observed_at LIMIT :limit"
        ))?;
        let records = submit
            .query_map(
                named_params! {
                    ":available": available,
                    ":validity": milliseconds(timing.lookup_validity),
                    ":now": now.0,
                    ":limit": limit(Lane::Submission),
                },
                content_record_from_row,
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut sources = self.connection.prepare(&format!(
            "SELECT {PATH_COLUMNS} FROM path_observations p JOIN watched_folders w USING (folder_identifier) \
             WHERE p.content_digest = :digest AND p.lifecycle = 'digested' AND w.admission = 'collecting' \
               AND p.folder_identifier IN (SELECT value FROM json_each(:available)) \
             ORDER BY {ARRIVAL_ORDER}"
        ))?;
        let mut contents_to_submit = Vec::with_capacity(records.len());
        for record in records {
            let paths = sources
                .query_map(
                    named_params! { ":digest": record.digest.hexadecimal(), ":available": available },
                    |row| Ok((path_key_from_row(row)?, readable_from_row(row)?)),
                )?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            contents_to_submit.push((record, paths));
        }

        let mut follow = self.connection.prepare(
            "SELECT content_digest, document_identifier FROM (\
                SELECT content_digest, document_identifier, status_read_at, received_at FROM contents \
                WHERE archive_standing = 'present' AND received_at IS NOT NULL AND received_at + :window > :now \
                  AND (document_status IS NULL OR document_status NOT IN ('archived', 'failed')) \
                ORDER BY received_at DESC LIMIT :followed) \
             WHERE status_read_at IS NULL OR status_read_at + :interval <= :now \
             ORDER BY received_at DESC LIMIT :limit",
        )?;
        let documents_to_follow = follow
            .query_map(
                named_params! {
                    ":window": milliseconds(timing.document_follow_window),
                    ":interval": milliseconds(timing.document_follow_interval),
                    ":now": now.0,
                    ":followed": i64::try_from(MAXIMUM_FOLLOWED_DOCUMENTS).unwrap_or(i64::MAX),
                    ":limit": limit(Lane::DocumentStatus),
                },
                |row| {
                    let identifier: String = row.get("document_identifier")?;
                    Ok((
                        digest_from_row(row, "content_digest")?,
                        DocumentIdentifier::parse(&identifier)
                            .ok_or_else(|| invalid_row(format!("malformed document identifier {identifier}")))?,
                    ))
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        Ok(WorkCandidates {
            due_directories,
            stable_paths,
            contents_to_look_up,
            contents_to_submit,
            documents_to_follow,
        })
    }

    /// The counts of the survey predicate. `initial_walk_completed` is the coordinator's knowledge
    /// and stays false here.
    pub fn survey_progress(&self, folder: FolderIdentifier) -> rusqlite::Result<SurveyProgress> {
        self.connection.query_row(
            "SELECT COUNT(*) FILTER (WHERE p.lifecycle IN ('stabilizing', 'stable')), \
                    COUNT(DISTINCT p.content_digest) FILTER (WHERE c.archive_standing = 'unresolved') \
             FROM path_observations p LEFT JOIN contents c USING (content_digest) WHERE p.folder_identifier = ?1",
            params![folder.value()],
            |row| {
                Ok(SurveyProgress {
                    initial_walk_completed: false,
                    paths_stabilizing_or_stable: row.get::<_, i64>(0)? as u64,
                    contents_unresolved: row.get::<_, i64>(1)? as u64,
                })
            },
        )
    }

    /// Counts over the named folders; distinct contents are counted once across them. The
    /// disregarded entries have no rows, so the coordinator adds them from its listings.
    pub fn backlog_summary(&self, folders: &[FolderIdentifier]) -> rusqlite::Result<BacklogSummary> {
        let mut by_reason = self.connection.prepare(
            "SELECT exclusion_reason, COUNT(*) FROM path_observations WHERE lifecycle = 'excluded' \
             AND folder_identifier IN (SELECT value FROM json_each(?1)) GROUP BY exclusion_reason",
        )?;
        let excluded_files_by_reason = by_reason
            .query_map(params![folder_list(folders)], |row| {
                Ok((
                    stored_variant(STORED_EXCLUSION_REASONS, &row.get::<_, String>(0)?)?,
                    row.get::<_, i64>(1)? as u64,
                ))
            })?
            .collect::<rusqlite::Result<BTreeMap<_, _>>>()?;
        self.connection.query_row(
            "SELECT COUNT(*) FILTER (WHERE p.lifecycle = 'digested'), \
                    COUNT(*) FILTER (WHERE c.archive_standing = 'present'), \
                    COUNT(*) FILTER (WHERE c.archive_standing = 'deleted'), \
                    COUNT(*) FILTER (WHERE c.archive_standing = 'refused'), \
                    COUNT(*) FILTER (WHERE c.archive_standing = 'absent'), \
                    COUNT(DISTINCT p.content_digest) FILTER (WHERE c.archive_standing = 'absent'), \
                    COUNT(*) FILTER (WHERE p.lifecycle = 'excluded'), \
                    COUNT(*) FILTER (WHERE p.lifecycle = 'unreadable'), \
                    COUNT(*) FILTER (WHERE p.lifecycle IN ('stabilizing', 'stable') OR c.archive_standing = 'unresolved') \
             FROM path_observations p LEFT JOIN contents c USING (content_digest) \
             WHERE p.folder_identifier IN (SELECT value FROM json_each(?1))",
            params![folder_list(folders)],
            |row| {
                let count = |index: usize| row.get::<_, i64>(index).map(|count| count as u64);
                Ok(BacklogSummary {
                    folders: folders.to_vec(),
                    candidate_files: count(0)?,
                    files_already_archived: count(1)?,
                    files_deleted_from_archive: count(2)?,
                    files_refused_by_archive: count(3)?,
                    files_new: count(4)?,
                    new_contents: count(5)?,
                    excluded_files: count(6)?,
                    excluded_files_by_reason,
                    disregarded_files: BTreeMap::new(),
                    unreadable_files: count(7)?,
                    files_under_examination: count(8)?,
                })
            },
        )
    }

    pub fn state_counts(&self) -> rusqlite::Result<StateCounts> {
        let count = |sql: &str| {
            self.connection
                .query_row(sql, [], |row| row.get::<_, i64>(0).map(|count| count as u64))
        };
        let paths = |lifecycle: &str| {
            count(&format!(
                "SELECT COUNT(*) FROM path_observations WHERE lifecycle = '{lifecycle}'"
            ))
        };
        let contents = |standing: &str| {
            count(&format!(
                "SELECT COUNT(*) FROM contents WHERE archive_standing = '{standing}'"
            ))
        };
        Ok(StateCounts {
            paths_stabilizing: paths("stabilizing")?,
            paths_awaiting_digest: paths("stable")?,
            paths_digested: paths("digested")?,
            paths_excluded: paths("excluded")?,
            paths_unreadable: paths("unreadable")?,
            contents_unresolved: contents("unresolved")?,
            contents_awaiting_submission: contents("absent")?,
            contents_present: contents("present")?,
            contents_deleted: contents("deleted")?,
            contents_refused: contents("refused")?,
            contents_failing: count(
                "SELECT COUNT(*) FROM contents WHERE archive_standing = 'absent' AND submission_failures >= 3",
            )?,
        })
    }

    /// The newest sighting of a content, withdrawn ones last, as the status names a file.
    const NEWEST_SIGHTING: &'static str = "(SELECT s.relative_path FROM content_sightings s \
        WHERE s.content_digest = c.content_digest ORDER BY s.withdrawn_at IS NOT NULL, s.last_seen_at DESC LIMIT 1)";

    /// Documents this collector received, newest first, each named by its newest sighting and
    /// linked under the stored archive origin.
    pub fn recent_receipts(&self, limit: usize) -> rusqlite::Result<Vec<Receipt>> {
        let mut statement = self.connection.prepare(&format!(
            "SELECT c.content_digest, c.document_identifier, c.document_status, c.failure_reason, c.received_at, \
                    {} AS relative_path, (SELECT archive_origin FROM archive_connection) AS archive_origin \
             FROM contents c WHERE c.received_at IS NOT NULL ORDER BY c.received_at DESC, c.content_digest LIMIT ?1",
            StateStore::NEWEST_SIGHTING
        ))?;
        let receipts = statement.query_map(params![i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
            let identifier: String = row.get("document_identifier")?;
            let origin: Option<String> = row.get("archive_origin")?;
            let status = match row.get::<_, Option<String>>("document_status")? {
                Some(name) => Some(
                    DocumentStatus::parse(&name, row.get("failure_reason")?)
                        .ok_or_else(|| invalid_row(format!("unknown document status {name}")))?,
                ),
                None => None,
            };
            Ok(Receipt {
                document_link: format!("{}/documents/{identifier}", origin.unwrap_or_default()),
                document: DocumentIdentifier::parse(&identifier)
                    .ok_or_else(|| invalid_row(format!("malformed document identifier {identifier}")))?,
                file_name: row
                    .get::<_, Option<String>>("relative_path")?
                    .unwrap_or_else(|| row.get("content_digest").unwrap_or_default()),
                received_at: Timestamp(row.get("received_at")?),
                status,
            })
        })?;
        receipts.collect()
    }

    /// Contents the archive refused for good, and absent contents with three or more failures,
    /// each named by its newest sighting.
    pub fn contents_needing_attention(&self) -> rusqlite::Result<Vec<ContentAttention>> {
        let mut statement = self.connection.prepare(&format!(
            "SELECT c.content_digest, c.refusal_reason, c.submission_failures, {} AS relative_path FROM contents c \
             WHERE c.archive_standing = 'refused' OR (c.archive_standing = 'absent' AND c.submission_failures >= 3) \
             ORDER BY c.content_digest",
            StateStore::NEWEST_SIGHTING
        ))?;
        let contents = statement.query_map([], |row| {
            let refusal = match row.get::<_, Option<String>>("refusal_reason")? {
                Some(reason) => Some(stored_variant(STORED_REFUSAL_REASONS, &reason)?),
                None => None,
            };
            Ok(ContentAttention {
                file_name: row
                    .get::<_, Option<String>>("relative_path")?
                    .unwrap_or_else(|| row.get("content_digest").unwrap_or_default()),
                refusal,
                failures: row.get::<_, i64>("submission_failures")?.try_into().unwrap_or(u32::MAX),
            })
        })?;
        contents.collect()
    }

    /// The earliest stabilization, unreadable retry, submission retry, or document status read:
    /// when the coordinator must wake for the store's sake.
    pub fn next_deadline(&self, now: Timestamp, timing: &TimingPolicy) -> rusqlite::Result<Option<Timestamp>> {
        self.connection
            .query_row(
                "SELECT MIN(deadline) FROM (\
                    SELECT observed_at + :stabilization AS deadline FROM path_observations WHERE lifecycle = 'stabilizing' \
                    UNION ALL SELECT unreadable_since + :retry FROM path_observations WHERE lifecycle = 'unreadable' \
                    UNION ALL SELECT retry_not_before FROM contents \
                        WHERE archive_standing = 'absent' AND retry_not_before IS NOT NULL \
                    UNION ALL SELECT COALESCE(status_read_at + :follow, received_at) FROM contents \
                        WHERE archive_standing = 'present' AND received_at IS NOT NULL AND received_at + :window > :now \
                          AND (document_status IS NULL OR document_status NOT IN ('archived', 'failed')))",
                named_params! {
                    ":stabilization": milliseconds(timing.stabilization_interval),
                    ":retry": milliseconds(timing.unreadable_retry_interval),
                    ":follow": milliseconds(timing.document_follow_interval),
                    ":window": milliseconds(timing.document_follow_window),
                    ":now": now.0,
                },
                |row| row.get::<_, Option<i64>>(0),
            )
            .map(|deadline| deadline.map(Timestamp))
    }
}

fn relative_path_text(path: &PathKey) -> String {
    path.directory.child(&path.name).as_str().to_owned()
}

impl StoreTransaction<'_> {
    /// Writes a path transition. `at` is the event's time: the first observation of a new row, and
    /// the sighting time of a content. A transition to Digested also inserts the content row as
    /// Unresolved when it is missing, so a Digested path's content row always exists, and records
    /// the sighting. A row that leaves Digested withdraws its sighting.
    pub fn apply_path(&self, path: &PathKey, transition: &PathTransition, at: Timestamp) -> rusqlite::Result<()> {
        let state = match transition {
            PathTransition::Unchanged => return Ok(()),
            PathTransition::Remove => {
                self.withdraw_sighting(path, at)?;
                self.transaction.execute(
                    "DELETE FROM path_observations WHERE folder_identifier = ?1 AND directory_key = ?2 AND entry_name = ?3",
                    params![path.folder.value(), path.directory.as_str(), path.name.to_bytes()],
                )?;
                return Ok(());
            }
            PathTransition::Store(state) => state,
        };
        let content = match state {
            PathState::Digested { content, .. } => Some(*content),
            _ => None,
        };
        let previous = self.stored_content(path)?;
        if previous.is_some() && previous != content {
            self.withdraw_sighting(path, at)?;
        }
        if let Some(content) = content {
            self.transaction.execute(
                "INSERT OR IGNORE INTO contents (content_digest, archive_standing) VALUES (?1, 'unresolved')",
                params![content.hexadecimal()],
            )?;
            self.transaction.execute(
                "INSERT INTO content_sightings (content_digest, folder_identifier, relative_path, first_seen_at, last_seen_at) \
                 VALUES (?1, ?2, ?3, ?4, ?4) \
                 ON CONFLICT DO UPDATE SET last_seen_at = excluded.last_seen_at, withdrawn_at = NULL",
                params![content.hexadecimal(), path.folder.value(), relative_path_text(path), at.0],
            )?;
        }
        let signature = state.signature();
        let (observed_at, exclusion_reason, unreadable_since, unreadable_cause) = match state {
            PathState::Stabilizing { observed_at, .. } => (*observed_at, None, None, None),
            PathState::Excluded { reason, .. } => {
                (at, Some(stored_name(STORED_EXCLUSION_REASONS, *reason)), None, None)
            }
            PathState::Unreadable { since, cause, .. } => (at, None, Some(since.0), Some(cause.as_str())),
            PathState::Stable { .. } | PathState::Digested { .. } => (at, None, None, None),
        };
        self.transaction.execute(
            "INSERT INTO path_observations (folder_identifier, directory_key, entry_name, device, inode, byte_size, \
                modification_nanoseconds, status_change_nanoseconds, dataless, lifecycle, observed_at, first_observed_at, \
                content_digest, exclusion_reason, unreadable_since, unreadable_cause) \
             VALUES (:folder, :directory, :name, :device, :inode, :byte_size, :modification, :status_change, :dataless, \
                :lifecycle, :observed_at, :observed_at, :content, :exclusion_reason, :unreadable_since, :unreadable_cause) \
             ON CONFLICT (folder_identifier, directory_key, entry_name) DO UPDATE SET \
                device = excluded.device, inode = excluded.inode, byte_size = excluded.byte_size, \
                modification_nanoseconds = excluded.modification_nanoseconds, \
                status_change_nanoseconds = excluded.status_change_nanoseconds, dataless = excluded.dataless, \
                lifecycle = excluded.lifecycle, observed_at = excluded.observed_at, content_digest = excluded.content_digest, \
                exclusion_reason = excluded.exclusion_reason, unreadable_since = excluded.unreadable_since, \
                unreadable_cause = excluded.unreadable_cause",
            named_params! {
                ":folder": path.folder.value(),
                ":directory": path.directory.as_str(),
                ":name": path.name.to_bytes(),
                ":device": signature.device as i64,
                ":inode": signature.inode as i64,
                ":byte_size": signature.byte_size as i64,
                ":modification": signature.modification_nanoseconds,
                ":status_change": signature.status_change_nanoseconds,
                ":dataless": i64::from(signature.dataless),
                ":lifecycle": lifecycle_name(state),
                ":observed_at": observed_at.0,
                ":content": content.map(|content| content.hexadecimal()),
                ":exclusion_reason": exclusion_reason,
                ":unreadable_since": unreadable_since,
                ":unreadable_cause": unreadable_cause,
            },
        )?;
        Ok(())
    }

    fn stored_content(&self, path: &PathKey) -> rusqlite::Result<Option<ContentDigest>> {
        let stored: Option<Option<String>> = self
            .transaction
            .query_row(
                "SELECT content_digest FROM path_observations \
                 WHERE folder_identifier = ?1 AND directory_key = ?2 AND entry_name = ?3",
                params![path.folder.value(), path.directory.as_str(), path.name.to_bytes()],
                |row| row.get(0),
            )
            .optional()?;
        Ok(stored
            .flatten()
            .and_then(|text| ContentDigest::parse_hexadecimal(&text)))
    }

    fn withdraw_sighting(&self, path: &PathKey, at: Timestamp) -> rusqlite::Result<()> {
        self.transaction.execute(
            "UPDATE content_sightings SET withdrawn_at = ?1 WHERE withdrawn_at IS NULL AND folder_identifier = ?2 \
             AND relative_path = ?3 AND content_digest = (SELECT content_digest FROM path_observations \
                 WHERE folder_identifier = ?2 AND directory_key = ?4 AND entry_name = ?5)",
            params![
                at.0,
                path.folder.value(),
                relative_path_text(path),
                path.directory.as_str(),
                path.name.to_bytes()
            ],
        )?;
        Ok(())
    }

    /// Deletes every row at or below each key; the root key removes the folder's rows. The
    /// sightings of the digested rows gain `withdrawn_at`.
    pub fn remove_subtrees(
        &self,
        folder: FolderIdentifier,
        subtrees: &[DirectoryKey],
        at: Timestamp,
    ) -> rusqlite::Result<()> {
        for subtree in subtrees {
            let prefix = if subtree.is_root() {
                String::new()
            } else {
                format!("{}/", subtree.as_str())
            };
            let mut digested = self.transaction.prepare(
                "SELECT folder_identifier, directory_key, entry_name FROM path_observations \
                 WHERE folder_identifier = ?1 AND lifecycle = 'digested' \
                 AND (directory_key = ?2 OR substr(directory_key, 1, length(?3)) = ?3)",
            )?;
            let paths = digested
                .query_map(params![folder.value(), subtree.as_str(), prefix], path_key_from_row)?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            for path in &paths {
                self.withdraw_sighting(path, at)?;
            }
            self.transaction.execute(
                "DELETE FROM path_observations WHERE folder_identifier = ?1 \
                 AND (directory_key = ?2 OR substr(directory_key, 1, length(?3)) = ?3)",
                params![folder.value(), subtree.as_str(), prefix],
            )?;
        }
        Ok(())
    }

    /// Replaces the row's standing, creating the row when it is missing.
    pub fn store_standing(&self, digest: &ContentDigest, standing: &ArchiveStanding) -> rusqlite::Result<()> {
        let (looked_up_at, failures, retry_not_before) = match standing {
            ArchiveStanding::Absent { looked_up_at, failures } => (
                Some(looked_up_at.0),
                i64::from(failures.count),
                failures.retry_not_before.map(|at| at.0),
            ),
            _ => (None, 0, None),
        };
        let document = match standing {
            ArchiveStanding::Present(document) => Some(document),
            _ => None,
        };
        let (status, failure_reason) = match document.and_then(|document| document.status.as_ref()) {
            Some(DocumentStatus::Failed { failure_reason }) => (Some("failed"), failure_reason.clone()),
            Some(status) => (Some(status.name()), None),
            None => (None, None),
        };
        self.transaction.execute(
            &format!(
                "INSERT INTO contents ({CONTENT_COLUMNS}) VALUES (:digest, :standing, :looked_up_at, :failures, \
                    :retry_not_before, :document, :status, :failure_reason, :status_read_at, :received_at, :refusal_reason) \
                 ON CONFLICT (content_digest) DO UPDATE SET archive_standing = excluded.archive_standing, \
                    looked_up_at = excluded.looked_up_at, submission_failures = excluded.submission_failures, \
                    retry_not_before = excluded.retry_not_before, document_identifier = excluded.document_identifier, \
                    document_status = excluded.document_status, failure_reason = excluded.failure_reason, \
                    status_read_at = excluded.status_read_at, received_at = excluded.received_at, \
                    refusal_reason = excluded.refusal_reason"
            ),
            named_params! {
                ":digest": digest.hexadecimal(),
                ":standing": standing_name(standing),
                ":looked_up_at": looked_up_at,
                ":failures": failures,
                ":retry_not_before": retry_not_before,
                ":document": document.map(|document| document.document.as_str()),
                ":status": status,
                ":failure_reason": failure_reason,
                ":status_read_at": document.and_then(|document| document.status_read_at).map(|at| at.0),
                ":received_at": document.and_then(|document| document.received_at).map(|at| at.0),
                ":refusal_reason": match standing {
                    ArchiveStanding::Refused(reason) => Some(stored_name(STORED_REFUSAL_REASONS, *reason)),
                    _ => None,
                },
            },
        )?;
        Ok(())
    }

    /// A new folder in Surveying. A root enrolled already fails the UNIQUE constraint.
    pub fn enroll_folder(&self, root: &Path, at: Timestamp) -> rusqlite::Result<FolderIdentifier> {
        self.transaction.execute(
            "INSERT INTO watched_folders (root_path, enrolled_at, admission) VALUES (?1, ?2, 'surveying')",
            params![EntryName::new(root.as_os_str()).to_bytes(), at.0],
        )?;
        Ok(FolderIdentifier::new(self.transaction.last_insert_rowid()))
    }

    pub fn store_admission(&self, folder: FolderIdentifier, admission: FolderAdmission) -> rusqlite::Result<()> {
        let decided_at = match admission {
            FolderAdmission::Collecting { decided_at } => Some(decided_at.0),
            FolderAdmission::Surveying | FolderAdmission::AwaitingDecision => None,
        };
        self.transaction.execute(
            "UPDATE watched_folders SET admission = ?1, decided_at = ?2 WHERE folder_identifier = ?3",
            params![admission_name(&admission), decided_at, folder.value()],
        )?;
        Ok(())
    }

    /// Cascades to the folder's paths and sightings. Contents stay.
    pub fn withdraw_folder(&self, folder: FolderIdentifier) -> rusqlite::Result<()> {
        self.transaction.execute(
            "DELETE FROM watched_folders WHERE folder_identifier = ?1",
            params![folder.value()],
        )?;
        Ok(())
    }

    /// Replaces the singleton; a different fingerprint clears the suspension.
    pub fn store_connection(&self, archive_origin: &str, credential_fingerprint: &str) -> rusqlite::Result<()> {
        self.transaction.execute(
            "INSERT INTO archive_connection (singleton, archive_origin, credential_fingerprint) VALUES (1, ?1, ?2) \
             ON CONFLICT (singleton) DO UPDATE SET archive_origin = excluded.archive_origin, \
                credential_fingerprint = excluded.credential_fingerprint, \
                suspension_reason = CASE WHEN credential_fingerprint = excluded.credential_fingerprint \
                    THEN suspension_reason ELSE NULL END, \
                suspended_at = CASE WHEN credential_fingerprint = excluded.credential_fingerprint \
                    THEN suspended_at ELSE NULL END",
            params![archive_origin, credential_fingerprint],
        )?;
        Ok(())
    }

    pub fn store_suspension(&self, suspension: Option<(SuspensionReason, Timestamp)>) -> rusqlite::Result<()> {
        self.transaction.execute(
            "UPDATE archive_connection SET suspension_reason = ?1, suspended_at = ?2 WHERE singleton = 1",
            params![
                suspension.map(|(reason, _)| stored_name(STORED_SUSPENSION_REASONS, reason)),
                suspension.map(|(_, at)| at.0)
            ],
        )?;
        Ok(())
    }

    pub fn commit(self) -> rusqlite::Result<()> {
        self.transaction.commit()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::time::Duration;

    use super::*;
    use crate::content_synchronization::{PresentDocument, SubmissionFailures};
    use crate::work_planning::ContentReservation;

    const MINUTE: i64 = 60_000;

    fn digest(byte: u8) -> ContentDigest {
        ContentDigest::from_bytes([byte; 32])
    }

    fn document(last: char) -> DocumentIdentifier {
        DocumentIdentifier::parse(&format!("4c5d6e7f-8091-4a2b-9c3d-4e5f6071829{last}")).unwrap()
    }

    fn signature(inode: u64, byte_size: u64) -> FileSignature {
        FileSignature {
            device: 0x8000_0000_0000_0001,
            inode,
            byte_size,
            modification_nanoseconds: 1_700_000_000_123_456_789,
            status_change_nanoseconds: 1_700_000_000_987_654_321,
            dataless: false,
        }
    }

    fn readable(inode: u64) -> ReadableSignature {
        classify_signature(signature(inode, 512)).unwrap()
    }

    fn key(folder: FolderIdentifier, directory: &str, name: &str) -> PathKey {
        PathKey {
            folder,
            directory: DirectoryKey::from_stored_text(directory.to_owned()),
            name: EntryName::new(name),
        }
    }

    fn store_with_folder(root: &str) -> (StateStore, FolderIdentifier) {
        let store = StateStore::open_in_memory().unwrap();
        let transaction = store.begin().unwrap();
        let folder = transaction.enroll_folder(Path::new(root), Timestamp(1)).unwrap();
        transaction.commit().unwrap();
        (store, folder)
    }

    fn write(store: &mut StateStore, write: impl FnOnce(&StoreTransaction<'_>) -> rusqlite::Result<()>) {
        let transaction = store.begin().unwrap();
        write(&transaction).unwrap();
        transaction.commit().unwrap();
    }

    #[test]
    fn opening_applies_the_migrations_once_and_refuses_a_newer_schema() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("collector.sqlite");
        let store = StateStore::open(&path).unwrap();
        assert_eq!(store.schema_version().unwrap(), 1);
        drop(store);
        let again = StateStore::open(&path).unwrap();
        assert_eq!(again.schema_version().unwrap(), 1);
        again.connection.pragma_update(None, "user_version", 99).unwrap();
        drop(again);
        match StateStore::open(&path) {
            Err(StoreOpenFailure::NewerSchema {
                found: 99,
                supported: 1,
            }) => {}
            other => panic!("expected NewerSchema, found {other:?}"),
        }
    }

    #[test]
    fn a_file_that_is_no_database_is_renamed_aside() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("collector.sqlite");
        std::fs::write(&path, b"not a database at all, but long enough to be read as a header").unwrap();
        let renamed_to = match StateStore::open(&path) {
            Err(StoreOpenFailure::Unreadable { renamed_to }) => renamed_to,
            other => panic!("expected Unreadable, found {other:?}"),
        };
        assert!(!path.exists());
        assert!(renamed_to.to_string_lossy().contains("collector.sqlite.unreadable-"));
        assert!(renamed_to.exists());
    }

    #[test]
    fn every_path_state_round_trips_and_a_digest_creates_the_content_row_and_its_sighting() {
        let (mut store, folder) = store_with_folder("/Users/anna/Downloads");
        let states = vec![
            PathState::Stabilizing {
                signature: signature(1, 0),
                observed_at: Timestamp(5),
            },
            PathState::Stable { signature: readable(2) },
            PathState::Digested {
                signature: readable(3),
                content: digest(0xAB),
            },
            PathState::Excluded {
                signature: signature(4, 0),
                reason: ExclusionReason::EmptyFile,
            },
            PathState::Unreadable {
                signature: readable(5),
                since: Timestamp(7),
                cause: "permission denied".to_owned(),
            },
        ];
        let paths: Vec<PathKey> = (0..states.len())
            .map(|index| key(folder, "Scans", &format!("scan_{index}.pdf")))
            .collect();
        write(&mut store, |transaction| {
            for (path, state) in paths.iter().zip(&states) {
                transaction.apply_path(path, &PathTransition::Store(state.clone()), Timestamp(10))?;
            }
            Ok(())
        });

        for (path, state) in paths.iter().zip(&states) {
            assert_eq!(store.path_state(path).unwrap().as_ref(), Some(state), "{path:?}");
        }
        assert_eq!(
            store.content_record(&digest(0xAB)).unwrap(),
            Some(ContentRecord {
                digest: digest(0xAB),
                standing: ArchiveStanding::Unresolved
            })
        );
        let sightings = |store: &StateStore| -> Vec<(String, i64, i64, Option<i64>)> {
            let mut statement = store
                .connection
                .prepare("SELECT relative_path, first_seen_at, last_seen_at, withdrawn_at FROM content_sightings")
                .unwrap();
            let rows = statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
                .unwrap();
            rows.collect::<rusqlite::Result<_>>().unwrap()
        };
        assert_eq!(sightings(&store), vec![("Scans/scan_2.pdf".to_owned(), 10, 10, None)]);

        write(&mut store, |transaction| {
            transaction.apply_path(&paths[2], &PathTransition::Store(states[2].clone()), Timestamp(20))?;
            transaction.apply_path(&paths[1], &PathTransition::Unchanged, Timestamp(20))
        });
        assert_eq!(sightings(&store), vec![("Scans/scan_2.pdf".to_owned(), 10, 20, None)]);

        write(&mut store, |transaction| {
            transaction.apply_path(&paths[2], &PathTransition::Remove, Timestamp(30))
        });
        assert_eq!(store.path_state(&paths[2]).unwrap(), None);
        assert_eq!(
            store
                .content_record(&digest(0xAB))
                .unwrap()
                .map(|record| record.standing),
            Some(ArchiveStanding::Unresolved)
        );
        assert_eq!(
            sightings(&store),
            vec![("Scans/scan_2.pdf".to_owned(), 10, 20, Some(30))]
        );
    }

    #[test]
    fn a_row_that_leaves_digested_withdraws_its_sighting() {
        let (mut store, folder) = store_with_folder("/Users/anna/Downloads");
        let path = key(folder, "", "Invoice.pdf");
        write(&mut store, |transaction| {
            transaction.apply_path(
                &path,
                &PathTransition::Store(PathState::Digested {
                    signature: readable(1),
                    content: digest(1),
                }),
                Timestamp(10),
            )
        });
        write(&mut store, |transaction| {
            transaction.apply_path(
                &path,
                &PathTransition::Store(PathState::Stabilizing {
                    signature: signature(2, 600),
                    observed_at: Timestamp(40),
                }),
                Timestamp(40),
            )
        });
        let withdrawn: Option<i64> = store
            .connection
            .query_row(
                "SELECT withdrawn_at FROM content_sightings WHERE content_digest = ?1",
                params![digest(1).hexadecimal()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(withdrawn, Some(40));
    }

    #[test]
    fn every_archive_standing_round_trips() {
        let mut store = StateStore::open_in_memory().unwrap();
        let standings = [
            ArchiveStanding::Unresolved,
            ArchiveStanding::Absent {
                looked_up_at: Timestamp(50),
                failures: SubmissionFailures {
                    count: 2,
                    retry_not_before: Some(Timestamp(900)),
                },
            },
            ArchiveStanding::Present(PresentDocument {
                document: document('3'),
                status: Some(DocumentStatus::Failed {
                    failure_reason: Some("unreadable_file".to_owned()),
                }),
                status_read_at: Some(Timestamp(70)),
                received_at: Some(Timestamp(60)),
            }),
            ArchiveStanding::Present(PresentDocument {
                document: document('4'),
                status: None,
                status_read_at: None,
                received_at: None,
            }),
            ArchiveStanding::Deleted,
            ArchiveStanding::Refused(RefusalReason::UnacceptedKind),
        ];
        write(&mut store, |transaction| {
            for (index, standing) in standings.iter().enumerate() {
                transaction.store_standing(&digest(index as u8), standing)?;
            }
            transaction.store_standing(&digest(0), &standings[1])?;
            transaction.store_standing(&digest(0), &standings[0])
        });
        for (index, standing) in standings.iter().enumerate() {
            let record = store.content_record(&digest(index as u8)).unwrap().unwrap();
            assert_eq!(
                record,
                ContentRecord {
                    digest: digest(index as u8),
                    standing: standing.clone()
                }
            );
        }
    }

    #[test]
    fn folders_round_trip_and_a_withdrawal_removes_their_paths_but_not_their_contents() {
        let (mut store, folder) = store_with_folder("/Users/anna/Downloads");
        let path = key(folder, "", "Invoice.pdf");
        write(&mut store, |transaction| {
            transaction.apply_path(
                &path,
                &PathTransition::Store(PathState::Digested {
                    signature: readable(1),
                    content: digest(1),
                }),
                Timestamp(10),
            )?;
            transaction.store_admission(folder, FolderAdmission::AwaitingDecision)
        });
        assert_eq!(
            store.folders().unwrap(),
            vec![FolderRecord {
                folder,
                root: PathBuf::from("/Users/anna/Downloads"),
                enrolled_at: Timestamp(1),
                admission: FolderAdmission::AwaitingDecision,
            }]
        );
        write(&mut store, |transaction| {
            transaction.store_admission(
                folder,
                FolderAdmission::Collecting {
                    decided_at: Timestamp(99),
                },
            )
        });
        assert_eq!(
            store.folders().unwrap()[0].admission,
            FolderAdmission::Collecting {
                decided_at: Timestamp(99)
            }
        );
        {
            let transaction = store.begin().unwrap();
            assert!(
                transaction
                    .enroll_folder(Path::new("/Users/anna/Downloads"), Timestamp(2))
                    .is_err()
            );
        }
        write(&mut store, |transaction| transaction.withdraw_folder(folder));
        assert_eq!(store.folders().unwrap(), vec![]);
        assert_eq!(store.path_state(&path).unwrap(), None);
        assert!(store.content_record(&digest(1)).unwrap().is_some());
    }

    #[test]
    fn the_connection_keeps_a_suspension_only_for_the_same_token() {
        let mut store = StateStore::open_in_memory().unwrap();
        assert_eq!(store.connection_record().unwrap(), None);
        write(&mut store, |transaction| {
            transaction.store_connection("https://archive.example.org", "fingerprint-1")?;
            transaction.store_suspension(Some((SuspensionReason::CredentialRefused, Timestamp(5))))
        });
        let suspended = ConnectionRecord {
            archive_origin: "https://archive.example.org".to_owned(),
            credential_fingerprint: "fingerprint-1".to_owned(),
            suspension: Some((SuspensionReason::CredentialRefused, Timestamp(5))),
        };
        assert_eq!(store.connection_record().unwrap(), Some(suspended.clone()));
        write(&mut store, |transaction| {
            transaction.store_connection("https://archive.example.org", "fingerprint-1")
        });
        assert_eq!(store.connection_record().unwrap(), Some(suspended));
        write(&mut store, |transaction| {
            transaction.store_connection("https://other.example.org", "fingerprint-2")
        });
        assert_eq!(
            store.connection_record().unwrap(),
            Some(ConnectionRecord {
                archive_origin: "https://other.example.org".to_owned(),
                credential_fingerprint: "fingerprint-2".to_owned(),
                suspension: None,
            })
        );
    }

    #[test]
    fn directory_contents_lists_the_rows_of_one_directory_and_its_child_keys() {
        let (mut store, folder) = store_with_folder("/Users/anna/Documents");
        let stable = |inode| {
            PathTransition::Store(PathState::Stable {
                signature: readable(inode),
            })
        };
        write(&mut store, |transaction| {
            transaction.apply_path(&key(folder, "", "top.pdf"), &stable(1), Timestamp(1))?;
            transaction.apply_path(&key(folder, "Scans", "a.pdf"), &stable(2), Timestamp(1))?;
            transaction.apply_path(&key(folder, "Scans/2026", "b.pdf"), &stable(3), Timestamp(1))?;
            transaction.apply_path(&key(folder, "Scans/2025", "c.pdf"), &stable(4), Timestamp(1))?;
            transaction.apply_path(&key(folder, "Scanned", "d.pdf"), &stable(5), Timestamp(1))
        });
        let DirectoryContents {
            files,
            subdirectories: children,
        } = store
            .directory_contents(folder, &DirectoryKey::from_stored_text("Scans".to_owned()))
            .unwrap();
        assert_eq!(
            files,
            vec![(EntryName::new("a.pdf"), PathState::Stable { signature: readable(2) })]
        );
        assert_eq!(
            children,
            vec![
                DirectoryKey::from_stored_text("Scans/2025".to_owned()),
                DirectoryKey::from_stored_text("Scans/2026".to_owned())
            ]
        );
        let DirectoryContents {
            files: root_files,
            subdirectories: root_children,
        } = store.directory_contents(folder, &DirectoryKey::root()).unwrap();
        assert_eq!(root_files.len(), 1);
        assert_eq!(
            root_children,
            vec![
                DirectoryKey::from_stored_text("Scanned".to_owned()),
                DirectoryKey::from_stored_text("Scans".to_owned())
            ]
        );

        write(&mut store, |transaction| {
            transaction.remove_subtrees(
                folder,
                &[DirectoryKey::from_stored_text("Scans".to_owned())],
                Timestamp(9),
            )
        });
        let remaining = store
            .directory_contents(folder, &DirectoryKey::root())
            .unwrap()
            .subdirectories;
        assert_eq!(remaining, vec![DirectoryKey::from_stored_text("Scanned".to_owned())]);
        assert_eq!(store.state_counts().unwrap().paths_awaiting_digest, 2);
    }

    /// Three folders: one collecting and available, one surveying, one collecting but unavailable.
    fn populated_store(now: Timestamp) -> (StateStore, [FolderIdentifier; 3]) {
        let store = StateStore::open_in_memory().unwrap();
        let transaction = store.begin().unwrap();
        let collecting = transaction
            .enroll_folder(Path::new("/collecting"), Timestamp(1))
            .unwrap();
        let surveying = transaction
            .enroll_folder(Path::new("/surveying"), Timestamp(1))
            .unwrap();
        let unavailable = transaction
            .enroll_folder(Path::new("/unavailable"), Timestamp(1))
            .unwrap();
        transaction
            .store_admission(
                collecting,
                FolderAdmission::Collecting {
                    decided_at: Timestamp(50 * MINUTE),
                },
            )
            .unwrap();
        transaction
            .store_admission(
                unavailable,
                FolderAdmission::Collecting {
                    decided_at: Timestamp(50 * MINUTE),
                },
            )
            .unwrap();
        let timing = TimingPolicy::default();
        let store_path = |path: &PathKey, state: PathState, at: i64| {
            transaction
                .apply_path(path, &PathTransition::Store(state), Timestamp(at))
                .unwrap();
        };
        let stabilizing = |observed_at: i64| PathState::Stabilizing {
            signature: signature(9, 10),
            observed_at: Timestamp(observed_at),
        };
        store_path(
            &key(collecting, "", "due.pdf"),
            stabilizing(now.0 - milliseconds(timing.stabilization_interval)),
            1,
        );
        store_path(&key(collecting, "Later", "later.pdf"), stabilizing(now.0), 1);
        store_path(&key(unavailable, "", "due.pdf"), stabilizing(0), 1);
        store_path(
            &key(collecting, "", "backlog.pdf"),
            PathState::Stable { signature: readable(1) },
            10 * MINUTE,
        );
        store_path(
            &key(collecting, "", "arrival.pdf"),
            PathState::Stable { signature: readable(2) },
            60 * MINUTE,
        );
        store_path(
            &key(surveying, "", "survey.pdf"),
            PathState::Stable { signature: readable(3) },
            5 * MINUTE,
        );
        store_path(
            &key(unavailable, "", "gone.pdf"),
            PathState::Stable { signature: readable(4) },
            5 * MINUTE,
        );
        let digested = |inode, byte| PathState::Digested {
            signature: readable(inode),
            content: digest(byte),
        };
        store_path(
            &key(collecting, "", "unresolved_backlog.pdf"),
            digested(10, 0x10),
            10 * MINUTE,
        );
        store_path(
            &key(collecting, "", "unresolved_arrival.pdf"),
            digested(11, 0x11),
            60 * MINUTE,
        );
        store_path(
            &key(surveying, "", "unresolved_survey.pdf"),
            digested(12, 0x12),
            5 * MINUTE,
        );
        store_path(
            &key(unavailable, "", "unresolved_gone.pdf"),
            digested(13, 0x13),
            5 * MINUTE,
        );
        store_path(&key(collecting, "", "stale.pdf"), digested(14, 0x14), 10 * MINUTE);
        store_path(&key(surveying, "", "stale_survey.pdf"), digested(15, 0x15), 10 * MINUTE);
        store_path(
            &key(collecting, "", "fresh_backlog.pdf"),
            digested(16, 0x16),
            10 * MINUTE,
        );
        store_path(
            &key(collecting, "", "fresh_arrival.pdf"),
            digested(17, 0x17),
            60 * MINUTE,
        );
        store_path(
            &key(collecting, "Copies", "fresh_arrival_copy.pdf"),
            digested(18, 0x17),
            61 * MINUTE,
        );
        store_path(&key(surveying, "", "fresh_survey.pdf"), digested(19, 0x18), 10 * MINUTE);
        store_path(&key(collecting, "", "backing_off.pdf"), digested(20, 0x19), 10 * MINUTE);
        store_path(&key(collecting, "", "present.pdf"), digested(21, 0x1A), 10 * MINUTE);
        store_path(&key(collecting, "", "received.pdf"), digested(22, 0x1B), 10 * MINUTE);
        let absent = |looked_up_at: i64, retry_not_before: Option<i64>| ArchiveStanding::Absent {
            looked_up_at: Timestamp(looked_up_at),
            failures: SubmissionFailures {
                count: 1,
                retry_not_before: retry_not_before.map(Timestamp),
            },
        };
        let stale = now.0 - milliseconds(timing.lookup_validity);
        transaction.store_standing(&digest(0x14), &absent(stale, None)).unwrap();
        transaction.store_standing(&digest(0x15), &absent(stale, None)).unwrap();
        transaction
            .store_standing(&digest(0x16), &absent(stale + 1, None))
            .unwrap();
        transaction
            .store_standing(&digest(0x17), &absent(now.0 - MINUTE, None))
            .unwrap();
        transaction
            .store_standing(&digest(0x18), &absent(now.0 - MINUTE, None))
            .unwrap();
        transaction
            .store_standing(&digest(0x19), &absent(now.0 - MINUTE, Some(now.0 + MINUTE)))
            .unwrap();
        let present = |last, status, status_read_at: Option<i64>, received_at: Option<i64>| {
            ArchiveStanding::Present(PresentDocument {
                document: document(last),
                status: Some(status),
                status_read_at: status_read_at.map(Timestamp),
                received_at: received_at.map(Timestamp),
            })
        };
        transaction
            .store_standing(&digest(0x1A), &present('a', DocumentStatus::Archived, None, None))
            .unwrap();
        transaction
            .store_standing(
                &digest(0x1B),
                &present(
                    'b',
                    DocumentStatus::Processing,
                    Some(now.0 - MINUTE),
                    Some(now.0 - 2 * MINUTE),
                ),
            )
            .unwrap();
        transaction
            .store_standing(
                &digest(0x1C),
                &present('c', DocumentStatus::Processing, Some(now.0), Some(now.0 - MINUTE)),
            )
            .unwrap();
        transaction
            .store_standing(
                &digest(0x1D),
                &present(
                    'd',
                    DocumentStatus::Archived,
                    Some(now.0 - MINUTE),
                    Some(now.0 - MINUTE),
                ),
            )
            .unwrap();
        store_path(&key(surveying, "", "refused.pdf"), digested(23, 0x1E), 10 * MINUTE);
        store_path(&key(surveying, "", "failing.pdf"), digested(24, 0x1F), 10 * MINUTE);
        transaction
            .store_standing(&digest(0x1E), &ArchiveStanding::Refused(RefusalReason::UnacceptedKind))
            .unwrap();
        transaction
            .store_standing(
                &digest(0x1F),
                &ArchiveStanding::Absent {
                    looked_up_at: Timestamp(now.0 - MINUTE),
                    failures: SubmissionFailures {
                        count: 3,
                        retry_not_before: Some(Timestamp(now.0 + 10 * MINUTE)),
                    },
                },
            )
            .unwrap();
        transaction
            .store_connection("https://archive.example.org", "fingerprint")
            .unwrap();
        transaction.commit().unwrap();
        (store, [collecting, surveying, unavailable])
    }

    #[test]
    fn work_candidates_come_from_available_folders_with_arrivals_first_within_each_lane_limit() {
        let now = Timestamp(100 * MINUTE);
        let (store, [collecting, surveying, _]) = populated_store(now);
        let timing = TimingPolicy::default();
        let capacity = LaneCapacity::default();
        let mut reservations = Reservations::default();
        reservations
            .contents
            .insert(digest(0x40), ContentReservation::Submitting);

        let candidates = store
            .work_candidates(&reservations, &capacity, &[collecting, surveying], now, &timing)
            .unwrap();

        assert_eq!(
            candidates.due_directories,
            vec![(collecting, DirectoryKey::root(), false)]
        );
        assert_eq!(
            candidates
                .stable_paths
                .iter()
                .map(|(path, _)| path.clone())
                .collect::<Vec<_>>(),
            vec![key(collecting, "", "arrival.pdf"), key(surveying, "", "survey.pdf")]
        );
        assert_eq!(
            candidates.contents_to_look_up,
            vec![digest(0x11), digest(0x12), digest(0x10), digest(0x14)]
        );
        let submissions: Vec<(ContentDigest, Vec<PathKey>)> = candidates
            .contents_to_submit
            .iter()
            .map(|(record, sources)| (record.digest, sources.iter().map(|(path, _)| path.clone()).collect()))
            .collect();
        assert_eq!(
            submissions,
            vec![
                (
                    digest(0x17),
                    vec![
                        key(collecting, "", "fresh_arrival.pdf"),
                        key(collecting, "Copies", "fresh_arrival_copy.pdf")
                    ]
                ),
                (digest(0x16), vec![key(collecting, "", "fresh_backlog.pdf")]),
            ]
        );
        assert_eq!(candidates.documents_to_follow, vec![(digest(0x1B), document('b'))]);
    }

    #[test]
    fn lane_limits_count_the_free_capacity_plus_the_reservations() {
        let now = Timestamp(100 * MINUTE);
        let (store, [collecting, surveying, _]) = populated_store(now);
        let timing = TimingPolicy::default();
        let capacity = LaneCapacity {
            digest: 1,
            submission: 1,
            ..LaneCapacity::default()
        };
        let mut reservations = Reservations::default();
        reservations.paths.insert(key(collecting, "", "arrival.pdf"));

        let candidates = store
            .work_candidates(&reservations, &capacity, &[collecting, surveying], now, &timing)
            .unwrap();

        assert_eq!(candidates.stable_paths.len(), 2);
        assert_eq!(candidates.contents_to_submit.len(), 1);
        assert_eq!(candidates.contents_to_submit[0].0.digest, digest(0x17));
    }

    #[test]
    fn the_status_queries_count_what_the_rows_hold() {
        let now = Timestamp(100 * MINUTE);
        let (store, [collecting, surveying, _]) = populated_store(now);
        let timing = TimingPolicy::default();

        assert_eq!(
            store.survey_progress(surveying).unwrap(),
            SurveyProgress {
                initial_walk_completed: false,
                paths_stabilizing_or_stable: 1,
                contents_unresolved: 1
            }
        );
        assert_eq!(
            store.backlog_summary(&[collecting]).unwrap(),
            BacklogSummary {
                folders: vec![collecting],
                candidate_files: 9,
                files_already_archived: 2,
                files_deleted_from_archive: 0,
                files_refused_by_archive: 0,
                files_new: 5,
                new_contents: 4,
                excluded_files: 0,
                excluded_files_by_reason: BTreeMap::new(),
                disregarded_files: BTreeMap::new(),
                unreadable_files: 0,
                files_under_examination: 6,
            }
        );
        assert_eq!(
            store.state_counts().unwrap(),
            StateCounts {
                paths_stabilizing: 3,
                paths_awaiting_digest: 4,
                paths_digested: 15,
                paths_excluded: 0,
                paths_unreadable: 0,
                contents_unresolved: 4,
                contents_awaiting_submission: 7,
                contents_present: 4,
                contents_deleted: 0,
                contents_refused: 1,
                contents_failing: 1,
            }
        );
        let receipts = store.recent_receipts(2).unwrap();
        let link = |last: char| format!("https://archive.example.org/documents/{}", document(last).as_str());
        assert_eq!(
            receipts,
            vec![
                Receipt {
                    document: document('c'),
                    document_link: link('c'),
                    file_name: digest(0x1C).hexadecimal(),
                    received_at: Timestamp(now.0 - MINUTE),
                    status: Some(DocumentStatus::Processing),
                },
                Receipt {
                    document: document('d'),
                    document_link: link('d'),
                    file_name: digest(0x1D).hexadecimal(),
                    received_at: Timestamp(now.0 - MINUTE),
                    status: Some(DocumentStatus::Archived),
                },
            ]
        );
        assert_eq!(store.recent_receipts(3).unwrap()[2].file_name, "received.pdf");
        assert_eq!(
            store.next_deadline(now, &timing).unwrap(),
            Some(Timestamp(milliseconds(timing.stabilization_interval)))
        );
        assert_eq!(
            store.contents_needing_attention().unwrap(),
            vec![
                ContentAttention {
                    file_name: "refused.pdf".to_owned(),
                    refusal: Some(RefusalReason::UnacceptedKind),
                    failures: 0,
                },
                ContentAttention {
                    file_name: "failing.pdf".to_owned(),
                    refusal: None,
                    failures: 3,
                },
            ]
        );
    }

    #[test]
    fn the_next_deadline_includes_the_follow_of_a_received_document() {
        let now = Timestamp(100 * MINUTE);
        let (store, _) = populated_store(now);
        let timing = TimingPolicy {
            stabilization_interval: Duration::from_secs(1_000_000),
            unreadable_retry_interval: Duration::from_secs(1_000_000),
            ..TimingPolicy::default()
        };
        assert_eq!(
            store.next_deadline(now, &timing).unwrap(),
            Some(Timestamp(
                now.0 - MINUTE + milliseconds(timing.document_follow_interval)
            ))
        );
    }

    /// The CHECK constraints repeat the variants of the Rust enums, so a row that no state can
    /// produce fails at write time. This keeps the two lists equal.
    #[test]
    fn the_check_constraints_list_exactly_the_stored_names_of_each_enum() {
        let mut checks: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for migration in MIGRATIONS {
            for line in migration.lines() {
                let Some((_, rest)) = line.split_once("CHECK (") else {
                    continue;
                };
                let Some((column, list)) = rest.split_once(" IN (") else {
                    continue;
                };
                let Some((list, _)) = list.split_once(')') else {
                    continue;
                };
                let names: Vec<String> = list
                    .split(',')
                    .filter_map(|name| name.trim().strip_prefix('\'').and_then(|name| name.strip_suffix('\'')))
                    .map(str::to_owned)
                    .collect();
                if !names.is_empty() {
                    checks.insert(column.trim().to_owned(), names);
                }
            }
        }
        fn names<Variant>(table: &[(Variant, &str)]) -> Vec<String> {
            table.iter().map(|(_, name)| (*name).to_owned()).collect()
        }
        let expected: BTreeMap<String, Vec<String>> = [
            ("suspension_reason", names(STORED_SUSPENSION_REASONS)),
            (
                "admission",
                STORED_ADMISSIONS.iter().map(|name| (*name).to_owned()).collect(),
            ),
            (
                "archive_standing",
                STORED_STANDINGS.iter().map(|name| (*name).to_owned()).collect(),
            ),
            ("refusal_reason", names(STORED_REFUSAL_REASONS)),
            (
                "lifecycle",
                STORED_LIFECYCLES.iter().map(|name| (*name).to_owned()).collect(),
            ),
            ("exclusion_reason", names(STORED_EXCLUSION_REASONS)),
        ]
        .into_iter()
        .map(|(column, names)| (column.to_owned(), names))
        .collect();
        assert_eq!(checks, expected);
    }

    #[test]
    fn the_stored_names_match_the_name_of_each_variant() {
        let admissions = [
            FolderAdmission::Surveying,
            FolderAdmission::AwaitingDecision,
            FolderAdmission::Collecting {
                decided_at: Timestamp(1),
            },
        ];
        assert_eq!(
            admissions.iter().map(admission_name).collect::<Vec<_>>(),
            STORED_ADMISSIONS
        );
        let standings = [
            ArchiveStanding::Unresolved,
            ArchiveStanding::Absent {
                looked_up_at: Timestamp(1),
                failures: SubmissionFailures::default(),
            },
            ArchiveStanding::Present(PresentDocument {
                document: document('1'),
                status: None,
                status_read_at: None,
                received_at: None,
            }),
            ArchiveStanding::Deleted,
            ArchiveStanding::Refused(RefusalReason::TooLarge),
        ];
        assert_eq!(
            standings.iter().map(standing_name).collect::<Vec<_>>(),
            STORED_STANDINGS
        );
        let lifecycles = [
            PathState::Stabilizing {
                signature: signature(1, 1),
                observed_at: Timestamp(1),
            },
            PathState::Stable { signature: readable(1) },
            PathState::Digested {
                signature: readable(1),
                content: digest(1),
            },
            PathState::Excluded {
                signature: signature(1, 1),
                reason: ExclusionReason::EmptyFile,
            },
            PathState::Unreadable {
                signature: readable(1),
                since: Timestamp(1),
                cause: String::new(),
            },
        ];
        assert_eq!(
            lifecycles.iter().map(lifecycle_name).collect::<Vec<_>>(),
            STORED_LIFECYCLES
        );
    }
}
