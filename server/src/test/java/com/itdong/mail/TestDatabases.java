package com.itdong.mail;

import org.springframework.test.context.DynamicPropertyRegistry;

/** Use only an explicitly supplied disposable test database; isolate HTTP suites by schema. */
final class TestDatabases {
  private TestDatabases() {}

  static void configure(DynamicPropertyRegistry registry, String schema) {
    if (!schema.matches("[a-z_]+")) throw new IllegalArgumentException("Invalid fixture schema");
    String external = System.getenv("TEST_DATABASE_URL");
    String url = external == null || external.isBlank()
        ? "jdbc:h2:mem:" + schema + ";MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1"
        : external;
    if (url.startsWith("jdbc:postgresql:")) {
      url = url.replaceAll("([?&])currentSchema=[^&]*&?", "$1").replaceAll("[?&]$", "");
      url += (url.contains("?") ? "&" : "?") + "currentSchema=" + schema;
      registry.add("spring.flyway.schemas", () -> schema);
      registry.add("spring.flyway.default-schema", () -> schema);
    } else if (external != null && !external.isBlank() && url.startsWith("jdbc:h2:")) {
      url += ";INIT=CREATE SCHEMA IF NOT EXISTS " + schema + "\\;SET SCHEMA " + schema;
      registry.add("spring.flyway.schemas", () -> schema);
      registry.add("spring.flyway.default-schema", () -> schema);
    }
    String finalUrl = url;
    registry.add("spring.datasource.url", () -> finalUrl);
    registry.add("spring.datasource.username", () -> System.getenv().getOrDefault("TEST_DATABASE_USER", "sa"));
    registry.add("spring.datasource.password", () -> System.getenv().getOrDefault("TEST_DATABASE_PASSWORD", ""));
  }
}
