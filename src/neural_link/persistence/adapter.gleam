// This module is deprecated.
//
// The persistence abstraction is now a plugin architecture:
//
// - persistence/plugin.gleam   — PersistencePlugin behaviour (the interface)
// - persistence/config.gleam  — PersistencePluginConfig
// - persistence/sqlite.gleam   — SqliteStore (primary operational store)
// - persistence/brain.gleam   — BrainPlugin (replicates to brain CLI)
//
// NLR-01KM9AD.2: Extract BrainPlugin from brain/bridge.gleam
// NLR-01KM9AD.3: Rename brains -> plugins in domain model
//
// This module will be removed after the migration is complete.
