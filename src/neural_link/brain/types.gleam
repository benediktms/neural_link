/// Brain client configuration
pub type BrainConfig {
  BrainConfig(brain_name: String)
}

/// Errors from brain operations
pub type BrainError {
  Timeout
  CommandFailed(output: String)
  ParseError(detail: String)
}

/// Convenience alias
pub type BrainResult(a) =
  Result(a, BrainError)
