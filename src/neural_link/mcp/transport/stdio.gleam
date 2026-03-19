import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import neural_link/mcp/codec
import neural_link/mcp/protocol.{type ToolDefinition, JsonRpcError}
import neural_link/mcp/transport.{type ToolCallHandler}

/// Read a line from stdin via FFI
@external(erlang, "neural_link_ffi", "read_line")
fn read_line() -> Result(String, String)

// ---------------------------------------------------------------------------
// Writer actor — serializes stdout writes to prevent interleaving
// ---------------------------------------------------------------------------

type WriterMessage {
  WriteLine(line: String)
  WriterShutdown
}

fn start_writer() -> Result(Subject(WriterMessage), String) {
  case
    actor.new(Nil)
    |> actor.on_message(fn(_state, msg) {
      case msg {
        WriteLine(line) -> {
          io.println(line)
          actor.continue(Nil)
        }
        WriterShutdown -> actor.stop()
      }
    })
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error("Failed to start writer actor")
  }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Start the async MCP stdio transport loop.
/// Each request is spawned in its own BEAM process.
pub fn start(tools: List(ToolDefinition), handler: ToolCallHandler) -> Nil {
  case start_writer() {
    Ok(writer) -> loop(tools, handler, writer)
    Error(_) -> {
      io.println_error("Failed to start stdio writer")
    }
  }
}

fn loop(
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  writer: Subject(WriterMessage),
) -> Nil {
  case read_line() {
    Error(_) -> Nil
    Ok(line) -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> loop(tools, handler, writer)
        _ -> {
          // Spawn each request in its own process for async handling
          let tools_ref = tools
          let handler_ref = handler
          let writer_ref = writer
          process.spawn(fn() {
            handle_line(trimmed, tools_ref, handler_ref, writer_ref)
          })
          loop(tools, handler, writer)
        }
      }
    }
  }
}

fn handle_line(
  line: String,
  tools: List(ToolDefinition),
  handler: ToolCallHandler,
  writer: Subject(WriterMessage),
) -> Nil {
  case codec.decode_request(line) {
    Error(_) -> {
      let response =
        codec.encode_error(
          None,
          JsonRpcError(code: protocol.parse_error, message: "Parse error"),
        )
      actor.send(writer, WriteLine(response))
    }
    Ok(request) -> {
      case request.id {
        None -> Nil
        Some(_) -> {
          let response = route_request(request, tools, handler)
          actor.send(writer, WriteLine(response))
        }
      }
    }
  }
}

fn route_request(
  request: protocol.JsonRpcRequest,
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
      transport.handle_tool_call(request, handler)
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
