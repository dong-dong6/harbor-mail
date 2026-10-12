package com.itdong.mail;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/** Serves only exact, build-indexed public assets, after the normal security filter. */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class PublicWebAssets extends OncePerRequestFilter {
  private final Map<String, Object> assets;

  PublicWebAssets(
      @Value("${mail.web-assets-manifest:META-INF/public-web-assets.json}") String manifest)
      throws IOException {
    var resource = new ClassPathResource(manifest);
    if (!resource.exists()) {
      // Backend-only builds retain the default no-store policy.
      assets = Map.of();
    } else {
      try (var input = resource.getInputStream()) {
        assets = Map.copyOf(Json.decode(new String(input.readAllBytes(), StandardCharsets.UTF_8)));
      }
    }
  }

  @Override
  protected void doFilterInternal(
      HttpServletRequest request, HttpServletResponse response, FilterChain chain)
      throws ServletException, IOException {
    String path = request.getRequestURI();
    if (path.equals("/")) path = "/index.html";
    Object indexed = assets.get(path);
    if (!(request.getMethod().equals("GET") || request.getMethod().equals("HEAD"))
        || path.startsWith("/api/")
        || path.equals("/oauth-complete.html")
        || !(indexed instanceof Map<?, ?> asset)) {
      chain.doFilter(request, response);
      return;
    }
    // No interpretation of encoded paths or arbitrary user-controlled paths.
    if (path.contains("%") || path.contains("..") || path.contains("\\")) {
      chain.doFilter(request, response);
      return;
    }
    String accepted = request.getHeader("Accept-Encoding");
    double gzipQuality = quality(accepted, "gzip");
    double identityQuality = quality(accepted, "identity");
    boolean gzip = asset.containsKey("gzipEtag") && gzipQuality > 0 && gzipQuality >= identityQuality;
    if (!gzip && identityQuality == 0) {
      response.setStatus(HttpServletResponse.SC_NOT_ACCEPTABLE);
      response.addHeader("Vary", "Accept-Encoding");
      return;
    }
    var resource = new ClassPathResource("static" + path + (gzip ? ".gz" : ""));
    if (!resource.exists()) {
      chain.doFilter(request, response);
      return;
    }
    // Open before changing policy so a packaging/I/O failure remains no-store.
    try (var input = resource.getInputStream()) {
      String etag = (String) asset.get(gzip ? "gzipEtag" : "etag");
      // Stable Flutter URLs are not content-hashed: EVERY reuse must revalidate.
      response.setHeader("Cache-Control", "public, no-cache, must-revalidate");
      // Security varies ACAO with Origin. Vary even when Origin is absent or denied.
      response.addHeader("Vary", response.containsHeader("Access-Control-Allow-Origin")
          ? "Accept-Encoding" : "Accept-Encoding, Origin");
      response.setHeader("ETag", etag);
      response.setContentType((String) asset.get("contentType"));
      if (gzip) response.setHeader("Content-Encoding", "gzip");
      if (matches(request.getHeader("If-None-Match"), etag)) {
        response.setStatus(HttpServletResponse.SC_NOT_MODIFIED);
        return;
      }
      response.setContentLengthLong(((Number) asset.get(gzip ? "gzipLength" : "length")).longValue());
      if (request.getMethod().equals("GET")) input.transferTo(response.getOutputStream());
    }
  }

  static boolean matches(String conditional, String etag) {
    if (conditional == null) return false;
    for (String value : conditional.split(",")) {
      value = value.trim();
      if (value.startsWith("W/")) value = value.substring(2);
      if (value.equals("*") || value.equals(etag)) return true;
    }
    return false;
  }

  static double quality(String accepted, String encoding) {
    if (accepted == null || accepted.isBlank()) return encoding.equals("identity") ? 1 : 0;
    Double wildcard = null;
    for (String item : accepted.split(",")) {
      String[] parts = item.trim().toLowerCase(Locale.ROOT).split(";");
      double quality = 1;
      for (int i = 1; i < parts.length; i++) {
        String parameter = parts[i].trim();
        if (parameter.startsWith("q=")) {
          try {
            quality = Double.parseDouble(parameter.substring(2));
            if (!Double.isFinite(quality) || quality < 0 || quality > 1) quality = 0;
          } catch (NumberFormatException ignored) {
            quality = 0;
          }
        }
      }
      if (parts[0].equals(encoding)) return quality;
      if (parts[0].equals("*")) wildcard = quality;
    }
    if (encoding.equals("identity")) return wildcard != null && wildcard == 0 ? 0 : 1;
    return wildcard == null ? 0 : wildcard;
  }
}
