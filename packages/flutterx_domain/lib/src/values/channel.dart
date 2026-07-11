/// Flutter release channel (docs/03 §1.1, docs/06 §2.1).
///
/// `dev` is archived — it exists only so historical releases in the registry
/// parse; new resolutions never target it (the default `channel-policy` rule
/// denies it, docs/03 §4.2).
enum Channel {
  stable,
  beta,
  dev,
  master;

  /// Parses a channel name as it appears in the releases index or user input.
  /// Returns `null` for unknown names — the caller decides whether that is a
  /// warning or a failure.
  static Channel? tryParse(String input) {
    for (final channel in values) {
      if (channel.name == input.toLowerCase().trim()) return channel;
    }
    return null;
  }
}
