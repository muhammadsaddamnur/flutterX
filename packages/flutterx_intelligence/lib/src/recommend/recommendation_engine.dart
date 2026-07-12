import 'dart:math' as math;

import 'package:flutterx_domain/flutterx_domain.dart';

/// The scoring weights (docs/03 §5.1) — config-tunable, shipped with the
/// documented defaults. Validated at load time (T2.4.4), never at
/// decision time.
final class RecommendationWeights {
  const RecommendationWeights({
    this.hintMatch = 30,
    this.latestPatch = 20,
    this.compatibilityMax = 40,
    this.stableChannel = 15,
    this.recencyMax = 10,
    this.alreadyInstalled = 8,
  });

  final int hintMatch;
  final int latestPatch;
  final int compatibilityMax;
  final int stableChannel;
  final int recencyMax;
  final int alreadyInstalled;

  /// Half-life of the recency signal (docs/03 §5.1).
  static const recencyHalfLife = Duration(days: 180);

  /// Parses `recommend.weights.<name>` overrides, rejecting invalid
  /// values at config-load time (docs/03 §5 edge cases).
  static Result<RecommendationWeights> fromSettings(
    Map<String, String> settings,
  ) {
    const defaults = RecommendationWeights();

    int parse(String name, int fallback, List<String> problems) {
      final raw = settings['recommend.weights.$name'];
      if (raw == null) return fallback;
      final value = int.tryParse(raw);
      if (value == null || value < 0) {
        problems.add('recommend.weights.$name: "$raw" (non-negative integer)');
        return fallback;
      }
      return value;
    }

    final problems = <String>[];
    final weights = RecommendationWeights(
      hintMatch: parse('hintMatch', defaults.hintMatch, problems),
      latestPatch: parse('latestPatch', defaults.latestPatch, problems),
      compatibilityMax: parse(
        'compatibilityMax',
        defaults.compatibilityMax,
        problems,
      ),
      stableChannel: parse('stableChannel', defaults.stableChannel, problems),
      recencyMax: parse('recencyMax', defaults.recencyMax, problems),
      alreadyInstalled: parse(
        'alreadyInstalled',
        defaults.alreadyInstalled,
        problems,
      ),
    );
    if (problems.isNotEmpty) {
      return Result.err(
        StorageFailure(
          code: 'FX-CONF-002',
          message: 'invalid recommendation weights: ${problems.join('; ')}',
          nextActions: const ['fix the config value or unset it'],
        ),
      );
    }
    return Result.ok(weights);
  }
}

/// [RecommendationEngine] per docs/03 §5: weighted additive scoring with
/// every contribution recorded as a [Reason], deterministic
/// version-descending tiebreak, and confidence from the score gap and
/// evidence strength.
final class StandardRecommendationEngine implements RecommendationEngine {
  StandardRecommendationEngine({this.weights = const RecommendationWeights()});

  final RecommendationWeights weights;

  @override
  Recommendation rank(CandidateSet candidates, Signals signals) {
    assert(candidates.candidates.isNotEmpty, 'empty sets never reach ranking');

    // A pin decided upstream — ranking degenerates, confidence is high.
    if (candidates.isPinned) {
      final release = candidates.candidates.single;
      final pin = candidates.pinProvenance!;
      return Recommendation(
        chosen: ScoredCandidate(
          release: release,
          score: 0,
          contributions: [
            Reason(text: 'pinned to ${pin.version} via ${pin.origin}'),
          ],
        ),
        confidence: Confidence.high,
      );
    }

    final scored =
        [
          for (final release in candidates.candidates)
            _score(release, candidates.candidates, signals),
        ]..sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          // Deterministic tiebreak: higher version wins (docs/03 §5.1).
          return byScore != 0
              ? byScore
              : b.release.version.compareTo(a.release.version);
        });

    return Recommendation(
      chosen: scored.first,
      alternatives: scored.skip(1).take(2).toList(),
      confidence: _confidence(scored, signals.evidence),
    );
  }

  ScoredCandidate _score(
    FlutterRelease release,
    List<FlutterRelease> all,
    Signals signals,
  ) {
    final reasons = <Reason>[];

    void add(int delta, String text) {
      if (delta != 0) reasons.add(Reason(text: text, delta: delta));
    }

    // Hint matches: familiarity beats recency by design (docs/03 §10).
    for (final hint in signals.evidence.hints) {
      final matches = hint.exactPatch
          ? hint.version == release.version
          : hint.version.sameMinorAs(release.version);
      if (matches) {
        add(weights.hintMatch, '${hint.origin} points at ${hint.version}');
      }
    }

    final isLatestPatch = !all.any(
      (other) =>
          other.channel == release.channel &&
          other.version.sameMinorAs(release.version) &&
          other.version > release.version,
    );
    if (isLatestPatch) {
      add(
        weights.latestPatch,
        '${release.version} is the latest patch of its minor',
      );
    }

    final compatibility = signals.compatibility[release.version];
    if (compatibility != null && compatibility.total > 0) {
      if (compatibility.hasIncompatible) {
        // Zero contribution, but the *why* must still show in --explain.
        reasons.add(
          Reason(
            text:
                'incompatible packages: '
                '${compatibility.incompatible.join(', ')}',
          ),
        );
      } else {
        final delta =
            (weights.compatibilityMax * compatibility.verified) ~/
            compatibility.total;
        add(
          delta,
          '${compatibility.verified}/${compatibility.total} '
          'packages verified compatible',
        );
      }
    }

    if (release.channel == Channel.stable) {
      add(weights.stableChannel, 'stable channel');
    }

    final ageDays = signals.now.difference(release.releasedAt).inDays;
    if (ageDays >= 0) {
      final recency =
          (weights.recencyMax *
                  math.pow(
                    2,
                    -ageDays / RecommendationWeights.recencyHalfLife.inDays,
                  ))
              .round();
      add(recency, 'released $ageDays days ago');
    }

    final ruleDelta = signals.ruleModifiers[release.version];
    if (ruleDelta != null) add(ruleDelta, 'rule adjustments');

    if (signals.installed.contains(release.version)) {
      add(weights.alreadyInstalled, 'already installed');
    }

    return ScoredCandidate(
      release: release,
      score: reasons.fold(0, (sum, reason) => sum + reason.delta),
      contributions: reasons,
    );
  }

  Confidence _confidence(
    List<ScoredCandidate> scored,
    ProjectEvidence evidence,
  ) {
    // Only soft evidence → the choice is a guess, however scored
    // (docs/03 §5.2).
    final hasHardEvidence =
        evidence.hard.isNotEmpty || evidence.pins.isNotEmpty;
    if (!hasHardEvidence) return Confidence.low;
    if (scored.length == 1) return Confidence.high;
    final gap = scored[0].score - scored[1].score;
    return gap >= 25 ? Confidence.high : Confidence.medium;
  }
}

/// Renders the `--explain` breakdown (docs/03 §5.3 example shape). Pure
/// text building — the CLI prints it verbatim.
String explainRecommendation(Recommendation recommendation) {
  final chosen = recommendation.chosen;
  final buffer = StringBuffer()
    ..writeln(
      'Resolved: Flutter ${chosen.release.version} '
      '(Dart ${chosen.release.dartVersion}) — confidence: '
      '${recommendation.confidence.name}',
    )
    ..writeln();
  for (final reason in chosen.contributions) {
    final delta = reason.delta == 0
        ? '     '
        : '${reason.delta > 0 ? '+' : ''}${reason.delta}'.padLeft(5);
    buffer.writeln('  $delta  ${reason.text}');
  }
  buffer.writeln('  ─────');
  buffer.writeln('  ${'${chosen.score}'.padLeft(5)}  total');
  for (final alt in recommendation.alternatives) {
    buffer.writeln('         vs. ${alt.release.version} (score ${alt.score})');
  }
  return buffer.toString();
}
