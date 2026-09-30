package com.itdong.mail.provider;

public final class ProviderException extends RuntimeException {
  private final String code;
  private final boolean ambiguous;

  public ProviderException(String code, boolean ambiguous) {
    super("Provider operation failed: " + code);
    this.code = code;
    this.ambiguous = ambiguous;
  }

  public String code() {
    return code;
  }

  public boolean ambiguous() {
    return ambiguous;
  }
}
