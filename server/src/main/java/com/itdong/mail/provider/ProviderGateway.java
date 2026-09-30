package com.itdong.mail.provider;

import java.time.Instant;
import java.util.List;

/** Provider-only DTOs: credentials must never be serialized by HTTP controllers. */
public interface ProviderGateway {
  record Credentials(String provider, String email, String accessToken, String secret) {
    @Override
    public String toString() {
      return "Credentials[REDACTED]";
    }
  }

  record Address(String name, String address) {}

  record Folder(String id, String name, String role, int unreadCount) {}

  record Attachment(String id, String fileName, String contentType, long size) {}

  record Mail(
      String remoteId,
      String folder,
      String fromName,
      String fromAddress,
      List<Address> to,
      List<Address> cc,
      String subject,
      String snippet,
      Instant receivedAt,
      boolean isRead,
      boolean isStarred,
      boolean hasAttachments,
      String bodyText,
      String bodyHtml,
      List<Attachment> attachments) {}

  record SyncPage(List<Mail> items, String nextCursor, boolean hasMore, String coverage) {}

  record Upload(String fileName, String contentType, byte[] bytes) {}

  record Outgoing(
      List<Address> to,
      List<Address> cc,
      List<Address> bcc,
      String subject,
      String bodyText,
      List<Upload> attachments,
      String messageId) {}

  record MutationResult(String remoteId) {}

  record Download(byte[] bytes, String contentType, String fileName) {}

  record SendResult(String status, String remoteId) {}

  List<Folder> folders(Credentials credentials);

  SyncPage sync(Credentials credentials, String folder, String cursor, int limit);

  Mail body(Credentials credentials, String remoteId);

  MutationResult mutate(Credentials credentials, String remoteId, String action, Boolean value);

  Download attachment(Credentials credentials, String remoteId, String attachmentId);

  SendResult send(Credentials credentials, Outgoing message);
}
