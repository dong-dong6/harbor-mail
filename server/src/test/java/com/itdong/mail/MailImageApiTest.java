package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

import java.io.*;
import java.net.URI;
import java.net.http.*;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT, properties="mail.worker-enabled=false")
@ActiveProfiles("demo")
class MailImageApiTest {
  @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { TestDatabases.configure(registry,"mail_images"); }
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired MailService mail;
  @Autowired MailImageService images;
  @MockitoBean SafeImageFetcher fetcher;
  final HttpClient http=HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
  String token;
  final String source="https://images.example.invalid/picture?private=fixture";

  @BeforeEach void setup() throws Exception {
    store.write(() -> {
      for(String table:List.of("remote_attachment","attachment","job","draft","mail_message","mail_account","change_log","access_token","oauth_state"))
        store.db.update("DELETE FROM "+table);
      return null;
    });
    security.attempts.clear(); mail.seed(); images.cache.clear();
    token=Json.string(security.login(Json.map("username","demo","password","demo-local-only"),"image-test"),"accessToken");
    body("<p>Synthetic body</p><img src='"+source+"'>");
    when(fetcher.fetch(anyString())).thenReturn(SafeImageFetcherTest.png());
  }
  void body(String html) {
    var value=store.data("mail_message","demo-0-0"); value.put("bodyHtml",html);
    store.db.update("UPDATE mail_message SET data=? WHERE id=?",Json.encode(value),"demo-0-0");
  }
  HttpResponse<byte[]> get(String suffix,String bearer) throws Exception {
    var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+"/api/v1/messages/"+suffix));
    if(bearer!=null) request.header("Authorization","Bearer "+bearer);
    return http.send(request.GET().build(),HttpResponse.BodyHandlers.ofByteArray());
  }
  String manifestPath() { return "demo-0-0/images?accountId=demo-gmail"; }
  String imagePath(String id) { return "demo-0-0/images/"+id+"?accountId=demo-gmail"; }
  @SuppressWarnings("unchecked") List<Map<String,Object>> entries(HttpResponse<byte[]> response) {
    return (List<Map<String,Object>>) Json.decode(new String(response.body(),java.nio.charset.StandardCharsets.UTF_8)).get("items");
  }
  String imageId() throws Exception { return Json.string(entries(get(manifestPath(),token)).getFirst(),"id"); }

  @Test void everyImageAndManifestRequestRequiresBearer() throws Exception {
    String id=imageId();
    assertEquals(401,get(manifestPath(),null).statusCode());
    assertEquals(401,get(imagePath(id),null).statusCode());
    assertEquals(401,get(imagePath(id),"invalid").statusCode());
    verifyNoInteractions(fetcher);
  }
  @Test void manifestUsesOnlyCurrentStoredBodyAndNeverFetches() throws Exception {
    body("<img src='"+source+"'><img src='"+source+"'><img src='cid:local'><img src='file:///x'><img src='data:image/png,abc'>");
    var response=get(manifestPath(),token); assertEquals(200,response.statusCode());
    var items=entries(response); assertEquals(1,items.size());
    assertEquals(source,items.getFirst().get("source"));
    assertTrue(Json.string(items.getFirst(),"id").matches("[a-f0-9]{64}"));
    verifyNoInteractions(fetcher);
  }
  @Test void droppedSubtreesDoNotConsumeManifestQuotaOrPermitImageFetches() throws Exception {
    StringBuilder hidden = new StringBuilder();
    for (int i = 0; i < 40; i++)
      hidden.append("<img src='https://images.example.invalid/hidden-").append(i).append("'>");
    body("<template>" + hidden + "</template><form>" + hidden + "</form>"
        + "<svg><foreignObject>" + hidden + "</foreignObject></svg>"
        + "<section><img src='" + source + "'></section>");
    var response = get(manifestPath(), token);
    assertEquals(200, response.statusCode());
    var items = entries(response);
    assertEquals(1, items.size());
    assertEquals(source, items.getFirst().get("source"));
    verifyNoInteractions(fetcher);
    String hiddenSource = "https://images.example.invalid/hidden-0";
    String hiddenId = Security.hash(hiddenSource + "\n" + hiddenSource);
    assertEquals(404, get(imagePath(hiddenId), token).statusCode());
    verifyNoInteractions(fetcher);
    assertEquals(200, get(imagePath(Json.string(items.getFirst(), "id")), token).statusCode());
    verify(fetcher, times(1)).fetch(source);
    verifyNoMoreInteractions(fetcher);
  }
  @Test void fetchReturnsVerifiedPngAndCacheStillRequiresAuthentication() throws Exception {
    String id=imageId(); var first=get(imagePath(id),token);
    assertEquals(200,first.statusCode()); assertEquals("image/png",first.headers().firstValue("content-type").orElse(""));
    assertEquals("no-store",first.headers().firstValue("cache-control").orElse(""));
    assertEquals(2,javax.imageio.ImageIO.read(new ByteArrayInputStream(first.body())).getWidth());
    assertArrayEquals(first.body(),get(imagePath(id),token).body());
    verify(fetcher,times(1)).fetch(source);
    store.db.update("DELETE FROM access_token");
    assertEquals(401,get(imagePath(id),token).statusCode());
    verify(fetcher,times(1)).fetch(source);
  }
  @Test void wrongAccountMessageAndUnknownImageCannotUseCachedGrant() throws Exception {
    String id=imageId(); assertEquals(200,get(imagePath(id),token).statusCode());
    assertEquals(404,get("demo-0-0/images/"+id+"?accountId=demo-outlook",token).statusCode());
    assertEquals(404,get("demo-0-1/images/"+id+"?accountId=demo-gmail",token).statusCode());
    assertEquals(404,get(imagePath("a".repeat(64)),token).statusCode());
    verify(fetcher,times(1)).fetch(source);
  }
  @Test void changedStoredBodyRevokesCachedImage() throws Exception {
    String id=imageId(); assertEquals(200,get(imagePath(id),token).statusCode());
    body("<p>The remote image was removed.</p>");
    assertEquals(404,get(imagePath(id),token).statusCode()); assertEquals(0,entries(get(manifestPath(),token)).size());
    verify(fetcher,times(1)).fetch(source);
  }
  @Test void deletedAccountCannotReadCachedImage() throws Exception {
    String id=imageId(); assertEquals(200,get(imagePath(id),token).statusCode());
    mail.disconnectAccount("demo-gmail");
    assertEquals(404,get(imagePath(id),token).statusCode());
    assertEquals(404,get(manifestPath(),token).statusCode()); verify(fetcher,times(1)).fetch(source);
  }
  @Test void fetchFailureHasGenericMessageAndNoUrlLeakOrFallback() throws Exception {
    String id=imageId(); when(fetcher.fetch(source)).thenThrow(SafeImageFetcher.unavailable());
    var response=get(imagePath(id),token); assertEquals(502,response.statusCode());
    String text=new String(response.body(),java.nio.charset.StandardCharsets.UTF_8);
    assertTrue(text.contains("IMAGE_UNAVAILABLE")); assertFalse(text.contains(source)); assertFalse(text.contains("private"));
    assertTrue(images.cache.isEmpty());
  }
  @Test void deletionDuringFetchIsRevalidatedBeforeReturnOrCaching() throws Exception {
    String id=imageId(); when(fetcher.fetch(source)).thenAnswer(i -> {
      body("<p>Body changed during request.</p>"); return SafeImageFetcherTest.png();
    });
    assertEquals(404,get(imagePath(id),token).statusCode()); assertTrue(images.cache.isEmpty());
  }
  @Test void cacheExpiresAfterTenMinutesAndIsLazilyCleaned() throws Exception {
    MutableClock clock=new MutableClock(); MailImageService controlled=new MailImageService(store,fetcher,clock);
    String id=imageId(); controlled.image("demo-0-0","demo-gmail",id);
    clock.now=MailImageService.CACHE_MILLIS-1; controlled.image("demo-0-0","demo-gmail",id);
    verify(fetcher,times(1)).fetch(source);
    clock.now=MailImageService.CACHE_MILLIS; controlled.image("demo-0-0","demo-gmail",id);
    verify(fetcher,times(2)).fetch(source);
    clock.now+=MailImageService.CACHE_MILLIS; controlled.manifest("demo-0-0","demo-gmail");
    assertTrue(controlled.cache.isEmpty());
  }
  @Test void manifestIsBoundedAndCacheEvictsOldEntries() throws Exception {
    StringBuilder html=new StringBuilder(); for(int i=0;i<40;i++) html.append("<img src='https://images.example.invalid/").append(i).append("'>");
    body(html.toString()); var items=entries(get(manifestPath(),token)); assertEquals(32,items.size());
    for(int i=0;i<18;i++) assertEquals(200,get(imagePath(Json.string(items.get(i),"id")),token).statusCode());
    assertEquals(MailImageService.MAX_CACHE_ENTRIES,images.cache.size());
  }
  static final class MutableClock extends Clock {
    long now;
    public ZoneId getZone(){return ZoneOffset.UTC;}
    public Clock withZone(ZoneId zone){return this;}
    public Instant instant(){return Instant.ofEpochMilli(now);}
  }
}
