import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import neural_link/mcp/codec
import neural_link/mcp/protocol.{
  type JsonRpcRequest, type ToolDefinition, JsonRpcError,
}

/// Read a line from stdin via FFI
@external(erlang, "neural_link_ffi", "read_line")
fn read_line() -> Result(String, String)

/// Type for the handler function that tools/call dispatches to
pub type ToolCallHandler =
  fn(String, Option(Dynamic)) -> Result(json.Json, String)

/// Start the MCP stdio transport loop.
/// Takes a list of tool definitions and a handler for tools/call.
pub fn start(tools: List(ToolDefinition), handler: ToolCallHandler) -> Nil {
  loop(tools, handler)
}

fn loop(tools: List(ToolDefinition), handler: ToolCallHandler) -> Nil {
  case read_line() {
    Error(_) -> Nil
    Ok(line) -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> loop(tools, handler)
        _ -> {
          handle_line(trimmed, tools, handler)
          loop(tools, handler)
        }
      }
    }
  }
}

fn handle_line(
  line: String,
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
) -> Nil {
  case codec.decode_request(line) {
    Error(_) -> {
      let response =
        codec.encode_error(
          None,
          JsonRpcError(code: protocol.parse_error, message: "Parse error"),
        )
      write_response(response)
    }
    Ok(request) -> {
      case request.id {
        None -> Nil
        Some(_) -> {
          let response = route_request(request, tools, handler)
          write_response(response)
        }
      }
    }
  }
}

fn route_request(
  request: JsonRpcRequest,
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
) -> String {
  case request.method {
    "initialize" -> {
      codec.encode_response(request.id, codec.encode_initialize_result())
    }
    "ping" -> {
      codec.encode_response(request.id, json.object([]))
    }
    "tools/list" -> {
      codec.encode_response(request.id, codec.encode_tools_list(tools))
    }
    "tools/call" -> {
      handle_tool_call(request, handler)
    }
    _ -> {
      codec.encode_error(
        request.id,
        JsonRpcError(
          code: protocol.method_not_found,
          message: "Method not found: " <> request.method,
        ),
      )
    }
  }
}

fn handle_tool_call(request: JsonRpcRequest, handler: ToolCallHandler) -> String {
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

fn write_response(response: String) -> Nil {
  io.println(response)
}
