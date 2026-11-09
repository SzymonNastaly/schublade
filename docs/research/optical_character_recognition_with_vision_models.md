# Optical character recognition with vision models: research notes

These notes collect what Schublade learned about reading documents with vision language models. They are raw material for a later blog post, so they keep the numbers, the failed ideas, and the sources.

Every result states how it was measured and on how much data. Most samples are small. The experiments ran on 8 and 9 November 2026 and used throwaway scripts that are not in this repository. The notes contain nothing from the private documents that were used.

## The system under study

Schublade reads a page that has no usable text layer with Moondream 3.1 on Workers AI (`@cf/moondream/moondream3.1-9B-A2B`). PDF pages are rendered to grayscale PNG at 150 dots per inch. Image uploads go to the model as uploaded. The request uses `task: "query"`, `reasoning: false`, `temperature: 0`, and `max_tokens: 4096`, and it passes through AI Gateway.

A typical page costs about $0.0005 and takes 3 to 15 seconds.

## The incident: a phone photo that never finished

A household member photographed a printed A4 letter with an iPhone and uploaded it from the installed web application. The upload worked. The document stayed in "Recognizing text" for six minutes and then failed. Four attempts each ended after 51 to 63 seconds with `Worker exceeded CPU time limit.`

The file was a baseline JPEG of 4032×3024 pixels and 1.79 MB with a Display P3 colour profile. It was not HEIC, it held one image, and it had no HDR gain map. Its one unusual property was the EXIF orientation tag with value 6. The stored pixels lie on their side, and viewers rotate them for display.

Moondream does not apply that tag. A sideways image reaches the model as sideways text.

| Input                                     | Route      | Time   | Stream events | Stream size | Answer length | Result                     |
| ----------------------------------------- | ---------- | ------ | ------------- | ----------- | ------------- | -------------------------- |
| The photo as stored                       | No gateway | 89.6 s | 4,100         | 28.23 MB    | 13,096 chars  | Reached the token cap      |
| The photo as stored                       | Gateway    | 8.0 s  | 361           | 0.61 MB     | 1,074 chars   | Ended normally, mostly invented text |
| The photo rotated upright, 1200×1600      | Gateway    | 4.8 s  | 225           | 0.24 MB     | 533 chars     | Correct except a few words |
| Dense synthetic page, upright, 2481×3508  | Both       | 10–15 s | 634          | 1.64 MB     | 2,065 chars   | Normal                     |
| The same page turned sideways             | Gateway    | 60.4 s | 2,840         | 14.34 MB    | 9,493 chars   | Ended in a repeating loop  |
| Synthetic receipt, upright, 4032×5376     | Both       | 8.7 s  | 442           | 0.61 MB     | 822 chars     | Normal                     |

Each row is one or two runs. The model varies between runs even at temperature 0.

Size alone did not cause the failure, because the upright 4032×5376 image finished normally. The sideways pages caused the long runs.

### What was ruled out

- Parsing the event stream. In workerd, a synthetic 285 MB stream took 500 ms to read and 34 ms to parse.
- Encoding the image. Base64 encoding 1.79 MB took 23 ms in workerd.
- The image format, Live Photo, and HDR. The JPEG markers show a plain single image.

### What is still unknown

The exact component that raises the CPU error is not established. Telemetry reports 368 ms of CPU for the whole workflow invocation, AI Gateway logged none of the four failed attempts, and a 59-second call through the gateway succeeded from a local Worker. The trigger is clear and the failing component is not.

## Lessons for anyone reading documents with a vision model

**Apply the orientation tag yourself.** A phone stores most portrait photos sideways and records the rotation in EXIF. Hugging Face's `load_image` applies it. A hosted model endpoint may not, and Moondream on Workers AI did not.

**A rotated page can make the model invent text.** It can also fail silently. One sideways run stopped normally after 8 seconds with a plausible table and a made-up telephone number. A check on the stop reason does not catch that run.

**Repetition loops are expensive twice.** The loop runs to the token cap, and on this endpoint every stream event repeats the whole answer so far, so the stream grows with the square of the answer. An answer of 13,096 characters took 28 MB.

**Keep the stop reason.** The final stream event carries `finish_reason` and `metrics.output_tokens`. Code that keeps only the answer text cannot tell a finished page from a truncated one.

**Set the token cap from real pages.** A dense A4 page needed about 630 tokens. A cap of 4096 mostly gives a loop more room.

**A cache can replay a bad answer.** AI Gateway caches successful responses. A repeated identical request came back in 95 ms with `cached=true`. A retry that sends the same bytes can return the same wrong text.

**More pixels stop helping.** Moondream resizes every image to fit at most 12 overlapping tiles of 378 pixels plus one overview. For an A4 shape that is about 910×1176 pixels of distinct image (computed from the published defaults, and the hosted build may differ). Anything larger is thrown away by the model.

**Do not trust a number from the data you tuned on.** See the orientation results below.

**Turning a page and hoping is not a fix.** A wrong rotation can finish normally, so "it finished" does not mean "it is upright". Replaying blind quarter turns on recorded readings archived bad text in 16 of 44 failures.

**Check after a failure when the common case is already right.** A check that runs on every document can damage healthy ones. Picking the longest of four readings on every page turned 5 of 25 upright pages the wrong way.

**Pay for an expensive check once per document.** Pages in one scan usually share a rotation. Record the rotation that won, and start later pages from it. A two-page sideways scan took five readings instead of eight.

**Length is a weak signal.** A page turned 180 degrees produced 496 characters where the upright page produced 454.

**Bad readings are fluent.** One sideways page produced a clean German table holding 2% of the page's real words. A dictionary or language detector would likely accept it (inferred).

**Stream the response when every event repeats the answer.** A page at the token limit streams megabytes. Reading line by line keeps only the latest event, so three readings can run at once without holding three copies.

**Test a provider's default.** The Images documentation describes a white default for transparent pixels. The JPEG output came back black until the request stated a background.

**Explain a score that drops.** A search evaluation fell from 8 of 8 to 4 of 8 after a change. The cause was three copies of every test document in the local archive, and both settings scored 8 of 8 with copies counted once.

## What the model code and the providers say

Moondream's published code converts to RGB, tiles, and normalizes. It has no rotation or EXIF handling. Its conversion to RGB does not composite transparency onto a background first, so a transparent PNG may turn black (inferred from the code, not tested). The FAQ describes the tiles and does not mention rotation or OCR.

No provider found ships a library that prepares images for its model. They publish advice instead.

- Google says "Verify that images are correctly rotated."
- Anthropic warns that Claude can make mistakes on low-quality, rotated, or very small images.
- Hugging Face's `load_image` applies `exif_transpose` and converts to RGB, which is the closest thing to a shared standard.

## What published pipelines do

**olmOCR** renders pages to a longest edge of 1288 pixels. The model reports whether the rotation is valid and which correction it needs, and the pipeline retries with the page turned. A response whose `finish_reason` is not `stop` counts as invalid. The temperature rises on each attempt, from 0.1 to 1.0, with a code comment saying this helps overcome repetition.

**PaddleOCR** has a document preprocessor with an orientation classifier and an optional unwarping model. The classifier, PP-LCNet_x1_0_doc_ori, is about 7 MB and its model card claims 99.06% accuracy across four orientations.

**LlamaIndex** recommends hard caps on time and output tokens, ending the stream when repetition appears, and retrying with a different temperature. It rejected presence and frequency penalties, because a transcription may need to repeat content faithfully.

**Earlier Schublade finding on splitting.** Cutting a thermal receipt photograph into halves and reading each half lowered accuracy from 7 of 10 item prices to 0 of 10, on one sample. Splitting looks attractive because each part would get all 12 tiles, and it did not work.

## Orientation detection when no tag exists

A scanned page or a photo can be sideways with no tag. Two test sets measure the candidates.

- **Fixtures.** The 18 pages of Schublade's synthetic test documents, in four rotations, which is 72 images. All use one font family.
- **Unseen set.** 64 generated pages, in four rotations, which is 256 images. It combines 8 system fonts, 4 texts (German, English, Polish, and an uppercase invoice table), and 2 qualities (clean, and blurred with noise and low contrast).

| Approach                                       | Fixtures                     | Unseen set                                   | Notes                                                 |
| ---------------------------------------------- | ---------------------------- | -------------------------------------------- | ----------------------------------------------------- |
| Hand-written text line and ascender detector   | 214 of 216, none wrong       | 74 of 256, 26 wrong, 156 undecided           | 7 of 64 upright pages wrongly rotated on unseen pages |
| Tesseract orientation mode, any confidence     | 58 of 72, 8 wrong, 6 silent  | 247 of 256, 9 wrong                          | Native binary                                         |
| Tesseract orientation mode, confidence ≥ 3     | 42 decided, none wrong       | 203 decided, none wrong                      | Leaves the rest unrotated                             |

The hand-written detector is the most useful failure in this document. It reached 214 of 216 after three rounds of tuning on the fixtures, including three skew variants of each image, and it collapsed on fonts and noise it had never seen.

Vision models were asked directly how many degrees a page must turn. The test used 8 pages in four rotations, which is 32 images per model, at a longest edge of 1024 pixels.

| Model                     | Correct  | Behaviour                                                        |
| ------------------------- | -------- | ---------------------------------------------------------------- |
| Moondream 3.1             | 8 of 32  | Answered 90 on 31 of 32 images                                   |
| Llama 4 Scout             | 14 of 32 | No clear pattern                                                 |
| DeepSeek V4.1 Flash       | 19 of 32 | 7 calls rate limited. Called every sideways page 90              |
| Gemma 4 26B               | 20 of 32 | 3 calls failed                                                   |
| GLM-5.3 Flash             | 24 of 32 | Perfect except one sideways direction. Median 10 s, slowest 90 s |

Both DeepSeek and GLM told upright from upside-down reliably and could not tell one sideways direction from the other.

Reading the page in all four rotations with Moondream and asking DeepSeek which transcription read as real text picked the upright reading 18 of 32 times.

Tesseract gave no answer on the thermal receipt photograph in any rotation, so short or noisy pages need another route.

## Dedicated OCR inside Cloudflare

The Workers AI catalogue lists no model built only for OCR among the 73 models it returned. Its image-capable models are general vision models.

AI Search has an OCR option, `indexing_options.use_ocr`, for scanned PDFs up to 10 MiB. Cloudflare does not name the engine, and the documentation read here does not describe a way to get the recognized text back, so it feeds the search index and cannot replace a transcription step.

The Worker size limit rose to 64 MiB uncompressed on all plans in September 2026, so a small model and an inference runtime fit inside a Worker.

## Measurements on real Cloudflare

These measurements ran on 9 November 2026 with throwaway Workers and one throwaway Container application on a Workers Paid account. CPU times come from Workers Observability. Moondream ran on Workers AI. All test pages are synthetic.

### Orientation detectors inside a Worker

Both engines deployed together as 35 MB (15.5 MB compressed), with 13 ms of startup time. All 656 calls returned a result, and every invocation in the telemetry ended with outcome `ok`. The CPU figures include decoding and resizing a full page PNG.

| Engine                              | CPU median | CPU p90 | Fixtures, 72 images    | Unseen set, 256 images  |
| ----------------------------------- | ---------- | ------- | ---------------------- | ----------------------- |
| PP-LCNet, confidence at least 0.7   | 256 ms     | 415 ms  | 72 decided, none wrong | 102 decided, none wrong |
| Tesseract, confidence at least 3    | 492 ms     | 738 ms  | 42 decided, none wrong | 203 decided, none wrong |
| Both, used together                 | about 750 ms | not measured | 72 decided, none wrong, no conflicts | 209 decided, none wrong, no conflicts |

Tesseract's results in the Worker matched the native binary exactly. It used 45 to 65 MB of WebAssembly memory.

The thresholds were chosen after seeing these results, although nearby values gave the same outcome. PP-LCNet looks only at a centre crop of the page, so the generated pages with text in the top third were often undecided. Almost all pages that neither engine decided were noisy uppercase invoice tables.

Getting them to run required three changes. Both Emscripten builds must be told they are not in Node.js. Each must instantiate a precompiled WebAssembly module, because Workers forbid compiling from bytes. ONNX Runtime needs one thread, the WebAssembly-only bundle, and a small patch to its instantiation hook.

### Lighter orientation models

The PP-LCNet architecture dates from September 2021. The document orientation weights reached Hugging Face in June 2025, and the ONNX export in May 2026. The weights have 339,373 downloads there, against 211 for the closest document model. A search of Hugging Face found no newer model that is both smaller and trained on document pages. None of the alternatives below were run.

| Model                                     | Published | File                       | Input | Compute                                |
| ----------------------------------------- | --------- | -------------------------- | ----- | -------------------------------------- |
| PP-LCNet x1.0 doc_ori                     | 2025      | 6.79 MB                    | 224   | 161M FLOPs                             |
| docTR MobileNetV3-Small page orientation  | 2024      | 6.10 MB, or 1.72 MB 8-bit  | 512   | about 330M FLOPs, scaled from 64M at 224 |
| Phi-3.5-Vision encoder (arXiv 2511.04161) | 2025      | not stated                 | not stated | not stated                        |

The Phi-3.5 paper reports about 96% on its own English benchmark. PaddleOCR reports 99.06% for PP-LCNet on its own data. The two numbers are not comparable. PP-LCNet x0.25 has 18M FLOPs and a 1.02 MB file, but it exists only for text lines at 0 and 180 degrees. Newer backbones such as MobileNetV4 have no published page orientation weights that I found, so using one means training it.

The model is a small part of the cost. Real Worker CPU time across 337 requests falls into two clusters, around 100 to 150 ms and around 250 to 350 ms. The higher cluster is probably a fresh isolate starting ONNX Runtime (inferred). The same WebAssembly on a laptop gives this breakdown.

| Stage                                 | Milliseconds |
| ------------------------------------- | ------------ |
| First session, mostly starting ONNX Runtime | about 100 |
| A second session, which loads only the model | about 10  |
| First inference                       | 36           |
| Later inference                       | 10           |
| Decode a 1240 by 1754 PNG             | 19.1         |
| Convert and resize that page          | 7.1          |
| Decode and resize a 256 by 362 PNG    | 1.6          |

An orientation check that runs only on suspect pages is almost always cold. A model ten times lighter would save about 20 ms of a cold run of about 136 ms (inferred). Handing the detector a small image saves more. ONNX Runtime is also the larger file, at 14.8 MB against 6.79 MB. Its documentation describes reduced builds with only the needed operators, but gives no sizes for WebAssembly.

### Kreuzberg and Xberg in a Worker

This was not run. Kreuzberg is now Xberg (`xberg-io/xberg`, MIT). The last `@kreuzberg/wasm` release, 4.10.2, holds an 87 MiB WebAssembly file, which exceeds the 64 MiB Worker limit. The current package, `@xberg-io/xberg-wasm` 1.3.10, holds a 36.4 MiB file and 1.7 MiB of JavaScript.

Its `detectOrientation` runs the same PP-LCNet model with the same 256 and 224 pixel preprocessing, so it cannot gain accuracy. The WebAssembly build links no ONNX Runtime. It runs the model on `tract`, a pure-Rust engine, and it excludes PaddleOCR. OCR in that build is Tesseract.

Xberg's own documentation reports native `tract` at 31.9 ms per PP-LCNet orientation run, against 2.8 ms for multi-threaded native ONNX Runtime. The WebAssembly build uses `opt-level = "z"` and `wasm-opt -Oz`, and its target flags in the repository do not enable SIMD. It should therefore be slower than 31.9 ms (inferred). ONNX Runtime in WebAssembly took 10 ms on a laptop.

The README lists Cloudflare Workers as a target, and `initSync` accepts a compiled module. The repository holds no Workers test. With the model, Xberg needs about 45 MB of the 64 MiB limit, against about 22 MB for ONNX Runtime. Its automatic rotation accepts a confidence of 0.35. In the measurements above, turning pages without a higher threshold turned 24 upright pages on the unseen set.

### PaddleOCR compared with Moondream

The test used 64 generated pages with known text and 9 scanned or photographed fixture pages. PaddleOCR ran the PP-OCRv5 mobile detector and the Latin mobile recognizer in a Container. Its output on Cloudflare was identical to a local run on all 73 pages.

| Measure                           | PaddleOCR | Moondream 3.1 |
| --------------------------------- | --------- | ------------- |
| Words found, all pages            | 99.0%     | 88.5%         |
| Characters correct, all pages     | 99.7%     | 95.8%         |
| Words found, German               | 100.0%    | 99.4%         |
| Words found, English              | 100.0%    | 99.7%         |
| Words found, Polish               | 98.8%     | 73.4%         |
| Words found, invoice tables       | 97.4%     | 81.6%         |
| Expected fields on fixtures       | 18 of 18  | 18 of 18      |
| Median seconds per page           | 5.9       | 9.0           |
| Slowest page, seconds             | 14.4      | 57.4          |

Moondream reaches 18 of 18 fields only with Schublade's euro sign repair, and 15 of 18 without it. Its Polish score comes from the service replacing letters such as `ń`, `ę`, and `ż` with U+FFFD, which is the same defect as the euro sign. In tables it sometimes drops a cell. PaddleOCR returns one line per text box, so table rows come apart, while Moondream keeps them together.

PaddleOCR fails more safely on rotated pages. On two pages turned 90 degrees it still read 86 of 87 and 137 of 137 distinct longer words. On a page turned 180 degrees it returned junk with a mean confidence of 0.35, against 0.99 upright. It invented no plausible text. A turn of 270 degrees was not tested.

### Running PaddleOCR on Containers

- The image is 1.68 GB. A `standard-1` instance has half a vCPU and 4 GiB.
- A cold start took 7 to 12 seconds. The first request after a new application waited 170 seconds and failed with no available instance.
- Without oneDNN a page took 34 seconds. With it a page took 5.9 seconds at the median.
- An unpinned `paddlepaddle` install failed with oneDNN on x86 (`NotImplementedError`). Version 3.2.2 works.
- The `cf` toolchain declares Containers with `defineContainer` and a `containers` array in `cloudflare.config.ts`.

At published prices a page costs about $0.00012 in CPU and memory (computed from 5.9 seconds on `standard-1`). The included 25 GiB-hours cover about 3,800 pages a month. Idle time before a container stops adds to that.

### PaddleOCR in a plain Worker

This was not tested. Transformers.js has no PP-OCR model code. Its repository holds `glm_ocr`, `lighton_ocr`, and `trocr`, and nothing for PaddleOCR. It would not change the constraints, because Transformers.js runs models through ONNX Runtime, the runtime that already ran PP-LCNet in a Worker. PaddleOCR publishes a browser SDK, `@paddleocr/paddleocr-js`, built on ONNX Runtime and OpenCV.js.

Official ONNX exports exist for the detector (4.83 MB) and the Latin recognizer (8.04 MB). With the 14.8 MB runtime they fit the 64 MiB Worker limit. The open risks are the 128 MB memory limit and the CPU time per page. Workers Free allows 10 ms, so this route cannot help a Free deployment.

### Finding a bad Moondream result after the fact

Moondream read 25 pages in four orientations with the planned 2048-token cap, which made 100 calls with no errors. The pages were 9 fixture scans and 16 generated pages. A reading counts as bad when it kept less than half of the distinct longer words of the upright reading. A reading is flagged when it stopped at the token limit, or when at least 30% of its lines or five-word sequences repeat. The 30% was set before the results were seen.

| Orientation | Pages | Stopped at limit | Flagged | Median seconds |
| ----------- | ----- | ---------------- | ------- | -------------- |
| Upright     | 25    | 0                | 0       | 4.3            |
| Turned 90   | 25    | 19               | 20      | 38.0           |
| Turned 180  | 25    | 14               | 15      | 33.1           |
| Turned 270  | 25    | 11               | 13      | 6.8            |

- Of the 75 turned readings, 62 were bad and 13 were usable.
- The flag caught 48 of the 62. The stop reason alone caught 44. No upright reading and no usable turned reading was flagged.
- The other 14 bad readings ended normally with short text. A check of the output cannot see them.
- On the 48 flagged readings, PP-LCNet at confidence 0.7 named the right turn 36 times, a wrong turn 0 times, and made no decision 12 times.
- Running PP-LCNet before every Moondream call would have named the right turn on 44 of the 62, and turned 0 of 25 upright pages.

The run used 13,459 Neurons, about $0.15.

### The Images binding on real uploads

A dev server sent real uploads through the remote Images binding and Moondream. A JPEG with sideways pixels and EXIF orientation 6 archived in 21 seconds with correct text, so the binding applies the tag. A transparent PNG with black text came back as "The image does not contain any text", because JPEG output turned the transparent pixels black despite the documented white default. Stating `background: "#FFFFFF"` on the output fixed it. The same sideways JPEG without a tag stopped at the token limit after 54 seconds and failed its document. Retry, which added a quarter turn, then read the correct text.

The original phone photo then passed on a real staging deployment. It archived in 27 seconds, with one Moondream call of 6.9 seconds and 103 ms of workflow CPU time. Before the fix, one call on that photo ran for 89.6 seconds, sent 4,100 events and 28.23 MB, and stopped at the token limit.

### Reading every rotation after a failure

Schublade now reads a page at all four rotations when the first reading stops at the token limit, and later pages start from the winner. These results replay the recorded readings of 25 synthetic pages in four orientations. The 44 failures are not independent, because each page can fail from up to three starting orientations.

| Rule for picking a reading     | Upright, of 44 failures | Bad text, of 44 failures |
| ------------------------------ | ----------------------- | ------------------------ |
| Most characters                | 40                      | 2                        |
| Most distinct space-split tokens | 42                    | 0                        |
| Most distinct `Intl.Segmenter` words | 40                | 2                        |
| Most digit groups              | 35                      | 9                        |
| Most lines                     | 28                      | 14                       |

Space-split tokens and `Intl.Segmenter` differ on one page, so that gap means little. Schublade uses `Intl.Segmenter`, which also separated words in Chinese, Japanese, Thai, and Arabic samples in workerd. Bad readings are fluent, such as a German table holding 2% of the page's real words, so language detection or a dictionary would likely accept them. That point is inferred and was not tested.

Running the check only after a failure left all 25 upright pages alone and fixed 40 of 75 turned readings. Running it always with the most characters fixed 60 of 75, but turned 5 of 25 upright pages. Blind turning on Retry would have archived bad text in 16 of the 44 failures.

On real services, a sideways JPEG without a tag took four readings and archived with correct text. A two-page sideways scan took five readings instead of eight. Running the three extra readings one after another took 195 seconds for the JPEG on a dev server. Running them in parallel took 135 seconds. The first reading must still fail, and the three parallel calls finished over 60 seconds, not at once. The cause of that spread is unknown.

### Reading errors and AI Search

Schublade's development index uses the `porter` tokenizer, `keyword_match_mode: "and"`, and hybrid retrieval with reciprocal rank fusion. The index holds clean text, so the errors were typed into the query as a stand-in for a document with the error. Keyword matching treats both directions alike. A one-word query is harder on the vector half than a long chunk with a few errors.

| Query                         | Rank with `and` | Rank with `or` |
| ----------------------------- | --------------- | -------------- |
| `Nordkabel`                   | 1               | 1              |
| `Nordkabe1`                   | 2               | 2              |
| `Talbruck` for `Talbrück`     | 1               | 1              |
| `Ta1brück`                    | 2               | 2              |
| `NK-2026-1O48-3391`           | 9               | 9              |
| `NK-2026-1048-3891`           | 4               | 4              |
| `DE28 9302 4580 O418 8200 37` | no result       | 1              |
| `Nordkabe1 Rechnung Oktober`  | 1               | 1              |

The vector half carries misread names. Misread numbers fare worse, and the `and` mode loses a whole multi-word query to one wrong term. The index is small, so a larger archive would rank these matches lower.

Search is not the only reader of this text. Classification receives the same Markdown, so a sender, a date, or an amount can come from an invented reading.

Moondream's service damages letters outside Latin-1. The 16 Polish pages held 138 replacement characters. The 16 German pages held none, and 208 umlauts and sharp s letters came through.

## What Workers Free allows

| Resource               | Workers Free                                       |
| ---------------------- | -------------------------------------------------- |
| CPU per invocation     | 10 ms, with tolerance for occasional overruns      |
| CPU per Workflow step  | 10 ms                                              |
| Workers AI             | 10,000 Neurons a day, about 100 per recognized page |
| Browser Run            | 10 minutes a day                                   |
| Images                 | 5,000 unique transformations a month               |
| Containers             | Not offered                                        |

Both orientation detectors use 25 to 50 times the Free CPU limit. Schublade itself already exceeds it. On a Paid staging deployment, a thumbnail took 176 ms of CPU, the home page 87 ms, and a whole ingestion workflow about 350 ms. Whether Schublade works on Free at all has not been tested on a real Free account.

## Decisions

Built and running on staging:

1. Normalize images through the Cloudflare Images binding, which applies the EXIF rotation. JPEG output needs a stated white background.
2. Limit the long edge to 1600 pixels.
3. Read the stop reason. Repetition checks were left out, because they caught only 4 more of the 62 bad readings.
4. Lower the token cap to 2048.
5. Skip the gateway cache for recognition.
6. Keep Moondream as the only recognizer. Most PDFs arrive with a text layer, and search tolerates small reading errors in names and prose.
7. When a page hits the token limit, read the other three rotations in parallel, keep the reading with the most distinct words, and record the rotation for later pages.
8. Use `keyword_match_mode: "or"` in AI Search.
9. Require Workers Paid for now, and keep Workers Free as a goal.

Rejected:

- Deskewing and flattening pages.
- Splitting pages into parts.
- Repetition penalties, which the Moondream schema does not offer.
- PaddleOCR in a Container, which needs a 1.68 GB image and Workers Paid and gains little on German and English.
- Xberg's WebAssembly build in a Worker, which runs the same model on a slower engine and needs about twice the upload.
- Turning a page blindly on Retry.
- Reading four rotations of every page. The cost would be four times every recognized page.

Open:

- Whether Schublade can run on Workers Free at all, which needs a test on a real Free account.
- Which component raised the original CPU limit error.
- How the methods compare on real household documents, because every comparison here uses synthetic pages.

## Ideas not tested yet

- **Ink check.** Count text-like marks in the page image and compare that with how much was read. It is deterministic and does not depend on language.
- **PP-LCNet as a tie-break.** Use it when the two best readings are close. It named the right turn in 33 of the 44 failures, and a wrong turn in none.
- **Two readings of one rotation.** Read the same rotation at two scales. Real text should agree, and invention should differ. It costs one more call per page checked.
- **Check every document's first page.** Once a realism check can reject junk, a first-page check could catch turned pages that finish normally, which was 20 of 75 turned readings.
- **Re-read earlier pages.** When a later page teaches a new rotation, the pages before it keep their old reading.
- **Show pages upright.** The recorded rotation could also turn the viewer and the thumbnail.
- **OCR on the device.** A future native application could recognize text on the phone and upload a PDF with a text layer, which skips Moondream with no server change.

## Possible blog posts

**What a vision model does with a sideways page.**

1. The bug: an upload that worked and a page that never finished.
2. Why a phone photo is sideways, and why your model may not care about EXIF.
3. Loops, confident invention, and the event stream that grows with the square of the answer.
4. The stop reason, token caps, retries, and caches.
5. Tiles, resolution, and why a 12 megapixel photo is mostly wasted.
6. A checklist for reading documents with vision models.

**Which way is up?**

1. The classifier that scored 99% until it met new fonts.
2. Why asking a vision model which way is up does not work.
3. PP-LCNet and Tesseract in a Worker, and why confidence thresholds matter.
4. Turning and hoping, measured.
5. Reading all four rotations, paying once per document, and what to count.
6. Why fluent junk defeats language checks.

**How good does OCR need to be for search?**

1. Most PDFs already have text.
2. A dedicated OCR engine against a vision model, and how visibly each one fails.
3. What typos do to keyword and vector search.
4. Why one setting, `or`, rescued a misread IBAN.

**Running OCR inside Cloudflare.**

1. What fits in a Worker, what needs a Container, and what Workers Free allows.
2. Where 256 ms of CPU goes when the model takes 10 ms.
3. ONNX Runtime, `tract`, and why a bigger library was not faster.
4. Paid today, Free as a goal.

## Sources

Read directly:

- [Moondream `image_crops.py`](https://raw.githubusercontent.com/vikhyat/moondream/main/moondream/torch/image_crops.py)
- [Moondream `vision.py`](https://raw.githubusercontent.com/vikhyat/moondream/main/moondream/torch/vision.py)
- [Moondream 3 `config.py`](https://huggingface.co/moondream/moondream3-preview/raw/main/config.py)
- [Moondream FAQ](https://docs.moondream.ai/faq)
- [Workers AI Moondream model page](https://developers.cloudflare.com/workers-ai/models/moondream3.1-9B-A2B/index.md)
- [Gemini image understanding](https://aistudio.google.com/docs/image-understanding)
- [Claude vision guide](https://platform.claude.com/docs/en/build-with-claude/vision)
- [Hugging Face `image_utils.py`](https://raw.githubusercontent.com/huggingface/transformers/main/src/transformers/image_utils.py)
- [olmOCR pipeline](https://raw.githubusercontent.com/allenai/olmocr/main/olmocr/pipeline.py)
- [LlamaIndex on failure modes of VLM OCR](https://llamaindex.ai/blog/engineering-insights-failure-modes-that-break-vlm-powered-ocr-in-production)
- [Cloudflare Images features](https://developers.cloudflare.com/images/optimization/features/)
- [Cloudflare Images binding](https://developers.cloudflare.com/images/optimization/binding/)
- [Cloudflare Images pricing](https://developers.cloudflare.com/images/pricing/)
- [Cloudflare Containers pricing](https://developers.cloudflare.com/containers/pricing/)
- [AI Search general availability](https://blog.cloudflare.com/ai-search-ga/)
- [Workflows limits](https://developers.cloudflare.com/workflows/reference/limits/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Browser Run limits](https://developers.cloudflare.com/browser-run/limits/)
- [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- [Getting started with Containers](https://developers.cloudflare.com/containers/get-started/)
- [PP-LCNet orientation model, ONNX export](https://huggingface.co/PaddlePaddle/PP-LCNet_x1_0_doc_ori_onnx)
- [AI Search keyword search](https://developers.cloudflare.com/ai-search/configuration/indexing/keyword-search/)
- [Transformers.js documentation](https://huggingface.co/docs/transformers.js/en/index)
- [PaddleOCR document orientation module](https://www.paddleocr.ai/latest/en/version3.x/module_usage/doc_img_orientation_classification.html)
- [OnnxTR orientation model configuration](https://raw.githubusercontent.com/felixdittrich92/OnnxTR/main/onnxtr/models/classification/models/mobilenet.py)
- [Kreuzberg document orientation source](https://docs.rs/crate/kreuzberg/4.9.0/source/src/doc_orientation.rs)
- [Seeing Straight, arXiv 2511.04161](https://arxiv.org/abs/2511.04161)
- [PP-LCNet paper, arXiv 2109.15099](https://arxiv.org/abs/2109.15099)
- [ONNX Runtime custom builds](https://onnxruntime.ai/docs/build/custom.html)
- [Xberg pure-Rust inference and latency](https://raw.githubusercontent.com/xberg-io/xberg/main/docs-site/src/content/docs/concepts/tract-inference.md)
- [Xberg WebAssembly README](https://raw.githubusercontent.com/xberg-io/xberg/main/crates/xberg-wasm/README.md)
- [Xberg decision record on ONNX Runtime and tract](https://raw.githubusercontent.com/xberg-io/xberg/main/adrs/0005-engine-neutral-inference-seam-over-ort-and-tract.md)
- [PP-OCRv5 mobile detector, ONNX export](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx)
- [PP-OCRv5 mobile Latin recognizer, ONNX export](https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx)

Seen through a search summary, to read before citing:

- [PP-LCNet orientation model card](https://huggingface.co/PaddlePaddle/PP-LCNet_x1_0_doc_ori)
- [PaddleOCR browser deployment](https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/browser.html)
- [PP-LCNet FLOPs and parameters](https://paddleclas-doc.readthedocs.io/zh/stable/models/PP-LCNet_en.html)
- [MobileNetV3-Small FLOPs in PaddleClas](https://paddleclas-doc.readthedocs.io/zh/stable/models/Mobile_en.html)
- [AI Gateway Workers binding options](https://developers.cloudflare.com/ai-gateway/integrations/worker-binding-methods/)
- [AI Search data source configuration](https://developers.cloudflare.com/ai-search/configuration/data-source/)
- [AI Search limits and pricing](https://developers.cloudflare.com/ai-search/platform/limits-pricing/)
- [Worker size limit changelog](https://developers.cloudflare.com/changelog/post/2026-09-04-increased-worker-size-limit/)
- [ONNX Runtime on Workers, unofficial](https://github-users.yhajoa.workers.dev/CosteGieF/ort-cloudflare-workers)
- [Orientation and skew detection, van Beusekom et al.](https://dfki.de/fileadmin/user_upload/import/4943_Joost-Orientation-Skew-Detection-IJDAR10.pdf)
- [Leptonica `flipdetect.c`](https://android.googlesource.com/platform/external/tesseract/+/refs/heads/main/liblept/flipdetect.c)
