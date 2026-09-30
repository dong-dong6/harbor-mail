package com.itdong.mail.provider;

import com.fasterxml.jackson.databind.*;
import java.io.*;
import java.net.*;
import java.net.http.*;
import java.time.Duration;
import java.util.*;

final class HttpTransport {
  final ObjectMapper json;
  final HttpClient client;

  HttpTransport(ObjectMapper json) {
    this.json = json;
    this.client =
        HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();
  }

  JsonNode request(
      String method,
      URI uri,
      String token,
      Object data,
      boolean submission,
      Map<String, String> extra) {
    try {
      HttpRequest.Builder b =
          HttpRequest.newBuilder(uri)
              .timeout(Duration.ofSeconds(45))
              .header("Accept", "application/json");
      if (token != null) b.header("Authorization", "Bearer " + token);
      extra.forEach(b::header);
      String encoded =
          data == null
              ? null
              : (data instanceof String ? (String) data : json.writeValueAsString(data));
      if (encoded != null && !extra.containsKey("Content-Type"))
        b.header("Content-Type", "application/json");
      b.method(
          method,
          encoded == null
              ? HttpRequest.BodyPublishers.noBody()
              : HttpRequest.BodyPublishers.ofString(encoded));
      HttpResponse<InputStream> r =
          client.send(b.build(), HttpResponse.BodyHandlers.ofInputStream());
      byte[] body;
      try (InputStream in = r.body()) {
        body = in.readNBytes(16 * 1024 * 1024 + 1);
      }
      if (r.statusCode() < 200 || r.statusCode() >= 300)
        throw new ProviderException(
            r.statusCode() == 401
                ? "AUTH_EXPIRED"
                : r.statusCode() == 429
                    ? "RATE_LIMITED"
                    : r.statusCode() == 404 ? "NOT_FOUND" : "PROVIDER_REJECTED",
            submission && r.statusCode() >= 500);
      if (body.length > 16 * 1024 * 1024)
        throw new ProviderException("RESPONSE_TOO_LARGE", submission);
      if (body.length == 0) return json.createObjectNode();
      return json.readTree(body);
    } catch (ProviderException e) {
      throw e;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new ProviderException("NETWORK_INTERRUPTED", submission);
    } catch (Exception e) {
      throw new ProviderException("NETWORK_ERROR", submission);
    }
  }

  static String enc(String s) {
    return URLEncoder.encode(s, java.nio.charset.StandardCharsets.UTF_8).replace("+", "%20");
  }
}
