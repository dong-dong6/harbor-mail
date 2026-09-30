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

  static String safeText(String html) {
    return org.jsoup.Jsoup.parse(html == null ? "" : html).text();
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

  static void parse(
      Part p, StringBuilder text, List<Attachment> attachments, String prefix, int depth)
      throws Exception {
    if (depth > 20 || attachments.size() > 100) throw new ProviderException("MIME_LIMIT", false);
    if (Part.ATTACHMENT.equalsIgnoreCase(p.getDisposition()) || p.getFileName() != null) {
      attachments.add(
          new Attachment(
              prefix,
              p.getFileName() == null ? "attachment" : p.getFileName(),
              p.getContentType(),
              Math.max(0, p.getSize())));
      return;
    }
    if (p.isMimeType("text/plain") || p.isMimeType("text/html")) {
      try (InputStream in = p.getInputStream()) {
        byte[] b = in.readNBytes(2 * 1024 * 1024 + 1);
        if (b.length > 2 * 1024 * 1024) throw new ProviderException("BODY_TOO_LARGE", false);
        String charset = new ContentType(p.getContentType()).getParameter("charset");
        String s =
            new String(
                b,
                charset == null
                    ? java.nio.charset.StandardCharsets.UTF_8
                    : java.nio.charset.Charset.forName(charset));
        if (text.length() + s.length() > 2 * 1024 * 1024)
          throw new ProviderException("BODY_TOO_LARGE", false);
        text.append(p.isMimeType("text/html") ? safeText(s) : s).append('\n');
      }
    } else if (p.isMimeType("multipart/*")) {
      Multipart mp = (Multipart) p.getContent();
      for (int i = 0; i < mp.getCount(); i++)
        parse(mp.getBodyPart(i), text, attachments, prefix + "." + i, depth + 1);
    }
  }
}
