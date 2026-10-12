package com.itdong.mail;

import com.yubico.webauthn.CredentialRepository;
import com.yubico.webauthn.RegisteredCredential;
import com.yubico.webauthn.data.ByteArray;
import com.yubico.webauthn.data.PublicKeyCredentialDescriptor;
import java.util.*;
import org.springframework.stereotype.Component;

/** Single-owner credential mapping; both lookup keys are checked against their persisted owner. */
@Component
public class PasskeyCredentialRepository implements CredentialRepository {
  final Store store;
  PasskeyCredentialRepository(Store store) { this.store = store; }

  static ByteArray bytes(String value) {
    try { return ByteArray.fromBase64Url(value); }
    catch (Exception e) { throw new IllegalStateException("Invalid stored public credential"); }
  }

  @Override public Set<PublicKeyCredentialDescriptor> getCredentialIdsForUsername(String username) {
    var result = new HashSet<PublicKeyCredentialDescriptor>();
    store.db.queryForList("SELECT c.credential_id FROM passkey_credential c JOIN owner_user o ON o.id=c.owner_id WHERE o.id=1 AND o.username=?", username)
        .forEach(row -> result.add(PublicKeyCredentialDescriptor.builder().id(bytes((String) row.get("credential_id"))).build()));
    return result;
  }

  @Override public Optional<ByteArray> getUserHandleForUsername(String username) {
    var rows = store.db.queryForList("SELECT p.user_handle FROM passkey_user p JOIN owner_user o ON o.id=p.owner_id WHERE o.id=1 AND o.username=?", username);
    return rows.isEmpty() ? Optional.empty() : Optional.of(bytes((String) rows.getFirst().get("user_handle")));
  }

  @Override public Optional<String> getUsernameForUserHandle(ByteArray userHandle) {
    var rows = store.db.queryForList("SELECT o.username FROM owner_user o JOIN passkey_user p ON p.owner_id=o.id WHERE o.id=1 AND p.user_handle=?", userHandle.getBase64Url());
    return rows.isEmpty() ? Optional.empty() : Optional.of((String) rows.getFirst().get("username"));
  }

  RegisteredCredential registered(Map<String, Object> row) {
    return RegisteredCredential.builder()
        .credentialId(bytes((String) row.get("credential_id")))
        .userHandle(bytes((String) row.get("user_handle")))
        .publicKeyCose(bytes((String) row.get("public_key")))
        .signatureCount(((Number) row.get("signature_count")).longValue())
        .backupEligible((Boolean) row.get("backup_eligible"))
        .backupState((Boolean) row.get("backup_state")).build();
  }

  @Override public Optional<RegisteredCredential> lookup(ByteArray credentialId, ByteArray userHandle) {
    var rows = store.db.queryForList("SELECT c.*,p.user_handle FROM passkey_credential c JOIN passkey_user p ON p.owner_id=c.owner_id "
        + "WHERE c.owner_id=1 AND c.credential_id=? AND p.user_handle=?", credentialId.getBase64Url(), userHandle.getBase64Url());
    return rows.isEmpty() ? Optional.empty() : Optional.of(registered(rows.getFirst()));
  }

  @Override public Set<RegisteredCredential> lookupAll(ByteArray credentialId) {
    var result = new HashSet<RegisteredCredential>();
    store.db.queryForList("SELECT c.*,p.user_handle FROM passkey_credential c JOIN passkey_user p ON p.owner_id=c.owner_id WHERE c.owner_id=1 AND c.credential_id=?", credentialId.getBase64Url())
        .forEach(row -> result.add(registered(row)));
    return result;
  }
}
