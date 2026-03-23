import gleam/list

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
// Plugin registry
// ---------------------------------------------------------------------------

/// A registry of replication plugins configured for a room.
///
/// Plugins are applied in order after the primary SqliteStore write succeeds.
/// Each plugin receives every event. Plugin errors are logged but do not
/// block or roll back the primary write.
pub type PluginRegistry {
  PluginRegistry(plugins: List(PersistencePluginConfig))
}

/// An empty plugin registry — no replication consumers.
pub fn empty() -> PluginRegistry {
  PluginRegistry(plugins: [])
}

/// Add a plugin to a registry.
pub fn add_plugin(
  registry: PluginRegistry,
  config: PersistencePluginConfig,
) -> PluginRegistry {
  PluginRegistry(plugins: list.append(registry.plugins, [config]))
}

/// Get all plugins in the registry.
pub fn plugins(registry: PluginRegistry) -> List(PersistencePluginConfig) {
  registry.plugins
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
