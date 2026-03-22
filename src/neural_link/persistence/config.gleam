// ---------------------------------------------------------------------------
// Persistence backend
// ---------------------------------------------------------------------------

/// A concrete persistence backend.
///
/// Each variant corresponds to a supported adapter implementation.
/// Variants marked "(stub)" have no working implementation — they exist
/// to prove the interface is backend-agnostic.
pub type PersistenceBackend {
  /// No persistence backend is configured.
  /// Operations return `Ok("disabled")` without contacting any backend.
  Disabled

  /// Brain CLI backend.
  /// The adapter calls `brain artifacts create` and `brain snapshots save`.
  Brain(brain_name: String)

  /// HTTP backend (stub — not implemented).
  /// The adapter calls a generic REST endpoint.
  Http(url: String, auth_token: String)
}

// ---------------------------------------------------------------------------
// Persistence config
// ---------------------------------------------------------------------------

/// Configuration for a persistence adapter.
///
/// Carries the backend variant and any credentials/endpoints needed to
/// contact the backend. The config is passed at each call site — no
/// global state is maintained by the adapter interface.
pub type PersistenceConfig {
  PersistenceConfig(backend: PersistenceBackend)
}

/// Build a Disabled persistence config.
pub fn disabled() -> PersistenceConfig {
  PersistenceConfig(backend: Disabled)
}

/// Build a Brain-backed persistence config from a brain name.
pub fn brain(name: String) -> PersistenceConfig {
  PersistenceConfig(backend: Brain(brain_name: name))
}

/// Build an Http-backed persistence config.
pub fn http(url: String, auth_token: String) -> PersistenceConfig {
  PersistenceConfig(backend: Http(url: url, auth_token: auth_token))
}
