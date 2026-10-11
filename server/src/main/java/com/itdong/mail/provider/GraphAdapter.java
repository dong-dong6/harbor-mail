package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;

import com.fasterxml.jackson.databind.*;
import java.net.URI;
import java.time.Instant;
import java.util.*;

final class GraphAdapter implements ProviderGateway {
  final HttpTransport http;
  final String base;

  GraphAdapter(ObjectMapper mapper, String base) {
    http = new HttpTransport(mapper);
    this.base = base;
  }

  JsonNode call(Credentials c, String method, String path, Object body, boolean send) {
    return http.request(
        method,
        URI.create(base + path),
        c.accessToken(),
        body,
        send,
        Map.of("Prefer", "IdType=\"ImmutableId\", outlook.body-content-type=\"html\""));
  }

  static String folderId(String role) {
    return switch (role == null ? "INBOX" : role) {
      case "INBOX" -> "inbox";
      case "SENT" -> "sentitems";
      case "TRASH" -> "deleteditems";
      case "ARCHIVE" -> "archive";
      default -> throw new ProviderException("NOT_SUPPORTED", false);
    };
  }

  public List<Folder> folders(Credentials c) {
    List<Folder> out = new ArrayList<>();
    for (String role : List.of("INBOX", "SENT", "TRASH", "ARCHIVE")) {
      JsonNode n = call(c, "GET", "/mailFolders/" + folderId(role), null, false);
      out.add(
          new Folder(
              role, n.path("displayName").asText(), role, n.path("unreadItemCount").asInt()));
    }
    return out;
  }

  public SyncPage sync(Credentials c, String folder, String cursor, int limit) {
    String path =
        "/mailFolders/"
            + folderId(folder)
            + "/messages?$top="
            + Math.max(1, Math.min(100, limit))
            + "&$orderby=receivedDateTime%20desc&$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,flag,hasAttachments,bodyPreview,parentFolderId";
    if (cursor != null && !cursor.isBlank()) {
      String decoded;
      try {
        decoded =
            new String(
                Base64.getUrlDecoder().decode(cursor), java.nio.charset.StandardCharsets.UTF_8);
      } catch (Exception e) {
        throw new ProviderException("INVALID_CURSOR", false);
      }
      if (!decoded.startsWith(base + "/mailFolders/") || !decoded.contains("/messages?"))
        throw new ProviderException("INVALID_CURSOR", false);
      path = decoded.substring(base.length());
    }
    JsonNode n = call(c, "GET", path, null, false);
    List<Mail> out = new ArrayList<>();
    for (JsonNode m : n.path("value")) out.add(parse(m, folder));
    String next = n.path("@odata.nextLink").asText(null);
    if (next != null && !next.startsWith(base + "/mailFolders/"))
      throw new ProviderException("INVALID_PROVIDER_CURSOR", false);
    return new SyncPage(
        out,
        next == null
            ? null
            : Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(next.getBytes(java.nio.charset.StandardCharsets.UTF_8)),
        next != null,
        "PARTIAL");
  }

  public Mail body(Credentials c, String id) {
    JsonNode n = call(c, "GET", "/messages/" + HttpTransport.enc(id), null, false);
    List<Attachment> attachments = new ArrayList<>();
    if (n.path("hasAttachments").asBoolean()) {
      JsonNode list =
          call(
              c,
              "GET",
              "/messages/"
                  + HttpTransport.enc(id)
                  + "/attachments?$select=id,name,contentType,size&$top=100",
              null,
              false);
      for (JsonNode a : list.path("value"))
        attachments.add(
            new Attachment(
                a.path("id").asText(),
                a.path("name").asText(),
                a.path("contentType").asText(),
                a.path("size").asLong()));
    }
    Mail m = parse(n, "");
    return new Mail(
        m.remoteId(),
        m.folder(),
        m.fromName(),
        m.fromAddress(),
        m.to(),
        m.cc(),
        m.subject(),
        m.snippet(),
        m.receivedAt(),
        m.isRead(),
        m.isStarred(),
        m.hasAttachments(),
        m.bodyText(),
        m.bodyHtml(),
        attachments);
  }

  static List<Address> addresses(JsonNode n) {
    List<Address> out = new ArrayList<>();
    for (JsonNode a : n) {
      JsonNode v = a.path("emailAddress");
      out.add(new Address(v.path("name").asText(), v.path("address").asText()));
    }
    return out;
  }

  Mail parse(JsonNode n, String folder) {
    JsonNode from = n.path("from").path("emailAddress");
    String content = MimeSupport.checked(n.path("body").path("content").asText());
    if (content.getBytes(java.nio.charset.StandardCharsets.UTF_8).length
        > MimeSupport.MAX_BODY_BYTES) throw new ProviderException("BODY_TOO_LARGE", false);
    boolean html = n.path("body").path("contentType").asText().equalsIgnoreCase("html");
    Instant date;
    try {
      date = Instant.parse(n.path("receivedDateTime").asText());
    } catch (Exception e) {
      date = Instant.EPOCH;
    }
    return new Mail(
        n.path("id").asText(),
        folder,
        from.path("name").asText(),
        from.path("address").asText(),
        addresses(n.path("toRecipients")),
        addresses(n.path("ccRecipients")),
        n.path("subject").asText(),
        n.path("bodyPreview").asText(),
        date,
        n.path("isRead").asBoolean(),
        n.path("flag").path("flagStatus").asText().equals("flagged"),
        n.path("hasAttachments").asBoolean(),
        html ? MimeSupport.safeText(content) : content,
        html ? content : "",
        List.of());
  }

  public MutationResult mutate(Credentials c, String id, String action, Boolean value) {
    String path = "/messages/" + HttpTransport.enc(id);
    switch (action) {
      case "SET_READ" ->
          call(c, "PATCH", path, Map.of("isRead", Boolean.TRUE.equals(value)), false);
      case "SET_STAR" ->
          call(
              c,
              "PATCH",
              path,
              Map.of(
                  "flag",
                  Map.of("flagStatus", Boolean.TRUE.equals(value) ? "flagged" : "notFlagged")),
              false);
      case "TRASH", "ARCHIVE", "RESTORE" -> {
        JsonNode moved =
            call(
                c,
                "POST",
                path + "/move",
                Map.of(
                    "destinationId",
                    action.equals("TRASH")
                        ? "deleteditems"
                        : action.equals("ARCHIVE") ? "archive" : "inbox"),
                false);
        String newId = moved.path("id").asText();
        if (newId.isBlank()) throw new ProviderException("MOVE_MAPPING_UNKNOWN", false);
        return new MutationResult(newId);
      }
      default -> throw new ProviderException("NOT_SUPPORTED", false);
    }
    return new MutationResult(id);
  }

  public Download attachment(Credentials c, String id, String attachmentId) {
    JsonNode n =
        call(
            c,
            "GET",
            "/messages/"
                + HttpTransport.enc(id)
                + "/attachments/"
                + HttpTransport.enc(attachmentId),
            null,
            false);
    if (!n.path("@odata.type").asText().equals("#microsoft.graph.fileAttachment"))
      throw new ProviderException("ATTACHMENT_TYPE_NOT_SUPPORTED", false);
    if (n.path("size").asLong() > 10 * 1024 * 1024)
      throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
    byte[] bytes;
    try {
      bytes = Base64.getDecoder().decode(n.path("contentBytes").asText());
    } catch (Exception e) {
      throw new ProviderException("INVALID_ATTACHMENT", false);
    }
    if (bytes.length > 10 * 1024 * 1024) throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
    return new Download(
        bytes,
        n.path("contentType").asText("application/octet-stream"),
        n.path("name").asText("attachment"));
  }

  public SendResult send(Credentials c, Outgoing o) {
    String raw;
    try {
      raw =
          Base64.getEncoder()
              .encodeToString(
                  Base64.getUrlDecoder().decode(MimeSupport.raw(MimeSupport.compose(c, o))));
    } catch (ProviderException e) {
      throw e;
    } catch (Exception e) {
      throw new ProviderException("INVALID_MESSAGE", false);
    }
    http.request(
        "POST",
        URI.create(base + "/sendMail"),
        c.accessToken(),
        raw,
        true,
        Map.of("Content-Type", "text/plain", "Prefer", "IdType=\"ImmutableId\""));
    return new SendResult("ACCEPTED", null);
  }
}
