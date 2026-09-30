CREATE TABLE transfers (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES devices(id),
    recipient_id TEXT NOT NULL REFERENCES devices(id),
    object_key TEXT NOT NULL UNIQUE,
    size_bytes INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX transfer_expiry_idx ON transfers(expires_at);
CREATE INDEX transfer_workspace_idx ON transfers(workspace_id, expires_at);
