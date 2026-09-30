package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;
import static org.junit.jupiter.api.Assertions.*;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.Test;

class ProviderMailTest {
  static class FakeSmtp implements AutoCloseable {
    final ServerSocket server;
    final ExecutorService executor = Executors.newSingleThreadExecutor();
    final List<String> commands = Collections.synchronizedList(new ArrayList<>());
    final Future<?> work;

    FakeSmtp(boolean rejectRecipient, boolean loseDataReply) throws Exception {
      server = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
      work =
          executor.submit(
              () -> {
                try (Socket s = server.accept()) {
                  s.setSoTimeout(5000);
                  BufferedReader r =
                      new BufferedReader(
                          new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                  PrintWriter w = new PrintWriter(s.getOutputStream(), true);
                  w.print("220 local fixture\r\n");
                  w.flush();
                  boolean data = false;
                  for (String line; (line = r.readLine()) != null; ) {
                    commands.add(line);
                    if (data) {
                      if (line.equals(".")) {
                        if (loseDataReply) return;
                        w.print("250 accepted\r\n");
                        data = false;
                      }
                    } else if (line.startsWith("EHLO")) w.print("250-local\r\n250 AUTH PLAIN\r\n");
                    else if (line.startsWith("AUTH")) w.print("235 authenticated\r\n");
                    else if (line.startsWith("MAIL")) w.print("250 sender\r\n");
                    else if (line.startsWith("RCPT"))
                      w.print(rejectRecipient ? "550 rejected\r\n" : "250 recipient\r\n");
                    else if (line.equals("DATA")) {
                      w.print("354 continue\r\n");
                      data = true;
                    } else if (line.equals("QUIT")) {
                      w.print("221 bye\r\n");
                      w.flush();
                      break;
                    } else w.print("250 okay\r\n");
                    w.flush();
                  }
                } catch (Exception e) {
                  throw new RuntimeException(e);
                }
              });
    }

    int port() {
      return server.getLocalPort();
    }

    public void close() throws Exception {
      server.close();
      executor.shutdownNow();
    }
  }

  Credentials credentials() {
    return new Credentials("QQ", "owner@example.test", null, "fixture-secret");
  }

  Outgoing message() {
    return new Outgoing(
        List.of(new Address("", "to@example.test")),
        List.of(),
        List.of(),
        "fixture",
        "hello",
        List.of(),
        "<fixture@example.test>");
  }

  ImapAdapter adapter(int port) {
    return new ImapAdapter(new ImapAdapter.Endpoint("127.0.0.1", 1, "127.0.0.1", port, false));
  }

  @Test
  void smtpAcceptedAfterFinalDataResponse() throws Exception {
    try (FakeSmtp s = new FakeSmtp(false, false)) {
      assertEquals("ACCEPTED", adapter(s.port()).send(credentials(), message()).status());
      assertTrue(s.commands.contains("DATA"));
    }
  }

  @Test
  void smtpRecipientRejectionIsNotAmbiguous() throws Exception {
    try (FakeSmtp s = new FakeSmtp(true, false)) {
      ProviderException e =
          assertThrows(
              ProviderException.class, () -> adapter(s.port()).send(credentials(), message()));
      assertFalse(e.ambiguous());
      assertFalse(s.commands.contains("DATA"));
    }
  }

  @Test
  void smtpMissingFinalDataReplyIsUnknown() throws Exception {
    try (FakeSmtp s = new FakeSmtp(false, true)) {
      ProviderException e =
          assertThrows(
              ProviderException.class, () -> adapter(s.port()).send(credentials(), message()));
      assertTrue(e.ambiguous());
      assertTrue(s.commands.contains("DATA"));
    }
  }

  @Test
  void imapUsesUidValidityAndRejectsMalformedIds() {
    String folder =
        Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString("INBOX".getBytes(StandardCharsets.UTF_8));
    ImapAdapter.Key k = ImapAdapter.key(folder + ":981:42");
    assertEquals(981, k.validity());
    assertEquals(42, k.uid());
    assertEquals(
        "INVALID_MESSAGE_ID",
        assertThrows(ProviderException.class, () -> ImapAdapter.key("42")).code());
  }

  @Test
  void productionHostsAreFixedTls() {
    ImapAdapter.Endpoint e = new ImapAdapter().endpoint(credentials());
    assertEquals("imap.qq.com", e.imap());
    assertEquals(993, e.imapPort());
    assertEquals("smtp.qq.com", e.smtp());
    assertTrue(e.tls());
    assertThrows(
        IllegalArgumentException.class,
        () -> new ImapAdapter(new ImapAdapter.Endpoint("evil.test", 993, "evil.test", 465, true)));
  }

  @Test
  void imapUidValidityMismatchUsesLocalProtocolFixture() throws Exception {
    try (ServerSocket ss = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      ExecutorService ex = Executors.newSingleThreadExecutor();
      Future<?> f =
          ex.submit(
              () -> {
                try (Socket s = ss.accept()) {
                  s.setSoTimeout(5000);
                  BufferedReader r =
                      new BufferedReader(
                          new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                  PrintWriter w = new PrintWriter(s.getOutputStream(), true);
                  w.print("* OK local IMAP fixture\r\n");
                  w.flush();
                  for (String line; (line = r.readLine()) != null; ) {
                    String tag = line.split(" ")[0];
                    String cmd = line.substring(tag.length() + 1).toUpperCase(Locale.ROOT);
                    if (cmd.startsWith("CAPABILITY"))
                      w.print("* CAPABILITY IMAP4rev1\r\n" + tag + " OK capabilities\r\n");
                    else if (cmd.startsWith("LOGIN")) w.print(tag + " OK login\r\n");
                    else if (cmd.startsWith("EXAMINE") || cmd.startsWith("SELECT"))
                      w.print(
                          "* 0 EXISTS\r\n"
                              + "* 0 RECENT\r\n"
                              + "* OK [UIDVALIDITY 999] current\r\n"
                              + "* FLAGS (\\Seen \\Flagged)\r\n"
                              + tag
                              + " OK [READ-ONLY] selected\r\n");
                    else if (cmd.startsWith("LOGOUT")) {
                      w.print("* BYE bye\r\n" + tag + " OK logout\r\n");
                      w.flush();
                      break;
                    } else w.print(tag + " OK complete\r\n");
                    w.flush();
                  }
                } catch (Exception e) {
                  throw new RuntimeException(e);
                }
              });
      try {
        ImapAdapter a =
            new ImapAdapter(
                new ImapAdapter.Endpoint("127.0.0.1", ss.getLocalPort(), "127.0.0.1", 1, false));
        ProviderException e =
            assertThrows(ProviderException.class, () -> a.body(credentials(), "SU5CT1g:123:5"));
        assertEquals("UIDVALIDITY_CHANGED", e.code());
        f.get(5, TimeUnit.SECONDS);
      } finally {
        ex.shutdownNow();
      }
    }
  }

  @Test
  void imapFlagMutationUsesResolvedUidWithoutExpunge() throws Exception {
    List<String> commands = Collections.synchronizedList(new ArrayList<>());
    try (ServerSocket ss = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      ExecutorService ex = Executors.newSingleThreadExecutor();
      Future<?> f =
          ex.submit(
              () -> {
                try (Socket sock = ss.accept()) {
                  sock.setSoTimeout(5000);
                  BufferedReader r =
                      new BufferedReader(
                          new InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8));
                  PrintWriter w = new PrintWriter(sock.getOutputStream(), true);
                  w.print("* OK local IMAP fixture\r\n");
                  w.flush();
                  for (String line; (line = r.readLine()) != null; ) {
                    commands.add(line);
                    String tag = line.split(" ")[0];
                    String cmd = line.substring(tag.length() + 1).toUpperCase(Locale.ROOT);
                    if (cmd.startsWith("CAPABILITY"))
                      w.print("* CAPABILITY IMAP4rev1 UNSELECT\r\n" + tag + " OK capabilities\r\n");
                    else if (cmd.startsWith("LOGIN")) w.print(tag + " OK login\r\n");
                    else if (cmd.startsWith("SELECT"))
                      w.print(
                          "* 1 EXISTS\r\n"
                              + "* 0 RECENT\r\n"
                              + "* OK [UIDVALIDITY 123] current\r\n"
                              + "* FLAGS (\\Seen \\Flagged)\r\n"
                              + tag
                              + " OK [READ-WRITE] selected\r\n");
                    else if (cmd.startsWith("UID FETCH"))
                      w.print("* 1 FETCH (UID 5)\r\n" + tag + " OK fetched\r\n");
                    else if (cmd.startsWith("LOGOUT")) {
                      w.print("* BYE bye\r\n" + tag + " OK logout\r\n");
                      w.flush();
                      break;
                    } else w.print(tag + " OK complete\r\n");
                    w.flush();
                  }
                } catch (Exception e) {
                  throw new RuntimeException(e);
                }
              });
      try {
        ImapAdapter a =
            new ImapAdapter(
                new ImapAdapter.Endpoint("127.0.0.1", ss.getLocalPort(), "127.0.0.1", 1, false));
        a.mutate(credentials(), "SU5CT1g:123:5", "SET_READ", true);
        f.get(5, TimeUnit.SECONDS);
        assertTrue(commands.stream().anyMatch(v -> v.contains("UID FETCH 5")));
        assertTrue(commands.stream().anyMatch(v -> v.contains("STORE") && v.contains("\\Seen")));
        assertFalse(commands.stream().anyMatch(v -> v.contains("EXPUNGE")));
      } finally {
        ex.shutdownNow();
      }
    }
  }

  @Test
  void smtpBccUsesEnvelopeButIsAbsentFromData() throws Exception {
    try (FakeSmtp s = new FakeSmtp(false, false)) {
      Outgoing o =
          new Outgoing(
              List.of(new Address("", "to@example.test")),
              List.of(),
              List.of(new Address("", "hidden@example.test")),
              "fixture",
              "hello",
              List.of(),
              "<fixture@example.test>");
      assertEquals("ACCEPTED", adapter(s.port()).send(credentials(), o).status());
      assertTrue(
          s.commands.stream()
              .anyMatch(v -> v.startsWith("RCPT") && v.contains("hidden@example.test")));
      int data = s.commands.indexOf("DATA");
      assertTrue(data >= 0);
      assertFalse(
          s.commands.subList(data + 1, s.commands.size()).stream()
              .anyMatch(v -> v.toLowerCase(Locale.ROOT).startsWith("bcc:")));
    }
  }

  @Test
  void imapMoveReturnsDestinationUidLocator() throws Exception {
    List<String> commands = Collections.synchronizedList(new ArrayList<>());
    try (ServerSocket ss = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      ExecutorService ex = Executors.newSingleThreadExecutor();
      Future<?> f =
          ex.submit(
              () -> {
                try (Socket sock = ss.accept()) {
                  sock.setSoTimeout(5000);
                  BufferedReader r =
                      new BufferedReader(
                          new InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8));
                  PrintWriter w = new PrintWriter(sock.getOutputStream(), true);
                  w.print("* OK local IMAP fixture\r\n");
                  w.flush();
                  for (String line; (line = r.readLine()) != null; ) {
                    commands.add(line);
                    String tag = line.split(" ")[0];
                    String cmd = line.substring(tag.length() + 1).toUpperCase(Locale.ROOT);
                    if (cmd.startsWith("CAPABILITY"))
                      w.print(
                          "* CAPABILITY IMAP4rev1 UNSELECT MOVE UIDPLUS\r\n"
                              + tag
                              + " OK capabilities\r\n");
                    else if (cmd.startsWith("LOGIN")) w.print(tag + " OK login\r\n");
                    else if (cmd.startsWith("SELECT"))
                      w.print(
                          "* 1 EXISTS\r\n"
                              + "* 0 RECENT\r\n"
                              + "* OK [UIDVALIDITY 123] current\r\n"
                              + "* FLAGS (\\Seen \\Flagged)\r\n"
                              + tag
                              + " OK [READ-WRITE] selected\r\n");
                    else if (cmd.startsWith("UID FETCH"))
                      w.print("* 1 FETCH (UID 5)\r\n" + tag + " OK fetched\r\n");
                    else if (cmd.startsWith("LIST"))
                      w.print(
                          "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"\r\n"
                              + tag
                              + " OK list\r\n");
                    else if (cmd.contains("MOVE"))
                      w.print(tag + " OK [COPYUID 456 5 77] moved\r\n");
                    else if (cmd.startsWith("LOGOUT")) {
                      w.print("* BYE bye\r\n" + tag + " OK logout\r\n");
                      w.flush();
                      break;
                    } else w.print(tag + " OK complete\r\n");
                    w.flush();
                  }
                } catch (Exception e) {
                  throw new RuntimeException(e);
                }
              });
      try {
        ImapAdapter a =
            new ImapAdapter(
                new ImapAdapter.Endpoint("127.0.0.1", ss.getLocalPort(), "127.0.0.1", 1, false));
        MutationResult result = a.mutate(credentials(), "SU5CT1g:123:5", "TRASH", null);
        assertEquals("VHJhc2g:456:77", result.remoteId());
        f.get(5, TimeUnit.SECONDS);
        assertTrue(commands.stream().anyMatch(v -> v.contains("UID FETCH 5")));
        assertTrue(commands.stream().anyMatch(v -> v.contains("MOVE")));
        assertFalse(commands.stream().anyMatch(v -> v.contains("EXPUNGE")));
      } finally {
        ex.shutdownNow();
      }
    }
  }
}
