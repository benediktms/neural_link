import simplifile

pub fn data_dir() -> String {
  case get_home_dir() {
    Ok(home) -> home <> "/.neural_link"
    Error(_) -> ".neural_link"
  }
}

pub fn ensure_data_dir() -> Result(String, String) {
  let dir = data_dir()

  case simplifile.is_directory(dir) {
    Ok(True) -> Ok(dir)
    Ok(False) | Error(_) -> {
      case simplifile.create_directory_all(dir) {
        Ok(_) -> Ok(dir)
        Error(error) -> {
          Error(
            "Failed to create data dir: " <> simplifile.describe_error(error),
          )
        }
      }
    }
  }
}

pub fn db_path() -> String {
  data_dir() <> "/neural_link.db"
}

pub fn sync_log_path() -> String {
  data_dir() <> "/sync.jsonl"
}

@external(erlang, "neural_link_ffi", "get_home_dir")
fn get_home_dir() -> Result(String, String)
