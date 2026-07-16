import 'package:flutterx_domain/flutterx_domain.dart';

/// One curated breaking-change/behavior note, keyed to the release that
/// introduced it (docs/03 §8.1 step 3).
final class KnowledgeEntry {
  KnowledgeEntry({required String introducedIn, required this.text, this.link})
    : introducedIn = SemVer.parse(introducedIn);

  final SemVer introducedIn;
  final String text;
  final String? link;
}

/// The curated breaking-change knowledge base (docs/03 §8.1). M3.8 seeds
/// the full 3.16→latest sweep; these entries cover the majors developers
/// hit most. Data-only — safe to extend without touching logic.
final class KnowledgeBase {
  KnowledgeBase(List<KnowledgeEntry> entries)
    : _entries = List.unmodifiable(entries);

  factory KnowledgeBase.builtin() => KnowledgeBase(_builtinEntries);

  final List<KnowledgeEntry> _entries;

  /// Notes introduced strictly after the lower and up to (inclusive) the
  /// higher of [from]/[to]. Order-independent so downgrades surface what
  /// would be *lost* the same way upgrades surface what is *gained*.
  List<UpgradeNote> entriesBetween(SemVer from, SemVer to) {
    final (lower, upper) = from < to ? (from, to) : (to, from);
    return [
      for (final entry in _entries)
        if (entry.introducedIn > lower && entry.introducedIn <= upper)
          UpgradeNote(
            text: '${entry.introducedIn}: ${entry.text}',
            link: entry.link,
          ),
    ];
  }
}

final _builtinEntries = <KnowledgeEntry>[
  KnowledgeEntry(
    introducedIn: '3.10.0',
    text:
        'Dart 3: sound null safety is mandatory; records, patterns, and '
        'class modifiers land. Impeller becomes the default iOS renderer.',
    link: 'https://docs.flutter.dev/release/breaking-changes',
  ),
  KnowledgeEntry(
    introducedIn: '3.16.0',
    text:
        'Material 3 is enabled by default (ThemeData.useMaterial3 now '
        'defaults to true) — visual changes across Material widgets.',
    link:
        'https://docs.flutter.dev/release/breaking-changes/material-3-migration',
  ),
  KnowledgeEntry(
    introducedIn: '3.22.0',
    text: 'WebAssembly (Wasm) compilation is stable for Flutter web.',
  ),
  KnowledgeEntry(
    introducedIn: '3.24.0',
    text:
        'Initial Swift Package Manager support for iOS/macOS plugins; '
        'some plugin tooling behavior changes.',
  ),
  KnowledgeEntry(
    introducedIn: '3.27.0',
    text:
        'Impeller becomes the default Android renderer on modern API '
        'levels — verify custom shaders and exotic GL usage.',
  ),
  KnowledgeEntry(
    introducedIn: '3.29.0',
    text: 'The dev channel and various legacy tooling flags are removed.',
  ),
];
