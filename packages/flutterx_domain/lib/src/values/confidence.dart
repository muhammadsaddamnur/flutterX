/// Confidence of a resolution decision (docs/03 §5.2).
///
/// Drives CLI behavior: high auto-applies, medium applies with alternatives
/// shown, low prompts on a TTY and fails with exit code 12 in CI unless
/// `--accept-low` (docs/04 §1.2).
enum Confidence { high, medium, low }
