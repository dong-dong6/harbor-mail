package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import org.junit.jupiter.api.Test;

class SecurityConfigTest {
  private Security security(boolean demo, String user, String password, String key, String bind) {
    return new Security(null, demo, user, password, key, bind, "http://localhost:3000");
  }

  @Test
  void productionRequiresAdmin() {
    assertThrows(
        IllegalStateException.class, () -> security(false, "", "", "", "127.0.0.1").init());
  }

  @Test
  void productionRejectsShortPassword() {
    assertThrows(
        IllegalStateException.class,
        () -> security(false, "admin", "short", "", "127.0.0.1").init());
  }

  @Test
  void productionRejectsDemoKey() {
    assertThrows(
        IllegalStateException.class,
        () ->
            security(
                    false,
                    "admin",
                    "a-unique-long-password",
                    "ZGVtby1vbmx5LWRvLW5vdC11c2UtaW4tcHJvZC0xMjM=",
                    "127.0.0.1")
                .init());
  }

  @Test
  void demoCannotBindPublicly() {
    assertThrows(
        IllegalStateException.class,
        () ->
            security(
                    true,
                    "demo",
                    "demo-local-only",
                    "ZGVtby1vbmx5LWRvLW5vdC11c2UtaW4tcHJvZC0xMjM=",
                    "0.0.0.0")
                .init());
  }

  @Test
  void bcryptPasswordLengthIsBytes() {
    assertThrows(
        IllegalStateException.class,
        () ->
            security(
                    true,
                    "demo",
                    "密".repeat(30),
                    "ZGVtby1vbmx5LWRvLW5vdC11c2UtaW4tcHJvZC0xMjM=",
                    "127.0.0.1")
                .init());
  }
}
