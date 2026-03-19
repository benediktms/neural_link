import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

/// JSON-RPC 2.0 request
pub type JsonRpcRequest {
  JsonRpcRequest(
    jsonrpc: String,
    method: String,
    params: Option(Dynamic),
    id: Option(JsonRpcId),
  )
}

/// JSON-RPC ID can be string or int
pub type JsonRpcId {
  StringId(String)
  IntId(Int)
}

/// JSON-RPC 2.0 error
pub type JsonRpcError {
  JsonRpcError(code: Int, message: String)
}

/// Standard error codes
pub const parse_error = -32_700

pub const invalid_request = -32_600

pub const method_not_found = -32_601

pub const invalid_params = -32_602

pub const internal_error = -32_603

/// MCP server info
pub type ServerInfo {
  ServerInfo(name: String, version: String)
}

/// MCP tool input schema property
pub type ToolProperty {
  ToolProperty(
    name: String,
    prop_type: String,
    description: String,
    required: Bool,
  )
}

/// MCP tool definition
pub type ToolDefinition {
  ToolDefinition(
    name: String,
    description: String,
    properties: List(ToolProperty),
  )
}
