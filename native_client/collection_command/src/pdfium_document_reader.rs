//! What `schublade-collector` reads from a PDF before it sends it: the text layer of each page and
//! a JPEG of the first page, through PDFium. It recognizes no text, so a scanned PDF and a picture
//! arrive without text, and the archive reads them itself.
//!
//! PDFium is a library the program binds when it starts, looking in this order:
//! 1. the file that `SCHUBLADE_PDFIUM_LIBRARY` names;
//! 2. `libpdfium.so` or `libpdfium.dylib` beside the executable, where a release bundles it;
//! 3. the system's library search path.
//!
//! `native_client/scripts/fetch_pdfium_library.sh` downloads the build that pdfium-render binds
//! to. Without the library the program sends every original alone, as a collector did before.

use std::path::{Path, PathBuf};

use archive_access::is_readable_text_layer;
use collection_core::candidate_classification::{ContentKind, identify_content_kind};
use collection_core::file_system_observation::VerifiedContent;
use collection_core::{DerivedRepresentations, DocumentReader};
use image::ExtendedColorType;
use image::codecs::jpeg::JpegEncoder;
use pdfium_render::prelude::{PdfDocument, PdfRenderConfig, Pdfium, PdfiumError};

pub const PDFIUM_LIBRARY_VARIABLE: &str = "SCHUBLADE_PDFIUM_LIBRARY";
/// The longer side of the first page's picture, as the reception expects it.
const THUMBNAIL_PIXELS: i32 = 480;
const THUMBNAIL_QUALITY: u8 = 80;

pub struct PdfiumDocumentReader {
    pdfium: Pdfium,
}

/// Each place the program looked for PDFium, with what failed there.
pub struct PdfiumAbsence {
    pub attempts: Vec<String>,
}

impl PdfiumDocumentReader {
    /// Binds the first PDFium library found in the order the module states.
    pub fn bind() -> Result<PdfiumDocumentReader, PdfiumAbsence> {
        let named = std::env::var_os(PDFIUM_LIBRARY_VARIABLE).map(PathBuf::from);
        let bundled = std::env::current_exe()
            .ok()
            .and_then(|executable| executable.parent().map(Pdfium::pdfium_platform_library_name_at_path));
        let mut attempts = Vec::new();
        for library in named.into_iter().chain(bundled) {
            match PdfiumDocumentReader::bind_to(&library) {
                Ok(reader) => return Ok(reader),
                Err(failure) => attempts.push(failure),
            }
        }
        match Pdfium::bind_to_system_library() {
            Ok(bindings) => Ok(PdfiumDocumentReader {
                pdfium: Pdfium::new(bindings),
            }),
            Err(error) => {
                attempts.push(format!("the system's library search path: {}", binding_failure(error)));
                Err(PdfiumAbsence { attempts })
            }
        }
    }

    pub fn bind_to(library: &Path) -> Result<PdfiumDocumentReader, String> {
        Pdfium::bind_to_library(library)
            .map(|bindings| PdfiumDocumentReader {
                pdfium: Pdfium::new(bindings),
            })
            .map_err(|error| format!("{}: {}", library.display(), binding_failure(error)))
    }
}

/// The loader's own sentence, which `PdfiumError` would print as a structure.
fn binding_failure(error: PdfiumError) -> String {
    match error {
        PdfiumError::LoadLibraryError(error) => match std::error::Error::source(&error) {
            Some(cause) => format!("{error}: {cause}"),
            None => error.to_string(),
        },
        error => error.to_string(),
    }
}

impl DocumentReader for PdfiumDocumentReader {
    fn read(&self, content: &VerifiedContent) -> DerivedRepresentations {
        if identify_content_kind(content.bytes()) != Some(ContentKind::PortableDocument) {
            return DerivedRepresentations::default();
        }
        let Ok(document) = self.pdfium.load_pdf_from_byte_slice(content.bytes(), None) else {
            return DerivedRepresentations::default();
        };
        let page_texts: Vec<String> = document
            .pages()
            .iter()
            .map(|page| {
                page.text()
                    .map(|text| text.all().replace("\r\n", "\n"))
                    .ok()
                    .filter(|text| is_readable_text_layer(text))
                    .unwrap_or_default()
            })
            .collect();
        DerivedRepresentations {
            // A document without a readable page goes without text, so the archive reads it.
            page_texts: if page_texts.iter().all(String::is_empty) {
                Vec::new()
            } else {
                page_texts
            },
            thumbnail: first_page_picture(&document),
        }
    }
}

/// The first page at most 480 pixels on its longer side, upright on white, as a JPEG.
fn first_page_picture(document: &PdfDocument<'_>) -> Option<Vec<u8>> {
    let configuration = PdfRenderConfig::new()
        .set_target_width(THUMBNAIL_PIXELS)
        .set_maximum_height(THUMBNAIL_PIXELS);
    let picture = document
        .pages()
        .first()
        .ok()?
        .render_with_config(&configuration)
        .ok()?
        .as_image()
        .ok()?
        .to_rgb8();
    let mut jpeg = Vec::new();
    JpegEncoder::new_with_quality(&mut jpeg, THUMBNAIL_QUALITY)
        .encode(
            picture.as_raw(),
            picture.width(),
            picture.height(),
            ExtendedColorType::Rgb8,
        )
        .ok()?;
    Some(jpeg)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test_fixtures/documents");

    /// The library `fetch_pdfium_library.sh` installs, or the one `SCHUBLADE_PDFIUM_LIBRARY` names.
    fn fetched_library() -> PathBuf {
        std::env::var_os(PDFIUM_LIBRARY_VARIABLE).map_or_else(
            || Pdfium::pdfium_platform_library_name_at_path(concat!(env!("CARGO_MANIFEST_DIR"), "/../target/pdfium")),
            PathBuf::from,
        )
    }

    fn fixture(name: &str) -> VerifiedContent {
        VerifiedContent::from_bytes(std::fs::read(Path::new(FIXTURES).join(name)).unwrap())
    }

    #[test]
    fn a_digital_pdf_gives_its_text_and_first_page_and_a_scanned_one_its_first_page_alone() {
        let reader = PdfiumDocumentReader::bind_to(&fetched_library())
            .unwrap_or_else(|failure| panic!("{failure}; run native_client/scripts/fetch_pdfium_library.sh"));

        let digital = reader.read(&fixture("telecommunication_invoice_digital.pdf"));
        let scanned = reader.read(&fixture("dental_invoice_scanned.pdf"));

        assert_eq!(digital.page_texts.len(), 1);
        for printed in [
            "Nordkabel Kommunikation GmbH",
            "67,13 €",
            "20.10.2026",
            "DE28 9302 4580 0418 8200 37",
            "NK-2026-1048-3391",
        ] {
            assert!(
                digital.page_texts[0].contains(printed),
                "{printed} in {}",
                digital.page_texts[0]
            );
        }
        assert!(!digital.page_texts[0].contains('\r'));
        assert_eq!(scanned.page_texts, Vec::<String>::new());
        for thumbnail in [digital.thumbnail, scanned.thumbnail] {
            let thumbnail = thumbnail.expect("the first page is drawn");
            let picture = image::load_from_memory_with_format(&thumbnail, image::ImageFormat::Jpeg).unwrap();
            assert_eq!(
                (picture.width().max(picture.height()), thumbnail.len() < 200_000),
                (480, true)
            );
        }
    }
}
