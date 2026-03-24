// ---------------------------------------------------------------------------
// Record kind
// ---------------------------------------------------------------------------

/// The kind of record being persisted.
///
/// Brain uses two distinct record types:
/// - `Snapshot`: room-open/close metadata, individual messages (lightweight)
/// - `Artifact`: full conversation transcript (heavyweight, structured content)
pub type RecordKind {
  Snapshot
  Artifact
}

/// Tags for labelling persisted records. Tags are backend-agnostic strings.
pub type RecordTags =
  List(String)

// ---------------------------------------------------------------------------
// Error model
// ---------------------------------------------------------------------------

/// Backend-agnostic errors from persistence operations.
///
/// Variants:
/// - `Disabled`: persistence is intentionally absent (not an error condition)
/// - `Timeout`: the operation timed out
/// - `Unavailable`: the persistence backend is unreachable or unavailable
/// - `AdapterError`: wraps backend-specific error detail
pub type PersistenceError {
  Disabled
  Timeout
  Unavailable(detail: String)
  AdapterError(backend: String, detail: String)
}

/// Convert a PersistenceError to a human-readable string.
pub fn error_to_string(err: PersistenceError) -> String {
  case err {
    Disabled -> "persistence_disabled"
    Timeout -> "persistence_timeout"
    Unavailable(detail) -> "persistence_unavailable: " <> detail
    AdapterError(backend, detail) ->
      "persistence_adapter_error(" <> backend <> "): " <> detail
  }
}
// Note: BrainError mapping lives in persistence/brain.gleam to keep
// brain-specific concerns out of the persistence type layer.
