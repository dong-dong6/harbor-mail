package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;

import com.itdong.mail.provider.ProviderGateway.Address;
import jakarta.mail.*;
import jakarta.mail.internet.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import org.eclipse.angus.mail.imap.IMAPFolder;

final class ImapAdapter implements ProviderGateway {
  record Endpoint(String imap, int imapPort, String smtp, int smtpPort, boolean tls) {}

  private final Endpoint testEndpoint;

  ImapAdapter() {
    testEndpoint = null;
  }

  ImapAdapter(Endpoint localTest) {
    if (!Set.of("localhost", "127.0.0.1", "::1").contains(localTest.imap())
        || !Set.of("localhost", "127.0.0.1", "::1").contains(localTest.smtp()))
      throw new IllegalArgumentException("Only loopback test endpoints");
    testEndpoint = localTest;
  }

  Endpoint endpoint(Credentials c) {
    if (testEndpoint != null) return testEndpoint;
    return switch (c.provider()) {
      case "QQ" -> new Endpoint("imap.qq.com", 993, "smtp.qq.com", 465, true);
      case "NETEASE" -> new Endpoint("imap.163.com", 993, "smtp.163.com", 465, true);
      default -> throw new ProviderException("NOT_SUPPORTED", false);
    };
  }

  Session session(Endpoint e) {
    Properties p = new Properties();
    for (String proto : List.of("imap", "smtp")) {
      p.setProperty("mail." + proto + ".connectiontimeout", "15000");
      p.setProperty("mail." + proto + ".timeout", "30000");
      p.setProperty("mail." + proto + ".writetimeout", "30000");
      p.setProperty("mail." + proto + ".ssl.enable", String.valueOf(e.tls()));
      p.setProperty("mail." + proto + ".ssl.checkserveridentity", "true");
    }
    p.setProperty("mail.imap.peek", "true");
    p.setProperty("mail.smtp.auth", "true");
    p.setProperty("mail.smtp.sendpartial", "false");
    return Session.getInstance(p);
  }

  Store connect(Credentials c) throws Exception {
    Endpoint e = endpoint(c);
    Store s = session(e).getStore("imap");
    s.connect(e.imap(), e.imapPort(), c.email(), c.secret());
    return s;
  }

  String role(jakarta.mail.Folder f) throws MessagingException {
    String name = f.getName();
    if (name.equalsIgnoreCase("INBOX")) return "INBOX";
    if (f instanceof IMAPFolder im) {
      for (String a : im.getAttributes()) {
        if (a.equalsIgnoreCase("\\Sent")) return "SENT";
        if (a.equalsIgnoreCase("\\Trash")) return "TRASH";
        if (a.equalsIgnoreCase("\\Archive")) return "ARCHIVE";
      }
    }
    return "CUSTOM";
  }

  jakarta.mail.Folder find(Store s, String wanted) throws Exception {
    if (wanted == null || wanted.equals("INBOX")) return s.getFolder("INBOX");
    for (jakarta.mail.Folder f : s.getDefaultFolder().list("*"))
      if (role(f).equals(wanted)) return f;
    throw new ProviderException("FOLDER_NOT_SUPPORTED", false);
  }

  public List<ProviderGateway.Folder> folders(Credentials c) {
    try (Store s = connect(c)) {
      List<ProviderGateway.Folder> out = new ArrayList<>();
      for (jakarta.mail.Folder f : s.getDefaultFolder().list("*"))
        if ((f.getType() & jakarta.mail.Folder.HOLDS_MESSAGES) != 0)
          out.add(
              new ProviderGateway.Folder(
                  f.getFullName(), f.getName(), role(f), Math.max(0, f.getUnreadMessageCount())));
      return out;
    } catch (Exception e) {
      throw safe(e, false);
    }
  }

  static String id(jakarta.mail.Folder f, UIDFolder u, Message m) throws Exception {
    return Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(f.getFullName().getBytes(StandardCharsets.UTF_8))
        + ":"
        + u.getUIDValidity()
        + ":"
        + u.getUID(m);
  }

  record Key(String folder, long validity, long uid) {}

  static Key key(String id) {
    try {
      String[] p = id.split(":", -1);
      if (p.length != 3) throw new IllegalArgumentException();
      return new Key(
          new String(Base64.getUrlDecoder().decode(p[0]), StandardCharsets.UTF_8),
          Long.parseLong(p[1]),
          Long.parseLong(p[2]));
    } catch (Exception e) {
      throw new ProviderException("INVALID_MESSAGE_ID", false);
    }
  }

  public SyncPage sync(Credentials c, String folder, String cursor, int limit) {
    try (Store s = connect(c)) {
      jakarta.mail.Folder f = find(s, folder);
      f.open(jakarta.mail.Folder.READ_ONLY);
      try {
        UIDFolder u = (UIDFolder) f;
        int count = f.getMessageCount();
        int size = Math.max(1, Math.min(100, limit));
        int end = count;
        if (cursor != null && !cursor.isBlank()) {
          Key k = key(cursor);
          if (!k.folder().equals(f.getFullName()) || k.validity() != u.getUIDValidity())
            throw new ProviderException("UIDVALIDITY_CHANGED", false);
          Message anchor = u.getMessageByUID(k.uid());
          if (anchor == null) throw new ProviderException("CURSOR_EXPIRED", false);
          end = anchor.getMessageNumber() - 1;
        }
        int start = Math.max(1, end - size + 1);
        List<Mail> out = new ArrayList<>();
        if (end >= 1) {
          Message[] messages = f.getMessages(start, end);
          FetchProfile fp = new FetchProfile();
          fp.add(FetchProfile.Item.ENVELOPE);
          fp.add(FetchProfile.Item.FLAGS);
          fp.add(UIDFolder.FetchProfileItem.UID);
          f.fetch(messages, fp);
          for (int i = messages.length - 1; i >= 0; i--)
            out.add(parse(messages[i], id(f, u, messages[i]), folder, false));
        }
        boolean more = start > 1;
        return new SyncPage(out, more ? out.get(out.size() - 1).remoteId() : null, more, "PARTIAL");
      } finally {
        f.close(false);
      }
    } catch (Exception e) {
      throw safe(e, false);
    }
  }

  public Mail body(Credentials c, String remoteId) {
    Key k = key(remoteId);
    try (Store s = connect(c)) {
      jakarta.mail.Folder f = s.getFolder(k.folder());
      f.open(jakarta.mail.Folder.READ_ONLY);
      try {
        Message m = resolve(f, k);
        return parse(m, remoteId, role(f), true);
      } finally {
        f.close(false);
      }
    } catch (Exception e) {
      throw safe(e, false);
    }
  }

  Message resolve(jakarta.mail.Folder f, Key k) throws Exception {
    UIDFolder u = (UIDFolder) f;
    if (u.getUIDValidity() != k.validity())
      throw new ProviderException("UIDVALIDITY_CHANGED", false);
    Message m = u.getMessageByUID(k.uid());
    if (m == null) throw new ProviderException("NOT_FOUND", false);
    return m;
  }

  Mail parse(Message m, String id, String folder, boolean full) throws Exception {
    List<Address> from = MimeSupport.addresses(m.getFrom());
    StringBuilder text = new StringBuilder();
    List<Attachment> att = new ArrayList<>();
    if (full) MimeSupport.parse(m, text, att, id, 0);
    Date date = m.getReceivedDate();
    if (date == null) date = m.getSentDate();
    return new Mail(
        id,
        folder,
        from.isEmpty() ? "" : from.get(0).name(),
        from.isEmpty() ? "" : from.get(0).address(),
        MimeSupport.addresses(m.getRecipients(Message.RecipientType.TO)),
        MimeSupport.addresses(m.getRecipients(Message.RecipientType.CC)),
        m.getSubject() == null ? "" : m.getSubject(),
        "",
        date == null ? Instant.EPOCH : date.toInstant(),
        m.isSet(Flags.Flag.SEEN),
        m.isSet(Flags.Flag.FLAGGED),
        !att.isEmpty(),
        text.toString(),
        "",
        att);
  }

  public MutationResult mutate(Credentials c, String remoteId, String action, Boolean value) {
    Key k = key(remoteId);
    try (Store s = connect(c)) {
      jakarta.mail.Folder moveTarget =
          (action.equals("TRASH") || action.equals("ARCHIVE") || action.equals("RESTORE"))
              ? find(
                  s,
                  action.equals("TRASH") ? "TRASH" : action.equals("ARCHIVE") ? "ARCHIVE" : "INBOX")
              : null;
      boolean moveSupported =
          moveTarget == null
              || (((org.eclipse.angus.mail.imap.IMAPStore) s).hasCapability("MOVE")
                  && ((org.eclipse.angus.mail.imap.IMAPStore) s).hasCapability("UIDPLUS"));
      jakarta.mail.Folder f = s.getFolder(k.folder());
      f.open(jakarta.mail.Folder.READ_WRITE);
      try {
        Message m = resolve(f, k);
        switch (action) {
          case "SET_READ" -> m.setFlag(Flags.Flag.SEEN, Boolean.TRUE.equals(value));
          case "SET_STAR" -> m.setFlag(Flags.Flag.FLAGGED, Boolean.TRUE.equals(value));
          case "TRASH", "ARCHIVE", "RESTORE" -> {
            jakarta.mail.Folder target = moveTarget;
            if (!(f instanceof IMAPFolder im) || !moveSupported)
              throw new ProviderException("MOVE_NOT_SUPPORTED", false);
            org.eclipse.angus.mail.imap.AppendUID[] mapped =
                im.moveUIDMessages(new Message[] {m}, target);
            if (mapped == null
                || mapped.length != 1
                || mapped[0] == null
                || mapped[0].uid <= 0
                || mapped[0].uidvalidity <= 0)
              throw new ProviderException("MOVE_MAPPING_UNKNOWN", false);
            return new MutationResult(
                Base64.getUrlEncoder()
                        .withoutPadding()
                        .encodeToString(target.getFullName().getBytes(StandardCharsets.UTF_8))
                    + ":"
                    + mapped[0].uidvalidity
                    + ":"
                    + mapped[0].uid);
          }
          default -> throw new ProviderException("NOT_SUPPORTED", false);
        }
        return new MutationResult(remoteId);
      } finally {
        f.close(false);
      }
    } catch (Exception e) {
      throw safe(e, false);
    }
  }

  public Download attachment(Credentials c, String remoteId, String attachmentId) {
    Key k = key(remoteId);
    if (!attachmentId.startsWith(remoteId + "."))
      throw new ProviderException("INVALID_ATTACHMENT", false);
    try (Store s = connect(c)) {
      jakarta.mail.Folder f = s.getFolder(k.folder());
      f.open(jakarta.mail.Folder.READ_ONLY);
      try {
        Part part = resolve(f, k);
        String[] indexes = attachmentId.substring(remoteId.length() + 1).split("\\.");
        if (indexes.length > 20) throw new ProviderException("MIME_LIMIT", false);
        for (String index : indexes) {
          int i = Integer.parseInt(index);
          if (!part.isMimeType("multipart/*")) throw new ProviderException("NOT_FOUND", false);
          Multipart mp = (Multipart) part.getContent();
          if (i < 0 || i >= mp.getCount()) throw new ProviderException("NOT_FOUND", false);
          part = mp.getBodyPart(i);
        }
        byte[] bytes;
        try (java.io.InputStream in = part.getInputStream()) {
          bytes = in.readNBytes(10 * 1024 * 1024 + 1);
        }
        if (bytes.length > 10 * 1024 * 1024)
          throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
        return new Download(
            bytes,
            part.getContentType(),
            part.getFileName() == null ? "attachment" : part.getFileName());
      } finally {
        f.close(false);
      }
    } catch (Exception e) {
      throw safe(e, false);
    }
  }

  public SendResult send(Credentials c, Outgoing o) {
    boolean submitting = false;
    Transport t = null;
    try {
      MimeMessage m = MimeSupport.compose(c, o);
      Endpoint e = endpoint(c);
      t = session(e).getTransport("smtp");
      t.connect(e.smtp(), e.smtpPort(), c.email(), c.secret());
      submitting = true;
      t.sendMessage(m, m.getAllRecipients());
      return new SendResult("ACCEPTED", m.getMessageID());
    } catch (Exception e) {
      if (e instanceof SendFailedException sf
          && sf.getValidSentAddresses()
              == null) { // Explicit SMTP rejection is safe; loss of a final DATA reply is
        // ambiguous.
        Exception n = sf.getNextException();
        if (n instanceof org.eclipse.angus.mail.smtp.SMTPAddressFailedException)
          return throwFailure("RECIPIENT_REJECTED", false);
        if (e instanceof org.eclipse.angus.mail.smtp.SMTPSendFailedException se
            && se.getReturnCode() >= 400) return throwFailure("SMTP_REJECTED", false);
      }
      throw safe(e, submitting);
    } finally {
      if (t != null)
        try {
          t.close();
        } catch (Exception ignored) {
        }
    }
  }

  static SendResult throwFailure(String code, boolean ambiguous) {
    throw new ProviderException(code, ambiguous);
  }

  static ProviderException safe(Exception e, boolean submitted) {
    if (e instanceof ProviderException pe) return pe;
    return new ProviderException(
        e instanceof AuthenticationFailedException ? "AUTH_EXPIRED" : "PROVIDER_ERROR", submitted);
  }
}
