package com.itdong.mail;

import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/messages/{messageId}/images")
public class MailImageController {
  final MailImageService images;
  MailImageController(MailImageService images) { this.images = images; }

  @GetMapping
  Object manifest(@PathVariable String messageId, @RequestParam String accountId) {
    return images.manifest(messageId, accountId);
  }
  @GetMapping("/{imageId}")
  ResponseEntity<byte[]> image(@PathVariable String messageId, @PathVariable String imageId,
      @RequestParam String accountId) {
    return ResponseEntity.ok().contentType(MediaType.IMAGE_PNG)
        .header(HttpHeaders.CACHE_CONTROL, "no-store")
        .header("X-Content-Type-Options", "nosniff")
        .body(images.image(messageId, accountId, imageId));
  }
}
