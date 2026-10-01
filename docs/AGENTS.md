# Kio's local specialist roster

Kio's agents are UI and workflow roles over one local task executor. The role decides which registered tools may handle a task; it does not start a separate model. The optional local planner selects among typed operations, and native code validates and executes each step.

| Agent | Role | Current registered work |
| --- | --- | --- |
| Kio | Coordinator | Fast-path answers, workflow planning, and handoff status. |
| Pip | PDF specialist | PDF operations, selectable text search, extraction, and OCR. |
| Pixel | Image specialist | Image conversion and inspection, comparisons, Vision background removal, and attention-based smart crop. |
| Zip | Archive specialist | ZIP creation, inspection, and safe extraction; PDF compression. |
| Echo | Media specialist | Audio/video trim and clip extraction, audio conversion to M4A, and optional on-device speech transcription/subtitles. |
| Clerk | File specialist | File copying/organization, duplicate reports, and confirmed moves. |
| Courier | Phone/file transfer | Optional encrypted PWA relay tasks and output delivery. |
| Scribe | Text specialist | Local-model text transformations and document summaries. |
| Table | Data specialist | CSV/TSV/JSON tables and bounded XLSX-to-CSV import. |
| Lens | Visual specialist | On-device OCR, receipt fields, and image table extraction. |
| Scout | Web specialist | Public HTTP(S) page text and link extraction. |
| Patch | Bounded source helper | Explanations, JSON formatting, and a separate proposed source copy with diff. |

The Mac remains the execution authority. Remote task messages contain no shell or arbitrary code capability. A specialist handoff is shown only when it comes from a real `TaskExecution` operation.

See [Workflow templates](WORKFLOWS.md), [Architecture](KIO_ARCHITECTURE.md), and [Security](SECURITY.md).
