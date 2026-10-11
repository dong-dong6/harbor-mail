package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;
import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;

class ProviderHttpTest {
  HttpServer server;
  String base;
  AtomicReference<String> request = new AtomicReference<>();

  @BeforeEach
  void start() throws Exception {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    base = "http://127.0.0.1:" + server.getAddress().getPort();
    server.start();
  }

  @AfterEach
  void stop() {
    server.stop(0);
  }

  void route(String path, int status, String body) {
    server.createContext(
        path,
        e -> {
          request.set(
              e.getRequestMethod()
                  + " "
                  + e.getRequestURI()
                  + " "
                  + new String(e.getRequestBody().readAllBytes(), StandardCharsets.UTF_8)
                  + " "
                  + e.getRequestHeaders().getFirst("Prefer"));
          byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
          e.getResponseHeaders().add("Content-Type", "application/json");
          e.sendResponseHeaders(status, bytes.length);
          e.getResponseBody().write(bytes);
          e.close();
        });
  }

  Credentials gmail() {
    return new Credentials("GMAIL", "owner@example.test", "local-test-token", null);
  }

  Outgoing outgoing() {
    return new Outgoing(
        List.of(new Address("", "to@example.test")),
        List.of(),
        List.of(),
        "Local fixture",
        "body",
        List.of(),
        "<fixture@example.test>");
  }

  @Test
  void gmailSyncUsesLabelsAndOpaqueCursor() {
    route("/messages", 200, "{\"messages\":[],\"nextPageToken\":\"abc\"}");
    SyncPage p = new GmailAdapter(new ObjectMapper(), base).sync(gmail(), "INBOX", null, 1000);
    assertTrue(p.hasMore());
    assertEquals("abc", p.nextCursor());
    assertTrue(request.get().contains("maxResults=100"));
    assertTrue(request.get().contains("labelIds=INBOX"));
  }

  @Test
  void gmailAbsoluteReadRemovesUnread() {
    route("/messages/42/modify", 200, "{}");
    new GmailAdapter(new ObjectMapper(), base).mutate(gmail(), "42", "SET_READ", true);
    assertTrue(request.get().contains("\"removeLabelIds\":[\"UNREAD\"]"));
  }

  @Test
  void gmailAcceptedAndFailureClassification() {
    route("/messages/send", 200, "{\"id\":\"sent1\"}");
    assertEquals(
        "ACCEPTED", new GmailAdapter(new ObjectMapper(), base).send(gmail(), outgoing()).status());
    assertTrue(request.get().contains("\"raw\""));
    server.removeContext("/messages/send");
    route("/messages/send", 503, "{\"error\":\"secret-should-not-leak\"}");
    ProviderException e =
        assertThrows(
            ProviderException.class,
            () -> new GmailAdapter(new ObjectMapper(), base).send(gmail(), outgoing()));
    assertTrue(e.ambiguous());
    assertFalse(e.getMessage().contains("secret-should"));
  }

  @Test
  void graphUsesImmutableIdsAndRejectsForeignCursor() {
    route("/mailFolders/inbox/messages", 200, "{\"value\":[]}");
    GraphAdapter g = new GraphAdapter(new ObjectMapper(), base);
    g.sync(gmail(), "INBOX", null, 10);
    assertTrue(request.get().contains("ImmutableId"));
    String evil =
        Base64.getUrlEncoder()
            .encodeToString(
                "https://evil.test/mailFolders/inbox/messages?x".getBytes(StandardCharsets.UTF_8));
    assertEquals(
        "INVALID_CURSOR",
        assertThrows(ProviderException.class, () -> g.sync(gmail(), "INBOX", evil, 10)).code());
  }

  @Test
  void graphSendDoesNotClaimDelivery() {
    route("/sendMail", 202, "{}");
    assertEquals(
        "ACCEPTED", new GraphAdapter(new ObjectMapper(), base).send(gmail(), outgoing()).status());
  }

  @Test
  void oauthPkceAndRefreshRetention() {
    route("/token", 200, "{\"access_token\":\"new-access\",\"expires_in\":3600}");
    OAuthClient client = new OAuthClient(new ObjectMapper(), base);
    OAuthClient.Config config =
        new OAuthClient.Config(
            "GMAIL", "client", "secret", "https://mail.example.test/callback", null);
    String url = client.authorizationUrl(config, "one-time-state", "challenge");
    assertTrue(url.contains("code_challenge_method=S256"));
    assertTrue(url.contains("access_type=offline"));
    OAuthClient.Tokens tokens = client.refresh(config, "old-refresh");
    assertEquals("old-refresh", tokens.refreshToken());
    assertTrue(request.get().contains("grant_type=refresh_token"));
    assertFalse(tokens.toString().contains("new-access"));
  }

  @Test
  void htmlIsPreservedAsUntrustedDataWithSafeTextFallback() {
    GmailAdapter g = new GmailAdapter(new ObjectMapper(), base);
    String data =
        Base64.getUrlEncoder()
            .encodeToString(
                "<script>bad()</script><p>Hello</p><img src=https://tracker.test>"
                    .getBytes(StandardCharsets.UTF_8));
    route(
        "/messages/m",
        200,
        "{\"id\":\"m\",\"payload\":{\"mimeType\":\"text/html\",\"body\":{\"data\":\""
            + data
            + "\"}}}");
    Mail m = g.body(gmail(), "m");
    assertEquals("<script>bad()</script><p>Hello</p><img src=https://tracker.test>", m.bodyHtml());
    assertTrue(m.bodyText().contains("Hello"));
    assertFalse(m.bodyText().contains("bad()"));
  }

  @Test
  void gmailFetchesBodyStoredUnderAttachmentId() throws Exception {
    String html = "<h1>Large HTML body</h1><img src='http://127.0.0.1:1/tracker'>";
    route(
        "/messages/m",
        200,
        "{\"id\":\"m\",\"payload\":{\"mimeType\":\"text/html\","
            + "\"body\":{\"data\":\"\",\"attachmentId\":\"body-only\",\"size\":100}}}");
    route(
        "/messages/m/attachments/body-only",
        200,
        new ObjectMapper()
            .writeValueAsString(
                Map.of(
                    "data",
                    Base64.getUrlEncoder().encodeToString(html.getBytes(StandardCharsets.UTF_8)))));
    Mail mail = new GmailAdapter(new ObjectMapper(), base).body(gmail(), "m");
    assertEquals(html, mail.bodyHtml());
    assertEquals("Large HTML body", mail.bodyText());
    assertFalse(mail.hasAttachments());
    assertTrue(request.get().contains("/attachments/body-only"));
  }

  @Test
  void graphRequestsHtmlAndPreservesItAlongsideFallback() throws Exception {
    String html = "<h2>Title</h2><p>First</p><p>Second</p>";
    route(
        "/messages/m",
        200,
        new ObjectMapper()
            .writeValueAsString(
                Map.of("id", "m", "body", Map.of("contentType", "HTML", "content", html))));
    Mail mail = new GraphAdapter(new ObjectMapper(), base).body(gmail(), "m");
    assertEquals(html, mail.bodyHtml());
    assertTrue(mail.bodyText().contains("First\n"));
    assertTrue(request.get().contains("outlook.body-content-type=\"html\""));
    assertTrue(request.get().contains("ImmutableId"));
  }

  @Test
  void gmailAttachmentMetadataAndBytes() {
    String json =
        "{\"id\":\"m\",\"payload\":{\"mimeType\":\"multipart/mixed\",\"parts\":[{\"filename\":\"note.txt\",\"mimeType\":\"text/plain\",\"body\":{\"attachmentId\":\"a\",\"size\":5}}]}}";
    route("/messages/m", 200, json);
    route("/messages/m/attachments/a", 200, "{\"data\":\"aGVsbG8\"}");
    GmailAdapter g = new GmailAdapter(new ObjectMapper(), base);
    assertTrue(g.body(gmail(), "m").hasAttachments());
    Download d = g.attachment(gmail(), "m", "a");
    assertEquals("hello", new String(d.bytes(), StandardCharsets.UTF_8));
    assertEquals("note.txt", d.fileName());
  }

  @Test
  void graphAttachmentMetadataAndBytes() {
    route("/messages/m", 200, "{\"id\":\"m\",\"hasAttachments\":true}");
    route(
        "/messages/m/attachments",
        200,
        "{\"value\":[{\"id\":\"a\",\"name\":\"note.txt\",\"size\":5,\"contentType\":\"text/plain\"}]}");
    route(
        "/messages/m/attachments/a",
        200,
        "{\"@odata.type\":\"#microsoft.graph.fileAttachment\",\"name\":\"note.txt\",\"size\":5,\"contentType\":\"text/plain\",\"contentBytes\":\"aGVsbG8=\"}");
    GraphAdapter g = new GraphAdapter(new ObjectMapper(), base);
    assertEquals(1, g.body(gmail(), "m").attachments().size());
    assertEquals(
        "hello", new String(g.attachment(gmail(), "m", "a").bytes(), StandardCharsets.UTF_8));
  }

  @Test
  void mimeContainsAllRecipientsAndAttachment() throws Exception {
    Outgoing o =
        new Outgoing(
            List.of(new Address("", "to@example.test")),
            List.of(new Address("", "cc@example.test")),
            List.of(new Address("", "bcc@example.test")),
            "fixture",
            "hello",
            List.of(new Upload("note.txt", "text/plain", "data".getBytes(StandardCharsets.UTF_8))),
            "<fixed@example.test>");
    var m = MimeSupport.compose(gmail(), o);
    assertEquals(3, m.getAllRecipients().length);
    assertEquals("<fixed@example.test>", m.getMessageID());
    List<Attachment> a = new ArrayList<>();
    MimeSupport.Body body = MimeSupport.parse(m, a, "m");
    assertEquals(1, a.size());
    assertEquals("note.txt", a.get(0).fileName());
    assertTrue(body.fallbackText().contains("hello"));
  }
}
