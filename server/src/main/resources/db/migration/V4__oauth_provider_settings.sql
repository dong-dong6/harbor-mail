-- Keep an environment-source row after reset so stale editors cannot reuse revision zero.
CREATE TABLE oauth_provider_settings (
  provider VARCHAR(30) PRIMARY KEY,
  source VARCHAR(20) NOT NULL,
  revision BIGINT NOT NULL,
  client_id VARCHAR(1024) NOT NULL,
  redirect_uri VARCHAR(2048) NOT NULL,
  tenant VARCHAR(253) NOT NULL,
  client_secret TEXT
);
INSERT INTO oauth_provider_settings VALUES ('GMAIL','ENVIRONMENT',0,'','','',NULL);
INSERT INTO oauth_provider_settings VALUES ('OUTLOOK','ENVIRONMENT',0,'','','',NULL);
INSERT INTO oauth_provider_settings VALUES ('EXCHANGE','ENVIRONMENT',0,'','','',NULL);
