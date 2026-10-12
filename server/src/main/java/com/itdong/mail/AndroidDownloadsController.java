package com.itdong.mail;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Public same-origin download endpoints; immutable APK stays outside static/. */
@RestController
public final class AndroidDownloadsController {
  private final AndroidDownloads downloads;

  public AndroidDownloadsController(AndroidDownloads downloads) { this.downloads = downloads; }

  @GetMapping(AndroidDownloads.MANIFEST_PATH)
  void manifest(HttpServletRequest request, HttpServletResponse response) throws IOException {
    if (!canonical(request, response, AndroidDownloads.MANIFEST_PATH)) return;
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setContentType("application/json");
    response.setCharacterEncoding("UTF-8");
    if (!request.getMethod().equals("HEAD")) response.getWriter().write(Json.encode(downloads.manifest()));
  }

  @GetMapping(AndroidDownloads.APK_PATH)
  void apk(HttpServletRequest request, HttpServletResponse response) throws IOException {
    if (!canonical(request, response, AndroidDownloads.APK_PATH)) return;
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    if (!downloads.available()) {
      response.setStatus(HttpServletResponse.SC_NOT_FOUND);
      response.setContentType("application/json");
      if (!request.getMethod().equals("HEAD"))
        response.getWriter().write("{\"error\":{\"code\":\"APK_UNAVAILABLE\",\"message\":\"No verified Android build is included\"}}");
      return;
    }
    try (var input = downloads.apk().getInputStream()) {
      response.setContentType("application/vnd.android.package-archive");
      response.setHeader("Content-Disposition", "attachment; filename=\"harbor-mail-dev.apk\"");
      // A stable URL must revalidate on every reuse, even between releases.
      response.setHeader("Cache-Control", "public, no-cache, must-revalidate");
      response.setHeader("ETag", downloads.etag());
      response.addHeader("Vary", "Origin");
      if (PublicWebAssets.matches(request.getHeader("If-None-Match"), downloads.etag())) {
        response.setStatus(HttpServletResponse.SC_NOT_MODIFIED);
        return;
      }
      response.setContentLengthLong(downloads.size());
      if (!request.getMethod().equals("HEAD")) input.transferTo(response.getOutputStream());
    }
  }

  private boolean canonical(HttpServletRequest request, HttpServletResponse response, String path) {
    if (!(request.getMethod().equals("GET") || request.getMethod().equals("HEAD"))
        || !request.getRequestURI().equals(path)) {
      response.setStatus(HttpServletResponse.SC_NOT_FOUND);
      return false;
    }
    return true;
  }
}
