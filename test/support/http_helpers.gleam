import gleam/string

@external(erlang, "erlang", "unique_integer")
pub fn erlang_unique_integer() -> Int

pub fn erlang_abs(n: Int) -> Int {
  case n < 0 {
    True -> -n
    False -> n
  }
}

/// Extract a string value from an MCP tool response by key.
/// MCP wraps tool output in a content block with escaped JSON, so we search
/// for the escaped pattern: \"key\":\"value\"
pub fn extract_json_string(body: String, key: String) -> Result(String, String) {
  let pattern = "\\\"" <> key <> "\\\":\\\""
  case string.split(body, pattern) {
    [_, rest, ..] ->
      case string.split(rest, "\\\"") {
        [value, ..] -> Ok(value)
        _ -> Error("key not found")
      }
    _ -> Error("key not found")
  }
}

pub fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] ->
      case string.lowercase(k) == string.lowercase(name) {
        True -> Ok(v)
        False -> find_header(rest, name)
      }
  }
}
