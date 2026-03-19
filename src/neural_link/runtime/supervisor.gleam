import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import neural_link/runtime/inbox
import neural_link/runtime/presence
import neural_link/runtime/registry

pub fn start() -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 60)
  |> supervisor.add(supervision.worker(registry.start))
  |> supervisor.add(supervision.worker(inbox.start))
  |> supervisor.add(supervision.worker(presence.start))
  |> supervisor.start
}
