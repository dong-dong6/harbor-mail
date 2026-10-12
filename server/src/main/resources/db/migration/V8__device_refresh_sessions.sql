-- Opt-in durable sessions only. Legacy access_token stays a two-column table.
ALTER TABLE device_pairing ADD COLUMN remember_device BOOLEAN NOT NULL DEFAULT FALSE;
-- Bind opt-in to the assertion ceremony; verification cannot upgrade its original intent.
ALTER TABLE passkey_request ADD COLUMN remember_device BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE passkey_request ADD COLUMN device_name VARCHAR(80);
CREATE TABLE device_session (
  id VARCHAR(80) PRIMARY KEY,
  device_id VARCHAR(80) NOT NULL UNIQUE REFERENCES paired_device(id) ON DELETE CASCADE,
  refresh_hash VARCHAR(64) NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  idle_expires_at BIGINT NOT NULL,
  absolute_expires_at BIGINT NOT NULL,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  retry_window_start BIGINT NOT NULL DEFAULT 0,
  retry_count INTEGER NOT NULL DEFAULT 0
);
-- Keep every hash until family deletion: exact delayed retries can be distinguished from reuse.
CREATE TABLE device_refresh_token (
  token_hash VARCHAR(64) PRIMARY KEY,
  session_id VARCHAR(80) NOT NULL REFERENCES device_session(id) ON DELETE CASCADE,
  request_id VARCHAR(36),
  successor_hash VARCHAR(64),
  consumed_at BIGINT,
  UNIQUE(session_id, request_id)
);
CREATE INDEX ix_refresh_session ON device_refresh_token(session_id);
CREATE INDEX ix_refresh_rotation_window ON device_refresh_token(session_id,consumed_at);
CREATE TABLE device_session_access (
  token_hash VARCHAR(64) PRIMARY KEY REFERENCES access_token(token_hash) ON DELETE CASCADE,
  session_id VARCHAR(80) NOT NULL REFERENCES device_session(id) ON DELETE CASCADE
);
CREATE INDEX ix_session_access ON device_session_access(session_id);

CREATE INDEX ix_device_session_expiry ON device_session(idle_expires_at,absolute_expires_at);
CREATE INDEX ix_paired_device_expiry ON paired_device(expires_at);
CREATE INDEX ix_access_token_expiry ON access_token(expires_at);
