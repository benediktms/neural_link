// ---------------------------------------------------------------------------
// Plugin configuration
// ---------------------------------------------------------------------------

/// Configuration for a replication plugin.
///
/// Each variant corresponds to a supported plugin implementation.
/// Variants marked "(placeholder)" have no working implementation yet.
pub type PersistencePluginConfig {
  /// Brain CLI replication plugin.
  /// Replicates room events to brain for memory graph indexing.
  BrainPlugin(brain_name: String)

  /// Sqlite replication plugin (placeholder — not implemented).
  /// For systems that need to consume neural_link events via SQLite replication.
  SqlitePlugin
}

// ---------------------------------------------------------------------------
// Helper constructors
// ---------------------------------------------------------------------------

/// Build a BrainPlugin config from a brain name.
pub fn brain_plugin(name: String) -> PersistencePluginConfig {
  BrainPlugin(brain_name: name)
}

/// Build a SqlitePlugin config (placeholder).
pub fn sqlite_plugin() -> PersistencePluginConfig {
  SqlitePlugin
}
