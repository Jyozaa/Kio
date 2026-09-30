CREATE TABLE pairing_ip_limits (
    ip_hash TEXT NOT NULL,
    window_start INTEGER NOT NULL,
    request_count INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (ip_hash, window_start)
);

CREATE INDEX pairing_ip_limit_expiry_idx ON pairing_ip_limits(expires_at);

CREATE TABLE transfer_device_limits (
    device_id TEXT NOT NULL,
    window_start INTEGER NOT NULL,
    request_count INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (device_id, window_start)
);

CREATE INDEX transfer_device_limit_expiry_idx ON transfer_device_limits(expires_at);
CREATE INDEX transfer_sender_created_idx ON transfers(sender_id, created_at);
