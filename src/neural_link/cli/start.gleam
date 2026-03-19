import gleam/int
import gleam/io
import gleam/list
import neural_link/cli/node
import neural_link/config/config
import neural_link/mcp/handlers
import neural_link/mcp/tools
import neural_link/mcp/transport/http as http_transport
import neural_link/mcp/transport/stdio as stdio_transport
import neural_link/runtime/supervisor

pub fn run(flags: List(String)) -> Nil {
  let foreground = list.contains(flags, "--foreground")
  case foreground {
    True -> run_foreground()
    False -> run_detached()
  }
}

fn run_foreground() -> Nil {
  case supervisor.start() {
    Ok(services) -> {
      let tool_defs = tools.all_tools()
      let handler =
        handlers.make_handler(
          services.registry,
          services.inbox,
          services.presence,
        )
      case config.load_transport() {
        config.Http ->
          http_transport.start(tool_defs, handler, config.load_port())
        config.Stdio -> stdio_transport.start(tool_defs, handler)
      }
    }
    Error(err) -> {
      io.println_error("Failed to start services: " <> err)
    }
  }
}

fn run_detached() -> Nil {
  // Check if already running
  case node.is_running() {
    True -> {
      io.println("neural_link is already running")
    }
    False -> {
      let port = config.load_port()
      case node.start_detached(port) {
        Ok(_) ->
          io.println("neural_link started on port " <> int.to_string(port))
        Error(err) -> io.println_error("Failed to start: " <> err)
      }
    }
  }
}
