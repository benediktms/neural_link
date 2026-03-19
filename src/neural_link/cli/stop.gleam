import gleam/io
import neural_link/cli/node

pub fn run() -> Nil {
  case node.is_running() {
    False -> {
      io.println("neural_link is not running")
    }
    True -> {
      case node.stop_remote() {
        Ok(_) -> io.println("neural_link stopped")
        Error(err) -> io.println_error("Failed to stop: " <> err)
      }
    }
  }
}
