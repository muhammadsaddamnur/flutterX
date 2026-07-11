/// Pure implementations of the SDK Intelligence engines (docs/03,
/// docs/06 §3). No I/O — file contents and snapshots are injected.
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/scanner/extractors/flutterx_yaml_extractor.dart';
export 'src/scanner/extractors/fvm_extractor.dart';
export 'src/scanner/extractors/puro_extractor.dart';
export 'src/scanner/standard_scanner.dart';
