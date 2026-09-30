# Reference-video parity benchmark

`fixtures/video_parity/canonical.json` records the nine reference utterances
from the user-provided 46.965-second `vid.mp4`. The natural-language variants
in `variants.json` are a separate held-out suite. Both fixtures declare
`training_eligible: false` and use a different schema, which the trajectory
exporter rejects. The benchmark checks direct intent, semantic
operation/object, exact literal and URL parameters, and no-action courtesy
behavior.

The supplied recording was inspected at regular intervals and transcribed
locally with the bundled tiny.en model. It shows the note title `Hello`, Google
results for Norbert Wiener, X, then Photo Booth with the resulting image. Local
transcription normalizes the spoken domain as `x.com`; the variant suite also
checks the user brief's spelling `X dot com`.

Run the offline parser/context fixture check:

```bash
scripts/agent.sh -m companion_agent.video_parity
```

Current result: canonical 9/9 and variants 16/16. This is parser and plan
normalization evidence only. It does not launch apps or establish action
completion, one-shot effect delivery, GUI verification, real microphone
behavior, or full video parity.

The live-safe scope is Notes create/edit with the benign title `Hello`, browser
search/navigation on an installed browser, and app-resolution checks. The
reference names Arc; this machine has Chrome, so a live acceptance adaptation
may use Chrome without adding that substitution to production behavior. The
Photo Booth capture step remains excluded: a real capture creates personal
media and the supplied brief does not authorize it. Physical speech and early
microphone interruption are user-only tests and were not simulated.

Candidate recall is measured independently in the backend benchmark at three
boundaries: source observation, exhaustive candidate builder, and the bounded
production choice set. This separates missing perception/filtering from model
ranking errors.

## Current live result (2026-09-29)

The rebuilt canonical app's embedded CUA health report returned `ok`. A typed
probe of the conversational Notes flow was inconclusive: the long app-open
utterance first returned `needs_user`, a simple `Open Notes` request completed,
and a later multi-turn probe did not return a completed result. A read-only AX
snapshot of the current Notes window did not show the exact `Hello` value. This
run is not counted as note creation or title-setting success; no existing Notes
data was deleted. No live browser task or Photo Booth capture was performed in
this pass. The physical shortcut and human speech remain user-only tests.
