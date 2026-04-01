import neural_link/domain/id
import neural_link/persistence/database
import neural_link/persistence/sqlite
import simplifile

pub fn cleanup(path: String) {
  case simplifile.delete(file_or_dir_at: path) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
}

pub fn unique_db_path(prefix: String) -> String {
  "/tmp/" <> id.generate(prefix) <> ".db"
}

pub fn unique_log_path(prefix: String) -> String {
  "/tmp/" <> id.generate(prefix) <> ".jsonl"
}

pub fn with_store(prefix: String, f: fn(sqlite.SqliteStore) -> Nil) {
  let path = unique_db_path(prefix)
  cleanup(path)
  let assert Ok(store) = sqlite.open(path)
  f(store)
  sqlite.close(store)
  cleanup(path)
}

pub fn with_store_and_log(
  prefix: String,
  f: fn(sqlite.SqliteStore, String) -> Nil,
) {
  let db_path = unique_db_path(prefix)
  let log_path = unique_log_path(prefix)
  cleanup(db_path)
  cleanup(log_path)

  let assert Ok(store) = database.open(database.File(db_path))
  f(store, log_path)
  sqlite.close(store)

  cleanup(db_path)
  cleanup(log_path)
}
