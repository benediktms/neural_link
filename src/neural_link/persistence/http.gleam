import neural_link/persistence/adapter
import neural_link/persistence/types

// ---------------------------------------------------------------------------
// HttpAdapter (stub)
// ---------------------------------------------------------------------------

/// A persistence adapter stub that always returns `Unavailable`.
///
/// This adapter proves the `PersistenceAdapter` interface is genuinely
/// backend-agnostic — a second adapter can exist without any brain dependency.
/// When the HTTP adapter is implemented, replace this stub with a real one.
pub fn http_adapter() -> adapter.PersistenceAdapter {
  adapter.PersistenceAdapter(
    save_snapshot: fn(_, _, _, _) {
      Error(types.Unavailable(detail: "http adapter not implemented"))
    },
    create_artifact: fn(_, _, _, _, _) {
      Error(types.Unavailable(detail: "http adapter not implemented"))
    },
  )
}
