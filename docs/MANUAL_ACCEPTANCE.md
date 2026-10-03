# Kio v2 manual acceptance guide

This guide is for the user's own interactive review after building the current checkout. Codex must not launch Kio or operate the UI. Build scripts print the app bundle path; use that exact bundle when you test so an older installed copy cannot be mistaken for this build.

Before testing, run `scripts/build-mac.sh` or `scripts/check.sh`, then open the resulting `Kio.app` yourself. `scripts/check.sh` compiles Debug and Release without opening either app. Use files and public media sources you are allowed to process. Follow My Voice requests microphone and Speech Recognition permission only when you start it.

## 1. Notch shell and navigation

- On launch, confirm Kio appears as a menu-bar app and the black notch shell is collapsed.
- Hover over the notch. It should expand into a compact, rectangular black dashboard with four spaces: **Kio**, **Sessions**, **Clipboard**, and **News**.
- Move the pointer away after selecting or clicking inside the dashboard. It should collapse after the short hover-exit delay, unless an active Cue session is holding the Cue surface open.
- Reopen it with **⌥⌘K**. Switch through all four spaces and confirm the last selected space is restored after reopening.
- Clipboard and News item counts should appear as compact navigation badges. Session unread signals should appear in Sessions. Badge-only updates should not expand the notch.
- Finish a Convert or Reel operation and inspect the collapsed notch. The temporary completion strip should retract; there should be no persistent “finished” title.
- Trigger two quick events if convenient. A higher-priority needs-input/failure event should be shown ahead of ordinary completion events, with the rest handled one at a time.
- In macOS Accessibility settings, enable Reduce Motion and reopen the dashboard. Shell transitions should use short easing instead of the normal spring. Cue text movement should remain non-bouncy.
- Confirm the Kio ribbon/bookmark mascot has the same silhouette and black eyes in the dashboard and temporary event strip. Its small breathing/action movement can be playful; the text surface should remain still.

## 2. Kio → Convert

- Drop one image onto the notch. It should appear as a Convert attachment without choosing a specialist or opening a chat window.
- Convert an image to JPEG, PNG, HEIC, WebP, or TIFF. Open the result and confirm the original still exists.
- Convert several images together and check that each output is created. Repeat with a width request such as `1200 px`.
- Convert an image with `jpeg under 2mb`. Check that the result is JPEG and at or under the requested size when that is achievable. If it is not, Kio should report the limitation rather than claim success.
- Convert a local video to MP3 using `mp3` or `give me the audio`. Check that the audio plays. Also try M4A, WAV, or FLAC only when you need those targets.
- Convert video to a supported MP4, MOV, WebM, or MKV target, resize it, and try a target-size request. Confirm unsupported codec/container combinations are reported clearly.
- Drop two PDFs and merge them. Repeat with a compression/size request and confirm the merged output is then compressed. Try a single PDF compression and several images to PDF.
- Ask for an unsupported transformation (for example, “make this cinematic”). Kio should explain that Convert does not support it and should not invoke a general model or change the source file.
- Confirm there are no archive, rename, file-organization, image-analysis, arbitrary PDF page-editing, or transcription controls in Convert.

## 3. Kio → Reel

- Paste or drop a public media URL. The Kio space should inspect it and show its title, source, duration when available, and only the inspected qualities/formats.
- Choose a quality and format and download. Check that the selected quality is honored, that the saved file plays, and that the destination does not overwrite an existing file.
- If the source provides language/original-track metadata, inspect a download known to have multiple audio tracks. Reel should prefer the original track based on the retained language preference signals.
- Try an audio-only download in MP3 or M4A where offered. If the source exposes subtitles, confirm the subtitles operation remains available through Reel's supported action path.
- Try an unsafe scheme or a loopback/private URL. It should be rejected before connecting. Do not use login-gated or DRM-protected media for this check.
- Confirm errors identify unsupported, inaccessible, or unverifiable media rather than displaying a false success.

## 4. Kio → Cue

- Choose Cue, paste a multi-paragraph script, and select **Classic**. Start, pause/resume, jump to a tapped word, and stop.
- Select **Follow My Voice** and start it manually. Grant permissions only if macOS asks. Read a paragraph aloud, pause, resume, and stop; then test a script with numbers, technical terms, and Kio/Kyo/Keo.
- Watch a long paragraph while the active word advances. Lines and word positions should stay fixed; the active word changes color without bolding, resizing, changing font, adding a capsule, or changing its width.
- The line should stay still while words advance across it. When progress enters the next visual line, the complete document should move up by roughly one line in a gentle 0.55-second ease, with no bounce or overshoot.
- Check paragraph spacing, justified non-final lines, leading-aligned final/short lines, and the fixed 17–18 pt typography. Cue should remain readable without changing size during a session.
- Move the pointer away during active Cue. The Cue reading surface should stay available until Cue is stopped; after stopping, move away and confirm the notch collapses normally.

## 5. Sessions

- Open Sessions and enable one provider hook that you use: Claude Code, Codex, Cursor, or OpenCode. Review the provider configuration diff yourself if desired; Kio should preserve unrelated hooks and create a single backup for JSON-based configurations.
- Start a new provider session. Confirm it appears locally with provider, project, and running state. Finish it and confirm the state changes and a brief ambient notch event appears.
- Where possible, trigger a permission/needs-input state. It should receive higher priority than a normal completion event.
- Open the expanded Sessions space to review the latest state, then mark it read. Disable the provider and confirm Kio removes only its own hook/plugin.
- Confirm no prompt, transcript, tool arguments, or terminal output appear in Kio. Hooks report bounded lifecycle metadata only.

## 6. Clipboard

- Enable Clipboard history in Settings. Copy plain text, an image, one or more files, and a folder. Confirm the items appear in Clipboard and that Kio's own pasteboard writes are not re-captured as new history.
- Search, pin an item, copy an older item back to the pasteboard, delete an item, then clear history. Pinned entries should survive ordinary retention; clear should remove Kio's saved image copies too.
- Set an application exclusion and copy from that app. Confirm it is skipped. Try an item marked concealed or transient where you have a safe way to do so.
- Check the configured retention and count limits. Clipboard should remain local and should not show private content in Sessions or News.

## 7. News

- Add a public HTTPS RSS or Atom URL and a topic label, save it, then refresh. Confirm headlines show publisher/date when available and open in the browser.
- Add a topic to the explicit alert-topic list and refresh a newly published matching item. Only an explicitly enabled topic may create a temporary ambient event. Ordinary feed refreshes should not expand the notch.
- Try an HTTP feed and a localhost/private URL. They should be rejected. Disable News in Settings and confirm refresh makes no network request.

## 8. Product reset

- Confirm there is no full chat window, chat transcript, model/provider-key screen, local Qwen download, specialist crew, phone pairing, Courier, PWA, relay, or mobile setup requirement.
- Confirm the dashboard has only the four spaces named above and Kio contains only Convert, Reel, and Cue.
- Verify every output opens in the expected app and the source files remain intact.

## Report issues

When reporting a problem, include the Kio version/build from the bundle you tested, macOS version, space/feature, exact steps, and the visible error. Do not include private clipboard contents, local project paths, or private media links.

Kio was not launched or interactively tested by Codex. Automated checks and build evidence are recorded in [Build status](BUILD_STATUS.md); they do not replace these visual, microphone, provider-hook, pasteboard, or live-feed checks.
