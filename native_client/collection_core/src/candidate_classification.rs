//! Which entries get a row, which signatures may be opened, and which leading bytes the archive
//! accepts. Every rule here is decided from a name, a signature, or twelve bytes, never from an
//! opened file.

use crate::domain_types::{EntryName, FileSignature};

/// The server's `MAXIMUM_DOCUMENT_BYTES`, decimal.
pub const MAXIMUM_CONTENT_BYTES: u64 = 25_000_000;

/// What `lstat` says an entry is, before anything is opened. Symbolic links are never followed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    RegularFile,
    Directory,
    SymbolicLink,
    Special,
}

/// Why an entry gets no row at all. Decided from its name and kind alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub enum DisregardReason {
    HiddenEntry,
    AppleDoubleCompanion,
    /// `.crdownload`, `.part`, and a `.download` package.
    IncompleteDownload,
    PackageDirectory,
    SymbolicLink,
    SpecialFile,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameDisposition {
    Admitted,
    Disregarded(DisregardReason),
}

/// Directories macOS presents as single files. Open question 6 of the design.
pub const PACKAGE_EXTENSIONS: &[&str] = &[
    "app",
    "bundle",
    "download",
    "framework",
    "key",
    "numbers",
    "pages",
    "photoslibrary",
    "plugin",
    "rtfd",
];

const INCOMPLETE_DOWNLOAD_FILE_EXTENSIONS: &[&str] = &["crdownload", "part"];

/// The one list of name rules. A directory that is disregarded is never descended into.
pub fn classify_entry_name(name: &EntryName, kind: EntryKind) -> NameDisposition {
    let text = name.as_os_str().to_string_lossy();
    let extension = text
        .rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase());
    let has_extension = |candidates: &[&str]| extension.as_deref().is_some_and(|found| candidates.contains(&found));
    let reason = match kind {
        EntryKind::SymbolicLink => Some(DisregardReason::SymbolicLink),
        EntryKind::Special => Some(DisregardReason::SpecialFile),
        _ if text.starts_with("._") => Some(DisregardReason::AppleDoubleCompanion),
        _ if text.starts_with('.') => Some(DisregardReason::HiddenEntry),
        EntryKind::RegularFile if has_extension(INCOMPLETE_DOWNLOAD_FILE_EXTENSIONS) => {
            Some(DisregardReason::IncompleteDownload)
        }
        EntryKind::Directory if has_extension(&["download"]) => Some(DisregardReason::IncompleteDownload),
        EntryKind::Directory if has_extension(PACKAGE_EXTENSIONS) => Some(DisregardReason::PackageDirectory),
        EntryKind::RegularFile | EntryKind::Directory => None,
    };
    match reason {
        Some(reason) => NameDisposition::Disregarded(reason),
        None => NameDisposition::Admitted,
    }
}

/// Why a path with a row is no candidate. Stored in `path_observations.exclusion_reason`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub enum ExclusionReason {
    EmptyFile,
    ExceedsSizeLimit,
    CloudPlaceholder,
    UnrecognizedContent,
}

/// A signature that may be opened: not empty, at most `MAXIMUM_CONTENT_BYTES`, not dataless.
/// Only `classify_signature` constructs it. Every function that opens a file takes one and
/// compares a fresh `lstat` with it before `open`, so a placeholder is never read and an oversized
/// video is never digested.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ReadableSignature(FileSignature);

impl ReadableSignature {
    pub fn signature(&self) -> &FileSignature {
        &self.0
    }
}

pub fn classify_signature(signature: FileSignature) -> Result<ReadableSignature, ExclusionReason> {
    if signature.dataless {
        Err(ExclusionReason::CloudPlaceholder)
    } else if signature.byte_size == 0 {
        Err(ExclusionReason::EmptyFile)
    } else if signature.byte_size > MAXIMUM_CONTENT_BYTES {
        Err(ExclusionReason::ExceedsSizeLimit)
    } else {
        Ok(ReadableSignature(signature))
    }
}

/// The kinds the archive accepts, identified by leading bytes exactly as `identifySourceFile` in
/// `src/ingestion/source_file.ts`. A test compares the two tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContentKind {
    PortableDocument,
    JointPhotographicImage,
    PortableNetworkGraphic,
    WebPicture,
}

impl ContentKind {
    pub fn media_type(self) -> &'static str {
        match self {
            ContentKind::PortableDocument => "application/pdf",
            ContentKind::JointPhotographicImage => "image/jpeg",
            ContentKind::PortableNetworkGraphic => "image/png",
            ContentKind::WebPicture => "image/webp",
        }
    }
}

/// Bytes expected at an offset. A kind matches when every one of its signatures matches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LeadingByteSignature {
    pub offset: usize,
    pub bytes: &'static [u8],
}

pub const LEADING_BYTE_SIGNATURES: &[(ContentKind, &[LeadingByteSignature])] = &[
    (
        ContentKind::PortableDocument,
        &[LeadingByteSignature {
            offset: 0,
            bytes: &[0x25, 0x50, 0x44, 0x46, 0x2d],
        }],
    ),
    (
        ContentKind::JointPhotographicImage,
        &[LeadingByteSignature {
            offset: 0,
            bytes: &[0xff, 0xd8, 0xff],
        }],
    ),
    (
        ContentKind::PortableNetworkGraphic,
        &[LeadingByteSignature {
            offset: 0,
            bytes: &[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        }],
    ),
    (
        ContentKind::WebPicture,
        &[
            LeadingByteSignature {
                offset: 0,
                bytes: &[0x52, 0x49, 0x46, 0x46],
            },
            LeadingByteSignature {
                offset: 8,
                bytes: &[0x57, 0x45, 0x42, 0x50],
            },
        ],
    ),
];

/// The digest lane reads this many bytes before it decides whether to read the rest.
pub const LEADING_BYTES_LENGTH: usize = 12;

pub fn identify_content_kind(leading_bytes: &[u8]) -> Option<ContentKind> {
    LEADING_BYTE_SIGNATURES
        .iter()
        .find(|(_, signatures)| {
            signatures.iter().all(|signature| {
                leading_bytes.get(signature.offset..signature.offset + signature.bytes.len()) == Some(signature.bytes)
            })
        })
        .map(|(kind, _)| *kind)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn name(text: &str) -> EntryName {
        EntryName::new(text)
    }

    #[test]
    fn the_name_filter_disregards_what_the_design_lists_and_admits_the_rest() {
        use EntryKind as Kind;
        use NameDisposition::{Admitted, Disregarded};
        let cases = [
            ("Invoice.pdf", Kind::RegularFile, Admitted),
            ("Scans", Kind::Directory, Admitted),
            (
                "invoice.PDF.crdownload",
                Kind::RegularFile,
                Disregarded(DisregardReason::IncompleteDownload),
            ),
            (
                "invoice.pdf.part",
                Kind::RegularFile,
                Disregarded(DisregardReason::IncompleteDownload),
            ),
            (
                "Kontoauszug.pdf.download",
                Kind::Directory,
                Disregarded(DisregardReason::IncompleteDownload),
            ),
            ("Kontoauszug.pdf.download", Kind::RegularFile, Admitted),
            (
                "Budget.numbers",
                Kind::Directory,
                Disregarded(DisregardReason::PackageDirectory),
            ),
            ("Budget.numbers", Kind::RegularFile, Admitted),
            (
                ".DS_Store",
                Kind::RegularFile,
                Disregarded(DisregardReason::HiddenEntry),
            ),
            (".git", Kind::Directory, Disregarded(DisregardReason::HiddenEntry)),
            (
                "._Invoice.pdf",
                Kind::RegularFile,
                Disregarded(DisregardReason::AppleDoubleCompanion),
            ),
            (
                "Invoice.pdf",
                Kind::SymbolicLink,
                Disregarded(DisregardReason::SymbolicLink),
            ),
            ("printer", Kind::Special, Disregarded(DisregardReason::SpecialFile)),
        ];
        for (text, kind, expected) in cases {
            assert_eq!(classify_entry_name(&name(text), kind), expected, "{text} as {kind:?}");
        }
    }

    fn signature(byte_size: u64, dataless: bool) -> FileSignature {
        FileSignature {
            device: 1,
            inode: 2,
            byte_size,
            modification_nanoseconds: 3,
            status_change_nanoseconds: 4,
            dataless,
        }
    }

    #[test]
    fn a_signature_is_readable_only_when_it_is_not_empty_within_the_limit_and_not_a_placeholder() {
        assert_eq!(classify_signature(signature(0, false)), Err(ExclusionReason::EmptyFile));
        assert_eq!(
            classify_signature(signature(25_000_001, false)),
            Err(ExclusionReason::ExceedsSizeLimit)
        );
        assert_eq!(
            classify_signature(signature(25_000_001, true)),
            Err(ExclusionReason::CloudPlaceholder)
        );
        let readable = classify_signature(signature(25_000_000, false)).unwrap();
        assert_eq!(readable.signature(), &signature(25_000_000, false));
    }

    #[test]
    fn leading_bytes_identify_each_accepted_kind_and_nothing_else() {
        let cases: [(&[u8], Option<ContentKind>); 7] = [
            (b"%PDF-1.7 rest", Some(ContentKind::PortableDocument)),
            (&[0xff, 0xd8, 0xff, 0xe0], Some(ContentKind::JointPhotographicImage)),
            (
                &[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0],
                Some(ContentKind::PortableNetworkGraphic),
            ),
            (b"RIFF\x00\x00\x00\x00WEBPVP8 ", Some(ContentKind::WebPicture)),
            (b"RIFF\x00\x00\x00\x00WAVE", None),
            (b"Hello", None),
            (b"%PDF", None),
        ];
        for (bytes, expected) in cases {
            assert_eq!(identify_content_kind(bytes), expected, "{bytes:?}");
        }
    }

    #[test]
    fn the_leading_bytes_length_covers_every_signature() {
        let furthest = LEADING_BYTE_SIGNATURES
            .iter()
            .flat_map(|(_, signatures)| signatures.iter())
            .map(|signature| signature.offset + signature.bytes.len())
            .max()
            .unwrap();
        assert_eq!(furthest, LEADING_BYTES_LENGTH);
    }

    /// The server identifies an upload by the same leading bytes, so the two tables must agree.
    /// This reads `fileSignatures` out of the TypeScript source line by line.
    #[test]
    fn the_leading_byte_signatures_equal_the_servers_source_file_table() {
        let source = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../src/ingestion/source_file.ts"
        ))
        .unwrap();
        let table_start = source.find("const fileSignatures").unwrap();
        let table = &source[table_start..];
        let table = &table[..table.find("\n}").unwrap()];

        let mut server: BTreeMap<String, Vec<(usize, Vec<u8>)>> = BTreeMap::new();
        let mut media_type = None;
        for line in table.lines().skip(1) {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix('"') {
                let (name, _) = rest.split_once('"').unwrap();
                media_type = Some(name.to_owned());
            }
            if let Some(rest) = line.split_once("offset: ").map(|(_, rest)| rest) {
                let (offset, rest) = rest.split_once(',').unwrap();
                let (_, bytes) = rest.split_once('[').unwrap();
                let (bytes, _) = bytes.split_once(']').unwrap();
                let bytes = bytes
                    .split(',')
                    .map(|byte| u8::from_str_radix(byte.trim().trim_start_matches("0x"), 16).unwrap())
                    .collect();
                server
                    .entry(media_type.clone().unwrap())
                    .or_default()
                    .push((offset.parse().unwrap(), bytes));
            }
        }

        let collector: BTreeMap<String, Vec<(usize, Vec<u8>)>> = LEADING_BYTE_SIGNATURES
            .iter()
            .map(|(kind, signatures)| {
                let signatures = signatures
                    .iter()
                    .map(|signature| (signature.offset, signature.bytes.to_vec()))
                    .collect();
                (kind.media_type().to_owned(), signatures)
            })
            .collect();
        assert_eq!(collector, server);
    }
}
