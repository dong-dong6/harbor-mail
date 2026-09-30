package com.itdong.mail;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;

public final class Json {
  public static final ObjectMapper MAPPER = new ObjectMapper();

  public static String encode(Object value) {
    try {
      return MAPPER.writeValueAsString(value);
    } catch (Exception e) {
      throw new IllegalArgumentException("Cannot encode data", e);
    }
  }

  public static Map<String, Object> decode(String value) {
    try {
      return MAPPER.readValue(value, new TypeReference<LinkedHashMap<String, Object>>() {});
    } catch (Exception e) {
      throw new IllegalArgumentException("Invalid stored data", e);
    }
  }

  public static String string(Map<String, Object> m, String k) {
    return Objects.toString(m.get(k), "");
  }

  public static long number(Map<String, Object> m, String k) {
    Object v = m.get(k);
    if (v instanceof Number n) return n.longValue();
    throw ApiError.bad("Required integer: " + k);
  }

  public static Map<String, Object> map(Object... pairs) {
    var m = new LinkedHashMap<String, Object>();
    for (int i = 0; i < pairs.length; i += 2) m.put((String) pairs[i], pairs[i + 1]);
    return m;
  }
}
