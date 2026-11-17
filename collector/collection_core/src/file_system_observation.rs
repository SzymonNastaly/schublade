//! What the collector reads from disk. The listing, the signature observation, the digest read,
//! and the source read arrive with the coordinator; this part holds the one type they share with
//! the archive client.

use sha2::{Digest, Sha256};

use crate::domain_types::ContentDigest;

/// The SHA-256 of bytes held in memory.
pub fn content_digest_of(bytes: &[u8]) -> ContentDigest {
    ContentDigest::from_bytes(Sha256::digest(bytes).into())
}

/// The bytes of a source, read whole, whose digest was computed from exactly these bytes. The
/// source read proves them against the authorized digest and the file's signature before and
/// after the read; this type keeps bytes and digest together so a PUT can never send other bytes
/// than the digest names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VerifiedContent {
    digest: ContentDigest,
    bytes: Vec<u8>,
}

impl VerifiedContent {
    pub fn from_bytes(bytes: Vec<u8>) -> VerifiedContent {
        VerifiedContent {
            digest: content_digest_of(&bytes),
            bytes,
        }
    }

    pub fn digest(&self) -> ContentDigest {
        self.digest
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_digest_is_the_sha256_of_the_bytes() {
        let content = VerifiedContent::from_bytes(b"Hello".to_vec());
        assert_eq!(
            content.digest().hexadecimal(),
            "185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969"
        );
        assert_eq!(content.bytes(), b"Hello");
    }
}
