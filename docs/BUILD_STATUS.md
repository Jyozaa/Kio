# Kio build and verification status

Last updated: 2026-10-02

## Repository and CI state

- Repository: `/Users/joe/Desktop/Kio`, branch `main`.
- Actual starting HEAD: `4df4e4fe68cd61d3d72a8945f671df647de0de30` (`improvements to reel`). Final HEAD is the same; changes remain local and uncommitted. No commit or push was made.
- GitHub Actions run [36990214348](https://github.com/Jyozaa/Kio/actions/runs/36990214348) for that unchanged HEAD was `in_progress` at both the start and final status checks. It cannot verify this uncommitted working tree. Run [36978665130](https://github.com/Jyozaa/Kio/actions/runs/36978665130) was also still in progress on the preceding `ede42d6` commit. The older completed run [36966311918](https://github.com/Jyozaa/Kio/actions/runs/36966311918) failed on `1dc9cfd`; it predates this pass.
- The stale duplicate `docs/BUILD_STATUS 2.md` and untracked `docs/BUILD_STATUS 3.md` were removed. This file is the current status record.

## Reel changes

- The earlier auto-dub selection happened because Kio kept an audio track's language but discarded yt-dlp's `language_preference`, `format_note`, `audio_channels`, `abr`, `preference`, and `source_preference`. Multiple AAC tracks therefore tied and extractor order could decide the winner. These signals are now retained in optional variant fields, so old saved `.kio-reel-info` records remain decodable.
- Audio is ranked by original, default, ordinary, then descriptive/audio-description class. Original indicators include `language_preference >= 10` or an original note; default includes `>= 5` or a default note; descriptive notes or `<= -10` rank last. Within a class, the selector considers target compatibility, preferred codec, bitrate, channels, source preference, and stable IDs. For MP4, H.264/AAC is preferred; for WebM, compatible VP9/AV1 and Opus streams are retained. An original track that needs a supported conversion outranks a more convenient dub.
- Same-quality streams receive deterministic ranking by language class, target-container/codec feasibility, codec, FPS, video/audio bitrate, channels, source preference, and stable IDs. Input order is not a tie-break. `best` is computed independently per target container. Exact requested quality remains preferred even if conversion is required; a lower-quality fallback is explicit in `ReelVariantResolution`.
- Reel now returns a typed resolution record containing requested quality/container, selected source IDs, output method, and whether a lower-quality fallback was used. Bounded internal diagnostics explain source codecs, audio language preference, conversion, and fallback without exposing raw IDs to ordinary users.
- Streamlink no longer claims its source container is MP4. Its source container and audio availability remain unknown when Streamlink cannot establish them; MP4 is represented as Kio's conversion target, not as observed source capability.
- One `ReelInspectionPolicy` bounds inspection JSON to 512 KiB and format/variant counts to 512 for both persisted reads and inspection output. Persisted arrays are checked before decoding so historical truncation behavior cannot hide an over-limit file. Reel inspection remains available for multiple downloads from the same card and keeps its bounded cleanup/retention behavior.
- Error categories distinguish source/audio selection, extractor process, FFmpeg decode/encode/mux, VideoToolbox, verification, timeout, cancellation, output limit, DRM, and authentication. Internal excerpts are bounded and path-sanitized. Streamlink fallback is limited to cases where another resolver may help; explicit inspected selections and DRM/auth/unsafe failures do not silently fall back.
- The distribution has no software H.264 encoder fallback. The misleading dead OpenH264 path was removed; VideoToolbox is the only H.264 encoder and its failures are reported. No GPL x264 was added. The manifest regression test verifies OpenH264 is absent.
- The full-chat inline Reel picker and notch picker still use the shared typed selection path. The picker actions call typed operations without converting a selection into English and reparsing it.

## Cue changes

- The broad forward search was replaced by anchored sequential matching from confirmed progress and a small prior context. Character and word strategies compare bounded local candidates; the matcher allows only small token skips and commits progress monotonically. A distant movement needs agreement from two distinct transcript identities, so duplicate recognition callbacks do not count as fresh evidence.
- Numbers keep contextual alternatives: spoken `one two three` may align with nearby `1, 2, 3`, while “one hundred twenty three” may align with nearby `123`. Interpretation depends on local script context.
- Kio/Kyo/Keo are local aliases only when Kio is the nearby expected token. Short common words need near-exact local evidence and cannot establish a distant position.
- Each reading session/restart/manual jump increments its transcript generation; callbacks from an older generation are rejected. The existing modern SpeechAnalyzer backend and SFSpeechRecognizer fallback are retained.
- `CueContextVocabulary` selects bounded distinctive terms from up to the next 160 script tokens, capped at 32 hints. It includes names, acronyms, uncommon terms, technical vocabulary, and Kio while excluding common stopwords. Context refreshes after eight confirmed tokens. SpeechAnalyzer receives updates through `setContext`; the legacy recognizer refreshes `contextualStrings` when it restarts its recognition task about every 50 seconds without restarting audio capture or changing the reading anchor.
- Follow My Voice is the default. The selected mode is stored through `@AppStorage("kio.cue.mode")` and restored rather than reset at launch.

## Semantic and related fixes

- Negation is represented as action polarity and blocks deterministic and model-generated tool plans generically, including negated actions that were not in a special-case verb list.
- A mixed request such as “trim this and convert it to MP4” now clarifies instead of silently planning only one action. Typed action-form normalization also handles plural and `y`-ending forms used by move/copy and related operations.
- No unrelated product areas were expanded. Existing chat/notch picker surfaces and Cue session pinning behavior were preserved.

## Verification

- Focused Swift runs completed during implementation: 15 Reel acceptance tests, 20 Cue tests, and 2 semantic regression tests passed. The final full command passed:

  ```sh
  KIO_REEL_RUNTIME_ROOT="$PWD/.cache/reel/runtime/Reel" \
    swift test --package-path Packages/KioKit --scratch-path /tmp/Kio-hardening-build
  ```

  The environment variable is needed for the two local-media integration tests to locate the already-prepared runtime. An initial full invocation without it reported those two tests as “runtime not prepared”; the configured full run then passed. SwiftPM emitted a non-fatal MLX bundle build-graph warning.
- `git diff --check` passed before this documentation update; it is repeated for the final repository check.
- The pinned Reel runtime manifest digest matched. Read-only helper probes passed: yt-dlp `2026.08.19`, Deno `2.9.7`, FFmpeg/ffprobe `9.0.2`, and Streamlink `8.6.0`; the Streamlink CLI imported successfully. FFmpeg advertises `h264_videotoolbox`; it does not advertise `libx264`.
- macOS Debug build passed with signing disabled from a temporary snapshot of the current working tree, after Xcode stalled on file coordination while reading the Desktop checkout. The unsigned product is `/tmp/KioHardeningDerivedDataTemp/Build/Products/Debug/Kio.app`, version `0.1.0`, build `1`. Its bundled Reel manifest matches the pinned cache. Xcode warned that the prepared-runtime script has no declared outputs and that signed upstream helper binaries cannot be stripped; the build succeeded.
- **Kio was not launched or interactively tested by Codex.** No microphone, live speech recognition, live media URL, phone, or relay deployment was used. The app, visual behavior, real source audio, and downloaded playback still need user acceptance.

## Remaining limitations

- Source audio preference can only be as reliable as metadata supplied by yt-dlp. When a source provides neither an original/default marker nor useful language metadata, the selector can rank available signals but cannot infer the creator's intent with certainty.
- The bundled runtime has no software H.264 fallback. A failed VideoToolbox encode returns a diagnostic. WebM output remains limited to compatible streams because incompatible WebM conversion is not supported.
- Authentication-gated and DRM-protected media are unsupported. Public-source compatibility still depends on the current site and extractor metadata.
- Cue's live recognizer behavior and vocabulary quality need a real microphone check, especially on long scripts. Manual checks are listed in [MANUAL_ACCEPTANCE.md](MANUAL_ACCEPTANCE.md#reliability-hardening-reel-audio-variants-exact-quality-cue-and-negation).
