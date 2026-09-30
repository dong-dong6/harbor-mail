package com.itdong.mail;

public class ApiError extends RuntimeException {
  final int status;
  final String code;

  public ApiError(int status, String code, String message) {
    super(message);
    this.status = status;
    this.code = code;
  }

  static ApiError bad(String message) {
    return new ApiError(400, "INVALID_REQUEST", message);
  }

  static ApiError missing() {
    return new ApiError(404, "NOT_FOUND", "Resource not found");
  }

  static ApiError conflict(String message) {
    return new ApiError(409, "CONFLICT", message);
  }
}
