package com.itdong.mail;

import jakarta.annotation.PostConstruct;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import javax.crypto.Cipher;
import javax.crypto.spec.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class Security extends OncePerRequestFilter {
  final Store store;
  final boolean demo;
  final String username, password, key, bind, origin;
  final BCryptPasswordEncoder bcrypt = new BCryptPasswordEncoder(12);
  final SecureRandom random = new SecureRandom();
  final Map<String, Attempt> attempts = new ConcurrentHashMap<>();
  byte[] encryptionKey;

  record Attempt(long start, int count) {}

  Security(
      Store store,
      @Value("${mail.demo}") boolean demo,
      @Value("${mail.admin-username}") String username,
      @Value("${mail.admin-password}") String password,
      @Value("${mail.encryption-key}") String key,
      @Value("${server.address}") String bind,
      @Value("${mail.allowed-origin}") String origin) {
    this.store = store;
    this.demo = demo;
    this.username = username;
    this.password = password;
    this.key = key;
    this.bind = bind;
    this.origin = origin;
  }

  @PostConstruct
  void init() {
    if (demo && !"127.0.0.1".equals(bind))
      throw new IllegalStateException("Demo MUST bind 127.0.0.1");
    if (username.isBlank()
        || username.length() > 120
        || password.isBlank()
        || password.getBytes(StandardCharsets.UTF_8).length > 72
        || (!demo && password.length() < 16))
      throw new IllegalStateException(
          "Set MAIL_ADMIN_USERNAME and a unique MAIL_ADMIN_PASSWORD (16+ characters)");
    try {
      encryptionKey = Base64.getDecoder().decode(key);
    } catch (Exception e) {
      throw new IllegalStateException("MAIL_ENCRYPTION_KEY must be base64 of 32 random bytes");
    }
    if (encryptionKey.length != 32
        || (!demo && key.equals("ZGVtby1vbmx5LWRvLW5vdC11c2UtaW4tcHJvZC0xMjM=")))
      throw new IllegalStateException("Set a unique 32-byte MAIL_ENCRYPTION_KEY");
    store.write(
        () -> {
          if (store.db.queryForObject("SELECT COUNT(*) FROM owner_user", Integer.class) == 0)
            store.db.update(
                "INSERT INTO owner_user VALUES(1,?,?)", username, bcrypt.encode(password));
          if (!demo
              && bcrypt.matches(
                  "demo-local-only",
                  store.db.queryForObject(
                      "SELECT password_hash FROM owner_user WHERE id=1", String.class)))
            throw new IllegalStateException(
                "Refusing a demo owner database in production; use a separate database");
          for (var credential : store.db.queryForList("SELECT secret FROM mail_account"))
            decrypt((String) credential.get("secret"));
          return null;
        });
  }

  public static String hash(String v) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(v.getBytes(StandardCharsets.UTF_8)));
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  public String token() {
    byte[] b = new byte[32];
    random.nextBytes(b);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
  }

  public String encrypt(String clear) {
    try {
      byte[] iv = new byte[12];
      random.nextBytes(iv);
      Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
      c.init(
          Cipher.ENCRYPT_MODE,
          new SecretKeySpec(encryptionKey, "AES"),
          new GCMParameterSpec(128, iv));
      return Base64.getEncoder().encodeToString(iv)
          + "."
          + Base64.getEncoder().encodeToString(c.doFinal(clear.getBytes(StandardCharsets.UTF_8)));
    } catch (Exception e) {
      throw new IllegalStateException("Credential encryption failed");
    }
  }

  public String decrypt(String encoded) {
    try {
      String[] p = encoded.split("\\.");
      Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
      c.init(
          Cipher.DECRYPT_MODE,
          new SecretKeySpec(encryptionKey, "AES"),
          new GCMParameterSpec(128, Base64.getDecoder().decode(p[0])));
      return new String(c.doFinal(Base64.getDecoder().decode(p[1])), StandardCharsets.UTF_8);
    } catch (Exception e) {
      throw new IllegalStateException("Credential decryption failed; check encryption key");
    }
  }

  synchronized void passwordAttempt(String ip) {
    long now = System.currentTimeMillis();
    attempts.entrySet().removeIf(e -> now - e.getValue().start > 900_000);
    // Global bucket plus IP bucket prevents unbounded spoofed-IP entries and distributed guessing.
    for (String bucket : List.of("GLOBAL", ip)) {
      Attempt a = attempts.get(bucket);
      if (a != null && a.count >= (bucket.equals("GLOBAL") ? 50 : 10))
        throw new ApiError(429, "RATE_LIMITED", "Too many login attempts; retry in 15 minutes");
      attempts.put(bucket, new Attempt(a == null ? now : a.start, a == null ? 1 : a.count + 1));
    }
  }

  void confirmOwnerPassword(String supplied, String ip) {
    passwordAttempt(ip);
    String hash = store.db.queryForObject("SELECT password_hash FROM owner_user WHERE id=1", String.class);
    if (supplied.isBlank() || supplied.getBytes(StandardCharsets.UTF_8).length > 72
        || !bcrypt.matches(supplied, hash))
      throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid username or password");
  }

  public Map<String, Object> login(Map<String, Object> body, String ip) {
    confirmOwnerPassword(Json.string(body, "password"), ip);
    var owner = store.one("SELECT * FROM owner_user WHERE id=1");
    if (!Json.string(body, "username").equals(owner.get("username")))
      throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid username or password");
    var session = issueOwnerSession();
    session.put("demoMode", demo);
    return session;
  }

  /** Shared eight-hour session issuance for password and verified WebAuthn authentication. */
  Map<String, Object> issueOwnerSession() {
    return store.write(() -> {
      String token = token();
      long now = System.currentTimeMillis(), expires = now + 8 * 3600_000L;
      store.db.update("DELETE FROM access_token WHERE expires_at<=?", now);
      store.db.update("INSERT INTO access_token VALUES(?,?)", hash(token), expires);
      return Json.map("accessToken", token, "expiresAt", Instant.ofEpochMilli(expires).toString());
    });
  }

  void logout(String tokenHash) {
    store.write(() -> {
      store.db.update("UPDATE device_pairing SET state='EXPIRED',secret_hash=NULL WHERE creator_hash=? AND state IN ('CREATED','CLAIMED','APPROVED')", tokenHash);
      store.db.update("UPDATE paired_device SET revoked=TRUE WHERE id IN (SELECT device_id FROM device_access_token WHERE token_hash=?)", tokenHash);
      store.db.update("DELETE FROM passkey_request WHERE creator_hash=?", tokenHash);
      store.db.update("DELETE FROM access_token WHERE token_hash=?", tokenHash);
      return null;
    });
  }

  /**
   * Use exactly one path interpretation for authorization and handler dispatch. All current API
   * identifiers and bundled assets use ASCII unreserved segments. Query values (including OAuth
   * codes and searches) are outside this check. Reject alternate spellings rather than duplicating
   * Tomcat/Spring decoding, matrix-parameter removal or dot-segment normalization.
   */
  static String canonicalRequestPath(HttpServletRequest request) {
    String raw = request.getRequestURI();
    if (raw == null || raw.isEmpty() || raw.charAt(0) != '/') return null;
    int segmentStart = 1;
    for (int i = 1; i <= raw.length(); i++) {
      if (i == raw.length() || raw.charAt(i) == '/') {
        String segment = raw.substring(segmentStart, i);
        if ((segment.isEmpty() && raw.length() != 1)
            || segment.equals(".") || segment.equals("..")) return null;
        segmentStart = i + 1;
      } else {
        char c = raw.charAt(i);
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_' || c == '~' || c == '-' || c == '.'))
          return null;
      }
    }
    String context = Objects.toString(request.getContextPath(), "");
    String servletPath = Objects.toString(request.getServletPath(), "");
    String pathInfo = request.getPathInfo();
    String routed = servletPath + Objects.toString(pathInfo, "");
    // Container routing is already resolved here. Fail closed on any disagreement with the raw
    // request target, including disagreement introduced by a future container policy change.
    if (!raw.equals(context + routed)) return null;
    // Prefix-mapped dispatchers match handlers against pathInfo; the default root dispatcher uses
    // servletPath. Never let a servlet mapping prefix hide an API path from authorization.
    return pathInfo == null ? servletPath : pathInfo;
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest req, HttpServletResponse res, FilterChain chain)
      throws ServletException, IOException {
    String requestId = Store.id();
    req.setAttribute("requestId", requestId);
    res.setHeader("X-Request-Id", requestId);
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    String path = canonicalRequestPath(req);
    if (path == null) {
      res.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
      res.setStatus(HttpServletResponse.SC_BAD_REQUEST);
      res.setContentType("application/json");
      res.getWriter().write(Json.encode(Json.map("error", Json.map(
          "code", "INVALID_PATH", "message", "Use the canonical request path", "requestId", requestId))));
      return;
    }
    // APK resources are deliberately outside public static assets. Expose only the two
    // explicit read routes, never an unauthenticated directory/prefix handler.
    if ((path.equals("/downloads/android") || path.startsWith("/downloads/android/"))
        && !(Set.of("/downloads/android/manifest.json", "/downloads/android/app.apk").contains(path)
            && Set.of("GET", "HEAD").contains(req.getMethod()))) {
      res.setStatus(404);
      return;
    }
    if (path.startsWith("/api/"))
      res.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
    else
      res.setHeader(
          "Content-Security-Policy", "frame-ancestors 'none'; object-src 'none'; base-uri 'self'");
    String reqOrigin = req.getHeader("Origin");
    if (origin.equals(reqOrigin)) {
      res.setHeader("Access-Control-Allow-Origin", origin);
      res.setHeader("Vary", "Origin");
      res.setHeader("Access-Control-Allow-Headers", "Authorization,Content-Type,Idempotency-Key");
      res.setHeader("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
    }
    if (req.getMethod().equals("OPTIONS")) {
      res.setStatus(origin.equals(reqOrigin) ? 204 : 403);
      return;
    }
    boolean publicPath =
        (path.equals("/api/v1/health") && Set.of("GET", "HEAD").contains(req.getMethod()))
            || (path.equals("/api/v1/auth/login") && req.getMethod().equals("POST"))
            || (Set.of("/api/v1/auth/device-pairings/claim", "/api/v1/auth/device-pairings/poll",
                "/api/v1/auth/device-pairings/redeem").contains(path) && req.getMethod().equals("POST"))
            || (path.equals("/api/v1/auth/passkeys/capabilities") && req.getMethod().equals("GET"))
            || (Set.of("/api/v1/auth/passkeys/authentication/options", "/api/v1/auth/passkeys/authentication/verify")
                .contains(path) && req.getMethod().equals("POST"))
            || (path.matches("/api/v1/oauth/(GMAIL|OUTLOOK|EXCHANGE)/callback")
                && req.getMethod().equals("GET"));
    if (path.startsWith("/api/") && !publicPath) {
      String h = req.getHeader("Authorization");
      boolean valid =
          h != null
              && h.startsWith("Bearer ")
              && store.db.queryForObject(
                      "SELECT COUNT(*) FROM access_token a WHERE a.token_hash=? AND a.expires_at>? "
                          + "AND NOT EXISTS (SELECT 1 FROM device_access_token t JOIN paired_device d ON d.id=t.device_id "
                          + "WHERE t.token_hash=a.token_hash AND (d.revoked=TRUE OR d.expires_at<=?))",
                      Integer.class,
                      hash(h.substring(7)),
                      System.currentTimeMillis(),
                      System.currentTimeMillis())
                  > 0;
      if (!valid) {
        res.setStatus(401);
        res.setContentType("application/json");
        res.getWriter()
            .write(
                Json.encode(
                    Json.map(
                        "error",
                        Json.map(
                            "code",
                            "UNAUTHORIZED",
                            "message",
                            "Sign in required",
                            "requestId",
                            requestId))));
        return;
      }
      String tokenHash = hash(h.substring(7));
      req.setAttribute("tokenHash", tokenHash);
      store.db.update("UPDATE paired_device SET last_seen_at=? WHERE revoked=FALSE AND last_seen_at<? "
          + "AND id IN (SELECT device_id FROM device_access_token WHERE token_hash=?)",
          System.currentTimeMillis(), System.currentTimeMillis() - 60_000, tokenHash);
    }
    if ((path.startsWith("/api/v1/auth/device-pairings") || path.startsWith("/api/v1/auth/passkeys")) && req.getQueryString() != null) {
      res.setStatus(400);
      res.setContentType("application/json");
      res.getWriter().write(Json.encode(Json.map("error", Json.map("code", "INVALID_REQUEST",
          "message", "Authentication inputs must use JSON bodies", "requestId", requestId))));
      return;
    }
    if (path.startsWith("/api/")
        && req.getContentType() != null
        && req.getContentType().toLowerCase(Locale.ROOT).contains("json")) {
      long max = path.startsWith("/api/v1/auth/passkeys/") ? 65_536 : path.startsWith("/api/v1/auth/") ? 4096 : 4 * 1024 * 1024;
      if (req.getContentLengthLong() > max) {
        res.setStatus(413);
        res.setContentType("application/json");
        res.getWriter()
            .write(
                Json.encode(
                    Json.map(
                        "error",
                        Json.map(
                            "code",
                            "REQUEST_TOO_LARGE",
                            "message",
                            "Request body exceeds limit",
                            "requestId",
                            requestId))));
        return;
      }
      HttpServletRequest wrapped =
          new HttpServletRequestWrapper(req) {
            @Override
            public ServletInputStream getInputStream() throws IOException {
              var input = super.getInputStream();
              return new ServletInputStream() {
                long read = 0;

                public int read() throws IOException {
                  int b = input.read();
                  if (b >= 0 && ++read > max) throw new IOException("Request body exceeds limit");
                  return b;
                }

                public boolean isFinished() {
                  return input.isFinished();
                }

                public boolean isReady() {
                  return input.isReady();
                }

                public void setReadListener(ReadListener listener) {
                  input.setReadListener(listener);
                }
              };
            }
          };
      chain.doFilter(wrapped, res);
      return;
    }
    chain.doFilter(req, res);
  }
}
