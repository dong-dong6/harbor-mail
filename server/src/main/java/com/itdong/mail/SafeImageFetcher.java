package com.itdong.mail;

import jakarta.annotation.PreDestroy;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.CRC32;
import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.ImageWriter;
import javax.imageio.stream.MemoryCacheImageInputStream;
import javax.imageio.stream.MemoryCacheImageOutputStream;
import javax.net.ssl.*;
import org.springframework.stereotype.Component;

/** A deliberately small, credential-free image transport. DNS is resolved once; the socket
 * connects only to one of those verified addresses. No URLConnection, ambient proxy, redirects,
 * cookies, authenticators, client certificates, or provider credentials are involved. */
@Component
public class SafeImageFetcher implements AutoCloseable {
  static final int MAX_BYTES = 4 * 1024 * 1024;
  static final long MAX_PIXELS = 8_000_000;
  static final int MAX_DIMENSION = 8192;
  private static final byte[] PNG_SIGNATURE = {(byte) 137, 80, 78, 71, 13, 10, 26, 10};
  private static final Set<String> PNG_CHUNKS = Set.of("IHDR", "PLTE", "tRNS", "IDAT", "IEND");
  static final int TOTAL_MS = 8_000, DNS_MS = 1_500, IO_MS = 2_000;
  private final ThreadPoolExecutor workers;
  private final ThreadPoolExecutor dnsWorkers;
  private final Resolver resolver;
  private final Exchange exchange;
  private final int totalMillis, dnsMillis;

  @FunctionalInterface interface Resolver { InetAddress[] resolve(String host) throws Exception; }
  @FunctionalInterface interface Exchange {
    byte[] read(URI uri, InetAddress address, long deadline, AtomicReference<Socket> active)
        throws Exception;
  }

  public SafeImageFetcher() { this(InetAddress::getAllByName, SafeImageFetcher::readSocket, TOTAL_MS, DNS_MS); }
  SafeImageFetcher(Resolver resolver, Exchange exchange, int totalMillis, int dnsMillis) {
    this.resolver = resolver;
    this.exchange = exchange;
    this.totalMillis = totalMillis;
    this.dnsMillis = dnsMillis;
    workers = pool(4, 4, "mail-image");
    dnsWorkers = pool(2, 4, "mail-image-dns");
  }
  private static ThreadPoolExecutor pool(int count, int queue, String name) {
    return new ThreadPoolExecutor(count, count, 0L, TimeUnit.MILLISECONDS,
        new ArrayBlockingQueue<>(queue), r -> {
          Thread t = new Thread(r, name); t.setDaemon(true); return t;
        }, new ThreadPoolExecutor.AbortPolicy());
  }

  public byte[] fetch(String source) {
    URI uri = parseUrl(source);
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(totalMillis);
    AtomicReference<Socket> active = new AtomicReference<>();
    Future<byte[]> work = null;
    try {
      work = workers.submit(() -> {
        Future<InetAddress[]> dns = null;
        try {
          dns = dnsWorkers.submit(() -> resolver.resolve(host(uri)));
          InetAddress[] addresses = dns.get(Math.min(dnsMillis, remaining(deadline)), TimeUnit.MILLISECONDS);
          if (addresses == null || addresses.length == 0 || addresses.length > 32) throw unavailable();
          // Reject the whole answer set, not just whichever address is chosen first.
          for (InetAddress address : addresses) if (!publicAddress(address)) throw unavailable();
          checkDeadline(deadline);
          byte[] raw = exchange.read(uri, addresses[0], deadline, active);
          checkDeadline(deadline);
          byte[] png = rasterPng(raw, deadline);
          checkDeadline(deadline);
          return png;
        } finally {
          if (dns != null) { dns.cancel(true); dnsWorkers.purge(); }
          close(active.getAndSet(null));
        }
      });
      return work.get(remaining(deadline), TimeUnit.MILLISECONDS);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw unavailable();
    } catch (Exception e) {
      // Never propagate a URL, DNS name, redirect, response body, or low-level network exception.
      throw unavailable();
    } finally {
      if (work != null) work.cancel(true);
      close(active.getAndSet(null));
      workers.purge();
    }
  }

  static ApiError unavailable() { return new ApiError(502, "IMAGE_UNAVAILABLE", "Remote image unavailable"); }
  static URI parseUrl(String raw) {
    try {
      if (raw == null || raw.length() > 4096 || !raw.equals(raw.trim())
          || raw.chars().anyMatch(c -> c < 33 || c == 127 || c == '\\')) throw unavailable();
      URI uri = new URI(raw);
      String scheme = uri.getScheme(), host = uri.getHost();
      if (!("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme))
          || host == null || host.isBlank() || uri.getRawUserInfo() != null
          || uri.getRawFragment() != null || uri.getRawAuthority().contains("%")) throw unavailable();
      int port = uri.getPort();
      if (port != -1 && port != (scheme.equalsIgnoreCase("https") ? 443 : 80)) throw unavailable();
      host = host(uri).toLowerCase(Locale.ROOT);
      if (host.contains(":") && !(InetAddress.getByName(host) instanceof Inet6Address)) throw unavailable();
      if (host.endsWith(".") || host.equals("localhost") || host.endsWith(".localhost")
          || host.endsWith(".local") || host.endsWith(".internal") || host.endsWith(".home")
          || (!host.contains(".") && !host.contains(":"))) throw unavailable();
      return uri;
    } catch (Exception e) { throw unavailable(); }
  }
  private static String host(URI uri) {
    String h = uri.getHost();
    return h.startsWith("[") ? h.substring(1, h.length() - 1) : h;
  }

  static boolean publicAddress(InetAddress address) {
    if (address == null || address.isAnyLocalAddress() || address.isLoopbackAddress()
        || address.isLinkLocalAddress() || address.isSiteLocalAddress() || address.isMulticastAddress()) return false;
    byte[] bytes = address.getAddress();
    if (bytes.length == 4) {
      int a = bytes[0] & 255, b = bytes[1] & 255, c = bytes[2] & 255, d = bytes[3] & 255;
      return !(a == 0 || a == 10 || a == 127 || a >= 224
          || (a == 100 && b >= 64 && b <= 127)
          || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31)
          || (a == 192 && (b == 0 || b == 168 || (b == 88 && c == 99)
              || (b == 31 && c == 196) || (b == 52 && c == 193) || (b == 175 && c == 48)))
          || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
          || (a == 203 && b == 0 && c == 113)
          || (a == 168 && b == 63 && c == 129 && d == 16));
    }
    if (bytes.length != 16 || !(address instanceof Inet6Address ipv6)
        || ipv6.getScopeId() != 0 || (bytes[0] & 0xe0) != 0x20) return false;
    // Only global unicast. Exclude transition/mapped/NAT64/Teredo/6to4, special and documentation ranges.
    int a = bytes[0] & 255, b = bytes[1] & 255, c = bytes[2] & 255, d = bytes[3] & 255;
    return !(a == 0x20 && b == 0x02
        || a == 0x20 && b == 0x01 && c < 2
        || a == 0x20 && b == 0x01 && c == 0x0d && d == 0xb8
        || a == 0x3f && b == 0xff && (c & 0xf0) == 0
        || a == 0x26 && b == 0x20 && c == 0 && d == 0x4f
            && (bytes[4] & 255) == 0x80 && bytes[5] == 0
        // ISATAP embeds a potentially private IPv4 destination under an otherwise public prefix.
        || (bytes[8] == 0 || bytes[8] == 2) && bytes[9] == 0
            && (bytes[10] & 255) == 0x5e && (bytes[11] & 255) == 0xfe);
  }

  static byte[] readSocket(URI uri, InetAddress address, long deadline, AtomicReference<Socket> active)
      throws Exception {
    Socket socket = new Socket(Proxy.NO_PROXY);
    active.set(socket);
    try {
      checkDeadline(deadline);
      int port = uri.getScheme().equalsIgnoreCase("https") ? 443 : 80;
      socket.connect(new InetSocketAddress(address, port), timeout(deadline));
      socket.setSoTimeout(timeout(deadline));
      if (port == 443) {
        SSLContext tls = SSLContext.getInstance("TLS");
        tls.init(new KeyManager[0], null, new SecureRandom());
        SSLSocket ssl = (SSLSocket) tls.getSocketFactory().createSocket(socket, host(uri), port, true);
        active.set(ssl);
        SSLParameters params = ssl.getSSLParameters();
        params.setEndpointIdentificationAlgorithm("HTTPS");
        // SNI is a hostname only; IP literals still require certificate IP matching.
        if (!host(uri).contains(":") && !host(uri).matches("[0-9.]+"))
          params.setServerNames(List.of(new SNIHostName(host(uri))));
        ssl.setSSLParameters(params);
        ssl.setSoTimeout(timeout(deadline));
        ssl.startHandshake();
        socket = ssl;
      }
      String path = uri.getRawPath();
      if (path == null || path.isEmpty()) path = "/";
      if (uri.getRawQuery() != null) path += "?" + uri.getRawQuery();
      String hostHeader = host(uri).contains(":") ? "[" + host(uri) + "]" : host(uri);
      // Fixed headers only. No credentials, cookies, referrer, compression or connection reuse.
      byte[] request = ("GET " + path + " HTTP/1.1\r\nHost: " + hostHeader
          + "\r\nAccept: image/png,image/jpeg,image/gif\r\nAccept-Encoding: identity"
          + "\r\nConnection: close\r\nUser-Agent: Harbor-Mail-Image/1\r\n\r\n")
          .getBytes(StandardCharsets.US_ASCII);
      checkDeadline(deadline);
      socket.getOutputStream().write(request);
      socket.getOutputStream().flush();
      return readResponse(socket.getInputStream(), deadline);
    } finally { close(socket); }
  }

  static byte[] readResponse(InputStream input, long deadline) throws IOException {
    InputStream in = new BufferedInputStream(new DeadlineInput(input, deadline));
    String status = line(in);
    if (!status.matches("HTTP/1\\.[01] 200(?: .*)?")) throw unavailable();
    Map<String, String> headers = new HashMap<>();
    int length = status.length();
    for (int count = 0; ; count++) {
      String line = line(in);
      length += line.length() + 2;
      if (count > 80 || length > 32768) throw unavailable();
      if (line.isEmpty()) break;
      int colon = line.indexOf(':');
      if (colon <= 0 || !line.substring(0, colon).matches("[A-Za-z0-9!#$%&'*+.^_`|~-]+")) throw unavailable();
      String name = line.substring(0, colon).toLowerCase(Locale.ROOT);
      String value = line.substring(colon + 1).trim();
      if (headers.putIfAbsent(name, value) != null
          && Set.of("content-length", "transfer-encoding", "content-type", "content-encoding").contains(name)) throw unavailable();
    }
    String type = headers.getOrDefault("content-type", "").split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
    if (!Set.of("image/png", "image/jpeg", "image/gif").contains(type)
        || !headers.getOrDefault("content-encoding", "identity").equalsIgnoreCase("identity")) throw unavailable();
    String transfer = headers.get("transfer-encoding"), size = headers.get("content-length");
    LimitedOutput out = new LimitedOutput();
    if (transfer != null) {
      if (!transfer.equalsIgnoreCase("chunked") || size != null) throw unavailable();
      for (int chunks = 0; ; chunks++) {
        if (chunks > 16384) throw unavailable();
        String chunkLine = line(in);
        // Extensions/trailers add complexity with no benefit to an image fetch. Fail closed.
        if (!chunkLine.matches("[0-9a-fA-F]{1,8}")) throw unavailable();
        long chunk = Long.parseLong(chunkLine, 16);
        if (chunk > MAX_BYTES - out.size()) throw unavailable();
        if (chunk == 0) { if (!line(in).isEmpty()) throw unavailable(); break; }
        copyExact(in, out, (int) chunk);
        if (!line(in).isEmpty()) throw unavailable();
      }
    } else if (size != null) {
      if (!size.matches("[0-9]{1,10}")) throw unavailable();
      long n = Long.parseLong(size);
      if (n > MAX_BYTES) throw unavailable();
      copyExact(in, out, (int) n);
    } else {
      byte[] buffer = new byte[8192];
      int n;
      while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
    }
    checkDeadline(deadline);
    return out.toByteArray();
  }
  private static String line(InputStream in) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (;;) {
      int c = in.read();
      if (c < 0 || out.size() > 8192) throw unavailable();
      if (c == '\r') { if (in.read() != '\n') throw unavailable(); return out.toString(StandardCharsets.US_ASCII); }
      if (c == '\n' || (c < 32 && c != '\t') || c >= 127) throw unavailable();
      out.write(c);
    }
  }
  private static void copyExact(InputStream in, OutputStream out, int size) throws IOException {
    byte[] bytes = new byte[8192];
    while (size > 0) {
      int n = in.read(bytes, 0, Math.min(bytes.length, size));
      if (n < 0) throw unavailable();
      out.write(bytes, 0, n); size -= n;
    }
  }
  static byte[] rasterPng(byte[] input) throws IOException {
    return rasterPng(input, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TOTAL_MS));
  }
  private static byte[] rasterPng(byte[] input, long deadline) throws IOException {
    if (input == null || input.length == 0 || input.length > MAX_BYTES) throw unavailable();
    // Choose a small format allowlist BEFORE invoking any decoder. BMP supports embedded images
    // with attacker-declared allocation lengths independent of its tiny outer pixel dimensions.
    String format;
    if (startsWith(input, PNG_SIGNATURE)) {
      format = "png";
      input = stripPngMetadata(input, deadline);
    } else if (input.length >= 3 && (input[0] & 255) == 255
        && (input[1] & 255) == 216 && (input[2] & 255) == 255) format = "jpeg";
    else if (startsWith(input, "GIF87a".getBytes(StandardCharsets.US_ASCII))
        || startsWith(input, "GIF89a".getBytes(StandardCharsets.US_ASCII))) format = "gif";
    else throw unavailable();
    ImageReader reader = builtinReader(format);
    BufferedImage decoded = null, clean = null;
    try (MemoryCacheImageInputStream stream = new MemoryCacheImageInputStream(new ByteArrayInputStream(input))) {
      try {
        reader.setInput(stream, true, true);
        int width = reader.getWidth(0), height = reader.getHeight(0);
        checkDimensions(width, height);
        checkDeadline(deadline);
        decoded = reader.read(0);
        if (decoded == null || decoded.getWidth() != width || decoded.getHeight() != height) throw unavailable();
        checkDeadline(deadline);
        // A fresh standard pixel buffer drops all EXIF, comments, ICC profiles and animation metadata.
        clean = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = clean.createGraphics();
        try { graphics.drawImage(decoded, 0, 0, null); } finally { graphics.dispose(); }
        LimitedOutput out = new LimitedOutput();
        ImageWriter writer = builtinPngWriter();
        // Bound ImageIO's seekable cache itself, not merely its eventual output sink. Avoid the
        // default disk cache and stop before an oversized PNG is retained or written to temp files.
        try (MemoryCacheImageOutputStream encoded = new MemoryCacheImageOutputStream(out) {
          @Override public void write(int b) throws IOException {
            checkDeadline(deadline);
            if (getStreamPosition() >= MAX_BYTES) throw unavailable();
            super.write(b);
          }
          @Override public void write(byte[] b, int off, int len) throws IOException {
            checkDeadline(deadline);
            if (getStreamPosition() + len > MAX_BYTES) throw unavailable();
            super.write(b, off, len);
          }
        }) {
          writer.setOutput(encoded);
          writer.write(null, new IIOImage(clean, null, null), writer.getDefaultWriteParam());
          encoded.flush();
        } finally { writer.dispose(); }
        checkDeadline(deadline);
        return out.toByteArray();
      } finally {
        reader.dispose();
        if (decoded != null) decoded.flush();
        if (clean != null) clean.flush();
      }
    } catch (ApiError e) { throw e; }
    catch (Exception e) { throw unavailable(); }
  }
  private static ImageReader builtinReader(String format) {
    for (Iterator<ImageReader> it = ImageIO.getImageReadersByFormatName(format); it.hasNext();) {
      ImageReader reader = it.next();
      if (reader.getClass().getModule().equals(ImageIO.class.getModule())
          && reader.getClass().getName().startsWith("com.sun.imageio.plugins.")) return reader;
      reader.dispose();
    }
    throw unavailable();
  }
  private static ImageWriter builtinPngWriter() {
    for (Iterator<ImageWriter> it = ImageIO.getImageWritersByFormatName("png"); it.hasNext();) {
      ImageWriter writer = it.next();
      if (writer.getClass().getModule().equals(ImageIO.class.getModule())
          && writer.getClass().getName().equals("com.sun.imageio.plugins.png.PNGImageWriter")) return writer;
      writer.dispose();
    }
    throw unavailable();
  }
  private static void checkDimensions(int width, int height) {
    if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION
        || (long) width * height > MAX_PIXELS) throw unavailable();
  }
  private static boolean startsWith(byte[] bytes, byte[] prefix) {
    return bytes.length >= prefix.length
        && Arrays.equals(bytes, 0, prefix.length, prefix, 0, prefix.length);
  }
  private static long unsignedInt(byte[] bytes, int offset) {
    return ((long) (bytes[offset] & 255) << 24) | ((long) (bytes[offset + 1] & 255) << 16)
        | ((long) (bytes[offset + 2] & 255) << 8) | (bytes[offset + 3] & 255);
  }
  private static byte[] stripPngMetadata(byte[] input, long deadline) throws IOException {
    LimitedOutput out = new LimitedOutput();
    out.write(PNG_SIGNATURE);
    int offset = 8, chunks = 0;
    boolean header = false, data = false, endedData = false;
    while (offset <= input.length - 12) {
      checkDeadline(deadline);
      if (++chunks > 4096) throw unavailable();
      long length = unsignedInt(input, offset);
      if (length > input.length - offset - 12) throw unavailable();
      int size = (int) length;
      String type = new String(input, offset + 4, 4, StandardCharsets.US_ASCII);
      if (!type.matches("[A-Za-z]{4}")) throw unavailable();
      CRC32 crc = new CRC32(); crc.update(input, offset + 4, size + 4);
      if (crc.getValue() != unsignedInt(input, offset + 8 + size)) throw unavailable();
      if (!header && !type.equals("IHDR")) throw unavailable();
      if (type.equals("IHDR")) {
        if (header || size != 13) throw unavailable();
        checkDimensions((int) unsignedInt(input, offset + 8), (int) unsignedInt(input, offset + 12));
        header = true;
      }
      if (type.equals("IDAT")) {
        if (endedData) throw unavailable();
        data = true;
      } else if (data) endedData = true;
      if (PNG_CHUNKS.contains(type)) out.write(input, offset, size + 12);
      else if (Character.isUpperCase(type.charAt(0))) throw unavailable();
      offset += size + 12;
      if (type.equals("IEND")) {
        if (size != 0 || !data || offset != input.length) throw unavailable();
        return out.toByteArray();
      }
    }
    throw unavailable();
  }
  static final class LimitedOutput extends ByteArrayOutputStream {
    @Override public synchronized void write(int b) { if (count >= MAX_BYTES) throw unavailable(); super.write(b); }
    @Override public synchronized void write(byte[] b, int off, int len) {
      if (len > MAX_BYTES - count) throw unavailable(); super.write(b, off, len);
    }
  }
  private static final class DeadlineInput extends FilterInputStream {
    final long deadline;
    DeadlineInput(InputStream in, long deadline) { super(in); this.deadline = deadline; }
    @Override public int read() throws IOException { checkDeadline(deadline); return super.read(); }
    @Override public int read(byte[] b, int o, int l) throws IOException { checkDeadline(deadline); return in.read(b, o, l); }
  }
  static long remaining(long deadline) { return Math.max(1, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())); }
  private static int timeout(long deadline) { checkDeadline(deadline); return (int) Math.min(IO_MS, remaining(deadline)); }
  private static void checkDeadline(long deadline) {
    if (System.nanoTime() >= deadline || Thread.currentThread().isInterrupted()) throw unavailable();
  }
  private static void close(Socket socket) { if (socket != null) try { socket.close(); } catch (IOException ignored) {} }
  @PreDestroy @Override public void close() { workers.shutdownNow(); dnsWorkers.shutdownNow(); }
}
