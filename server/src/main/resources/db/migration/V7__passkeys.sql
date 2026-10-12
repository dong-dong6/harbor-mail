-- Public credential material only. Private keys remain with the user's authenticator.
CREATE TABLE passkey_user (
  owner_id INTEGER PRIMARY KEY REFERENCES owner_user(id),
  user_handle VARCHAR(86) NOT NULL UNIQUE,
  revocation_epoch BIGINT NOT NULL DEFAULT 0
);
CREATE TABLE passkey_credential (
  id VARCHAR(36) PRIMARY KEY,
  owner_id INTEGER NOT NULL REFERENCES passkey_user(owner_id),
  credential_id VARCHAR(2048) NOT NULL UNIQUE,
  public_key TEXT NOT NULL,
  signature_count BIGINT NOT NULL,
  backup_eligible BOOLEAN NOT NULL,
  backup_state BOOLEAN NOT NULL,
  name VARCHAR(80) NOT NULL,
  created_at BIGINT NOT NULL,
  last_used_at BIGINT
);
CREATE TABLE passkey_request (
  id VARCHAR(36) PRIMARY KEY,
  operation VARCHAR(20) NOT NULL,
  creator_hash VARCHAR(64),
  credential_name VARCHAR(80),
  request_json TEXT NOT NULL,
  expires_at BIGINT NOT NULL,
  credential_epoch BIGINT NOT NULL
);
CREATE INDEX ix_passkey_request_expiry ON passkey_request(expires_at);
