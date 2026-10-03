# Architecture

## Mac app

`apps/mac/KioMac` is a SwiftUI/AppKit accessory app whose primary window is a borderless status-level notch panel. `NotchPanelController` sizes the black shell for collapsed, ambient-event, and expanded states. `NotchEventCoordinator` arbitrates transient events by priority and suppresses News events unless a topic alert was explicitly enabled. Dashboard selection is stored in `UserDefaults`.

`DashboardView.swift` composes the four spaces—Kio, Sessions, Clipboard, and News—inside the notch. `DashboardRuntime.swift` owns the single `KioDashboardModel`, conversion/Reel dispatch, local stores, pasteboard polling, and session-inbox processing. `SettingsView.swift` configures motion, output location, shortcuts, hooks, clipboard retention, and News enablement. There is no full chat scene or conversation store.

Kio has one small ribbon/bookmark mascot. Convert, Reel, and Cue are features. Shell motion uses a spring unless macOS Reduce Motion or Kio's override requests a short ease transition. Cue text uses a separate non-bouncy whole-document movement policy.

## Swift packages

- `KioCore`: artifact references, supported operation/argument types, and safe output helpers.
- `KioModel`: deterministic Convert request parsing; dashboard/session/clipboard/news models; bounded local stores; safe public HTTP URL policy; Cue tracking and stable document layout.
- `KioTools`: image, PDF, media conversion, and Reel operations.

There is no LLM client, model download, generic planner/repair loop, phone relay, chat persistence, archive product, or specialist ownership registry. `TaskStep` represents a typed native operation boundary, not a generated multi-step semantic plan.

## Convert engines

Convert dispatches typed requests to retained native image, media, or PDF routines in `ToolExecutor`. Local files are inspected as `ArtifactRef`; scoped access is released after work. Existing files remain untouched. Output paths are conflict-safe and selected through `OutputLocation`. Media operations use the pinned bundled runtime described in `Packages/KioKit/Sources/KioTools/Resources/ReelRuntime.json`.

The parser recognizes a small supported vocabulary—format names, pixel width, target size, audio extraction, PDF merge/compression, and images-to-PDF. It rejects requests outside the implemented operations; it does not use an LLM.

## Reel

Reel shares typed operations with Convert but keeps a dedicated inspector/downloader path. Safe URL validation, exact inspected variants, audio language preference, runtime selection, destination validation, and output verification remain in the Reel engine. The bundled runtime is installed into app resources during an explicit build, never downloaded during normal app use.

## Cue stable presentation

`CueTextAlignment` continues to map speech progress to canonical word tokens. `CueStableDocumentLayout` measures and wraps all tokens for a fixed script and available width, stores each token's line, and justifies qualifying non-final lines. The SwiftUI view renders every prelaid line with regular 17.5 pt text; current-word color is the only per-token visual change. The offset is derived from the current line, so it stays still within a line and advances by one line with a 0.55 s ease.

Follow My Voice uses the existing Apple Speech/SpeechAnalyzer lifecycle. Classic is a timed mode. Microphone and Speech Recognition permissions are requested only after the user presses Start in Follow My Voice.

## Sessions

Each integration writes an atomic, mode-0600 JSON record into `~/Library/Application Support/Kio/Sessions/Inbox`. The shared Python/JavaScript hook record contains only normalized lifecycle metadata. The app consumes and removes inbox files, normalizes them through `SessionHookAdapter`, and saves at most 80 recent sessions and 1,000 event identifiers in `Sessions.json`.

Provider hooks are opt-in and separate: Claude Code and Codex use command hooks; Cursor uses its hooks configuration; OpenCode uses a local plugin. Kio never scrapes terminals, reads shell history, or browses provider transcript storage. Existing provider configuration is backed up once before Kio edits its hook entries.

## Clipboard

When enabled, the app polls `NSPasteboard.general` for change-count updates. It skips macOS concealed/transient types and user-excluded app identifiers, then stores plain text, up to 32 file URLs, or bounded local PNG copies with a SHA-256 fingerprint. `ClipboardStore` keeps up to the configured number of recent entries plus pinned entries, with a 500-entry hard cap. Captured image copies have a 128 MB total budget and are removed when history entries are deleted or pruned. No clipboard data is synchronized or sent to a model.

## News

The user supplies public HTTPS RSS or Atom sources, topic labels, and optional alert-topic labels. `NewsStore` fetches only on explicit refresh, validates public source hosts, parses feed XML, filters configured topics, de-duplicates by article URL, and retains at most 160 items. Normal cache changes do not create notch events. Only a new item in an explicitly enabled alert topic can enter `NotchEventCoordinator`.

## Build verification

`scripts/check.sh` runs package tests, helper checks, Reel runtime validation, and noninteractive Debug/Release Xcode builds. It does not launch Kio. The user performs all visual, microphone, live-feed, clipboard UI, and provider-hook acceptance checks; see [Manual acceptance](MANUAL_ACCEPTANCE.md).
