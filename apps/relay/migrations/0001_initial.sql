PRAGMA foreign_keys = ON;

CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    mac_device_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('mac', 'phone')),
    display_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    credential_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    revoked_at INTEGER
);

CREATE TABLE pairing_requests (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    mac_device_id TEXT NOT NULL REFERENCES devices(id),
    token_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE TABLE envelopes (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL REFERENCES devices(id),
    recipient_id TEXT NOT NULL REFERENCES devices(id),
    nonce TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE INDEX devices_workspace_idx ON devices(workspace_id, revoked_at);
CREATE INDEX pairing_expiry_idx ON pairing_requests(expires_at, consumed_at);
CREATE INDEX inbox_idx ON envelopes(recipient_id, consumed_at, created_at);
CREATE INDEX envelope_expiry_idx ON envelopes(expires_at);
