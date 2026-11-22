//! A person's search text as terms, each with its expression for the two search tables, and the
//! excerpt of an extracted text around the first word a term finds.
//!
//! A document is found when every term is found in its details or in its text. The details
//! find a term anywhere inside a word, by trigrams, and the text finds it at the beginning of a
//! word. A term shorter than three characters has no trigram, so it is found in the text only.

/// More terms than a person types. A pasted paragraph is cut here.
const MAXIMUM_TERMS: usize = 12;
const SHORTEST_DETAIL_TERM_CHARACTERS: usize = 3;

/// The text before the found word that a passage shows at most, and the passage's length, both
/// in bytes of the extracted text. A row of the list shows about two lines of it.
const PASSAGE_LEAD_BYTES: usize = 48;
const PASSAGE_BYTES: usize = 160;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchExpression {
    terms: Vec<SearchTerm>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchTerm {
    /// As the person typed it.
    text: String,
    /// Its first run of letters and digits, folded, which an excerpt looks for.
    opening_word: String,
}

impl SearchExpression {
    /// The terms are what whitespace separates. A term without a letter or a digit is left out.
    pub fn parse(text: &str) -> SearchExpression {
        let terms = text
            .split_whitespace()
            .filter_map(|term| {
                let opening_word = term
                    .split(|character: char| !character.is_alphanumeric())
                    .find(|run| !run.is_empty())?;
                Some(SearchTerm {
                    text: term.to_owned(),
                    opening_word: opening_word.chars().map(folded).collect(),
                })
            })
            .take(MAXIMUM_TERMS)
            .collect();
        SearchExpression { terms }
    }

    pub fn terms(&self) -> &[SearchTerm] {
        &self.terms
    }

    /// The passage of an extracted text around its first word that begins with a term, on one
    /// line and without Markdown marks. `None` when no word does.
    ///
    /// A search of the text reads every found document up to that word, so the walk looks only
    /// for the bytes that can open a term and then asks whether a word begins there. Deciding
    /// for every byte whether it belongs to a word took four times as long.
    pub fn excerpt(&self, text: &str) -> Option<String> {
        // A term's first letter in both cases, and every byte that begins a character beyond
        // ASCII, because an umlaut folds to its letter.
        let mut may_open = [false; 256];
        may_open[0xC0..].fill(true);
        for term in &self.terms {
            if let Some(first) = term.opening_word.bytes().next().filter(u8::is_ascii) {
                may_open[usize::from(first)] = true;
                may_open[usize::from(first.to_ascii_uppercase())] = true;
            }
        }
        let bytes = text.as_bytes();
        let mut searched = 0;
        while let Some(found) = bytes[searched..].iter().position(|byte| may_open[usize::from(*byte)]) {
            let offset = searched + found;
            let begins_word = text[..offset]
                .chars()
                .next_back()
                .is_none_or(|before| !is_word_character(before));
            if begins_word && self.terms.iter().any(|term| term.opens(&text[offset..])) {
                return Some(passage_around(text, offset));
            }
            searched = offset + 1;
        }
        None
    }
}

impl SearchTerm {
    /// The expression that finds the term anywhere in the details, or `None` for a term that
    /// has no trigram.
    pub fn detail_expression(&self) -> Option<String> {
        (self.text.chars().count() >= SHORTEST_DETAIL_TERM_CHARACTERS).then(|| self.phrase())
    }

    /// The expression that finds the term at the beginning of a word of the text. A term of
    /// several words, such as `nk-2021`, is those words in a row.
    pub fn text_expression(&self) -> String {
        format!("{}*", self.phrase())
    }

    fn phrase(&self) -> String {
        format!("\"{}\"", self.text.replace('"', "\"\""))
    }

    /// Whether the text begins with the term's opening word.
    fn opens(&self, text: &str) -> bool {
        let mut letters = text.chars().map(folded);
        self.opening_word
            .chars()
            .all(|expected| letters.next() == Some(expected))
    }
}

/// Whether the character belongs to a word, as the text table's tokenizer decides it. The
/// letters with diacritics are answered here, because the lookup of the standard library took
/// most of the time of a walk through a German text.
fn is_word_character(character: char) -> bool {
    match character {
        '×' | '÷' => false,
        'À'..='ɏ' => true,
        _ => character.is_alphanumeric(),
    }
}

/// A character as both search tables index it and as an alphabetical order reads it: in lower
/// case and without its diacritic, for the Latin letters of European names.
pub(crate) fn folded(character: char) -> char {
    let lower = character.to_lowercase().next().unwrap_or(character);
    match lower {
        'à'..='å' | 'ā'..='ą' => 'a',
        'ç' | 'ć'..='č' => 'c',
        'ď' => 'd',
        'è'..='ë' | 'ē'..='ě' => 'e',
        'ĝ'..='ģ' => 'g',
        'ĥ' => 'h',
        'ì'..='ï' | 'ĩ'..='į' => 'i',
        'ĵ' => 'j',
        'ķ' => 'k',
        'ĺ'..='ľ' => 'l',
        'ñ' | 'ń'..='ň' => 'n',
        'ò'..='ö' | 'ō'..='ő' => 'o',
        'ŕ'..='ř' => 'r',
        'ś'..='š' => 's',
        'ţ'..='ť' => 't',
        'ù'..='ü' | 'ũ'..='ų' => 'u',
        'ŵ' => 'w',
        'ý' | 'ÿ' | 'ŷ' => 'y',
        'ź'..='ž' => 'z',
        _ => lower,
    }
}

/// The text around the word at `found`: from the beginning of its sentence when that lies
/// within the lead, otherwise from a whole word, to a whole word at the passage's length.
fn passage_around(text: &str, found: usize) -> String {
    let mut start = found.saturating_sub(PASSAGE_LEAD_BYTES);
    while !text.is_char_boundary(start) {
        start -= 1;
    }
    let mut end = (found + PASSAGE_BYTES).min(text.len());
    while !text.is_char_boundary(end) {
        end += 1;
    }
    let mut lead = &text[start..found];
    let sentence_start = lead.char_indices().rev().find_map(|(index, character)| {
        let after = index + character.len_utf8();
        let ends_sentence = character == '\n'
            || (matches!(character, '.' | '!' | '?') && lead[after..].starts_with(char::is_whitespace));
        ends_sentence.then_some(after)
    });
    let cut_before = match sentence_start {
        Some(sentence_start) => {
            lead = &lead[sentence_start..];
            false
        }
        None if start > 0 => {
            lead = lead.find(char::is_whitespace).map_or("", |space| &lead[space..]);
            true
        }
        None => false,
    };
    let mut rest = &text[found..end];
    let cut_after = end < text.len();
    if cut_after && let Some(space) = rest.rfind(char::is_whitespace) {
        rest = &rest[..space];
    }
    let separates =
        |character: char| character.is_whitespace() || matches!(character, '#' | '*' | '|' | '`' | '>' | '_');
    let rules = |word: &&str| !word.chars().all(|character| matches!(character, '-' | '=' | ':'));
    let words: Vec<&str> = lead
        .split(separates)
        .chain(rest.split(separates))
        .filter(rules)
        .collect();
    format!(
        "{}{}{}",
        if cut_before { "… " } else { "" },
        words.join(" "),
        if cut_after { " …" } else { "" }
    )
}
