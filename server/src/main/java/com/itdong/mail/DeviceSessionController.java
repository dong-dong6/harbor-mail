package com.itdong.mail;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/auth")
class DeviceSessionController {
  final DeviceSessionService sessions;
  DeviceSessionController(DeviceSessionService sessions) { this.sessions = sessions; }

  @PostMapping(value = "/refresh", consumes = "application/json")
  Object refresh(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    return sessions.refresh(body, request.getRemoteAddr());
  }

  @PostMapping(value = "/device-session/logout", consumes = "application/json")
  ResponseEntity<Void> logout(@RequestBody Map<String, Object> body, HttpServletRequest request) {
    sessions.logout(body, request.getRemoteAddr());
    return ResponseEntity.noContent().build();
  }
}
