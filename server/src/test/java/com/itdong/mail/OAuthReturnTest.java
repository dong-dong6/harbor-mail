package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import org.junit.jupiter.api.Test;

class OAuthReturnTest {
  @Test void successUsesFixedSameOriginLocationWithoutSecrets() {
    var oauth = mock(OAuthService.class);
    var controller = new MailController(null, null, oauth, null);
    String id = "0123456789abcdef0123456789abcdef";
    when(oauth.callback("GMAIL", "private-state", "private-code", "")).thenReturn(id);
    var result = controller.callback("GMAIL", "private-state", "private-code", "");
    assertEquals(303, result.getStatusCode().value());
    assertEquals("/oauth-complete.html#" + id, result.getHeaders().getFirst("Location"));
    assertNull(result.getBody());
    verify(oauth).callback("GMAIL", "private-state", "private-code", "");
  }

  @Test void legacyOrUnsafeMarkerNeverBecomesAnOpenRedirect() {
    var oauth = mock(OAuthService.class);
    var controller = new MailController(null, null, oauth, null);
    for (String id : new String[] {"", "https://evil.example", "//evil.example", "<script>"}) {
      when(oauth.callback("GMAIL", "s", "c", "")).thenReturn(id);
      assertEquals("/oauth-complete.html#connected",
          controller.callback("GMAIL", "s", "c", "").getHeaders().getFirst("Location"));
    }
  }

  @Test void failureIsNotConvertedIntoSuccessNavigation() {
    var oauth = mock(OAuthService.class);
    var controller = new MailController(null, null, oauth, null);
    when(oauth.callback("GMAIL", "s", "", "access_denied"))
        .thenThrow(new ApiError(400, "OAUTH_DENIED", "Authorization not completed"));
    assertThrows(ApiError.class, () -> controller.callback("GMAIL", "s", "", "access_denied"));
  }
}
