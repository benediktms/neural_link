import gleam/erlang/process
import neural_link/runtime/supervisor as runtime_supervisor

pub fn main() -> Nil {
  let assert Ok(_supervisor) = runtime_supervisor.start()
  process.sleep_forever()
}
