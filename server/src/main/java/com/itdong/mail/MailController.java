package com.itdong.mail;

import jakarta.servlet.http.HttpServletRequest;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/v1")
public class MailController {
  final MailService mail;
  final Security security;
  final OAuthService oauth;

  MailController(MailService mail, Security security, OAuthService oauth) {
    this.mail = mail;
    this.security = security;
    this.oauth = oauth;
  }

  @GetMapping("/health")
  Object health() {
    return Json.map("status", "UP", "version", "0.1.0", "demoMode", security.demo);
  }

  @PostMapping("/auth/login")
  Object login(@RequestBody Map<String, Object> b, HttpServletRequest r) {
    return security.login(b, r.getRemoteAddr());
  }

  @PostMapping("/auth/logout")
  ResponseEntity<?> logout(@RequestHeader("Authorization") String h) {
    mail.store.db.update(
        "DELETE FROM access_token WHERE token_hash=?", Security.hash(h.substring(7)));
    return ResponseEntity.noContent().build();
  }

  @GetMapping("/accounts")
  Object accounts() {
    return Json.map("items", mail.accounts());
  }

  @PostMapping("/accounts/imap")
  Object account(@RequestBody Map<String, Object> b) {
    return mail.addImap(b);
  }

  @GetMapping("/accounts/{id}/folders")
  Object folders(@PathVariable String id) {
    return Json.map("items", mail.folders(id));
  }

  @PostMapping("/accounts/{id}/sync")
  ResponseEntity<?> sync(@PathVariable String id) {
    return ResponseEntity.accepted().body(mail.sync(id));
  }

  @GetMapping("/sync-jobs/{id}")
  Object syncJob(@PathVariable String id) {
    return mail.job(id, "SYNC");
  }

  @GetMapping("/messages")
  Object messages(
      @RequestParam(defaultValue = "") String accountId,
      @RequestParam(defaultValue = "INBOX") String folder,
      @RequestParam(defaultValue = "") String query,
      @RequestParam(defaultValue = "false") boolean unreadOnly,
      @RequestParam(defaultValue = "") String cursor,
      @RequestParam(defaultValue = "50") int limit) {
    return mail.messages(accountId, folder, query, unreadOnly, cursor, limit);
  }

  @GetMapping("/messages/{id}")
  Object detail(@PathVariable String id) {
    return mail.detail(id);
  }

  @PostMapping("/commands")
  ResponseEntity<?> command(
      @RequestHeader("Idempotency-Key") String key, @RequestBody Map<String, Object> b) {
    return ResponseEntity.accepted().body(mail.command(key, b));
  }

  @GetMapping("/commands/{id}")
  Object command(@PathVariable String id) {
    return mail.job(id, "COMMAND");
  }

  @GetMapping("/drafts")
  Object drafts() {
    return Json.map("items", mail.drafts());
  }

  @PostMapping("/drafts")
  Object draft(@RequestBody Map<String, Object> b) {
    return mail.saveDraft(null, b);
  }

  @PatchMapping("/drafts/{id}")
  Object draft(@PathVariable String id, @RequestBody Map<String, Object> b) {
    return mail.saveDraft(id, b);
  }

  @DeleteMapping("/drafts/{id}")
  ResponseEntity<?> delete(@PathVariable String id) {
    mail.deleteDraft(id);
    return ResponseEntity.noContent().build();
  }

  @PostMapping("/drafts/{id}/attachments")
  Object upload(@PathVariable String id, @RequestParam("file") MultipartFile file) {
    return mail.upload(id, file);
  }

  @GetMapping("/attachments/{id}/content")
  ResponseEntity<byte[]> attachment(@PathVariable String id) {
    var a = mail.download(id);
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_OCTET_STREAM)
        .header(
            HttpHeaders.CONTENT_DISPOSITION,
            ContentDisposition.attachment()
                .filename(a.fileName(), StandardCharsets.UTF_8)
                .build()
                .toString())
        .body(a.bytes());
  }

  @PostMapping("/drafts/{id}/send")
  ResponseEntity<?> send(
      @PathVariable String id,
      @RequestHeader("Idempotency-Key") String key,
      @RequestBody Map<String, Object> b) {
    return ResponseEntity.accepted().body(mail.send(id, key, b));
  }

  @GetMapping("/send-intents")
  Object sends() {
    return Json.map("items", mail.jobs("SEND"));
  }

  @GetMapping("/send-intents/{id}")
  Object send(@PathVariable String id) {
    return mail.job(id, "SEND");
  }

  @GetMapping("/changes")
  Object changes(@RequestParam(defaultValue = "") String after) {
    return mail.changes(after);
  }

  @GetMapping("/settings/capabilities")
  Object capabilities() {
    return Json.map(
        "demoMode",
        security.demo,
        "providers",
        List.of("GMAIL", "OUTLOOK", "QQ", "NETEASE", "EXCHANGE").stream()
            .map(
                p ->
                    Json.map(
                        "provider",
                        p,
                        "configured",
                        !security.demo
                            && (Set.of("QQ", "NETEASE").contains(p) || oauth.configured(p)),
                        "supportsOAuth",
                        Set.of("GMAIL", "OUTLOOK", "EXCHANGE").contains(p),
                        "supportsImap",
                        Set.of("QQ", "NETEASE").contains(p)))
            .toList(),
        "limits",
        Json.map("maxAttachmentBytes", MailService.MAX_ATTACHMENT),
        "features",
        Json.map(
            "html",
            false,
            "offlineCache",
            false,
            "remoteAttachmentDownload",
            true,
            "fullHistory",
            false,
            "push",
            false));
  }

  @PostMapping("/oauth/{provider}/start")
  Object oauthStart(@PathVariable String provider) {
    return oauth.start(provider);
  }

  @GetMapping(value = "/oauth/{provider}/callback", produces = MediaType.TEXT_PLAIN_VALUE)
  String callback(
      @PathVariable String provider,
      @RequestParam(defaultValue = "") String state,
      @RequestParam(defaultValue = "") String code,
      @RequestParam(defaultValue = "") String error) {
    oauth.callback(provider, state, code, error);
    return "Mailbox connected. You may close this window and refresh the account list.";
  }
}
