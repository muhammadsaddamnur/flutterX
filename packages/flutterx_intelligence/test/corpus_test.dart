import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

/// The resolution-accuracy corpus (T2.9.1, docs/07 M2.9): real-world
/// shaped projects with expected outcomes, run through the full pure
/// pipeline (scan → solve → rules → rank) against a pinned registry
/// snapshot. Every committed case must pass — growing this toward the
/// ~50-project corpus is ongoing work.
///
/// Case layout: `test/corpus/cases/<name>/` with evidence files encoded as
/// `f_<path with __ for />` (never name a fixture `pubspec.yaml` — pub
/// adopts it) plus `expected.yaml`.
void main() {
  final snapshot = _loadSnapshot();
  final now = DateTime.utc(2026, 7, 13);
  final casesDir = Directory('test/corpus/cases');

  for (final caseDir
      in casesDir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path))) {
    final name = caseDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    test('corpus: $name', () {
      final expected = _flatYaml(
        File('${caseDir.path}/expected.yaml').readAsStringSync(),
      );
      final outcome = _resolve(_loadEvidence(caseDir), snapshot, now);

      if (expected['conflict'] == 'true') {
        expect(outcome.conflict, isTrue, reason: 'expected a solve conflict');
        return;
      }
      if (expected['denied'] == 'true') {
        expect(outcome.denied, isTrue, reason: 'expected policy denial');
        return;
      }
      expect(outcome.recommendation, isNotNull, reason: outcome.toString());
      final chosen = outcome.recommendation!.chosen.release;
      expect('${chosen.version}', expected['flutter']);
      if (expected['confidence'] case final confidence?) {
        expect(outcome.recommendation!.confidence.name, confidence);
      }
      if (expected['warning'] case final warning?) {
        expect(
          outcome.warnings.map((w) => w.code),
          contains(warning),
          reason: 'expected warning $warning',
        );
      }
    });
  }
}

// ── The pure pipeline, exactly as ResolveProject conducts it ─────────────

final class _Outcome {
  _Outcome({
    this.recommendation,
    this.conflict = false,
    this.denied = false,
    this.warnings = const [],
  });

  final Recommendation? recommendation;
  final bool conflict;
  final bool denied;
  final List<ScanWarning> warnings;

  @override
  String toString() =>
      'conflict=$conflict denied=$denied '
      'chosen=${recommendation?.chosen.release.version}';
}

_Outcome _resolve(
  EvidenceFiles files,
  RegistrySnapshot snapshot,
  DateTime now,
) {
  final evidence = StandardProjectScanner().scan(files);
  final solver = StandardVersionSolver();
  final solved = solver.solve(evidence, snapshot);
  if (solved.isEmpty) return _Outcome(conflict: true);

  var allowed = solved;
  var modifiers = const <SemVer, int>{};
  if (!solved.isPinned) {
    final engine = RuleEngine(buildRules(const {}));
    final context = RuleContext(
      evidence: evidence,
      newestKnown: snapshot.releases.where((r) => !r.retracted).firstOrNull,
      now: now,
      candidates: solved.candidates,
    );
    final ruled = engine.apply(solved.candidates, context);
    if (ruled.allDenied) {
      return _Outcome(denied: true, warnings: evidence.warnings);
    }
    allowed = CandidateSet.solved(ruled.allowed, solved.trace);
    modifiers = ruled.modifiers;
  }

  return _Outcome(
    recommendation: StandardRecommendationEngine().rank(
      allowed,
      Signals(evidence: evidence, ruleModifiers: modifiers, now: now),
    ),
    warnings: evidence.warnings,
  );
}

// ── Fixture loading ───────────────────────────────────────────────────────

EvidenceFiles _loadEvidence(Directory caseDir) => EvidenceFiles(
  files: {
    for (final entry in caseDir.listSync().whereType<File>())
      if (_fileName(entry).startsWith('f_'))
        _fileName(entry).substring(2).replaceAll('__', '/'): entry
            .readAsStringSync(),
  },
);

String _fileName(File file) => file.uri.pathSegments.last;

RegistrySnapshot _loadSnapshot() {
  final json =
      jsonDecode(File('test/corpus/registry_snapshot.json').readAsStringSync())
          as Map<String, Object?>;
  return RegistrySnapshot(
    releases: [
      for (final raw in json['releases']! as List<Object?>)
        FlutterRelease(
          version: SemVer.parse(
            (raw! as Map<String, Object?>)['version']! as String,
          ),
          channel: Channel.tryParse(
            (raw as Map<String, Object?>)['channel']! as String,
          )!,
          gitTag: raw['version']! as String,
          frameworkSha: 'corpus',
          dartVersion: SemVer.parse(raw['dart']! as String),
          releasedAt: DateTime.parse(raw['releasedAt']! as String),
          artifacts: const {},
          retracted: raw['retracted'] == true,
        ),
    ],
    fetchedAt: DateTime.utc(2026, 7, 13),
    source: 'corpus',
  );
}

/// Minimal flat `key: value` reader for expected.yaml — no YAML dep needed
/// for two-line files.
Map<String, String> _flatYaml(String content) => {
  for (final line in content.split('\n'))
    if (line.contains(':'))
      line.split(':').first.trim(): line.split(':').sublist(1).join(':').trim(),
};
