package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;
import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.mail.Session;
import jakarta.mail.internet.MimeMessage;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.junit.jupiter.api.Test;

class ProviderBodyTest {
  final ObjectMapper json = new ObjectMapper();
  final Credentials credentials = new Credentials("GMAIL", "owner@example.test", "fixture", null);

  MimeMessage mime(String raw) throws Exception {
    return new MimeMessage(
        Session.getInstance(new Properties()),
        new ByteArrayInputStream(raw.replace("\n", "\r\n").getBytes(StandardCharsets.UTF_8)));
  }

  JsonNode gmailPart(String type, String content) {
    return json.valueToTree(
        Map.of(
            "mimeType",
            type,
            "body",
            Map.of(
                "data",
                Base64.getUrlEncoder()
                    .withoutPadding()
                    .encodeToString(content.getBytes(StandardCharsets.UTF_8)))));
  }

  Mail gmail(JsonNode payload) {
    return new GmailAdapter(json, "http://127.0.0.1:1")
        .parse(credentials, json.valueToTree(Map.of("id", "fixture", "payload", payload)), true);
  }

  @Test
  void mimeAlternativePreservesBothRepresentationsWithoutDuplicatingText() throws Exception {
    var message =
        mime(
            """
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary=outer

            --outer
            Content-Type: multipart/alternative; boundary=body

            --body
            Content-Type: text/plain; charset=UTF-8

            Plain version
            --body
            Content-Type: text/html; charset=UTF-8

            <h1>Rich version</h1><table><tr><td>One</td><td>Two</td></tr></table>
            --body--
            --outer
            Content-Type: text/plain
            Content-Disposition: attachment; filename=notes.txt

            This attachment must not become body text
            --outer--
            """);
    List<Attachment> attachments = new ArrayList<>();
    var body = MimeSupport.parse(message, attachments, "fixture");
    assertEquals("Plain version", body.fallbackText());
    assertEquals(
        "<h1>Rich version</h1><table><tr><td>One</td><td>Two</td></tr></table>", body.html());
    assertEquals(1, attachments.size());
    assertEquals("fixture.1", attachments.getFirst().id());
    assertEquals("notes.txt", attachments.getFirst().fileName());
    var mail = new ImapAdapter().parse(message, "fixture", "INBOX", true);
    assertEquals(body.html(), mail.bodyHtml());
    assertEquals("Plain version", mail.bodyText());
  }

  @Test
  void gmailAlternativesChooseLastSupportedHtmlWithoutAppendingItsText() {
    var payload =
        json.valueToTree(
            Map.of(
                "mimeType",
                "multipart/alternative",
                "parts",
                List.of(
                    gmailPart("text/plain", "Plain version"),
                    gmailPart("text/html", "<p>Old</p>"),
                    gmailPart("text/html", "<p>Rich version</p>"))));
    Mail mail = gmail(payload);
    assertEquals("Plain version", mail.bodyText());
    assertEquals("<p>Rich version</p>", mail.bodyHtml());
  }

  @Test
  void htmlOnlyHasReadableFallbackWithoutActiveContentOrRemoteFetches() throws Exception {
    String html =
        "<style>hide</style><script>bad()</script><p>First &amp; second</p>"
            + "<p>Third<br>Fourth</p><img src='http://127.0.0.1:1/tracker'>";
    Mail mail = gmail(gmailPart("text/html", html));
    assertEquals(html, mail.bodyHtml());
    assertTrue(mail.bodyText().contains("First & second\n"));
    assertTrue(mail.bodyText().contains("Third\nFourth"));
    assertFalse(mail.bodyText().contains("bad()"));
    assertFalse(mail.bodyText().contains("hide"));
    assertFalse(mail.bodyText().contains("tracker"));
    var mimeBody =
        MimeSupport.parse(
            mime("Content-Type: text/html; charset=UTF-8\n\n" + html),
            new ArrayList<>(),
            "fixture");
    assertEquals(html, mimeBody.html());
    assertEquals(mail.bodyText(), mimeBody.fallbackText());
  }

  @Test
  void plainTextStaysPlainAcrossAllAdapters() throws Exception {
    String text = "Line one\nLine two <literal>";
    Mail google = gmail(gmailPart("text/plain", text));
    assertEquals(text, google.bodyText());
    assertEquals("", google.bodyHtml());
    var mimeBody =
        MimeSupport.parse(
            mime("Content-Type: text/plain; charset=UTF-8\n\n" + text),
            new ArrayList<>(),
            "fixture");
    assertEquals(text.replace("\n", "\r\n"), mimeBody.fallbackText());
    assertEquals("", mimeBody.html());
    Mail graph =
        new GraphAdapter(json, "http://127.0.0.1:1")
            .parse(
                json.valueToTree(Map.of("body", Map.of("contentType", "text", "content", text))),
                "INBOX");
    assertEquals(text, graph.bodyText());
    assertEquals("", graph.bodyHtml());
  }

  @Test
  void charsetAndQuotedPrintableAreDecodedBeforePreservingHtml() throws Exception {
    var mimeBody =
        MimeSupport.parse(
            mime(
                """
                Content-Type: text/html; charset=ISO-8859-1
                Content-Transfer-Encoding: quoted-printable

                <p>Caf=E9</p>"""),
            new ArrayList<>(),
            "fixture");
    assertEquals("<p>Café</p>", mimeBody.html());
    assertEquals("Café", mimeBody.fallbackText());
    JsonNode payload =
        json.valueToTree(
            Map.of(
                "mimeType",
                "text/html",
                "headers",
                List.of(Map.of("name", "Content-Type", "value", "text/html; charset=ISO-8859-1")),
                "body",
                Map.of(
                    "data",
                    Base64.getUrlEncoder()
                        .encodeToString("<p>Café</p>".getBytes(StandardCharsets.ISO_8859_1)))));
    assertEquals("<p>Café</p>", gmail(payload).bodyHtml());
  }

  @Test
  void relatedUsesDeclaredRootWithoutAddingOtherRelatedBodies() throws Exception {
    var mimeBody =
        MimeSupport.parse(
            mime(
                """
                Content-Type: multipart/related; boundary=related; start="<root>"

                --related
                Content-Type: text/html
                Content-ID: <other>

                <p>Not the root</p>
                --related
                Content-Type: text/html
                Content-ID: <root>

                <p>Root body</p><img src="cid:logo">
                --related
                Content-Type: image/png
                Content-ID: <logo>
                Content-Disposition: inline; filename=logo.png
                Content-Transfer-Encoding: base64

                ZmFrZQ==
                --related--
                """),
            new ArrayList<>(),
            "fixture");
    assertEquals("<p>Root body</p><img src=\"cid:logo\">", mimeBody.html());
    assertEquals("Root body", mimeBody.fallbackText());
    var other =
        (com.fasterxml.jackson.databind.node.ObjectNode) gmailPart("text/html", "<p>Not root</p>");
    var root =
        (com.fasterxml.jackson.databind.node.ObjectNode) gmailPart("text/html", "<p>Root body</p>");
    root.set("headers", json.valueToTree(List.of(Map.of("name", "Content-ID", "value", "<root>"))));
    Mail google =
        gmail(
            json.valueToTree(
                Map.of(
                    "mimeType",
                    "multipart/related",
                    "headers",
                    List.of(
                        Map.of(
                            "name",
                            "Content-Type",
                            "value",
                            "multipart/related; start=\"<root>\"")),
                    "parts",
                    List.of(other, root))));
    assertEquals("<p>Root body</p>", google.bodyHtml());
    assertEquals("Root body", google.bodyText());
  }

  @Test
  void mixedBodiesKeepAdditionalTextAndHtmlWithoutConvertingAttachments() {
    Mail mail =
        gmail(
            json.valueToTree(
                Map.of(
                    "mimeType",
                    "multipart/mixed",
                    "parts",
                    List.of(
                        gmailPart("text/html", "<p>First section</p>"),
                        gmailPart("text/plain", "Second <section>")))));
    assertEquals("First section\n\nSecond <section>", mail.bodyText());
    assertTrue(mail.bodyHtml().contains("<p>First section</p>"));
    assertTrue(mail.bodyHtml().contains("<pre>Second &lt;section&gt;</pre>"));
  }

  @Test
  void unnamedTextAttachmentIsNotAnAlternativeBody() {
    var attachment =
        (com.fasterxml.jackson.databind.node.ObjectNode) gmailPart("text/plain", "Attachment text");
    attachment.set(
        "headers",
        json.valueToTree(List.of(Map.of("name", "Content-Disposition", "value", "attachment"))));
    Mail mail =
        gmail(
            json.valueToTree(
                Map.of(
                    "mimeType",
                    "multipart/mixed",
                    "parts",
                    List.of(gmailPart("text/html", "<p>Body</p>"), attachment))));
    assertEquals("Body", mail.bodyText());
    assertEquals("<p>Body</p>", mail.bodyHtml());
    assertEquals(1, mail.attachments().size());
  }

  @Test
  void allAdaptersRejectOversizedHtml() throws Exception {
    String huge = "x".repeat(MimeSupport.MAX_BODY_CHARS + 1);
    assertEquals(
        "BODY_TOO_LARGE",
        assertThrows(ProviderException.class, () -> gmail(gmailPart("text/html", huge))).code());
    assertEquals(
        "BODY_TOO_LARGE",
        assertThrows(
                ProviderException.class,
                () ->
                    MimeSupport.parse(
                        mime("Content-Type: text/html\n\n" + huge), new ArrayList<>(), "fixture"))
            .code());
    assertEquals(
        "BODY_TOO_LARGE",
        assertThrows(
                ProviderException.class,
                () ->
                    new GraphAdapter(json, "http://127.0.0.1:1")
                        .parse(
                            json.valueToTree(
                                Map.of("body", Map.of("contentType", "html", "content", huge))),
                            "INBOX"))
            .code());
  }

  @Test
  void mimeDepthAndTotalPartLimitsAreEnforced() {
    JsonNode payload = gmailPart("text/plain", "Text");
    for (int i = 0; i < 22; i++)
      payload = json.valueToTree(Map.of("mimeType", "multipart/mixed", "parts", List.of(payload)));
    final JsonNode deeplyNested = payload;
    assertEquals(
        "MIME_LIMIT", assertThrows(ProviderException.class, () -> gmail(deeplyNested)).code());
    JsonNode manyParts =
        json.valueToTree(
            Map.of(
                "mimeType",
                "multipart/mixed",
                "parts",
                Collections.nCopies(1000, gmailPart("image/png", ""))));
    assertEquals(
        "MIME_LIMIT", assertThrows(ProviderException.class, () -> gmail(manyParts)).code());
  }
}
