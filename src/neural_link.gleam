import argv
import gleam/io
import neural_link/cli/docs
import neural_link/cli/start
import neural_link/cli/stop

pub fn main() -> Nil {
  case argv.load().arguments {
    ["start", ..flags] -> start.run(flags)
    ["stop"] -> stop.run()
    ["docs", ..args] -> docs.run(args)
    ["version"] -> io.println("neural_link 0.1.0")
    ["help"] | ["--help"] | ["-h"] -> print_usage()
    [] -> print_usage()
    [cmd, ..] -> {
      io.println_error("Unknown command: " <> cmd)
      print_usage()
    }
  }
}

fn print_usage() -> Nil {
  io.println(
    "neural_link — multi-agent coordination service

Usage: nlk <command> [options]

Commands:
  start [--foreground]  Start the MCP server (default: daemonized)
  stop                  Stop the running server
  docs [path]           Upsert neural_link section into AGENTS.md
  version               Print version
  help                  Show this help",
  )
}
