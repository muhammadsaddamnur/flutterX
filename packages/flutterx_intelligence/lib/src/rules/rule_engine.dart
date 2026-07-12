import 'package:flutterx_domain/flutterx_domain.dart';

/// The Rule Engine's output for one candidate set (docs/03 §4.1): the
/// survivors, the denial table, and per-version score modifiers with their
/// reasons (fed to the Recommendation Engine as `Signals.ruleModifiers`).
final class RuleEngineResult {
  RuleEngineResult({
    required List<FlutterRelease> allowed,
    required List<({String candidate, String ruleId, String reason})> denials,
    required Map<SemVer, int> modifiers,
    required Map<SemVer, List<Reason>> modifierReasons,
  }) : allowed = List.unmodifiable(allowed),
       denials = List.unmodifiable(denials),
       modifiers = Map.unmodifiable(modifiers),
       modifierReasons = Map.unmodifiable(modifierReasons);

  final List<FlutterRelease> allowed;
  final List<({String candidate, String ruleId, String reason})> denials;

  /// Net prefer/penalize delta per allowed version.
  final Map<SemVer, int> modifiers;

  /// The explainable trail behind each modifier.
  final Map<SemVer, List<Reason>> modifierReasons;

  bool get allDenied => allowed.isEmpty;
}

/// Aggregates [Rule]s over a candidate set (docs/03 §4.1): rules are
/// evaluated independently per candidate, deny wins over everything,
/// penalties/preferences accumulate — order-independent by construction.
final class RuleEngine {
  RuleEngine(List<Rule> rules) : _rules = List.unmodifiable(rules);

  final List<Rule> _rules;

  RuleEngineResult apply(List<FlutterRelease> candidates, RuleContext context) {
    final allowed = <FlutterRelease>[];
    final denials = <({String candidate, String ruleId, String reason})>[];
    final modifiers = <SemVer, int>{};
    final modifierReasons = <SemVer, List<Reason>>{};

    for (final release in candidates) {
      var denied = false;
      var delta = 0;
      final reasons = <Reason>[];
      for (final rule in _rules) {
        final verdict = rule.evaluate(release, context);
        switch (verdict.action) {
          case RuleAction.deny:
            denials.add((
              candidate: '${release.version}',
              ruleId: rule.id,
              reason: verdict.reason,
            ));
            denied = true;
          case RuleAction.penalize || RuleAction.prefer:
            delta += verdict.scoreDelta;
            reasons.add(
              Reason(
                text: '${rule.id}: ${verdict.reason}',
                delta: verdict.scoreDelta,
              ),
            );
          case RuleAction.allow:
            break;
        }
      }
      if (denied) continue;
      allowed.add(release);
      if (delta != 0) {
        modifiers[release.version] = delta;
        modifierReasons[release.version] = reasons;
      }
    }

    return RuleEngineResult(
      allowed: allowed,
      denials: denials,
      modifiers: modifiers,
      modifierReasons: modifierReasons,
    );
  }

  /// The exit-13 story (docs/03 §4.3): every candidate denied → the denial
  /// table plus the *single-relaxation* suggestion, computed by re-running
  /// with each rule disabled (cheap at this scale).
  PolicyDenied explainAllDenied(
    List<FlutterRelease> candidates,
    RuleContext context,
    RuleEngineResult result,
  ) {
    final unblockers = <String>[];
    for (final rule in _rules) {
      final without = RuleEngine(
        [..._rules]..removeWhere((r) => r.id == rule.id),
      ).apply(candidates, context);
      if (!without.allDenied) {
        unblockers.add(
          'relaxing ${rule.id} would unblock '
          '${without.allowed.length} candidate(s)',
        );
      }
    }
    return PolicyDenied(
      message: 'all ${candidates.length} candidate(s) denied by policy',
      denials: result.denials,
      nextActions: unblockers.isEmpty
          ? const ['no single rule relaxation unblocks — review the policy']
          : unblockers,
    );
  }
}
