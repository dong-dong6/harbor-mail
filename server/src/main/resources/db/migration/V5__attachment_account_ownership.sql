-- Preserve the original five attachment columns for older application versions.
-- Ownership survives draft deletion; shared bytes can be assigned to a surviving account.
CREATE TABLE attachment_owner (
  attachment_id VARCHAR(80) PRIMARY KEY REFERENCES attachment(id) ON DELETE CASCADE,
  account_id VARCHAR(80) NOT NULL
);
INSERT INTO attachment_owner (attachment_id,account_id)
  SELECT attachment.id,draft.account_id FROM attachment JOIN draft ON draft.id=attachment.draft_id;
CREATE INDEX ix_attachment_owner_account ON attachment_owner(account_id);
