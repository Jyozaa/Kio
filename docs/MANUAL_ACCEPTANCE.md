# Kio manual acceptance guide

This checklist is for the user to run after the code-only verification pass. The app, browser, and microphone were not opened for this pass, so every visual, permission, and live-service item below remains unverified until you perform it.

Use your own files and media you have permission to save. Do not put real provider keys in screenshots, screen recordings, or issue reports. Record the Kio version and build number for any failure.

## Focused acceptance: Cue startup, notch pinning, and Reel inspection

This section covers the focused fixes from baseline `69f7943f082e2fbf38b9f5847574f520932beb5b`. Codex did not launch Kio, request microphone access, inspect Cue visually, or use a live media URL. The following checks remain for you.

### Test 1 — Cue crash

1. From `/Users/joe/Desktop/Kio`, build and install using `bash scripts/dev-run.sh`.
2. Launch Kio and expand the notch.
3. Open Cue and paste:

   ```text
   Welcome to Kio.
   This is a short Cue crash test.
   The teleprompter should remain open while I speak.
   When I finish, the notch should collapse.
   ```

4. Select **Follow My Voice** and press **Start**.

Expected: Kio does not crash; first-use microphone/speech permission may appear; the active teleprompter opens and the waveform responds.

If Kio crashes, collect the newest Kio report from `~/Library/Logs/DiagnosticReports/` and Console entries for subsystem `app.kio.mac`, category `Cue`. Do not paste unrelated private logs.

### Test 2 — Word Tracking crash

Repeat Test 1 with **Word Tracking**. Expected: no crash.

### Test 3 — Classic

Repeat Test 1 with **Classic**. Expected: no microphone is required and Kio does not crash. If Classic works while both speech modes fail, that points toward audio/speech startup.

### Test 4 — Cue stays expanded

Start **Follow My Voice**, move the pointer completely away from the notch, and wait 10 seconds. Expected: the notch stays fully expanded and the teleprompter remains visible. Switch to another app; Cue should remain expanded while the session is active.

### Test 5 — Cue natural completion

Use a short 1–2 sentence script and read it to the end. Expected: recognition reaches the end, a brief completion state appears, Cue exits, and the black notch smoothly collapses. The mascot should not appear during collapse; the collapsed notch should be completely black.

### Test 6 — Manual Done

Start a longer script and press **Done** or **Close** before finishing. Expected: speech stops, Cue exits, the notch collapses, and no expanded normal Kio screen remains.

### Test 7 — Pointer does not override Cue

Start Cue, move the pointer away, back, then away again. Expected: the notch remains expanded until Cue ends.

### Test 8 — Reel inspection

Use a video URL you have permission to download, paste it, and ask **“download this”**. Expected: no “malformed media inspection data” error; Reel displays title/media information and a quality picker when needed.

### Test 9 — Reel explicit download

Ask **“download this in 720p mp4”**. Expected: the download proceeds without an inspection parsing error.

### Test 10 — Reel audio

Ask **“download the audio as m4a”**. Expected: Reel returns a valid M4A result.

If Reel still fails, record the site/domain, exact Kio error, and Reel Diagnostics versions. Do not provide a sensitive/private URL.

## Focused acceptance: Cue transcript tracking and bundled Reel

This covers the 2026-10-01 implementation pass. Codex did not launch Kio, inspect the UI, request permissions, use a browser, or run a live media URL. Perform these checks manually after installing the Debug build.

### A. Cue active appearance

1. From `/Users/joe/Desktop/Kio`, run `bash scripts/dev-run.sh`, then launch the canonical Kio app.
2. Expand the notch, open Cue, and paste:

   > Welcome to Kio, the smart assistant that lives in your MacBook notch. Today I am testing the new Cue teleprompter. The words should follow my voice smoothly as I speak in real time. I should be able to look near the camera instead of constantly looking down. When I finish this paragraph, Cue should remain stable and easy to read.

3. Choose **Word Tracking** and press **Start**.

Expect roughly 3–5 readable lines, a bounded reading window, readable past words, an inline accent current word with no capsule, dimmer future text, a compact waveform/recent-phrase/listening/Done strip, and almost no persistent controls. No mascot or regular composer should appear. Fail if text is tiny, chip-like, reflows on every word, or shows a dense full-script wall.

### B. Word Tracking

Read naturally, pause for three seconds, and resume. Expect accurate monotonic movement, stable position during silence, and resumed tracking after the pause. Small recognition delay is acceptable; random reverse movement or an uncertain large jump is not.

### C. Follow My Voice

Exit/reopen Cue, choose **Follow My Voice**, and read the first sentence slowly. Pause mid-sentence. The highlight must follow recognized words, stop promptly in silence, and resume from the spoken position. It must not advance on a WPM timer.

### D. Fast speech

Restart Follow My Voice and read “Today I am testing the new Cue teleprompter” noticeably faster. Expect quick transcript-based catch-up rather than a fixed-rate lag.

### E. Variable speed

Read one sentence slowly, the next quickly, then a third at normal pace. The highlight should change pace with recognized words.

### F. Filler words

Read “Today I am, um, testing the new Cue teleprompter.” Cue should continue past “um.”

### G. Omitted short word

Use script “The words should follow my voice smoothly” and say “The words should follow voice smoothly.” Cue should continue past the omitted “my.”

### H. Recognition revision

Speak a phrase that is initially misrecognized, then naturally correct it. Expect recovery without moving backward through confirmed words.

### I. Waveform

Observe silence, loud speech, quiet speech, then silence. Expect dim/low bars while quiet, a compact level response while speaking, smaller activity for quiet speech, and quick decay after stopping. It must not lag by seconds.

### J. Recent recognized phrase

While speaking, check the bottom snippet. It should update with the last few words and never expand into the full transcript.

### K. Control reveal and hide

Move the pointer over Cue. Pause, Restart, text size, Done, and the Classic-only speed control should appear as an overlay. Stop moving for about three seconds; controls should fade without shifting the script. Move over a control and confirm it remains usable.

### L. Classic

Choose **Classic**. Expect fixed-speed scrolling, Pause/Resume, Restart, and a speed control. Classic must remain usable without microphone or Speech Recognition permission.

### M. Permissions

On first speech-tracking start, allow microphone and Speech Recognition if desired. Quit/reopen Kio and confirm no permission prompt appears at launch. If Speech Recognition is denied, Classic must remain usable.

### N. Reel Settings

Open **Kio Settings → Reel**. Expect **Status: Ready**, **Media engine: Bundled with Kio**, and **Diagnostics…**. There must be no Prepare Reel, Python setup, helper folder, or download progress.

### O. Reel diagnostics

Open Diagnostics and confirm yt-dlp, Deno, FFmpeg, ffprobe, Streamlink, and Python versions. Runtime files must resolve inside `Kio.app/Contents/Resources/Reel`, not `~/Library/Application Support/Kio/Helpers`.

### P. Permitted YouTube video

Use a video you own or may save. Submit its URL to Reel, inspect it, choose 720p MP4, and download. Expect no setup prompt and a valid local file.

### Q. 1080p and Deno

Request the permitted video in 1080p MP4. Expect direct execution for the explicit choice and no missing-JavaScript-runtime warning. This does not guarantee every remote source remains available.

### R. Audio

For a permitted VOD, request M4A, then MP3. Confirm each file plays and has the requested extension. Reel should not ask to prepare helpers.

### S. Cancellation

Start a moderately large permitted Reel download and press Stop. Expect process termination, temporary-output cleanup, no incomplete result, and Kio returning to a usable state.

### T. Clean-install runtime source

If `~/Library/Application Support/Kio/Helpers` exists, rename it temporarily. Launch the new app and try Reel; it should use the copy inside Kio.app. Restore the old directory afterward if needed.

### U. CPU observation

Use Follow My Voice for several minutes and observe Activity Monitor/fan behavior. There should be no unnecessary local Qwen inference. Reel downloads/transcoding may use CPU. Record unusual sustained usage as an observation.

For Cue failures, include a screenshot plus exact script, words spoken, and highlight position. For Reel, include the URL domain only, requested format/quality, full error, and diagnostics versions. Never include API keys or private speech recordings.

## A. Launch the intended development build

From Terminal, run the repository's existing stable-signing installer:

```sh
cd /Users/joe/Desktop/Kio
bash scripts/dev-run.sh
```

This builds the Debug app, signs it with the already-configured local Kio identity, installs it to `/Users/joe/Applications/Kio.app`, and launches that canonical copy. It does not create an Apple Development certificate. If Kio is already installed and you only want to relaunch it, use:

```sh
open -na "/Users/joe/Applications/Kio.app"
```

Confirm the installed app's version and build in Terminal:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Users/joe/Applications/Kio.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "/Users/joe/Applications/Kio.app/Contents/Info.plist"
```

The current project settings report version `0.1.0`, build `1`. If the output differs, check that `/Users/joe/Applications/Kio.app` is the build you intended to test.

## B. Collapsed notch

1. Launch Kio and move the pointer well away from the notch.
2. Wait at least five seconds.
3. Inspect the MacBook notch and the display directly below it.

**Expected:** the collapsed silhouette is black and blends into the hardware. No cream Kio, eyes, specialist, text, icon, indicator, animation, or colored flicker is visible.

**Failure:** any mascot or decoration remains while collapsed, a character flashes before the black surface opens, or the black shape is visibly detached from the hardware notch. Capture a still image showing the whole top edge of the screen.

## C. Expansion and collapse synchronization

1. Hover over the notch and watch it open.
2. Move the pointer away and watch it close.
3. Repeat five times slowly, then five times quickly.
4. Include a run where you click the composer, type briefly, then move the pointer away.

**Expected:** the black shell and its contents move as one shape. Text, mascot, controls, chips, result card, and hit area stay inside the black silhouette. Contents retract into the notch; nothing floats after the shell closes. Expansion shows the shell before or as content appears. Reduce Motion still preserves a single contained transition.

**Failure:** a one-frame ghost, a control or character outside the shell, a jagged rectangle, content disappearing before the shell, or the shell closing while a focused interaction is still in progress. If it fails, make a short screen recording that includes the pointer and the full notch during both slow and quick repetitions.

## D. Mascot body outline

Inspect Kio, then trigger tasks owned by Pixel, Echo, Scribe, Reel, and Cue so each character appears. Use a small avatar and the larger notch mascot where available.

**Expected:** every body has a subtle darker edge visible against black; the two eyes remain unoutlined. The body still reads as a soft pastel blob and does not gain a bright white stroke or neon glow. On small avatars, the border must not overwhelm the body.

**Failure:** a missing or bright outline, outlined eyes, an unreadable body, or visibly lumpy/asymmetric shape. Capture one larger and one small example.

## E. Blinking and idle movement

1. Leave Kio expanded and idle for 30–45 seconds.
2. Observe without moving the pointer for several seconds at a time.

**Expected:** multiple natural single blinks; an occasional double blink is acceptable. Eyes briefly become nearly flat and reopen smoothly. Breathing, glances, and lean are subtle; Kio does not bounce continuously. If there has been no blink after about 15 seconds, record that as a failure.

## F. Cursor awareness

Move the pointer, in order, to the expanded notch's left edge, right edge, composer, and a point above the mascot. Pause at each position, then stop moving.

**Expected:** the eyes notice the pointer first. The body follows about a fraction of a second later with a small lean, then relaxes after the pointer stops. While typing, the gaze favors the composer. Reduce Motion removes exaggerated body travel but keeps the face legible.

**Failure:** eyes do not react, the body moves before the eyes, movement twitches or tracks every tiny cursor change, or typing makes the character stare away from the composer.

## G. Full chat cleanup

Open History from the notch.

**Expected:** the chat is black to match the notch, the header is compact, and it does not show a permanent row of all agents. Kio is the default speaker; the active specialist appears only when relevant. Crew is a compact menu, search is opened only on demand, artifact actions are compact, and the composer remains usable.

Compare its density with the prior build. Capture the whole chat window if an agent wall, oversized artifact card, or crowded control row remains.

## H. Provider and BYOK checks

For each provider for which you already have a key—OpenAI, Anthropic, Gemini, OpenRouter, and Groq—repeat these steps:

1. Open **Kio → Settings → Intelligence**.
2. Select the provider and enter its API key in the secure field.
3. Select **Save key**. Confirm the field clears and Kio reports that the key is saved in Keychain.
4. Select **Test connection** and wait for the model-list result.
5. Select **Fetch models**; choose an available model, or enter the model identifier manually.
6. Run a short semantic request such as “Summarize this paragraph in one sentence.”
7. Quit and reopen Kio; check the provider still reports a saved key without revealing the key.
8. Select **Remove key** and confirm the provider becomes disconnected.

Do not paste secrets into normal chat. Keep screenshots clear of the key field while typing and never include raw keys in logs.

With **Content privacy → Ask before sending contents**, run a semantic task on a local text file. **Expected:** Kio asks before sending document text to the selected provider; canceling sends nothing. A request that needs only file metadata should not show that content prompt. Repeat with **Metadata only** and confirm the cloud content task is blocked. Use **Allow contents** only if you intend to opt in.

**Expected for all providers:** requests go directly to the chosen provider; the key stays masked and survives restart; a failure does not silently switch providers; a cloud task does not start Local Qwen. If a provider fails, record its name, model identifier, error text, and time—but never the key.

## I. Local-Qwen fan check

Select a configured cloud provider, then attach suitable local fixtures and try:

- “Merge these PDFs.”
- “Resize this image to 1200 px.”
- “Rename this file to final.”

**Expected:** deterministic native operations complete without preparing or loading Local Qwen. Observe Activity Monitor or Kio's local-model status if available. Then ask for a semantic summary and confirm the selected cloud provider handles it. Fan level is subjective; record it as an observation, not a pass/fail by itself.

## J. Pixel format conversion

Prepare one HEIC/HEIF photo, one JPEG, one PNG with transparency, and optionally one TIFF. Attach one file at a time unless a test says batch.

1. For HEIC, ask “Convert this to JPEG.” Verify a `.jpg` or `.jpeg` result opens in Preview and looks correct.
2. Convert the same HEIC to PNG.
3. Convert the JPEG to PNG.
4. Convert the transparent PNG to JPEG. Verify the formerly transparent area is white rather than black.
5. If TIFF is available, convert it to PNG.
6. Select three HEIC images and ask “Convert these to JPEG.”
7. If ImageIO supports WebP or HEIC output on this Mac, verify the output extension agrees with the actual file type. Unsupported encoders should not be offered as successful outputs.

**Expected:** batch conversion creates three outputs, sources remain unchanged, each extension agrees with its encoded bytes, JPEG uses white to flatten alpha, and animation loss is explicitly identified if an animated first frame is converted.

**Failure:** wrong extension/encoding, missing batch output, overwritten source, black alpha background, or silent animation loss. Keep the input files and note their formats and macOS version.

## K. Pixel background removal

Choose a photo with a clear person or object against a distinguishable background.

1. Attach one image and ask “Remove the background.”
2. Open the result in Preview or an editor that displays transparency.
3. Attach two or three different images and ask “Remove the backgrounds.”

**Expected:** one transparent PNG per input; each output keeps its original source unchanged and has a usable alpha channel. A photo without a usable subject mask should fail with a clear explanation.

**Failure:** source overwritten, output is entirely transparent or black, wrong file count, or result is not a transparent PNG.

## L. Reel bundled runtime (previous pass)

For current Reel behavior, use focused tests N–T below. The former on-demand helper setup flow is retired. The current app reads helpers from its bundled Resources/Reel directory and does not install them into Application Support. Gallery download is intentionally unavailable because gallery-dl is GPL-2.0-only and this repository does not declare Kio redistribution terms.

## M. Reel YouTube/VOD inspection and download

Use a public video you own or are explicitly allowed to save.

1. Paste its URL into the notch.
2. Type “Download this.”
3. Review the Reel inspection and compact picker.
4. Select `720p` and `MP4`, then Download.
5. Verify the result opens and the source page has not changed.
6. Repeat with “Download this in 1080p MP4.”

**Expected:** inspection shows a safe title, duration/source where available, and only normalized qualities and containers reported by the source—not raw extractor format IDs. Explicit quality and format skip the picker when understood. Unsupported or unavailable options produce a clear error.

## N. Reel audio

Using a permitted VOD URL, ask “Download the audio as MP3.” Verify the output is `.mp3`, plays in a local player, and contains no video track. Repeat with “Get this as M4A.” WAV/FLAC are optional if offered for that source.

**Expected:** Reel acquires the online source and uses Echo/local FFmpeg for conversion when needed. It must not silently produce a video file or claim a format the output does not have.

## O. Direct video URL

Use a permitted direct public `.mp4` URL, not an account-only or local-network URL. Ask Kio to download it.

**Expected:** Reel uses native direct HTTP when the requested format matches the source, verifies a non-empty result, and keeps it under the task size limit. Redirects to private/local addresses must be rejected.

## P. Live stream

Use a brief public stream you are permitted to save. Ask “Save this livestream.” Confirm the working state identifies Reel, then use **Stop** after a short sample.

**Expected:** the stream is identified as live where source metadata allows; Stop ends the helper promptly and leaves no partial result exposed. Do not test DRM-protected or account-gated streams.

## Q. Download cancellation

If you have a permitted large direct download, start it and press **Stop** while it is running.

**Expected:** the task cancels promptly, no incomplete destination appears as a completed artifact, temporary files are removed, and Kio returns to an idle usable composer.

**Failure:** Stop does nothing, a corrupted result is exposed, or temporary output remains after the task has settled. Note how long cancellation took and the helper in use.

## R. Cue setup

Open the notch, select **Cue**, and confirm setup appears inside the expanded notch rather than a separate giant window. Select **Word Tracking** and paste this exact test script:

> Welcome to Kio. Today I am testing the Cue teleprompter. The words should highlight as I speak. The prompt should follow my voice without jumping around. When I finish this sentence, Cue should reach the end.

**Expected:** script editor, mode selector, language choice, readable text-size control, and **Start** are visible. The standard conversation/composer remains out of the way once Cue is active.

## S. Cue Word Tracking and permissions

1. Press **Start** in Word Tracking.
2. On first use, macOS may ask for Microphone and Speech Recognition access. Allow them only if you want to test speech tracking. The request should occur now, not at Kio launch.
3. Read the test script naturally. Pause for two seconds, repeat a word, skip a short word, then continue.

**Expected:** the read words become lower emphasis, the current word has clear contrast, and upcoming text stays readable. Progress follows the spoken script, does not move backward on transcript revisions, does not advance during silence, and does not jump across many words on one uncertain recognition update. The active line stays near a comfortable reading position.

If permission is denied, Classic remains usable and Cue offers a button to open the relevant System Settings privacy pane. Kio must not ask for Accessibility or Screen Recording permission for Cue.

## T. Cue manual jump

While Word Tracking is active, click a later visible word and continue reading from there.

**Expected:** the reading position jumps to the selected word. A transcript from before the jump must not pull the highlight backward. If the recognizer needs to restart, it should resume at the selected position.

## U. Cue Classic mode

Exit Cue, reopen setup, select **Classic**, and press Start.

**Expected:** no microphone or Speech Recognition permission is requested. Scrolling advances at the selected speed; Pause freezes it, Resume continues it, Restart returns to the beginning, and Done/Exit returns to the normal notch.

## V. Cue Follow My Voice mode (previous pass)

Select **Follow My Voice** and press Start. Allow microphone and Speech Recognition access if desired. The highlight follows recognized script words; it does not scroll from microphone volume or configured WPM. Use focused tests C–H below.

## W. Cue completion

Finish a short script in each mode that supports completion.

**Expected:** a stable “Script complete” state appears with **Restart** and **Done**. It does not vanish immediately. Restart returns to the beginning; Done closes Cue and restores the regular Kio composer.

## X. Scribe to Cue

Paste some notes and ask: “Turn this into a short speaking script.” When the text result appears, choose **Cue** / **Open in Cue** on the result.

**Expected:** Cue setup opens with the result text loaded into its editor. It does not submit that text to speech recognition until you press Start.

## Y. Reduce Motion

Enable **Kio → Settings → General → Reduce Kio character motion**. Repeat notch open/close, blinking, and Cue tests.

**Expected:** exaggerated body travel is reduced; the black shell still moves in sync with its contents; the character remains legible; no content floats; Cue remains functional. Blinking may remain because it is a small expression rather than body travel.

## Z. Permission and credential regression

After you have used Cue once, quit and reopen the canonical app. Do not open Cue immediately.

**Expected:** Kio does not repeatedly request microphone or Speech Recognition at launch. Any previously saved BYOK key remains connected and masked. Permissions are requested only when the matching Cue feature starts; macOS may remember the choice or let you change it in System Settings.

If a prompt repeats unexpectedly, record the exact prompt text, macOS version, Kio version/build, and whether the bundle path is `/Users/joe/Applications/Kio.app`. Do not include keys, transcripts, or private audio in a report.

## Optional phone roster check

If you use the already-paired PWA, reload it manually and confirm Reel and Cue appear in the shared roster and their status messages decode. Do not re-pair or deploy as part of this code acceptance pass.

## HARDENING PASS — format routing, media contracts, Reel, Cue, and phone isolation

This section covers the release-hardening changes on top of the repository state inspected for this pass. Codex ran source-level and noninteractive checks only. **Kio was not launched or interactively tested by Codex.** Run these checks with copies of files you can safely use; do not use media you are not authorized to download.

### 1. Install the build you are testing

From Terminal, run:

```sh
cd /Users/joe/Desktop/Kio
bash scripts/dev-run.sh
```

This builds, installs, and launches the canonical local app at `/Users/joe/Applications/Kio.app`. Confirm the version/build shown by Kio (or inspect `CFBundleShortVersionString` and `CFBundleVersion` in that app's `Contents/Info.plist`) before testing. This is a manual user step; Codex did not run it.

### 2. Image destination format and preservation

Use one PNG test image and keep the original available for comparison. Attach it and run these as separate requests:

1. **“convert this png to a heic”** — expect a `.heic` output. Open it in Preview and confirm the image is legible; if Preview's Inspector reports the type, confirm HEIC. The attached PNG must remain unchanged.
2. **“convert this into jpeg”** — expect JPEG content with the exact `.jpeg` extension.
3. **“make this a jpg”** — expect JPEG content with the exact `.jpg` extension.
4. **“convert this PNG to TIFF”** — expect `.tiff` and an image that opens in Preview.
5. **“give me a webp version”** — if Kio reports success, expect a decodable `.webp`; if the installed ImageIO encoder does not support WebP, expect a clear unsupported-format result instead of a mislabeled file.
6. Repeat with a JPEG source and ask **“convert JPEG to PNG”**. Expect `.png` content, a readable result, and an unchanged source.

If available, use a JPEG with EXIF orientation (portrait pixels with a rotate-display tag). Convert it, resize it, and create a PDF from it. All three outputs should look upright as the original does. For an animated GIF or other animated input, confirm Kio says only the first frame was used.

### 3. Audio conversion from audio and video

Attach a small video fixture with an audible audio track. For each request below, start from the original video:

1. **“convert this into mp3”**
2. **“give me the audio as m4a”**
3. **“turn this video into wav”**
4. **“extract the audio as flac”**

Each result should have the requested extension, play in a local audio player, and contain audio without a video stream. If Kio reports success, its result details should identify the requested format. Repeat MP3/M4A/WAV/FLAC from a small audio-only source. A source with no audio track should produce a specific no-audio error, not a blank successful file.

### 4. Table direction and safe clarification

Attach a small JSON object/array and ask **“convert this JSON to CSV”**. Expect a `.csv` result. Attach a CSV and ask **“turn this CSV into JSON”**; expect `.json`. Check that headers/values map correctly. Then ask **“don't convert this to PNG”** with an image attached; Kio must ask what you want or leave it unchanged and must not create a PNG conversion.

With a disposable multi-page PDF, ask **“get rid of page seven”** and check that exactly that page is removed from a new copy. Repeat from the original with **“take pages five through twelve”**; expect a separate eight-page PDF in the original order. The source PDF should remain unchanged.

### 5. Reel inspection, picker parity, and supported sources

Use several different public media providers for media you own or are permitted to save. Do not use account-only, DRM-protected, or private material.

For each source:

1. Paste its URL and ask **“download this”**.
2. Expect an inspection card that shows the media title and provider, with quality/format controls when that source exposes choices. No `.kio-reel-info` item should appear as a normal file result or “Done” output.
3. Compare the Reel controls in the notch and History/full chat. Both should offer the same source, quality, and format choices.
4. Select **720p MP4** where available and download. Expect a conflict-safe filename derived from the source title, a playable video, and a verified MP4 result. If 720p or a compatible MP4 stream is unavailable, Kio should state that clearly rather than claim it selected one.
5. Repeat with **audio MP3**. Expect a playable `.mp3` with no video stream.

Try one source that resolves through a generic extractor and, if available, one that resolves through Streamlink. A provider failure should be reported as unsupported, authentication-required, or DRM-protected when that is what the resolver can establish. Kio should not use browser cookies or bypass access controls.

If you have a permitted direct-media URL that redirects, check that a normal public redirect can complete and a redirect to localhost/private-network space is rejected. For a live stream, stop it after a short sample; expect cancellation to stop the helper and remove incomplete output. Do not leave a live capture running unattended.

### 6. Cue exact alignment regression

In Cue, paste this exact script:

> testing, testing, 1, 2, 3, my name is joe and today i am testing cue in my productivity app kio

Select **Word Tracking** or **Follow My Voice**. Speak one phrase at a time, pausing between phrases:

1. “testing”
2. “testing testing”
3. “one”
4. “two three”
5. “my”
6. “my name is joe”
7. “and today i am testing cue”
8. “in my productivity app kio”

The first “testing” should select the first occurrence; the repeated phrase should advance to the second; speaking “one” or “my” alone must not teleport to a distant duplicate. Contextual phrases may make larger forward progress. Pause, then continue. Repeated or revised recognition callbacks must not independently confirm a distant jump. The recent-phrase display should show what was recognized even if the highlight holds position. Finally move the pointer away during Cue and confirm the session stays open; finish or press **Done** and confirm it exits and the notch collapses.

### 7. Phone/local input isolation and task messages

Leave an unrelated local file attached in the Mac composer—for example, a private PDF you do not intend to send. From the already-paired phone/PWA, submit a different request with a different test image. On the Mac, inspect the operation/result and confirm it uses only the phone image; the local PDF must not be processed, included, or sent to a provider. Then retry the same phone request after a staging failure if you can reproduce one; it should remain eligible for retry because it was not accepted.

For a local request, confirm the intended composer attachments are used as usual. Drop the same file twice in one batch and confirm Kio does not create duplicate attachments. Submit a workflow/template list request and confirm the user message appears only once.

### 8. Result and failure language

Stop a running task with the Stop control. It should say **“Cancelled”** (or an equally clear cancellation message), clean temporary outputs, and leave the app usable. Trigger an ordinary unsupported format/source failure; it should state the actual issue and must not report **“Operation Stopped”** as if that were a cancellation. For successful image/audio/video/PDF tasks, check that **Done** appears only alongside the verified output.

### Report a failure

Record the exact request, source file type (or media provider/domain only), requested target, Kio version/build, and the visible error/result. For orientation/Cue issues, include a screenshot or short recording that does not reveal private documents, keys, speech content, or account-only media. Do not attach API keys, browser cookies, private URLs, or private recordings.
