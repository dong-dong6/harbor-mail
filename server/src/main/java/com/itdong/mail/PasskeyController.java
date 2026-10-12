package com.itdong.mail;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/auth/passkeys")
public class PasskeyController {
  final PasskeyService passkeys;
  PasskeyController(PasskeyService passkeys) { this.passkeys = passkeys; }
  @GetMapping("/capabilities") Object capabilities(HttpServletRequest request) {
    passkeys.publicRateLimit(request.getRemoteAddr()); return passkeys.capabilities();
  }
  @PostMapping("/registration/options") Object registerOptions(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return passkeys.registrationOptions(DevicePairingController.creator(request), body, request.getRemoteAddr());
  }
  @PostMapping("/registration/verify") Object registerVerify(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return passkeys.registrationVerify(DevicePairingController.creator(request), body);
  }
  @PostMapping("/authentication/options") Object authenticateOptions(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return passkeys.authenticationOptions(body, request.getRemoteAddr());
  }
  @PostMapping("/authentication/verify") Object authenticateVerify(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return passkeys.authenticationVerify(body, request.getRemoteAddr());
  }
  @GetMapping Object list() { return Json.map("items", passkeys.list()); }
  @PostMapping("/{id}/delete") ResponseEntity<Void> delete(@PathVariable String id, @RequestBody Map<String, Object> body, HttpServletRequest request) {
    passkeys.delete(DevicePairingController.creator(request), id, body, request.getRemoteAddr());
    return ResponseEntity.noContent().build();
  }
}
