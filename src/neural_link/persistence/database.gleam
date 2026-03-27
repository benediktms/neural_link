import gleam/list
import gleam/string
import neural_link/persistence/sqlite
import neural_link/persistence/types
import simplifile

pub type DatabaseTarget {
  Memory
  File(path: String)
}

pub type RuntimePaths {
  RuntimePaths(data_dir: String, db_path: String, sync_log_path: String)
}

pub fn runtime_paths() -> Result(RuntimePaths, String) {
  case data_dir_from_env_or_home() {
    Ok(data_dir) ->
      Ok(RuntimePaths(
        data_dir: data_dir,
        db_path: data_dir <> "/neural_link.db",
        sync_log_path: data_dir <> "/sync.jsonl",
      ))
    Error(error) -> Error(error)
  }
}

pub fn open(target: DatabaseTarget) -> Result(sqlite.SqliteStore, String) {
  case target {
    Memory -> open_sqlite(":memory:")
    File(path) -> {
      let dir = parent_dir(path)

      case simplifile.create_directory_all(dir) {
        Ok(_) -> open_sqlite(path)
        Error(error) ->
          Error(
            "Failed to create data dir: " <> simplifile.describe_error(error),
          )
      }
    }
  }
}

fn open_sqlite(path: String) -> Result(sqlite.SqliteStore, String) {
  case sqlite.open(path) {
    Ok(store) -> Ok(store)
    Error(error) -> Error(types.error_to_string(error))
  }
}

fn data_dir_from_env_or_home() -> Result(String, String) {
  case get_env("NEURAL_LINK_DATA_DIR") {
    Ok(data_dir) -> Ok(data_dir)
    Error(_) ->
      case get_home_dir() {
        Ok(home) -> Ok(home <> "/.neural_link")
        Error(_) ->
          Error(
            "Unable to resolve data dir: NEURAL_LINK_DATA_DIR not set and HOME unavailable",
          )
      }
  }
}

fn parent_dir(path: String) -> String {
  let parts = string.split(path, "/")

  case list.reverse(parts) {
    [] -> "."
    [_] -> "."
    [_, ..rest] -> {
      let parent = string.join(list.reverse(rest), "/")
      case parent {
        "" -> "/"
        _ -> parent
      }
    }
  }
}

@external(erlang, "neural_link_ffi", "get_env")
fn get_env(name: String) -> Result(String, String)

@external(erlang, "neural_link_ffi", "get_home_dir")
fn get_home_dir() -> Result(String, String)
