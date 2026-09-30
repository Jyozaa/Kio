ALTER TABLE workspaces ADD COLUMN phone_paired_at INTEGER;

UPDATE workspaces
SET phone_paired_at = (
    SELECT MIN(created_at) FROM devices
    WHERE devices.workspace_id = workspaces.id AND devices.role = 'phone'
)
WHERE phone_paired_at IS NULL
  AND EXISTS (SELECT 1 FROM devices WHERE devices.workspace_id = workspaces.id AND devices.role = 'phone');

CREATE INDEX workspace_lifecycle_idx ON workspaces(phone_paired_at, created_at);
CREATE INDEX device_workspace_activity_idx ON devices(workspace_id, last_seen);
CREATE INDEX pairing_workspace_created_idx ON pairing_requests(workspace_id, created_at);
CREATE INDEX envelope_workspace_expiry_idx ON envelopes(workspace_id, expires_at);
