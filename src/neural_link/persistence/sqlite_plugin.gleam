import neural_link/persistence/plugin
import neural_link/persistence/types

// ---------------------------------------------------------------------------
// SqlitePlugin (stub)
// ---------------------------------------------------------------------------

/// A replication plugin stub that always returns `Unavailable`.
///
/// This proves the `PersistencePlugin` interface is genuinely backend-agnostic —
/// a second plugin can exist alongside BrainPlugin without any brain dependency.
///
/// When the SqlitePlugin is implemented, it would replicate neural_link events
/// to a secondary SQLite database for consumers that need a raw event feed.
pub fn sqlite_plugin() -> plugin.PersistencePlugin {
  plugin.PersistencePlugin(
    name: "sqlite",
    notify: fn(event: plugin.PluginEvent) {
      case event {
        plugin.PluginInit -> Ok(Nil)
        _ -> Error(types.Unavailable(detail: "sqlite plugin not implemented"))
      }
    },
  )
}
