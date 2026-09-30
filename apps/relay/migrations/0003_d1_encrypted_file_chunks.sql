ALTER TABLE transfers RENAME TO transfers_legacy;

CREATE TABLE transfers (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES devices(id),
    recipient_id TEXT NOT NULL REFERENCES devices(id),
    size_bytes INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

INSERT INTO transfers (id, workspace_id, sender_id, recipient_id, size_bytes, created_at, expires_at)
SELECT id, workspace_id, sender_id, recipient_id, size_bytes, created_at, expires_at FROM transfers_legacy;

DROP TABLE transfers_legacy;

CREATE INDEX transfer_expiry_idx ON transfers(expires_at);
CREATE INDEX transfer_workspace_idx ON transfers(workspace_id, expires_at);

CREATE TABLE transfer_chunks (
    transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    encrypted_chunk BLOB NOT NULL,
    PRIMARY KEY (transfer_id, chunk_index)
);
