//! The only way the file system reaches the state: a listing of one directory, compared with the
//! rows stored for that directory. Events from the watcher, the walker, a rescan flag, and the
//! start of the app all become listings, so a lost event costs latency and never correctness.

use crate::domain_types::{DirectoryKey, EntryName, FileSignature, FolderIdentifier, PathKey, Timestamp};
use crate::path_lifecycle::{PathEvent, PathState};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectoryListing {
    pub folder: FolderIdentifier,
    pub directory: DirectoryKey,
    pub outcome: ListingOutcome,
    pub listed_at: Timestamp,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListingOutcome {
    /// Entries that passed `classify_entry_name`. Disregarded names never appear here.
    Listed {
        files: Vec<(EntryName, FileSignature)>,
        subdirectories: Vec<EntryName>,
    },
    /// The directory exists and could not be read. Removes nothing.
    Unreadable { cause: String },
    /// The directory does not exist. Everything stored at and below it is gone.
    Vanished,
}

/// The effects of one listing on the stored state.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reconciliation {
    pub path_events: Vec<(PathKey, PathEvent)>,
    /// Stored rows at or below these keys are deleted (a subdirectory the listing lacks, or the
    /// listed directory itself when it vanished).
    pub removed_subtrees: Vec<DirectoryKey>,
    /// Subdirectories with no stored row below them: the coordinator lists them recursively, so
    /// a directory created while its event was lost is still found.
    pub unexplored_subdirectories: Vec<DirectoryKey>,
}

/// Pure and idempotent: reconciling the same listing twice produces events that `advance_path`
/// turns into `Unchanged`.
///
/// `stored_files` are the rows whose directory is exactly `listing.directory`.
/// `stored_subdirectories` are the keys of child directories that have rows below them.
///
/// A root that vanished or could not be read is the folder's availability, never a removal, so
/// an unmounted volume keeps its rows. The coordinator routes such a root listing to the
/// availability region, and this function changes nothing for it either way.
pub fn reconcile_directory(
    listing: &DirectoryListing,
    stored_files: &[(EntryName, PathState)],
    stored_subdirectories: &[DirectoryKey],
) -> Reconciliation {
    let mut reconciliation = Reconciliation::default();
    let (files, subdirectories) = match &listing.outcome {
        ListingOutcome::Listed { files, subdirectories } => (files, subdirectories),
        ListingOutcome::Unreadable { .. } => return reconciliation,
        ListingOutcome::Vanished => {
            if !listing.directory.is_root() {
                reconciliation.removed_subtrees.push(listing.directory.clone());
            }
            return reconciliation;
        }
    };
    let path_key = |name: &EntryName| PathKey {
        folder: listing.folder,
        directory: listing.directory.clone(),
        name: name.clone(),
    };
    for (name, signature) in files {
        reconciliation.path_events.push((
            path_key(name),
            PathEvent::Listed {
                signature: *signature,
                at: listing.listed_at,
            },
        ));
    }
    for (name, _) in stored_files {
        if !files.iter().any(|(listed, _)| listed == name) {
            reconciliation.path_events.push((path_key(name), PathEvent::NotListed));
        }
    }
    let listed_subdirectories: Vec<DirectoryKey> = subdirectories
        .iter()
        .map(|name| listing.directory.child(name))
        .collect();
    for stored in stored_subdirectories {
        if !listed_subdirectories.contains(stored) {
            reconciliation.removed_subtrees.push(stored.clone());
        }
    }
    for listed in listed_subdirectories {
        if !stored_subdirectories.contains(&listed) {
            reconciliation.unexplored_subdirectories.push(listed);
        }
    }
    reconciliation
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate_classification::classify_signature;

    const FOLDER: FolderIdentifier = FolderIdentifier::new(3);

    fn signature(inode: u64) -> FileSignature {
        FileSignature {
            device: 1,
            inode,
            byte_size: 100,
            modification_nanoseconds: 5,
            status_change_nanoseconds: 5,
            dataless: false,
        }
    }

    fn name(text: &str) -> EntryName {
        EntryName::new(text)
    }

    fn stable(inode: u64) -> PathState {
        PathState::Stable {
            signature: classify_signature(signature(inode)).unwrap(),
        }
    }

    fn key(directory: &DirectoryKey, text: &str) -> PathKey {
        PathKey {
            folder: FOLDER,
            directory: directory.clone(),
            name: name(text),
        }
    }

    fn listing(directory: DirectoryKey, outcome: ListingOutcome) -> DirectoryListing {
        DirectoryListing {
            folder: FOLDER,
            directory,
            outcome,
            listed_at: Timestamp(1_000),
        }
    }

    #[test]
    fn a_listing_reports_every_entry_and_removes_only_what_a_successful_listing_lacks() {
        let downloads = DirectoryKey::from_stored_text("Downloads".to_owned());
        let listed = listing(
            downloads.clone(),
            ListingOutcome::Listed {
                files: vec![
                    (name("Invoice.pdf"), signature(1)),
                    (name("Rechnung.pdf"), signature(2)),
                ],
                subdirectories: vec![name("Scans"), name("Archive")],
            },
        );
        let stored_files = [(name("Invoice.pdf"), stable(1)), (name("Old.pdf"), stable(9))];
        let stored_subdirectories = [downloads.child(&name("Scans")), downloads.child(&name("Gone"))];

        let reconciliation = reconcile_directory(&listed, &stored_files, &stored_subdirectories);

        assert_eq!(
            reconciliation,
            Reconciliation {
                path_events: vec![
                    (
                        key(&downloads, "Invoice.pdf"),
                        PathEvent::Listed {
                            signature: signature(1),
                            at: Timestamp(1_000)
                        }
                    ),
                    (
                        key(&downloads, "Rechnung.pdf"),
                        PathEvent::Listed {
                            signature: signature(2),
                            at: Timestamp(1_000)
                        }
                    ),
                    (key(&downloads, "Old.pdf"), PathEvent::NotListed),
                ],
                removed_subtrees: vec![downloads.child(&name("Gone"))],
                unexplored_subdirectories: vec![downloads.child(&name("Archive"))],
            }
        );
    }

    #[test]
    fn a_decomposed_subdirectory_name_finds_the_rows_the_walker_stored() {
        let root = DirectoryKey::root();
        let listed = listing(
            root.clone(),
            ListingOutcome::Listed {
                files: vec![],
                subdirectories: vec![name("Vertra\u{0308}ge")],
            },
        );
        let stored = [root.child(&name("Vertr\u{00E4}ge"))];
        assert_eq!(reconcile_directory(&listed, &[], &stored), Reconciliation::default());
    }

    #[test]
    fn an_unreadable_listing_changes_nothing() {
        let scans = DirectoryKey::from_stored_text("Scans".to_owned());
        let unreadable = listing(
            scans.clone(),
            ListingOutcome::Unreadable {
                cause: "permission denied".to_owned(),
            },
        );
        let stored = [(name("scan_0001.pdf"), stable(4))];
        assert_eq!(
            reconcile_directory(&unreadable, &stored, &[scans.child(&name("2025"))]),
            Reconciliation::default()
        );
    }

    #[test]
    fn a_vanished_subdirectory_removes_its_subtree_but_a_vanished_root_removes_nothing() {
        let scans = DirectoryKey::from_stored_text("Scans".to_owned());
        let stored = [(name("scan_0001.pdf"), stable(4))];
        assert_eq!(
            reconcile_directory(&listing(scans.clone(), ListingOutcome::Vanished), &stored, &[]),
            Reconciliation {
                removed_subtrees: vec![scans],
                ..Reconciliation::default()
            }
        );
        assert_eq!(
            reconcile_directory(&listing(DirectoryKey::root(), ListingOutcome::Vanished), &stored, &[]),
            Reconciliation::default()
        );
    }
}
