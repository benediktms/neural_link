import gleam/io
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport
import neural_link/runtime/registry

pub fn main() -> Nil {
  case registry.start() {
    Ok(started) -> {
      let registry_subject = started.data
      let tool_defs = tools.all_tools()
      let handler = handlers.make_handler(registry_subject)
      transport.start(tool_defs, handler)
    }
    Error(_) -> {
      io.println_error("Failed to start registry")
    }
  }
}
