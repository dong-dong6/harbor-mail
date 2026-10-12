package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.awt.image.BufferedImage;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.stream.Stream;
import javax.imageio.ImageIO;
import javax.imageio.metadata.IIOMetadataNode;
import javax.imageio.stream.MemoryCacheImageOutputStream;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.*;

class SafeImageFetcherTest {
  static byte[] png() throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    BufferedImage image = new BufferedImage(2, 3, BufferedImage.TYPE_INT_RGB);
    image.setRGB(0, 0, 0xff00ff);
    ImageIO.write(image, "png", out); return out.toByteArray();
  }
  static long deadline() { return System.nanoTime() + TimeUnit.SECONDS.toNanos(5); }
  static byte[] response(String head, byte[] body) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    out.write(head.getBytes(StandardCharsets.US_ASCII)); out.write(body); return out.toByteArray();
  }
  static InetAddress ip(String s) throws UnknownHostException { return InetAddress.getByName(s); }

  @ParameterizedTest
  @ValueSource(strings = {"0.0.0.0", "0.2.3.4", "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.255.255.255",
      "100.64.0.0", "100.127.255.255", "169.254.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255",
      "192.168.1.1", "192.0.0.1", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.255.255",
      "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255",
      "::", "::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "fe80::1", "fc00::1", "fdff::1", "ff02::1",
      "64:ff9b::808:808", "64:ff9b:1::808:808", "2002:0808:0808::1", "2001::1", "2001:20::1",
      "2001:db8::1", "3fff:0001::1", "100::1", "fec0::1", "2001:2::1", "2001:10::1",
      "168.63.129.16", "192.31.196.1", "192.52.193.1", "192.175.48.1", "2620:4f:8000::1",
      "2606:4700::5efe:7f00:1", "2606:4700::200:5efe:a00:1"})
  void rejectsNonPublicAddresses(String value) throws Exception { assertFalse(SafeImageFetcher.publicAddress(ip(value))); }

  @Test void rejectsScopedGlobalIpv6() throws Exception {
    assertFalse(SafeImageFetcher.publicAddress(Inet6Address.getByAddress(null,
        ip("2606:4700:4700::1111").getAddress(), 2)));
  }

  @ParameterizedTest @ValueSource(strings={"8.8.8.8", "1.1.1.1", "9.9.9.9", "100.63.255.255", "100.128.0.1", "172.15.1.1", "172.32.1.1", "192.167.1.1", "198.17.1.1", "198.20.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450:4001::1"})
  void permitsPublicAddresses(String value) throws Exception { assertTrue(SafeImageFetcher.publicAddress(ip(value))); }

  @ParameterizedTest @ValueSource(strings={"file:///etc/passwd", "ftp://example.com/a", "data:image/png;base64,eA==", "javascript:x", "//example.com/x", "https://", "https://user:pass@example.com/a", "https://user@example.com/a", "https://example.com:8443/a", "http://example.com:443/a", "https://localhost/a", "https://x.localhost/a", "https://x.local/a", "https://x.internal/a", "https://x.home/a", "https://example.com./a", "https://example.com/a#b", "https://example.com/a b", "https://example.com/\r\nx", "https://example.com/\\x", "https://example/a", "https://[fe80::1%25eth0]/x", "https://[::ffff:8.8.8.8]/x", "https://example.com:-1/a", "https://ex%61mple.com/x", " https://example.com/x"})
  void rejectsUnsafeUrlShapes(String source) { assertThrows(ApiError.class, () -> SafeImageFetcher.parseUrl(source)); }

  @ParameterizedTest @ValueSource(strings={"https://example.com/image.png", "http://example.com/x?a=1&b=2", "https://example.com:443/x", "http://example.com:80/x", "https://[2606:4700::1111]/a", "https://8.8.8.8/a", "HTTPS://EXAMPLE.COM/a"})
  void acceptsSafeUrlShapes(String source) { assertNotNull(SafeImageFetcher.parseUrl(source)); }

  @Test void rejectsNullAndLongUrls() {
    assertThrows(ApiError.class, () -> SafeImageFetcher.parseUrl(null));
    assertThrows(ApiError.class, () -> SafeImageFetcher.parseUrl("https://example.com/" + "x".repeat(4096)));
  }
  @Test void validatesEveryDnsAnswerBeforeAnySocket() throws Exception {
    AtomicInteger calls = new AtomicInteger();
    try (var fetch = new SafeImageFetcher(h -> new InetAddress[]{ip("8.8.8.8"), ip("127.0.0.1")},
        (u, a, d, active) -> { calls.incrementAndGet(); return png(); }, 500, 100)) {
      assertThrows(ApiError.class, () -> fetch.fetch("https://example.com/a")); assertEquals(0, calls.get());
    }
  }
  @Test void resolvesExactlyOnceAndPinsVerifiedAddress() throws Exception {
    AtomicInteger dns = new AtomicInteger();
    try (var fetch = new SafeImageFetcher(h -> { assertEquals("example.com", h); dns.incrementAndGet(); return new InetAddress[]{ip("8.8.8.8")}; },
        (u, a, d, active) -> { assertEquals("8.8.8.8", a.getHostAddress()); return png(); }, 1000, 200)) {
      assertEquals(2, ImageIO.read(new ByteArrayInputStream(fetch.fetch("https://example.com/a"))).getWidth());
      assertEquals(1, dns.get());
    }
  }
  @Test void dnsAndTransportFailuresHaveOnlyGenericError() throws Exception {
    try (var fetch = new SafeImageFetcher(h -> { throw new UnknownHostException("SECRET-SOURCE"); }, (u,a,d,s) -> png(), 500, 100)) {
      ApiError error = assertThrows(ApiError.class, () -> fetch.fetch("https://example.com/private-query"));
      assertEquals("Remote image unavailable", error.getMessage()); assertNull(error.getCause());
    }
    try (var fetch = new SafeImageFetcher(h -> new InetAddress[]{ip("8.8.8.8")}, (u,a,d,s) -> { throw new IOException("SECRET-SOURCE"); }, 500, 100)) {
      assertEquals("IMAGE_UNAVAILABLE", assertThrows(ApiError.class, () -> fetch.fetch("https://example.com/private-query")).code);
    }
  }
  @Test void dnsDeadlineIsBounded() {
    try (var fetch = new SafeImageFetcher(h -> { Thread.sleep(5000); return new InetAddress[0]; }, (u,a,d,s) -> png(), 400, 60)) {
      assertTimeout(Duration.ofMillis(600), () -> assertThrows(ApiError.class, () -> fetch.fetch("https://example.com/a")));
    }
  }
  @Test void totalDeadlineClosesActiveSocket() {
    Socket socket = new Socket();
    try (var fetch = new SafeImageFetcher(h -> new InetAddress[]{ip("8.8.8.8")}, (u,a,d,s) -> { s.set(socket); Thread.sleep(5000); return png(); }, 100, 50)) {
      assertTimeout(Duration.ofMillis(600), () -> assertThrows(ApiError.class, () -> fetch.fetch("https://example.com/a")));
      assertTrue(socket.isClosed());
    }
  }
  @Test void imageWorkersAndQueueAreBounded() throws Exception {
    CountDownLatch started = new CountDownLatch(4), release = new CountDownLatch(1);
    AtomicInteger running = new AtomicInteger(), maximum = new AtomicInteger();
    ExecutorService callers = Executors.newFixedThreadPool(12);
    try (var fetch = new SafeImageFetcher(h -> new InetAddress[]{ip("8.8.8.8")}, (u,a,d,s) -> {
      int n = running.incrementAndGet(); maximum.accumulateAndGet(n, Math::max); started.countDown();
      try { release.await(); return png(); } finally { running.decrementAndGet(); }
    }, 3000, 1000)) {
      List<Future<?>> futures = new ArrayList<>();
      for (int i=0; i<12; i++) futures.add(callers.submit(() -> { try { fetch.fetch("https://example.com/a"); } catch (ApiError ignored) {} }));
      assertTrue(started.await(1, TimeUnit.SECONDS));
      Thread.sleep(100); assertEquals(4, maximum.get());
      assertTrue(futures.stream().filter(Future::isDone).count() >= 4, "Four excess calls must be rejected, never queued without a bound");
      release.countDown(); for (Future<?> f : futures) f.get(4, TimeUnit.SECONDS);
    } finally { release.countDown(); callers.shutdownNow(); }
  }
  @Test void dnsWorkersRemainBoundedEvenWhenResolverIgnoresInterrupts() throws Exception {
    CountDownLatch started = new CountDownLatch(2), release = new CountDownLatch(1);
    AtomicInteger running = new AtomicInteger(), maximum = new AtomicInteger();
    ExecutorService callers = Executors.newFixedThreadPool(4);
    try (var fetch = new SafeImageFetcher(h -> {
      int n = running.incrementAndGet(); maximum.accumulateAndGet(n, Math::max); started.countDown();
      while (release.getCount() > 0) try { release.await(); } catch (InterruptedException ignored) {}
      running.decrementAndGet(); return new InetAddress[]{ip("8.8.8.8")};
    }, (u,a,d,s) -> png(), 400, 50)) {
      for (int i=0; i<4; i++) callers.submit(() -> { try { fetch.fetch("https://example.com/a"); } catch (ApiError ignored) {} });
      assertTrue(started.await(1, TimeUnit.SECONDS)); Thread.sleep(150); assertEquals(2, maximum.get());
    } finally { release.countDown(); callers.shutdownNow(); }
  }

  @ParameterizedTest @ValueSource(strings={"301 Moved", "302 Found", "307 Temporary Redirect", "308 Permanent Redirect", "401 Unauthorized", "407 Proxy Authentication", "404 Not Found", "500 Error", "100 Continue", "206 Partial Content"})
  void rejectsNon200StatusWithoutFollowing(String status) throws Exception {
    byte[] raw = response("HTTP/1.1 " + status + "\r\nLocation: https://secret.example/x\r\n\r\n", new byte[0]);
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(raw), deadline()));
  }
  @ParameterizedTest @ValueSource(strings={"Content-Type: image/svg+xml", "Content-Type: image/bmp", "Content-Type: image/x-ms-bmp", "Content-Type: text/html", "Content-Type: application/octet-stream", "Content-Type: image/webp", "Content-Type: image/png\r\nContent-Encoding: gzip", "Content-Type: image/png\r\nContent-Length: 4194305", "Content-Type: image/png\r\nContent-Length: -1", "Content-Type: image/png\r\nContent-Length: 1\r\nContent-Length: 1", "Content-Type: image/png\r\nTransfer-Encoding: gzip", "Content-Type: image/png\r\nTransfer-Encoding: chunked\r\nContent-Length: 5", "Content-Type: image/png\r\n Content-Length: 5", "Content-Type: image/png\r\nContent-Type: image/jpeg"})
  void rejectsUnsafeHeaders(String headers) throws Exception {
    byte[] raw = response("HTTP/1.1 200 OK\r\n" + headers + "\r\n\r\n", png());
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(raw), deadline()));
  }
  @Test void acceptsFixedLengthAndChunkedRasterResponses() throws Exception {
    byte[] image = png();
    byte[] fixed = response("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: " + image.length + "\r\n\r\n", image);
    assertArrayEquals(image, SafeImageFetcher.readResponse(new ByteArrayInputStream(fixed), deadline()));
    ByteArrayOutputStream body = new ByteArrayOutputStream();
    body.write((Integer.toHexString(image.length) + "\r\n").getBytes(StandardCharsets.US_ASCII)); body.write(image); body.write("\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
    byte[] chunked = response("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n", body.toByteArray());
    assertArrayEquals(image, SafeImageFetcher.readResponse(new ByteArrayInputStream(chunked), deadline()));
  }
  @Test void refusesOversizedUnknownLengthAndTruncation() throws Exception {
    byte[] tooLarge = response("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n", new byte[SafeImageFetcher.MAX_BYTES+1]);
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(tooLarge), deadline()));
    byte[] truncated = response("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 50\r\n\r\n", new byte[10]);
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(truncated), deadline()));
  }
  @ParameterizedTest @ValueSource(strings={"ZZ\r\n", "400001\r\n", "-1\r\n", "1;ext=x\r\nx\r\n0\r\n\r\n", "1\r\nxXX", "0\r\nX-Trailer: x\r\n\r\n"})
  void rejectsMalformedOrOversizedChunks(String body) throws Exception {
    byte[] raw = response("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n", body.getBytes(StandardCharsets.US_ASCII));
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(raw), deadline()));
  }
  @Test void rejectsInvalidSvgAndOversizedInput() {
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng("<svg xmlns='http://www.w3.org/2000/svg'/>".getBytes(StandardCharsets.UTF_8)));
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(new byte[0]));
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(new byte[SafeImageFetcher.MAX_BYTES+1]));
  }
  @Test void rejectsExcessivePixelDimensionsBeforeDecoding() throws Exception {
    byte[] image = png();
    // Width/height in PNG IHDR; reader.getWidth reads these before allocating pixels.
    image[16]=0; image[17]=0; image[18]=15; image[19]=(byte)160; // 4000
    image[20]=0; image[21]=0; image[22]=15; image[23]=(byte)160;
    java.util.zip.CRC32 crc = new java.util.zip.CRC32(); crc.update(image,12,17);
    long value=crc.getValue(); for(int i=0;i<4;i++) image[29+i]=(byte)(value >>> (24-8*i));
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(image));
  }
  @Test void decodesAndReencodesFreshPngDroppingMetadata() throws Exception {
    BufferedImage image = new BufferedImage(2,3,BufferedImage.TYPE_INT_RGB);
    var writer = ImageIO.getImageWritersByFormatName("png").next();
    ByteArrayOutputStream encoded = new ByteArrayOutputStream();
    try (var stream = new MemoryCacheImageOutputStream(encoded)) {
      writer.setOutput(stream);
      var metadata = writer.getDefaultImageMetadata(new javax.imageio.ImageTypeSpecifier(image), writer.getDefaultWriteParam());
      IIOMetadataNode tree = new IIOMetadataNode("javax_imageio_png_1.0"), text = new IIOMetadataNode("tEXt"), entry = new IIOMetadataNode("tEXtEntry");
      entry.setAttribute("keyword","Comment"); entry.setAttribute("value","SECRET-METADATA"); text.appendChild(entry); tree.appendChild(text);
      metadata.mergeTree("javax_imageio_png_1.0", tree);
      writer.write(null, new javax.imageio.IIOImage(image,null,metadata), writer.getDefaultWriteParam());
    } finally { writer.dispose(); }
    assertTrue(new String(encoded.toByteArray(),StandardCharsets.ISO_8859_1).contains("SECRET-METADATA"));
    byte[] clean=SafeImageFetcher.rasterPng(encoded.toByteArray());
    assertFalse(new String(clean,StandardCharsets.ISO_8859_1).contains("SECRET-METADATA"));
    assertEquals(3,ImageIO.read(new ByteArrayInputStream(clean)).getHeight());
  }
  @Test void outputBoundIsEnforced() {
    SafeImageFetcher.LimitedOutput out = new SafeImageFetcher.LimitedOutput();
    out.write(new byte[SafeImageFetcher.MAX_BYTES],0,SafeImageFetcher.MAX_BYTES);
    assertThrows(ApiError.class, () -> out.write(1));
    assertThrows(ApiError.class, () -> out.write(new byte[1],0,1));
  }
  @Test void expiredResponseDeadlineFailsClosed() throws Exception {
    assertThrows(ApiError.class, () -> SafeImageFetcher.readResponse(new ByteArrayInputStream(png()), System.nanoTime()-1));
  }

  @Test void tinyBmpCannotAllocateAttackerDeclaredEmbeddedImageBuffer() throws Exception {
    // Run under a bounded heap: a regression must fail this isolated child, not exhaust the test JVM.
    String java = System.getProperty("java.home") + "/bin/java";
    String classpath = System.getProperty("surefire.test.class.path", System.getProperty("java.class.path"));
    Process process = new ProcessBuilder(java, "-Xmx32m", "-cp", classpath,
        BmpLimitProbe.class.getName()).redirectErrorStream(true).start();
    try {
      assertTrue(process.waitFor(15, TimeUnit.SECONDS), "BMP rejection must finish promptly");
      String output = new String(process.getInputStream().readNBytes(8192), StandardCharsets.UTF_8);
      assertEquals(0, process.exitValue(), output);
      assertTrue(output.contains("BMP_REJECTED_BEFORE_ALLOCATION"), output);
    } finally { process.destroyForcibly(); }
  }

  public static class BmpLimitProbe {
    public static void main(String[] args) {
      var header = java.nio.ByteBuffer.allocate(54).order(java.nio.ByteOrder.LITTLE_ENDIAN);
      header.put((byte) 'B').put((byte) 'M').putInt(54).putInt(0).putInt(54);
      header.putInt(40).putInt(1).putInt(1).putShort((short) 1).putShort((short) 0);
      // BI_PNG's imageSize used to allocate 256 MiB despite the 54-byte input and 1x1 dimensions.
      header.putInt(5).putInt(256 * 1024 * 1024).putInt(0).putInt(0).putInt(0).putInt(0);
      try {
        SafeImageFetcher.rasterPng(header.array());
        throw new AssertionError("BMP was accepted");
      } catch (ApiError expected) {
        System.out.println("BMP_REJECTED_BEFORE_ALLOCATION");
      } catch (Throwable failure) {
        failure.printStackTrace();
        System.exit(1);
      }
    }
  }

  static byte[] pngChunk(String type, byte[] data) throws IOException {
    var bytes = new ByteArrayOutputStream();
    var output = new DataOutputStream(bytes);
    byte[] name = type.getBytes(StandardCharsets.US_ASCII);
    output.writeInt(data.length); output.write(name); output.write(data);
    var crc = new java.util.zip.CRC32(); crc.update(name); crc.update(data);
    output.writeInt((int) crc.getValue());
    return bytes.toByteArray();
  }

  @Test void stripsCompressedPngMetadataBeforeDecoderAndRejectsInvalidLengthsAndCrc() throws Exception {
    byte[] original = png();
    byte[] compressed = pngChunk("iCCP", "profile\0\0deliberately-not-deflate".getBytes(StandardCharsets.US_ASCII));
    var bytes = new ByteArrayOutputStream();
    bytes.write(original, 0, 33); bytes.write(compressed);
    bytes.write(original, 33, original.length - 33);
    byte[] clean = SafeImageFetcher.rasterPng(bytes.toByteArray());
    assertEquals(2, ImageIO.read(new ByteArrayInputStream(clean)).getWidth());
    assertFalse(new String(clean, StandardCharsets.ISO_8859_1).contains("iCCP"));
    byte[] badCrc = original.clone(); badCrc[29] ^= 1;
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(badCrc));
    byte[] hugeClaim = original.clone(); hugeClaim[33] = 0x7f;
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(hugeClaim));
  }

  @Test void rejectsHugeSingleDimensionBeforeRowBufferAllocation() throws Exception {
    byte[] input = png();
    java.nio.ByteBuffer.wrap(input).putInt(16, 1_000_000).putInt(20, 1);
    var crc = new java.util.zip.CRC32(); crc.update(input, 12, 17);
    java.nio.ByteBuffer.wrap(input).putInt(29, (int) crc.getValue());
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(input));
  }

  @Test void reencodedPngCacheIsBoundedEvenWhenJpegInputFits() throws Exception {
    BufferedImage noisy = new BufferedImage(1500, 1500, BufferedImage.TYPE_INT_RGB);
    var random = new Random(1234);
    for (int y = 0; y < noisy.getHeight(); y++)
      for (int x = 0; x < noisy.getWidth(); x++) noisy.setRGB(x, y, random.nextInt());
    var jpeg = new ByteArrayOutputStream();
    assertTrue(ImageIO.write(noisy, "jpeg", jpeg)); noisy.flush();
    assertTrue(jpeg.size() < SafeImageFetcher.MAX_BYTES);
    assertThrows(ApiError.class, () -> SafeImageFetcher.rasterPng(jpeg.toByteArray()));
  }

  @Test void legitimateJpegAndGifRemainSupportedAfterDecoderAllowlist() throws Exception {
    for (String format : List.of("jpeg", "gif")) {
      BufferedImage image = new BufferedImage(2, 3, BufferedImage.TYPE_INT_RGB);
      var encoded = new ByteArrayOutputStream();
      assertTrue(ImageIO.write(image, format, encoded)); image.flush();
      byte[] result = SafeImageFetcher.rasterPng(encoded.toByteArray());
      assertEquals(137, result[0] & 255);
      BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(result));
      assertEquals(2, decoded.getWidth()); assertEquals(3, decoded.getHeight()); decoded.flush();
    }
  }
}
