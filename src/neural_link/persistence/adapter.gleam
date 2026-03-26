// This module is deprecated.
//
// The persistence abstraction is now a plugin architecture:
//
// - persistence/plugin.gleam   — PersistencePlugin behaviour (the interface)
// - persistence/config.gleam  — PersistencePluginConfig
// - persistence/sqlite.gleam   — SqliteStore (primary operational store)
// - persistence/brain.gleam   — BrainPlugin (replicates to brain CLI)
//
// All migrations from this module are complete.
//
// This module will be removed after the migration is complete.
