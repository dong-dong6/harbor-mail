package com.itdong.mail;

import java.util.*;
import java.util.function.Supplier;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Component
public class Store {
  final JdbcTemplate db;
  final TransactionTemplate tx;

  Store(JdbcTemplate db, PlatformTransactionManager tm) {
    this.db = db;
    tx = new TransactionTemplate(tm);
  }

  // Serialize mutations with a database row lock: sequence allocation and commit order agree.
  public <T> T write(Supplier<T> work) {
    return tx.execute(
        s -> {
          db.queryForObject("SELECT seq FROM app_state WHERE id=1 FOR UPDATE", Long.class);
          return work.get();
        });
  }

  public void changed(String type, String id, long revision) {
    long seq = db.queryForObject("SELECT seq FROM app_state WHERE id=1", Long.class) + 1;
    db.update("UPDATE app_state SET seq=? WHERE id=1", seq);
    db.update("INSERT INTO change_log VALUES(?,?,?,?)", seq, type, id, revision);
  }

  public Map<String, Object> one(String sql, Object... args) {
    var rows = db.queryForList(sql, args);
    if (rows.isEmpty()) throw ApiError.missing();
    return rows.getFirst();
  }

  public Map<String, Object> data(String table, String id) {
    return Json.decode((String) one("SELECT data FROM " + table + " WHERE id=?", id).get("data"));
  }

  static String id() {
    return UUID.randomUUID().toString();
  }
}
