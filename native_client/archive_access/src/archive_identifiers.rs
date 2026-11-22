//! The two names an archive gives: the digest of a content and the identifier of a record. Both
//! are parsed from the archive's text only at a boundary, a store or a route.

/// The SHA-256 of one exact byte sequence, the name of a content in the archive and here.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ContentDigest([u8; 32]);

impl ContentDigest {
    pub fn from_bytes(bytes: [u8; 32]) -> ContentDigest {
        ContentDigest(bytes)
    }

    /// Accepts exactly 64 lowercase hexadecimal characters, as the server's `sha256Pattern`.
    pub fn parse_hexadecimal(text: &str) -> Option<ContentDigest> {
        if text.len() != 64 {
            return None;
        }
        let mut bytes = [0u8; 32];
        for (index, pair) in text.as_bytes().chunks(2).enumerate() {
            let high = lowercase_hexadecimal_value(pair[0])?;
            let low = lowercase_hexadecimal_value(pair[1])?;
            bytes[index] = high << 4 | low;
        }
        Some(ContentDigest(bytes))
    }

    pub fn hexadecimal(&self) -> String {
        self.0.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

fn lowercase_hexadecimal_value(character: u8) -> Option<u8> {
    match character {
        b'0'..=b'9' => Some(character - b'0'),
        b'a'..=b'f' => Some(character - b'a' + 10),
        _ => None,
    }
}

impl std::fmt::Debug for ContentDigest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "ContentDigest({})", self.hexadecimal())
    }
}

/// Whether the text is a UUID as the archive writes every record identifier: `8-4-4-4-12`
/// lowercase hexadecimal groups, as the server's route pattern.
pub fn is_record_identifier(text: &str) -> bool {
    const GROUP_LENGTHS: [usize; 5] = [8, 4, 4, 4, 12];
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == GROUP_LENGTHS.len()
        && groups.iter().zip(GROUP_LENGTHS).all(|(group, length)| {
            group.len() == length && group.bytes().all(|byte| lowercase_hexadecimal_value(byte).is_some())
        })
}

/// The identifier of a document, validated at the boundary because it becomes part of a path.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize)]
pub struct DocumentIdentifier(String);

impl DocumentIdentifier {
    pub fn parse(text: &str) -> Option<DocumentIdentifier> {
        is_record_identifier(text).then(|| DocumentIdentifier(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_content_digest_round_trips_through_lowercase_hexadecimal_only() {
        let text = "b60d823ff8fc9d5e3f8979eb7be7fd57d31bcb959dcc0ec5260c4daf6ec98150";
        let digest = ContentDigest::parse_hexadecimal(text).unwrap();
        assert_eq!(digest.hexadecimal(), text);
        assert_eq!(format!("{digest:?}"), format!("ContentDigest({text})"));
        assert_eq!(ContentDigest::parse_hexadecimal(&text.to_uppercase()), None);
        assert_eq!(ContentDigest::parse_hexadecimal(&text[..63]), None);
        assert_eq!(ContentDigest::parse_hexadecimal(&format!("{text}0")), None);
    }

    #[test]
    fn a_document_identifier_follows_the_route_pattern_of_the_server() {
        assert!(DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f60718293").is_some());
        assert_eq!(DocumentIdentifier::parse("4C5D6E7F-8091-4A2B-9C3D-4E5F60718293"), None);
        assert_eq!(DocumentIdentifier::parse("4c5d6e7f80914a2b9c3d4e5f60718293"), None);
        assert_eq!(DocumentIdentifier::parse("4c5d6e7f-8091-4a2b-9c3d-4e5f6071829"), None);
    }
}
