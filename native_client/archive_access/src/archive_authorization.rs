//! `GET /api/v1/authorization`: what the token may do in which archive. A client reads it before
//! it stores anything, the collector to learn whether the token may ingest and the local copy to
//! learn which journal and which scope it mirrors.

use crate::archive_exchange::{ArchiveCondition, ArchiveExchange};

/// The levels of a token in the server's order. Each grants every permission of those before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PermissionLevel {
    Read,
    Ingest,
    Modify,
    Administer,
}

impl PermissionLevel {
    /// The level as the server writes it.
    pub fn parse(name: &str) -> Option<PermissionLevel> {
        Some(match name {
            "read" => PermissionLevel::Read,
            "ingest" => PermissionLevel::Ingest,
            "modify" => PermissionLevel::Modify,
            "administer" => PermissionLevel::Administer,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            PermissionLevel::Read => "read",
            PermissionLevel::Ingest => "ingest",
            PermissionLevel::Modify => "modify",
            PermissionLevel::Administer => "administer",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveAuthorization {
    /// Names the change journal of the archive's database. Another one means another journal.
    pub journal_identifier: String,
    /// The description a member gave the token in Settings.
    pub token_description: String,
    pub permission_level: PermissionLevel,
    /// Whether the token sees only a part of the archive.
    pub restricted: bool,
    /// Names what the token may see. Two tokens with one digest see the same records.
    pub scope_digest: String,
}

#[derive(serde::Deserialize)]
struct AuthorizationAnswer {
    journal_identifier: String,
    token: TokenAnswer,
}

#[derive(serde::Deserialize)]
struct TokenAnswer {
    description: String,
    permission_level: String,
    restricted: bool,
    scope_digest: String,
}

pub fn read_authorization(exchange: &ArchiveExchange) -> Result<ArchiveAuthorization, ArchiveCondition> {
    let response = exchange.get("/api/v1/authorization")?;
    if response.status() != 200 {
        return Err(response.protocol_violation());
    }
    let answer: AuthorizationAnswer =
        serde_json::from_str(response.body()).map_err(|_| response.protocol_violation())?;
    Ok(ArchiveAuthorization {
        journal_identifier: answer.journal_identifier,
        token_description: answer.token.description,
        permission_level: PermissionLevel::parse(&answer.token.permission_level)
            .ok_or_else(|| response.protocol_violation())?,
        restricted: answer.token.restricted,
        scope_digest: answer.token.scope_digest,
    })
}
