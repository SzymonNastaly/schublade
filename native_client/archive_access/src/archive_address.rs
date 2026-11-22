use crate::archive_identifiers::DocumentIdentifier;

/// An archive origin, `https://` (or `http://` for a local server).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveAddress(url::Url);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveAddressRefusal {
    pub detail: String,
}

impl ArchiveAddress {
    /// Keeps the origin only; a pasted path such as `/settings` is dropped.
    pub fn parse(text: &str) -> Result<ArchiveAddress, ArchiveAddressRefusal> {
        let refusal = |detail: &str| ArchiveAddressRefusal {
            detail: detail.to_owned(),
        };
        let url = url::Url::parse(text.trim()).map_err(|error| refusal(&format!("{error}")))?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(refusal("The archive address must start with https://"));
        }
        if url.host_str().is_none() {
            return Err(refusal("The archive address must name a host"));
        }
        let origin = url.origin().ascii_serialization();
        url::Url::parse(&origin)
            .map(ArchiveAddress)
            .map_err(|error| refusal(&format!("{error}")))
    }

    /// Without a trailing slash, as `request.url` names it on the server.
    pub fn origin(&self) -> String {
        self.0.origin().ascii_serialization()
    }

    /// The page of a document in the browser, the one place a link into the archive is composed.
    pub fn document_page(&self, document: &DocumentIdentifier) -> String {
        format!("{}/documents/{}", self.origin(), document.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_archive_address_keeps_only_the_origin() {
        let address = ArchiveAddress::parse(" https://Archive.Example.org/settings?tab=tokens ").unwrap();
        assert_eq!(address.origin(), "https://archive.example.org");
        assert_eq!(
            ArchiveAddress::parse("http://localhost:3000/").unwrap().origin(),
            "http://localhost:3000"
        );
        assert!(ArchiveAddress::parse("archive.example.org").is_err());
        assert!(ArchiveAddress::parse("ftp://archive.example.org").is_err());
        assert!(ArchiveAddress::parse("https://").is_err());
    }
}
