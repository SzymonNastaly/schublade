use sha2::{Digest, Sha256};

/// The bearer token. Never logged, never stored in a database, never serialized.
pub struct ArchiveToken(String);

impl ArchiveToken {
    pub fn new(token: String) -> ArchiveToken {
        ArchiveToken(token.trim().to_owned())
    }

    /// The token itself, for the credential store and the request header only.
    pub fn secret(&self) -> &str {
        &self.0
    }

    /// SHA-256 of the token as hexadecimal, the only form a database holds.
    pub fn fingerprint(&self) -> String {
        Sha256::digest(self.0.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

impl std::fmt::Debug for ArchiveToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ArchiveToken(..)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_shows_only_its_fingerprint() {
        let token = ArchiveToken::new("secret-token\n".to_owned());
        assert_eq!(
            token.fingerprint(),
            "930bbdc51b6aed5c2a5678fd6e28dee7a05e8a4b643cfc0b4427c3efb86c0d94"
        );
        assert_eq!(format!("{token:?}"), "ArchiveToken(..)");
        assert_ne!(token.fingerprint(), ArchiveToken::new("other".to_owned()).fingerprint());
    }
}
