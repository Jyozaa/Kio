# Helper protocol v1

UTF-8 NDJSON over stdin/stdout, one JSON object per line, maximum 65,536 bytes.
Every envelope has `version: 1`, `kind`, `task_id` (1–128 characters), `text` and
`status` strings. Newlines in text are JSON-escaped. Stdout is protocol-only.

UI → helper: command(text=goal), cancel(same task_id), health.
Helper → UI: event(text=short safe status), result, error,
health. Terminal result statuses: completed, cancelled, needs_user. Only one task
runs at once. A duplicate task identifier is rejected. Foreign task events do not
change the current UI. Malformed input reports a content-free protocol_error.
Oversized/truncated frames close the helper stream. EOF cancels the active task.

Read-only UI answers use a distinct `answer` message kind while keeping protocol
version 1. The terminal status must be `answered`, `text` must exactly match the
bounded answer string, and the typed payload contains `answer`, `confidence`,
`source_app`, `source_window`, and at most eight short evidence strings. The Swift UI
validates these bounds and presents the answer in the compact overlay. The payload
contains no observed controls, CUA tokens, coordinates, or action authority.

Example:
```json
{"version":1,"kind":"command","task_id":"a","text":"Open Notes","status":""}
{"version":1,"kind":"event","task_id":"a","text":"Looking at the page…","status":"observing"}
{"version":1,"kind":"cancel","task_id":"a","text":"","status":""}
{"version":1,"kind":"result","task_id":"a","text":"Stopped.","status":"cancelled"}
```

The phase-2 helper requires --demo and never performs computer actions. It streams
observing/working/completed with cancellable waits to test the actual process pipe.
Historical Part 1 confirmation was a blocked terminal state; the current autonomous policy has no approval flow.

Phase 9 added the optional command `target` string for an installed app. It contains
no Driver IDs and remains available as a diagnostic override. Production commands
normally leave it empty: the runtime resolves a target from the typed semantic plan,
installed-app inventory, current foreground app, exact task identity, and bounded
session context. A missing target is valid for computer-use tasks; only unresolved or
genuinely ambiguous live evidence returns `needs_user`. Window selection uses exact
task identity, active/key/main state, current-Space visibility and bounded z-order
evidence rather than requiring exactly one visible window.

The default helper now runs the real runtime; --demo remains explicitly inert.
Legacy confirmation_required is decode-only; no current helper emits it.
The UI shows a blocked-action panel and lets the user dismiss it or act manually.

Phase 11.0 changes the product display name to Kio only. Protocol version, fields,
message kinds and session/cancellation semantics are unchanged.

Phase 14 privacy settings are read locally from Application Support/Kio/config/privacy.json;
the NDJSON v1 wire schema is unchanged. Gemini is text-only and advisory; it has no
visual screenshot schema and never supplies a protocol action or executable payload.

## Phase 16 autonomous policy revision

No approval request is emitted by the current helper. BLOCK produces needs_user.
NDJSON v1 retains decoding of legacy confirmation_required/approve/approval_id
for compatibility only. An inbound approve is rejected as unsupported and confers
no authority; old confirmation responses become a terminal needsUser update in
Swift, with no confirmation UI. Normal messages omit approval_id entirely.

Trajectories have their own `trajectory_schema_version: 1`; they are not NDJSON
commands and cannot be replayed into the helper's action protocol. No wire changes
were required for Phase 17.

Phase 19 packaging leaves NDJSON v1 unchanged. Setup uses a separate bounded JSON
status subprocess; it cannot execute computer actions. Keychain secrets travel only
in the private child environment and never in a protocol message.

Final hardening retains protocol v1. Helper disconnect/malformed output fails the
active task; Run can reconnect to a fresh helper. Stage timing and replay remain
local diagnostic interfaces, not new model-facing execution commands.
