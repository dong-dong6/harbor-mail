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
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
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

  public synchronized Map<String, Object> login(Map<String, Object> body, String ip) {
    long now = System.currentTimeMillis();
    attempts.entrySet().removeIf(e -> now - e.getValue().start > 900_000);
    // Global bucket plus IP bucket prevents unbounded spoofed-IP entries and distributed guessing.
    for (String bucket : List.of("GLOBAL", ip)) {
      Attempt a = attempts.get(bucket);
      if (a != null && a.count >= (bucket.equals("GLOBAL") ? 50 : 10))
        throw new ApiError(429, "RATE_LIMITED", "Too many login attempts; retry in 15 minutes");
      attempts.put(bucket, new Attempt(a == null ? now : a.start, a == null ? 1 : a.count + 1));
    }
    var owner = store.one("SELECT * FROM owner_user WHERE id=1");
    String supplied = Json.string(body, "password");
    boolean valid =
        supplied.getBytes(StandardCharsets.UTF_8).length <= 72
            && bcrypt.matches(supplied, (String) owner.get("password_hash"));
    if (!valid || !Json.string(body, "username").equals(owner.get("username")))
      throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid username or password");
    String token = token();
    long expires = now + 8 * 3600_000L;
    store.db.update("DELETE FROM access_token WHERE expires_at<?", now);
    store.db.update("INSERT INTO access_token VALUES(?,?)", hash(token), expires);
    return Json.map(
        "accessToken",
        token,
        "expiresAt",
        Instant.ofEpochMilli(expires).toString(),
        "demoMode",
        demo);
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
    if (req.getRequestURI().startsWith("/api/"))
      res.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
    else
      res.setHeader(
          "Content-Security-Policy", "frame-ancestors 'none'; object-src 'none'; base-uri 'self'");
    String reqOrigin = req.getHeader("Origin");
    if (origin.equals(reqOrigin)) {
      res.setHeader("Access-Control-Allow-Origin", origin);
      res.setHeader("Vary", "Origin");
      res.setHeader("Access-Control-Allow-Headers", "Authorization,Content-Type,Idempotency-Key");
      res.setHeader("Access-Control-Allow-Methods", "GET,POST,PATCH,DELETE,OPTIONS");
    }
    if (req.getMethod().equals("OPTIONS")) {
      res.setStatus(origin.equals(reqOrigin) ? 204 : 403);
      return;
    }
    String path = req.getRequestURI();
    boolean publicPath =
        path.equals("/api/v1/health")
            || path.equals("/api/v1/auth/login")
            || (path.matches("/api/v1/oauth/(GMAIL|OUTLOOK|EXCHANGE)/callback")
                && req.getMethod().equals("GET"));
    if (path.startsWith("/api/") && !publicPath) {
      String h = req.getHeader("Authorization");
      boolean valid =
          h != null
              && h.startsWith("Bearer ")
              && store.db.queryForObject(
                      "SELECT COUNT(*) FROM access_token WHERE token_hash=? AND expires_at>?",
                      Integer.class,
                      hash(h.substring(7)),
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
    }
    if (path.startsWith("/api/")
        && req.getContentType() != null
        && req.getContentType().toLowerCase(Locale.ROOT).contains("json")) {
      long max = path.equals("/api/v1/auth/login") ? 4096 : 4 * 1024 * 1024;
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
