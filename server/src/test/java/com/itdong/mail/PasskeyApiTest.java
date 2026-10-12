package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Entirely disposable keys and authenticator fixtures. Production verification remains Yubico-only. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {"mail.worker-enabled=false", "mail.allowed-origin=https://mail.example.invalid:8443"})
@ActiveProfiles("demo")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class PasskeyApiTest {
  static final String ORIGIN = "https://mail.example.invalid:8443", RP = "mail.example.invalid";
  @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { TestDatabases.configure(registry, "passkey_test"); }
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired PasskeyService passkeys;
  @Autowired PasskeyCredentialRepository repository;
  final HttpClient http = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
  String browser, otherBrowser;

  @BeforeEach void reset() {
    store.write(() -> {
      for (String table : List.of("passkey_request", "passkey_credential", "passkey_user", "device_pairing", "device_access_token", "paired_device", "access_token")) store.db.update("DELETE FROM " + table);
      return null;
    });
    security.attempts.clear(); passkeys.publicAttempts.clear(); browser = session(); otherBrowser = session();
  }
  String session() { String token = security.token(); store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token), System.currentTimeMillis() + 3600000); return token; }
  HttpResponse<String> call(String method, String path, Object body, String bearer) throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1/auth/passkeys" + path)).timeout(java.time.Duration.ofSeconds(15)).header("Content-Type", "application/json");
    if (bearer != null) request.header("Authorization", "Bearer " + bearer);
    return http.send(request.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(Json.encode(body))).build(), HttpResponse.BodyHandlers.ofString());
  }
  Map<String, Object> ok(HttpResponse<String> response) { assertEquals(200, response.statusCode(), response.body()); assertEquals("no-store", response.headers().firstValue("Cache-Control").orElseThrow()); return Json.decode(response.body()); }
  Map<String, Object> options() throws Exception { return ok(call("POST", "/registration/options", Json.map("password", "demo-local-only", "name", "Synthetic passkey"), browser)); }
  Map<String, Object> authOptions() throws Exception { return ok(call("POST", "/authentication/options", Json.map(), null)); }
  @SuppressWarnings("unchecked") static Map<String, Object> publicKey(Map<String, Object> opts) { return (Map<String, Object>) opts.get("publicKey"); }
  static String encoded(byte[] bytes) { return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes); }
  static byte[] digest(byte[] bytes) throws Exception { return MessageDigest.getInstance("SHA-256").digest(bytes); }
  static byte[] utf8(String s) { return s.getBytes(StandardCharsets.UTF_8); }
  static byte[] join(byte[]... arrays) { var out = new ByteArrayOutputStream(); for (byte[] array : arrays) out.writeBytes(array); return out.toByteArray(); }
  static byte[] coordinate(BigInteger value) { byte[] bytes = value.toByteArray(), fixed = new byte[32]; System.arraycopy(bytes, Math.max(0, bytes.length-32), fixed, Math.max(0,32-bytes.length), Math.min(32,bytes.length)); return fixed; }
  // Minimal fixed-format CBOR fixture ENCODING only. There is no application verification code here.
  static byte[] cborBytes(byte[] value) { return join(value.length < 256 ? new byte[]{0x58, (byte)value.length} : new byte[]{0x59, (byte)(value.length>>8), (byte)value.length}, value); }
  record Authenticator(KeyPair key, byte[] id, String handle) {
    Map<String,Object> base(Map<String,Object> response) { return Json.map("id", encoded(id), "rawId", encoded(id), "type", "public-key", "response", response, "clientExtensionResults", Json.map()); }
    byte[] client(Map<String,Object> opts, String type, String origin) { return utf8(Json.encode(Json.map("type", type, "challenge", publicKey(opts).get("challenge"), "origin", origin, "crossOrigin", false))); }
    byte[] authData(String rp, int flags, int counter) throws Exception { return join(digest(utf8(rp)), new byte[]{(byte)flags}, ByteBuffer.allocate(4).putInt(counter).array()); }
    Map<String,Object> registration(Map<String,Object> opts, String origin, String rp, int flags) throws Exception {
      var pub = (ECPublicKey) key.getPublic();
      byte[] cose = join(HexFormat.of().parseHex("a5010203262001215820"), coordinate(pub.getW().getAffineX()), HexFormat.of().parseHex("225820"), coordinate(pub.getW().getAffineY()));
      byte[] data = join(authData(rp, flags | 0x40, 0), new byte[16], new byte[]{0,(byte)id.length}, id, cose);
      byte[] attestation = join(HexFormat.of().parseHex("a363666d74646e6f6e656761747453746d74a0686175746844617461"), cborBytes(data));
      return base(Json.map("clientDataJSON", encoded(client(opts,"webauthn.create",origin)), "attestationObject", encoded(attestation), "transports", List.of("internal")));
    }
    Map<String,Object> assertion(Map<String,Object> opts, String origin, String rp, int flags, int counter, String userHandle) throws Exception {
      byte[] client = client(opts,"webauthn.get",origin), data = authData(rp, flags, counter);
      var signer = Signature.getInstance("SHA256withECDSA"); signer.initSign(key.getPrivate()); signer.update(join(data,digest(client)));
      return base(Json.map("clientDataJSON", encoded(client), "authenticatorData", encoded(data), "signature", encoded(signer.sign()), "userHandle", userHandle));
    }
  }
  Authenticator authenticator(Map<String,Object> options) throws Exception {
    var generator = KeyPairGenerator.getInstance("EC"); generator.initialize(new ECGenParameterSpec("secp256r1"));
    return new Authenticator(generator.generateKeyPair(), Base64.getUrlDecoder().decode(security.token()), (String)((Map<?,?>)publicKey(options).get("user")).get("id"));
  }
  Map<String,Object> verifyBody(Map<String,Object> opts, Map<String,Object> credential) { return Json.map("requestId", opts.get("requestId"), "credential", credential); }
  Authenticator enroll(int flags) throws Exception { var opts=options(); var authenticator=authenticator(opts); ok(call("POST","/registration/verify",verifyBody(opts,authenticator.registration(opts,ORIGIN,RP,flags)),browser)); return authenticator; }
  HttpResponse<String> authenticate(Authenticator auth, int flags, int counter) throws Exception { var opts=authOptions(); return call("POST","/authentication/verify",verifyBody(opts,auth.assertion(opts,ORIGIN,RP,flags,counter,auth.handle())),null); }

  @Test void fullValidCryptoFlowIssuesIndependentEightHourOwnerSession() throws Exception {
    var auth=enroll(5); long before=System.currentTimeMillis(); var result=ok(authenticate(auth,5,1));
    assertEquals(Set.of("accessToken","expiresAt","accountName","permission"),result.keySet()); assertEquals("demo",result.get("accountName")); assertEquals("OWNER_FULL_ACCESS",result.get("permission")); assertNotEquals(browser,result.get("accessToken"));
    long expires=Instant.parse((String)result.get("expiresAt")).toEpochMilli(); assertTrue(expires>=before+8*3600000L && expires<=System.currentTimeMillis()+8*3600000L);
    assertEquals(200,call("GET","",null,(String)result.get("accessToken")).statusCode());
    var row=store.one("SELECT * FROM passkey_credential"); assertEquals(1L,((Number)row.get("signature_count")).longValue()); assertNotNull(row.get("last_used_at"));
    assertFalse(row.toString().contains(encoded(auth.key().getPrivate().getEncoded())));
  }
  @Test void registrationOptionsRequireResidentCredentialUvAndExcludeExisting() throws Exception {
    var auth=enroll(5); var opts=publicKey(options()); var selection=(Map<?,?>)opts.get("authenticatorSelection");
    assertEquals("required",selection.get("userVerification")); assertEquals("required",selection.get("residentKey")); assertEquals("none",opts.get("attestation")); assertEquals(120000,opts.get("timeout"));
    assertEquals(RP,((Map<?,?>)opts.get("rp")).get("id")); assertEquals(encoded(auth.id()),((Map<?,?>)((List<?>)opts.get("excludeCredentials")).getFirst()).get("id"));
  }
  @Test void publicCapabilitiesAndUserlessOptionsNeverEnumerateAccount() throws Exception {
    var before=ok(call("GET","/capabilities",null,null)); assertEquals(Set.of("available","rpId"),before.keySet());
    var opts=publicKey(authOptions()); assertFalse(opts.containsKey("username")); assertFalse(opts.containsKey("user")); assertTrue(!opts.containsKey("allowCredentials") || ((List<?>)opts.get("allowCredentials")).isEmpty()); assertEquals("required",opts.get("userVerification"));
    enroll(5); assertEquals(before,ok(call("GET","/capabilities",null,null)));
  }
  @Test void passwordReauthFailureRetainsOwnerBearer() throws Exception {
    var response=call("POST","/registration/options",Json.map("password","wrong","name","test"),browser); assertEquals(403,response.statusCode()); assertTrue(response.body().contains("REAUTHENTICATION_FAILED"));
    assertEquals(200,call("GET","",null,browser).statusCode());
  }
  @Test void ownerBearerAndExactCreatorAreRequired() throws Exception {
    assertEquals(401,call("POST","/registration/options",Json.map("password","demo-local-only","name","test"),null).statusCode());
    var opts=options();var auth=authenticator(opts);var body=verifyBody(opts,auth.registration(opts,ORIGIN,RP,5));
    assertEquals(400,call("POST","/registration/verify",body,otherBrowser).statusCode()); ok(call("POST","/registration/verify",body,browser));
  }
  @Test void pairedDeviceCannotCreateOrDeleteCredentials() throws Exception {
    String id=Store.id();long now=System.currentTimeMillis();store.db.update("INSERT INTO paired_device VALUES(?,?,?,?,?,FALSE)",id,"Synthetic",now,now+3600000,now);store.db.update("INSERT INTO device_access_token VALUES(?,?)",Security.hash(otherBrowser),id);
    assertEquals(403,call("POST","/registration/options",Json.map("password","demo-local-only","name","test"),otherBrowser).statusCode());
    assertEquals(403,call("POST","/"+Store.id()+"/delete",Json.map("password","demo-local-only"),otherBrowser).statusCode());
  }
  @Test void registrationRequestIsConsumedEvenWhenCryptographicValidationFails() throws Exception {
    var opts=options();var auth=authenticator(opts);
    assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,"wrong.invalid",5)),browser).statusCode());
    assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,RP,5)),browser).statusCode()); assertEquals(0,store.db.queryForObject("SELECT COUNT(*) FROM passkey_credential",Integer.class));
  }
  @Test void assertionIsSingleUseUnderConcurrentRedemption() throws Exception {
    var auth=enroll(5);var opts=authOptions();var body=verifyBody(opts,auth.assertion(opts,ORIGIN,RP,5,1,auth.handle()));
    try(var pool=Executors.newFixedThreadPool(2)) {var a=pool.submit(()->call("POST","/authentication/verify",body,null).statusCode());var b=pool.submit(()->call("POST","/authentication/verify",body,null).statusCode());assertEquals(List.of(200,401),java.util.stream.Stream.of(a.get(),b.get()).sorted().toList());}
  }
  @Test void expiredChallengesAndExpiredCreatorCannotRegister() throws Exception {
    var opts=options();var auth=authenticator(opts);store.db.update("UPDATE passkey_request SET expires_at=?",System.currentTimeMillis()-1);
    assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,RP,5)),browser).statusCode());
    opts=options();store.db.update("UPDATE access_token SET expires_at=? WHERE token_hash=?",System.currentTimeMillis()-1,Security.hash(browser));
    assertEquals(401,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,RP,5)),browser).statusCode());
  }
  @Test void missingUvAndUpRejectedByStandardLibrary() throws Exception {
    for(int flags:List.of(1,4,0)) {var opts=options();var auth=authenticator(opts);assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,RP,flags)),browser).statusCode());}
    var auth=enroll(5);for(int flags:List.of(1,4,0))assertEquals(401,authenticate(auth,flags,1).statusCode());
  }
  @Test void originMustExactlyMatchConfiguredSchemeHostAndPort() throws Exception {
    for(String origin:List.of("https://mail.example.invalid", "https://sub.mail.example.invalid:8443", "http://mail.example.invalid:8443", "https://attacker.invalid")) {var opts=options();var auth=authenticator(opts);assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,origin,RP,5)),browser).statusCode());}
  }
  @Test void authenticationRejectsWrongOriginRpAndUserHandle() throws Exception {
    var auth=enroll(5);
    for(String[] values:List.of(new String[]{"https://attacker.invalid",RP,auth.handle()},new String[]{ORIGIN,"wrong.invalid",auth.handle()},new String[]{ORIGIN,RP,security.token()},new String[]{ORIGIN,RP,null})) {
      var opts=authOptions();assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,auth.assertion(opts,values[0],values[1],5,1,values[2])),null).statusCode());
    }
  }
  @Test void invalidSignatureFailsAndConsumesRequest() throws Exception {
    var auth=enroll(5);var opts=authOptions();var response=auth.assertion(opts,ORIGIN,RP,5,1,auth.handle());
    @SuppressWarnings("unchecked")var fields=(Map<String,Object>)response.get("response");fields.put("signature",security.token());
    assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,response),null).statusCode());
    assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,auth.assertion(opts,ORIGIN,RP,5,1,auth.handle())),null).statusCode());
  }
  @Test void oldAndNonzeroReplayedCountersFailForNonBackedUpKeys() throws Exception {var auth=enroll(5);ok(authenticate(auth,5,1));assertEquals(401,authenticate(auth,5,1).statusCode());assertEquals(401,authenticate(auth,5,0).statusCode());ok(authenticate(auth,5,2));}
  @Test void syncedKeysPermitNonIncreasingCountersButBackupEligibilityCannotChange() throws Exception {var auth=enroll(13);ok(authenticate(auth,29,1));ok(authenticate(auth,29,1));ok(authenticate(auth,13,0));assertEquals(401,authenticate(auth,5,2).statusCode());assertEquals(1L,((Number)store.one("SELECT * FROM passkey_credential").get("signature_count")).longValue());}
  @Test void zeroCountersAreSupportedByLibrary() throws Exception {var auth=enroll(5);ok(authenticate(auth,5,0));ok(authenticate(auth,5,0));}
  @Test void deletingCredentialRequiresPasswordAndInvalidatesPendingRequests() throws Exception {
    var auth=enroll(5);var row=store.one("SELECT * FROM passkey_credential");String id=(String)row.get("id");var opts=authOptions();
    assertEquals(403,call("POST","/"+id+"/delete",Json.map("password","wrong"),browser).statusCode());assertEquals(200,call("GET","",null,browser).statusCode());
    assertEquals(204,call("POST","/"+id+"/delete",Json.map("password","demo-local-only"),browser).statusCode());
    assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,auth.assertion(opts,ORIGIN,RP,5,1,auth.handle())),null).statusCode());assertEquals(401,authenticate(auth,5,1).statusCode());
    assertEquals(0,store.db.queryForObject("SELECT COUNT(*) FROM passkey_request WHERE id=?",Integer.class,opts.get("requestId")));
  }
  @Test void metadataListsOnlyOpaqueApplicationIdentifiers() throws Exception {
    var auth=enroll(5);var list=ok(call("GET","",null,browser));var item=(Map<?,?>)((List<?>)list.get("items")).getFirst();assertEquals(Set.of("id","name","createdAt","lastUsedAt"),item.keySet());assertNotEquals(encoded(auth.id()),item.get("id"));assertNull(item.get("lastUsedAt"));assertFalse(Json.encode(list).contains(auth.handle()));assertEquals(401,call("GET","",null,null).statusCode());
  }
  @Test void routesAreExactAndSecretQueryInputsRejected() throws Exception {
    for(String path:List.of("/authentication/options/extra","/authentication/verify/extra","/capabilities/extra","/registration/options")) assertEquals(401,call("POST",path,Json.map(),null).statusCode());
    assertEquals(401,call("GET","/authentication/options",null,null).statusCode());assertEquals(401,call("POST","/capabilities",Json.map(),null).statusCode());assertEquals(400,call("POST","/authentication/options?challenge=secret",Json.map(),null).statusCode());
    assertEquals(413,call("POST","/authentication/verify",Json.map("junk","x".repeat(65537)),null).statusCode());
  }
  @Test void boundsAndPublicThrottleApplyBeforeCredentialParsing() throws Exception {
    for(int i=0;i<PasskeyService.MAX_PER_SESSION;i++)options();assertEquals(429,call("POST","/registration/options",Json.map("password","demo-local-only","name","test"),browser).statusCode());
    passkeys.publicAttempts.put("IP:127.0.0.1",new Security.Attempt(System.currentTimeMillis(),60));assertEquals(429,call("POST","/authentication/options",Json.map(),null).statusCode());assertEquals(429,call("POST","/authentication/verify",Json.map(),null).statusCode());
  }
  @Test void unavailableOriginDoesNotExposeOrEnableTrust() {
    for(String origin:List.of("http://mail.example.invalid", "https://mail.example.invalid/", "https://user@mail.example.invalid", "https://127.0.0.1", "https://mail.example.invalid#fragment")) {
      var sec=new Security(store,false,"","","","127.0.0.1",origin);var service=new PasskeyService(store,sec,new DevicePairingService(store,sec),repository,"");assertEquals(false,service.capabilities().get("available"));assertThrows(ApiError.class,service::relyingParty);
    }
    var sec=new Security(store,true,"","","","127.0.0.1","http://localhost:8080");var service=new PasskeyService(store,sec,new DevicePairingService(store,sec),repository,"");assertEquals("localhost",service.configuration().rpId());
  }
  @Test void androidOriginsRequireExplicitCanonicalSha256Allowlist() {
    var trusted=new PasskeyService(store,security,new DevicePairingService(store,security),repository,"android:apk-key-hash:"+security.token());assertEquals(2,trusted.configuration().origins().size());
    for(String origin:List.of("android:apk-key-hash:short","https://unapproved.example", "android:apk-key-hash:"+security.token()+"=", ",")) {
      var service=new PasskeyService(store,security,new DevicePairingService(store,security),repository,origin);assertEquals(false,service.capabilities().get("available"));
    }
  }
  @Test void repositoryRequiresBothCredentialAndPersistedOwnerHandle() throws Exception {
    var auth=enroll(5);assertTrue(repository.lookup(new com.yubico.webauthn.data.ByteArray(auth.id()),PasskeyCredentialRepository.bytes(security.token())).isEmpty());assertTrue(repository.getCredentialIdsForUsername("unknown").isEmpty());assertTrue(repository.getUserHandleForUsername("unknown").isEmpty());
  }
  @Test void tamperedChallengeAndCeremonyTypeFail() throws Exception {
    var auth=enroll(5);
    for(String field:List.of("challenge","type","crossOrigin")) {
      var opts=authOptions();var assertion=auth.assertion(opts,ORIGIN,RP,5,1,auth.handle());
      @SuppressWarnings("unchecked") var response=(Map<String,Object>)assertion.get("response");
      var client=Json.decode(new String(Base64.getUrlDecoder().decode((String)response.get("clientDataJSON")),StandardCharsets.UTF_8));
      client.put(field,field.equals("crossOrigin") ? true : field.equals("type") ? "webauthn.create" : security.token());
      byte[] clientBytes=utf8(Json.encode(client));
      response.put("clientDataJSON",encoded(clientBytes));
      var signer=Signature.getInstance("SHA256withECDSA");signer.initSign(auth.key().getPrivate());
      signer.update(join(Base64.getUrlDecoder().decode((String)response.get("authenticatorData")),digest(clientBytes)));
      response.put("signature",encoded(signer.sign()));
      assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,assertion),null).statusCode());
    }
    var registration=options();assertEquals(401,call("POST","/authentication/verify",verifyBody(registration,Json.map()),null).statusCode());
  }
  @Test void duplicateRegistrationDoesNotOverwriteCredential() throws Exception {
    var auth=enroll(5);var opts=options();assertEquals(400,call("POST","/registration/verify",verifyBody(opts,auth.registration(opts,ORIGIN,RP,5)),browser).statusCode());assertEquals(1,store.db.queryForObject("SELECT COUNT(*) FROM passkey_credential",Integer.class));
  }
  @Test void logoutInvalidatesPendingRegistrationImmediately() throws Exception {
    var opts=options();security.logout(Security.hash(browser));assertEquals(0,store.db.queryForObject("SELECT COUNT(*) FROM passkey_request",Integer.class));assertEquals(401,call("POST","/registration/verify",verifyBody(opts,Json.map()),browser).statusCode());
  }
  @Test void deletionEpochRejectsAlreadyConsumedCeremonies() throws Exception {
    enroll(5);var opts=options();var saved=passkeys.consume(verifyBody(opts,Json.map()),"REGISTER",Security.hash(browser));
    String id=(String)store.one("SELECT id FROM passkey_credential").get("id");passkeys.delete(Security.hash(browser),id,Json.map("password","demo-local-only"),"127.0.0.1");
    assertThrows(ApiError.class,()->passkeys.requireLiveRequest(saved,"REGISTER"));
  }
  @Test void expiredAuthenticationChallengeFailsWithoutIssuingSession() throws Exception {
    var auth=enroll(5);var opts=authOptions();store.db.update("UPDATE passkey_request SET expires_at=?",System.currentTimeMillis()-1);
    assertEquals(401,call("POST","/authentication/verify",verifyBody(opts,auth.assertion(opts,ORIGIN,RP,5,1,auth.handle())),null).statusCode());assertEquals(2,store.db.queryForObject("SELECT COUNT(*) FROM access_token",Integer.class));
  }

}
