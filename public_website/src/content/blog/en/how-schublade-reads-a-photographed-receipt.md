---
title: "How Schublade reads a photographed receipt"
description: "From a crooked phone photo to searchable text. How Schublade picks a text source, turns photos upright, reads them with Moondream, and handles sideways pages."
publishedOn: 2026-11-22
translationKey: reading-receipts
tags: ["text recognition", "engineering"]
---

A receipt from the pharmacy reaches Schublade as a phone photo. It is slightly crooked, printed on thermal paper, and stored sideways, because that is how phones store most portrait photos. A few minutes later the archive shows it as a receipt with a title, a date, a sender, and an amount, and a search for the shop finds it.

This post follows the steps in between, cheapest first, because most documents never need the expensive ones.

## Text layer first

Many documents arrive as PDFs that already contain their text. An invoice from an online shop, a bank statement, or a letter printed from a word processor carries a text layer, the invisible text a PDF viewer lets you select. Reading it costs nothing. Running a vision model over the page costs money and time and can make mistakes.

So Schublade looks at every page of a PDF and picks one of three sources for its text, in this order.

1. **The converted section.** Cloudflare's `toMarkdown()` conversion turns the PDF into Markdown, which keeps tables as tables. Schublade takes a page's section when it holds at least 40 letters or digits and at least 90% of the letters and digits of the page's text layer.
2. **The text layer.** PDFium, compiled to WebAssembly, extracts the text layer directly. Schublade takes it when it holds at least 40 letters or digits and fewer than one replacement character per ten of them. A font without a usable character mapping comes out as replacement characters, so such a page fails this test.
3. **Text recognition.** Only a page that fails both tests goes to the vision model.

### Why the 90% rule exists

The conversion usually works well. On all 27 digital pages of Schublade's test documents, a complete conversion held every letter and digit of the text layer. But Chromium prints tagged PDFs, and on a forwarded email `toMarkdown()` kept the three header lines of page 1, dropped the layout tables below them, and returned page 2 empty. PDFium read both pages in full.

The 90% comparison catches that case. If the conversion holds much less text than the text layer, Schublade trusts the text layer instead. Such a page then costs no rendering and no billed recognition.

A scanned page fails the first two tests, because a scan's text layer is empty or nearly so. Fewer than 40 letters and digits counts as a scan. A photo has no text layer at all, so it goes straight to recognition.

## Making the photo upright

The photo of the receipt has a catch. A phone stores the pixels of a portrait photo on their side and records the rotation in an EXIF tag. Photo viewers read the tag and turn the picture for display. Moondream, the model Schublade uses for recognition, reads the stored pixels and ignores the tag. It sees the receipt sideways.

A household member photographed a printed A4 letter with an iPhone. The upload worked, and then the document stayed in "Recognizing text" for six minutes and failed. The photo was 4032 by 3024 pixels with orientation tag 6. In one run on the stored pixels, the model wrote 13,096 characters and stopped only at its token cap. The same photo turned upright came back in 4.8 seconds, correct except for a few words.

So every uploaded image now goes through Cloudflare Images before the model sees it. The Images binding applies the EXIF orientation. It also scales the image down so the longer edge is at most 1600 pixels, and it writes a JPEG at quality 90 on a white background. The white background matters. Without it, transparent pixels came back black, which hid black text on a transparent PNG.

After that change, the original phone photo archived in 27 seconds on a real deployment, with one Moondream call of 6.9 seconds.

Scanned PDF pages take a different route to the same place. PDFium renders each page that needs recognition to a grayscale PNG at 150 dots per inch.

## Reading the page with Moondream

Schublade sends the upright image to Moondream 3.1 on Workers AI, through AI Gateway on your account. It asks the model to transcribe all text exactly as printed, line by line, and to keep numbers, dates, amounts, and IBANs. Temperature is 0. Schublade skips the gateway cache, because a cached answer to the same bytes would repeat a bad reading on retry.

The answer arrives as a stream of events, and every event repeats the whole answer so far. Schublade reads the stream line by line and keeps only the latest event. The last event also carries the stop reason. If the stop reason is `length`, the model ran into its limit of 2048 output tokens, and the page never finished. Schublade does not keep that text. Upright test pages used at most 597 tokens, so a page that reaches 2048 is almost always a page the model could not read.

One more repair happens here. Moondream sometimes returns a replacement character where a euro sign was printed. When that character stands right before or after an amount such as `12,49`, Schublade puts the euro sign back.

## When a page hits the limit, read it four ways

EXIF does not help with a scan fed in the wrong way round, or a photo without the tag. Those pages reach the model sideways or upside down, and the model loops until it hits the limit.

When the first reading of a page hits the token limit, Schublade reads the page at the other three rotations, 90, 180, and 270 degrees, in parallel workflow steps. It keeps the reading with the most distinct words. `Intl.Segmenter` counts the words, so the count also works in scripts without spaces between words. A looping reading repeats itself, so it has few distinct words even when it is long.

Schublade records the winning rotation on the document. Later pages start from that rotation, because pages of one scan usually share it. In a test, a two-page sideways scan took five readings instead of eight.

A document fails with "unreadable page" only when no rotation finishes. It then appears under Failed documents, where you can retry or delete it.

### Why not read every page four times

Reading four rotations of every page would cost four times as much for every recognized page. It also does harm. In a replay of recorded readings, picking the longest of four readings on every page turned 5 of 25 upright pages the wrong way. Checking only after a failure left all 25 upright pages alone.

The check has a known gap. A wrong rotation can sometimes finish normally with fluent, invented text, and a check that runs only after a failure does not see it. That is an open problem, and the [research notes on text recognition](https://github.com/SzymonNastaly/schublade/blob/main/docs/research/optical_character_recognition_with_vision_models.md) in the repository list ideas for it.

## From text to a filed receipt

Once every page has text, Schublade joins the pages into one Markdown document. A language model reads it and fills in the title, the date, the sender, the category, the person, and fields such as the amount. The text goes into the search index, and a few minutes later the receipt shows up in searches.

The cost follows the path. A PDF with a readable text layer skips recognition. Each recognized page costs about 0.0008 USD, and classification costs about 0.0023 USD per document. A page that hits the limit costs three more readings, and the later pages of the same document start from the rotation that worked.

Send the photo from the [web app](/web/) on your phone, or scan it with the [iPhone app](/iphone/) once it is out. For the bigger picture, start with [Introducing Schublade](/blog/introducing-schublade/).
