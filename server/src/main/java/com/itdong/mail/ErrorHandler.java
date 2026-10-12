package com.itdong.mail;

import com.itdong.mail.provider.ProviderException;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MaxUploadSizeExceededException;

@RestControllerAdvice
public class ErrorHandler {
  @ExceptionHandler(Exception.class)
  ResponseEntity<?> handle(Exception e, HttpServletRequest r) {
    int status = 500;
    String code = "INTERNAL_ERROR", message = "Operation failed; inspect server health";
    if (e instanceof ApiError a) {
      status = a.status;
      code = a.code;
      message = a.getMessage();
    } else if (e instanceof ProviderException p) {
      status = 502;
      code = p.code();
      message = "Mailbox provider operation failed";
    } else if (e instanceof org.springframework.web.servlet.resource.NoResourceFoundException) {
      status = 404;
      code = "NOT_FOUND";
      message = "Resource not found";
    } else if (e instanceof org.springframework.web.HttpMediaTypeNotSupportedException) {
      status = 415; code = "INVALID_CONTENT_TYPE"; message = "Use application/json";
    } else if (e instanceof MaxUploadSizeExceededException) {
      status = 413;
      code = "ATTACHMENT_TOO_LARGE";
      message = "Maximum raw attachment size is 10 MiB";
    } else if (e instanceof org.springframework.http.converter.HttpMessageNotReadableException
        || e instanceof org.springframework.web.bind.MissingRequestHeaderException
        || e
            instanceof
            org.springframework.web.method.annotation.MethodArgumentTypeMismatchException) {
      status = 400;
      code = "INVALID_REQUEST";
      message = "Invalid request";
    }
    if (status == 500)
      org.slf4j.LoggerFactory.getLogger(ErrorHandler.class)
          .error(
              "Request {} failed with {}",
              r.getAttribute("requestId"),
              e.getClass().getSimpleName());
    var error = Json.map("code", code, "message", message, "requestId", r.getAttribute("requestId"));
    var response = ResponseEntity.status(status);
    if (e instanceof ApiError a && a.retryAfterSeconds > 0) {
      error.put("retryAfterSeconds", a.retryAfterSeconds);
      response.header("Retry-After", Integer.toString(a.retryAfterSeconds));
    }
    return response.body(Json.map("error", error));
  }
}
