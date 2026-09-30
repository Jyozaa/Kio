# Kio compatibility results

Kio discovers capabilities for arbitrary ordinary macOS applications. This table is
the set tested on this host; it is not an application support whitelist. Results used
CUA Driver 0.30.4. AX observations below recorded only control counts and timing; UI
labels and content were not included in this report.

## Browsers

| Application | Installed | Primary route | Fallback route | Tasks tested | Result / known issue |
|---|---|---|---|---|---|
| Safari | Yes | AX | Signed CUA Perception only when AX is insufficient | Local form task, four actions; long workflow; poor-AX visual fixture | AX task reached independently verified Success. The current normalized DOM route is unavailable. One direct local fixture URL attempt failed closed; no route bypass. |
| Google Chrome | Yes | AX | Signed CUA Perception when available | Google search; local form task, four actions; local workflow | All listed tasks completed and were verified. Structured browser authorization for the existing profile remains unavailable on this host. |
| Firefox | No | — | — | Not tested | Not installed in the current app inventory. |
| Arc | No | — | — | Not tested | Not installed in the current app inventory. |
| Brave | No | — | — | Not tested | Not installed in the current app inventory. |
| Microsoft Edge | No | — | — | Not tested | Not installed in the current app inventory. |

## Native macOS applications

| Application | Installed | Primary route | Fallback route | Tasks tested | Result / known issue |
|---|---|---|---|---|---|
| Calculator | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 146 controls in the Phase 32 read-only sample. No calculator operation was performed. |
| Finder | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 246 controls observed. A dedicated temporary-folder create/rename task was not completed. |
| Notes | Yes | Direct app launch; AX observation | — | Launch and read-only AX observation; new-note workflow attempt | 71 controls were observed in the measured read-only sample. The new-note attempt did not return a trustworthy completion result, so no content-entry success is claimed; no personal note contents were recorded. |
| Calendar | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 190 controls observed. No event was created or changed. |
| Reminders | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 126 controls observed. No reminder was created or changed. |
| Preview | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 102 controls observed. No document was changed. |
| System Settings | Yes | Direct app launch; AX observation | — | Launch and real AX observation | Launch independently verified; 119 controls observed. No security or privacy setting was changed. |

The AX counts are single observations, not a reliability score. A separate live
Calculator direct command was independently verified as running. Native dialogs were
also exercised in the Chrome → confirmation dialog → Chrome workflow; the file picker
remains unsupported and fails closed as documented in Phase 25.

## Electron and hybrid applications

| Application | Installed | Primary route | Fallback route | Tasks tested | Result / known issue |
|---|---|---|---|---|---|
| Discord | Yes | AX | None needed in inspected window | Read-only observation | 117 controls were observed after startup. No message was sent or edited. |
| Visual Studio Code | Yes | AX for the selected window | Signed CUA Perception when available | Read-only observation | AX controls were available; the structured browser route was unavailable. No editor action or mutation was performed. |
| Notion | Yes | — | — | Not tested | Installed, but no task was run. |
| Spotify | Yes | — | — | Not tested | Installed, but no task was run. |

## Fixtures and boundaries

The local Chrome/Safari form fixture exercised text entry, selection, action and
independent goal verification. The poor-AX visual fixture exercised CUA screenshot
capture, the separately installed signed CUA Perception extension, bounded candidates
and capture-bound CUA actions. The
12-action browser workflow and cross-surface native confirmation are recorded in
`docs/phase-status.md`. CUA 0.30.4 did not expose a usable normalized DOM action route
for the installed browser setup, and no browser authorization/profile change was
attempted. Visual clicks require the live native capture identity; if unavailable,
Kio stops for the user. These results do not claim universal GUI support.

The Phase 33 page-level scroll fixture completed with a fresh AX WebArea token and an
independent Success marker. Nested scroll containers did not complete because the
current CUA route exposes the page WebArea token rather than a safe nested-region
target.
