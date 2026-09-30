package com.itdong.mail.provider;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;

public final class DefaultProviderGateway implements ProviderGateway {
  private final ProviderGateway gmail, graph, imap;

  public DefaultProviderGateway(ObjectMapper mapper) {
    gmail = new GmailAdapter(mapper, "https://gmail.googleapis.com/gmail/v1/users/me");
    graph = new GraphAdapter(mapper, "https://graph.microsoft.com/v1.0/me");
    imap = new ImapAdapter();
  }

  ProviderGateway adapter(Credentials c) {
    return switch (c.provider()) {
      case "GMAIL" -> gmail;
      case "OUTLOOK", "EXCHANGE" -> graph;
      case "QQ", "NETEASE" -> imap;
      default -> throw new ProviderException("NOT_SUPPORTED", false);
    };
  }

  public List<Folder> folders(Credentials c) {
    return adapter(c).folders(c);
  }

  public SyncPage sync(Credentials c, String f, String cursor, int limit) {
    return adapter(c).sync(c, f, cursor, limit);
  }

  public Mail body(Credentials c, String id) {
    return adapter(c).body(c, id);
  }

  public MutationResult mutate(Credentials c, String id, String action, Boolean value) {
    return adapter(c).mutate(c, id, action, value);
  }

  public Download attachment(Credentials c, String id, String attachmentId) {
    return adapter(c).attachment(c, id, attachmentId);
  }

  public SendResult send(Credentials c, Outgoing o) {
    return adapter(c).send(c, o);
  }
}
