/// Host operating system a release publishes artifacts for (docs/03 §1.1,
/// docs/06 §7).
///
/// Named `TargetOs` (not `Platform`) to avoid clashing with `dart:io`'s
/// `Platform` in infrastructure packages.
enum TargetOs { macos, linux, windows }
