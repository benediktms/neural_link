import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}
import gleam/string

pub type AuthFailure {
  MissingHeader
  MalformedHeader
  InvalidToken
}

pub fn describe(failure: AuthFailure) -> String {
  case failure {
    MissingHeader -> "Missing Authorization header"
    MalformedHeader -> "Authorization header must be 'Bearer <token>'"
    InvalidToken -> "Invalid bearer token"
  }
}

pub fn check(
  req: Request(t),
  expected: Option(String),
) -> Result(Nil, AuthFailure) {
  case expected {
    None -> Ok(Nil)
    Some(token) ->
      case request.get_header(req, "authorization") {
        Error(_) -> Error(MissingHeader)
        Ok(value) -> validate(value, token)
      }
  }
}

fn validate(
  header_value: String,
  expected: String,
) -> Result(Nil, AuthFailure) {
  case string.split_once(string.trim(header_value), " ") {
    Error(_) -> Error(MalformedHeader)
    Ok(#(scheme, presented)) ->
      case string.lowercase(scheme) {
        "bearer" ->
          case string.trim(presented) == expected {
            True -> Ok(Nil)
            False -> Error(InvalidToken)
          }
        _ -> Error(MalformedHeader)
      }
  }
}
