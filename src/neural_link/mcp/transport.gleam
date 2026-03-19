import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import neural_link/mcp/codec
import neural_link/mcp/protocol.{type JsonRpcRequest, JsonRpcError}

/// Type for the handler function that tools/call dispatches to
pub type ToolCallHandler =
  fn(String, Option(Dynamic)) -> Result(json.Json, String)

/// Shared tools/call handler used by both stdio and HTTP transports
pub fn handle_tool_call(
  request: JsonRpcRequest,
  handler: ToolCallHandler,
) -> String {
  case request.params {
    None ->
      codec.encode_error(
        request.id,
        JsonRpcError(code: protocol.invalid_params, message: "Missing params"),
      )
    Some(params) -> {
      case decode_tool_call_params(params) {
        Error(_) ->
          codec.encode_error(
            request.id,
            JsonRpcError(
              code: protocol.invalid_params,
              message: "Invalid tool call params",
            ),
          )
        Ok(#(tool_name, arguments)) -> {
          case handler(tool_name, arguments) {
            Ok(result_json) -> {
              let content =
                json.object([
                  #(
                    "content",
                    json.preprocessed_array([
                      json.object([
                        #("type", json.string("text")),
                        #("text", json.string(json.to_string(result_json))),
                      ]),
                    ]),
                  ),
                ])
              codec.encode_response(request.id, content)
            }
            Error(err_msg) -> {
              let content =
                json.object([
                  #(
                    "content",
                    json.preprocessed_array([
                      json.object([
                        #("type", json.string("text")),
                        #("text", json.string(err_msg)),
                      ]),
                    ]),
                  ),
                  #("isError", json.bool(True)),
                ])
              codec.encode_response(request.id, content)
            }
          }
        }
      }
    }
  }
}

fn decode_tool_call_params(
  params: Dynamic,
) -> Result(#(String, Option(Dynamic)), Nil) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.optional_field(
      "arguments",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(name, arguments))
  }
  decode.run(params, decoder)
  |> result.map_error(fn(_) { Nil })
}
