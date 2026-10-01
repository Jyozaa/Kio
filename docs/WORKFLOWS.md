# Workflows

Kio runs typed, locally registered operations. A workflow template stores an operation graph and safe typed arguments; it never stores a source path, generated code, or a shell command.

## Ask Kio

Drop files into the composer or attach them using Finder's **Services → Send to Kio**. You can also paste text, a URL, an image, or a file from the clipboard. Describe the result you want. Common unambiguous requests take a deterministic fast path; semantic text work may use the optional local model.

Use the contextual action chips in either the notch or full chat for common tasks, or drag a result onto a specialist avatar to see actions supported for that file. Both action rows submit request text through the same planner and registered operations. The PDF “Pages…” suggestion focuses the composer and waits for a page range. When an action is ambiguous, Kio asks which one to run.

Pip can combine two to 32 PDFs and still images into one verified PDF. Each source becomes pages in the order the files were selected; originals remain unchanged.

## Save and run a template

After a successful workflow, choose **Save workflow** and give it a name. Open **Workflows** to inspect its steps, rename or delete it, or run it on attached files. You can also ask “Run *name* on these.” Kio validates all input types before it instantiates the saved operation graph.

For example, a template may contain:

1. Merge the selected PDFs.
2. Compress the result.

Template runs use new inputs; they do not reuse old file paths. If an input does not fit, Kio asks for compatible files instead of running a partial workflow.

## Table workflows

CSV, TSV, and JSON table inputs support inspection, statistics, sorting, filtering, deduplication, normalization, column selection/renaming/reordering, comparison, merging, and CSV/JSON conversion. An XLSX workbook is read through a bounded, read-only importer and exported as CSV. Kio does not recalculate formulas or preserve workbook formatting, macros, or Excel behavior.

## Image and media workflows

Pixel can make a Vision attention-based smart crop when a salient subject is detected; the crop is saved as a new image and leaves the source untouched. Echo can trim a video or extract a bounded clip, and can convert one audio file to M4A while preserving the original.

## File safety

Organization creates and verifies copies under the selected folder or Kio's result location. Downloads organization requires the selected folder to be named `Downloads`; it groups direct child files by type into a verified copy tree and leaves all sources in place. Module organization groups selected filenames by the prefix before `.`, `_`, or `-`. Clerk's recent/name searches inspect only a selected folder's direct regular files (or the selected files) and report metadata or matching names. A requested move displays a preview and asks for confirmation first. Kio does not scan the whole Mac. Outputs preserve the source by default.

## Mobile

The optional PWA sends encrypted task envelopes and attachments through the relay; the paired Mac runs the operation. Pair in Kio Settings, then use the PWA to send text, URLs, and multiple images or files. The Mac can return multiple output attachments. The browser can queue a task while the Mac is offline and retry it after reconnection. See [Mobile pairing](MOBILE_PAIRING.md) for setup and current browser support.
