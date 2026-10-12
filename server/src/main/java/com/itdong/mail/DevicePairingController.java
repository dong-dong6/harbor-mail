package com.itdong.mail;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/auth")
public class DevicePairingController {
  final DevicePairingService pairing;
  DevicePairingController(DevicePairingService pairing) { this.pairing = pairing; }
  static String creator(HttpServletRequest request) { return (String) request.getAttribute("tokenHash"); }

  @PostMapping("/device-pairings")
  Object create(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.create(creator(request), body);
  }

  @GetMapping("/device-pairings/{id}")
  Object view(@PathVariable String id, HttpServletRequest request) {
    return pairing.view(creator(request), id);
  }

  @PostMapping("/device-pairings/{id}/approve")
  Object approve(@PathVariable String id, @RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.approve(creator(request), id, body, request.getRemoteAddr());
  }

  @PostMapping("/device-pairings/{id}/reject")
  Object reject(@PathVariable String id, @RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.reject(creator(request), id, body);
  }

  @PostMapping("/device-pairings/claim")
  Object claim(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.claim(body, request.getRemoteAddr());
  }

  @PostMapping("/device-pairings/poll")
  Object poll(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.poll(body, request.getRemoteAddr());
  }

  @PostMapping("/device-pairings/redeem")
  Object redeem(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return pairing.redeem(body, request.getRemoteAddr());
  }

  @GetMapping("/devices")
  Object devices() { return Json.map("items", pairing.devices()); }

  @DeleteMapping("/devices/{id}")
  ResponseEntity<Void> revoke(@PathVariable String id) {
    pairing.revoke(id);
    return ResponseEntity.noContent().build();
  }
}
