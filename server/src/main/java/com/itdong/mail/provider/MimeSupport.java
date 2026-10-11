package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;

import com.itdong.mail.provider.ProviderGateway.Address;
import jakarta.activation.*;
import jakarta.mail.*;
import jakarta.mail.internet.*;
import jakarta.mail.util.ByteArrayDataSource;
import java.io.*;
import java.util.*;

final class MimeSupport {
  static MimeMessage compose(Credentials c, Outgoing o) throws Exception {
    MimeMessage m = new MimeMessage(Session.getInstance(new Properties()));
    m.setFrom(new InternetAddress(c.email(), true));
    recipients(m, Message.RecipientType.TO, o.to());
    recipients(m, Message.RecipientType.CC, o.cc());
    recipients(m, Message.RecipientType.BCC, o.bcc());
    if (m.getAllRecipients() == null || m.getAllRecipients().length == 0)
      throw new ProviderException("INVALID_RECIPIENT", false);
    if (o.subject() != null && (o.subject().contains("\r") || o.subject().contains("\n")))
      throw new ProviderException("INVALID_SUBJECT", false);
    m.setSubject(o.subject() == null ? "" : o.subject(), "UTF-8");
    MimeMultipart mixed = new MimeMultipart("mixed");
    MimeBodyPart text = new MimeBodyPart();
    text.setText(o.bodyText() == null ? "" : o.bodyText(), "UTF-8");
    mixed.addBodyPart(text);
    long total = 0;
    if (o.attachments() != null)
      for (Upload u : o.attachments()) {
        total += u.bytes().length;
        if (total > 10 * 1024 * 1024) throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
        MimeBodyPart part = new MimeBodyPart();
        part.setDataHandler(new DataHandler(new ByteArrayDataSource(u.bytes(), u.contentType())));
        part.setFileName(u.fileName());
        part.setDisposition(Part.ATTACHMENT);
        mixed.addBodyPart(part);
      }
    m.setContent(mixed);
    m.setSentDate(new Date());
    m.saveChanges();
    if (o.messageId() != null && !o.messageId().contains("\r") && !o.messageId().contains("\n"))
      m.setHeader("Message-ID", o.messageId());
    return m;
  }

  static void recipients(MimeMessage m, Message.RecipientType type, List<Address> addresses)
      throws Exception {
    if (addresses != null)
      for (Address a : addresses) {
        InternetAddress ia = new InternetAddress(a.address(), true);
        ia.validate();
        m.addRecipient(type, ia);
      }
  }

  static String raw(MimeMessage m) throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    m.writeTo(out);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(out.toByteArray());
  }

  static final int MAX_BODY_CHARS = 2_000_000;
  static final int MAX_BODY_BYTES = 2 * 1024 * 1024;

  // Provider HTML is untrusted data. Only the client's isolated, sanitized reader may render it.
  // Jsoup parses locally; it never resolves image URLs or other resources.
  static String safeText(String html) {
    var document = org.jsoup.Jsoup.parse(html == null ? "" : html);
    document.select("script,style,head,template").remove();
    document.select("br").forEach(br -> br.replaceWith(new org.jsoup.nodes.TextNode("\n")));
    document
        .select("p,div,section,article,header,footer,h1,h2,h3,h4,h5,h6,ul,ol,li,tr,blockquote")
        .before("\n")
        .after("\n");
    document.select("td,th").after("\t");
    String text =
        document
            .body()
            .wholeText()
            .replace('\u00a0', ' ')
            .replaceAll("[ \t]+\n", "\n")
            .replaceAll("\n[ \t]+", "\n")
            .replaceAll("\n{3,}", "\n\n")
            .strip();
    return checked(text);
  }

  static String checked(String value) {
    String s = value == null ? "" : value;
    if (s.length() > MAX_BODY_CHARS) throw new ProviderException("BODY_TOO_LARGE", false);
    return s;
  }

  record Body(String text, String html) {
    static final Body EMPTY = new Body("", "");

    Body {
      text = checked(text);
      html = checked(html);
    }

    String fallbackText() {
      return text.isBlank() && !html.isBlank() ? safeText(html) : text;
    }
  }

  static final class ParseBudget {
    int parts;
    long bytes;

    void part(int depth) {
      if (depth > 20 || ++parts > 1000) throw new ProviderException("MIME_LIMIT", false);
    }

    void bytes(int count) {
      bytes += count;
      if (bytes > MAX_BODY_BYTES) throw new ProviderException("BODY_TOO_LARGE", false);
    }
  }

  static Body combine(List<Body> bodies, boolean alternative) {
    if (alternative) {
      // Each alternative is the same content, not another paragraph. Keep the last supported
      // representation of each type and derive a fallback only after this selection.
      String text = "", html = "";
      for (Body body : bodies) {
        if (!body.text().isBlank()) text = body.text();
        if (!body.html().isBlank()) html = body.html();
      }
      return new Body(text, html);
    }
    List<Body> content =
        bodies.stream().filter(b -> !b.text().isBlank() || !b.html().isBlank()).toList();
    if (content.isEmpty()) return Body.EMPTY;
    if (content.size() == 1) return content.getFirst();
    StringBuilder text = new StringBuilder(), html = new StringBuilder();
    boolean hasHtml = content.stream().anyMatch(b -> !b.html().isBlank());
    for (Body body : content) {
      if (!text.isEmpty()) text.append("\n\n");
      text.append(body.fallbackText());
      if (hasHtml) {
        html.append("<section>");
        html.append(
            body.html().isBlank()
                ? "<pre>" + org.jsoup.nodes.Entities.escape(body.text()) + "</pre>"
                : body.html());
        html.append("</section>");
      }
      if (text.length() > MAX_BODY_CHARS || html.length() > MAX_BODY_CHARS)
        throw new ProviderException("BODY_TOO_LARGE", false);
    }
    return new Body(text.toString(), html.toString());
  }

  static String decodeText(byte[] bytes, String contentType, ParseBudget budget) throws Exception {
    budget.bytes(bytes.length);
    String charset = new ContentType(contentType).getParameter("charset");
    try {
      return checked(
          new String(
              bytes,
              charset == null
                  ? java.nio.charset.StandardCharsets.UTF_8
                  : java.nio.charset.Charset.forName(charset)));
    } catch (java.nio.charset.UnsupportedCharsetException
        | java.nio.charset.IllegalCharsetNameException e) {
      // Broken charset declarations should not make otherwise readable messages inaccessible.
      return checked(new String(bytes, java.nio.charset.StandardCharsets.UTF_8));
    }
  }

  static List<Address> addresses(jakarta.mail.Address[] in) {
    if (in == null) return List.of();
    return Arrays.stream(in)
        .map(
            a ->
                a instanceof InternetAddress i
                    ? new Address(i.getPersonal() == null ? "" : i.getPersonal(), i.getAddress())
                    : new Address("", a.toString()))
        .toList();
  }

  static Body parse(Part part, List<Attachment> attachments, String prefix) throws Exception {
    return parse(part, attachments, prefix, 0, new ParseBudget());
  }

  private static Body parse(
      Part p, List<Attachment> attachments, String prefix, int depth, ParseBudget budget)
      throws Exception {
    budget.part(depth);
    if (Part.ATTACHMENT.equalsIgnoreCase(p.getDisposition()) || p.getFileName() != null) {
      if (attachments.size() >= 100) throw new ProviderException("MIME_LIMIT", false);
      attachments.add(
          new Attachment(
              prefix,
              p.getFileName() == null ? "attachment" : p.getFileName(),
              p.getContentType(),
              Math.max(0, p.getSize())));
      return Body.EMPTY;
    }
    if (p.isMimeType("text/plain") || p.isMimeType("text/html")) {
      try (InputStream in = p.getInputStream()) {
        byte[] bytes = in.readNBytes(MAX_BODY_BYTES + 1);
        String value = decodeText(bytes, p.getContentType(), budget);
        return p.isMimeType("text/html") ? new Body("", value) : new Body(value, "");
      }
    }
    if (p.isMimeType("multipart/*")) {
      Multipart mp = (Multipart) p.getContent();
      List<Body> bodies = new ArrayList<>();
      int root = 0;
      String start = new ContentType(p.getContentType()).getParameter("start");
      for (int i = 0; i < mp.getCount(); i++) {
        Part child = mp.getBodyPart(i);
        if (start != null
            && Arrays.asList(
                    Objects.requireNonNullElse(child.getHeader("Content-ID"), new String[0]))
                .contains(start)) root = i;
        bodies.add(parse(child, attachments, prefix + "." + i, depth + 1, budget));
      }
      // Related resources are not extra message bodies. Never download external resource URLs.
      if (p.isMimeType("multipart/related"))
        return bodies.isEmpty() ? Body.EMPTY : bodies.get(root);
      return combine(bodies, p.isMimeType("multipart/alternative"));
    }
    return Body.EMPTY;
  }
}
