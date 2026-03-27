import argv
import gleam/io
import neural_link/cli/docs
import neural_link/cli/start
import neural_link/cli/stop
import neural_link/cli/sync

pub fn main() -> Nil {
  case argv.load().arguments {
    ["start", ..flags] -> start.run(flags)
    ["stop"] -> {
      stop.run()
      halt(0)
    }
    ["docs", ..args] -> {
      docs.run(args)
      halt(0)
    }
    ["sync", ..args] -> {
      sync.run(args)
      halt(0)
    }
    ["version"] -> {
      io.println("neural_link 0.1.0")
      halt(0)
    }
    ["help"] | ["--help"] | ["-h"] -> {
      print_usage()
      halt(0)
    }
    [] -> {
      print_usage()
      halt(0)
    }
    [cmd, ..] -> {
      io.println_error("Unknown command: " <> cmd)
      print_usage()
      halt(1)
    }
  }
}

@external(erlang, "neural_link_ffi", "halt")
fn halt(code: Int) -> Nil

fn print_usage() -> Nil {
  io.println(
    "neural_link — multi-agent coordination service

Usage: nlk <command> [options]

Commands:
  start [--foreground]  Start the MCP server (default: daemonized)
  stop                  Stop the running server
  docs [path]           Upsert neural_link section into AGENTS.md
  sync [options]        Sync closed rooms to brain
  version               Print version
  help                  Show this help",
  )
}
