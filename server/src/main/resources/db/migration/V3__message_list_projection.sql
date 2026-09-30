-- Keep list reads independent of cached message bodies and attachment metadata.
ALTER TABLE mail_message ADD COLUMN summary TEXT;
