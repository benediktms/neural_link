import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import neural_link/mcp/protocol.{
  type JsonRpcError, type JsonRpcId, type JsonRpcRequest, type ToolDefinition,
  IntId, JsonRpcRequest, StringId,
}

/// Decode a JSON-RPC request from a JSON string
pub fn decode_request(input: String) -> Result(JsonRpcRequest, json.DecodeError) {
  json.parse(from: input, using: request_decoder())
}

fn request_decoder() -> decode.Decoder(JsonRpcRequest) {
  use jsonrpc <- decode.field("jsonrpc", decode.string)
  use method <- decode.field("method", decode.string)
  use params <- decode.optional_field(
    "params",
    None,
    decode.optional(decode.dynamic),
  )
  use id <- decode.optional_field("id", None, id_decoder())
  decode.success(JsonRpcRequest(jsonrpc:, method:, params:, id:))
}

fn id_decoder() -> decode.Decoder(Option(JsonRpcId)) {
  decode.one_of(decode.string |> decode.map(fn(s) { Some(StringId(s)) }), [
    decode.int |> decode.map(fn(i) { Some(IntId(i)) }),
    decode.success(None),
  ])
}

/// Encode a successful response
pub fn encode_response(id: Option(JsonRpcId), result: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", encode_id(id)),
    #("result", result),
  ])
  |> json.to_string
}

/// Encode an error response
pub fn encode_error(id: Option(JsonRpcId), error: JsonRpcError) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", encode_id(id)),
    #(
      "error",
      json.object([
        #("code", json.int(error.code)),
        #("message", json.string(error.message)),
      ]),
    ),
  ])
  |> json.to_string
}

fn encode_id(id: Option(JsonRpcId)) -> json.Json {
  case id {
    None -> json.null()
    Some(StringId(s)) -> json.string(s)
    Some(IntId(i)) -> json.int(i)
  }
}

/// Encode tool definitions for tools/list response
pub fn encode_tools_list(tools: List(ToolDefinition)) -> json.Json {
  json.object([#("tools", json.array(tools, encode_tool))])
}

fn encode_tool(tool: ToolDefinition) -> json.Json {
  let required_names =
    list.filter_map(tool.properties, fn(p) {
      case p.required {
        True -> Ok(p.name)
        False -> Error(Nil)
      }
    })
  let props =
    json.object(
      list.map(tool.properties, fn(p) {
        #(
          p.name,
          json.object([
            #("type", json.string(p.prop_type)),
            #("description", json.string(p.description)),
          ]),
        )
      }),
    )
  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #(
      "inputSchema",
      json.object([
        #("type", json.string("object")),
        #("properties", props),
        #("required", json.array(required_names, json.string)),
      ]),
    ),
  ])
}

/// Encode initialize response
pub fn encode_initialize_result() -> json.Json {
  json.object([
    #("protocolVersion", json.string("2024-11-05")),
    #("capabilities", json.object([#("tools", json.object([]))])),
    #(
      "serverInfo",
      json.object([
        #("name", json.string("neural_link")),
        #("version", json.string("0.1.0")),
      ]),
    ),
  ])
}
