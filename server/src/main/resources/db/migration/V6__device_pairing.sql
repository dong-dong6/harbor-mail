-- Keep access_token's two-column shape for existing sessions and callers.
CREATE TABLE paired_device (
  id VARCHAR(80) PRIMARY KEY,
  name VARCHAR(80) NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  last_seen_at BIGINT NOT NULL,
  revoked BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE device_access_token (
  token_hash VARCHAR(64) PRIMARY KEY REFERENCES access_token(token_hash) ON DELETE CASCADE,
  device_id VARCHAR(80) NOT NULL REFERENCES paired_device(id) ON DELETE CASCADE
);
CREATE INDEX ix_device_token_device ON device_access_token(device_id);
CREATE TABLE device_pairing (
  id VARCHAR(80) PRIMARY KEY,
  creator_hash VARCHAR(64) NOT NULL,
  secret_hash VARCHAR(64),
  code_challenge VARCHAR(43),
  device_name VARCHAR(80),
  confirmation_code VARCHAR(6),
  state VARCHAR(16) NOT NULL,
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  last_poll_at BIGINT NOT NULL DEFAULT 0
);
CREATE INDEX ix_pairing_creator ON device_pairing(creator_hash);
CREATE INDEX ix_pairing_expiry ON device_pairing(expires_at);
