import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/flutter_release.dart';

/// What a rule decided for one candidate (docs/03 §4.1).
enum RuleAction { allow, deny, penalize, prefer }

/// A rule's verdict for one candidate. [scoreDelta] applies only to
/// `penalize` (negative) and `prefer` (positive) and feeds the
/// Recommendation Engine.
final class RuleVerdict {
  const RuleVerdict.allow()
    : action = RuleAction.allow,
      reason = '',
      scoreDelta = 0;

  const RuleVerdict.deny(this.reason)
    : action = RuleAction.deny,
      scoreDelta = 0;

  const RuleVerdict.penalize(this.scoreDelta, this.reason)
    : action = RuleAction.penalize,
      assert(scoreDelta < 0, 'penalty must be negative');

  const RuleVerdict.prefer(this.scoreDelta, this.reason)
    : action = RuleAction.prefer,
      assert(scoreDelta > 0, 'preference must be positive');

  final RuleAction action;

  /// Human-readable reason shown in `--explain` and denial tables.
  final String reason;

  final int scoreDelta;
}

/// Ambient facts rules may consult (docs/03 §4.1). Extended as rules need
/// more context; kept explicit so rules stay pure and testable.
final class RuleContext {
  const RuleContext({
    required this.evidence,
    required this.newestKnown,
    required this.now,
    this.candidates = const [],
  });

  final ProjectEvidence evidence;

  /// The newest non-retracted release in the snapshot (for freshness/latest
  /// comparisons).
  final FlutterRelease? newestKnown;

  /// Injected clock (freshness windows) — rules never read wall time.
  final DateTime now;

  /// The full candidate set under evaluation — read-only context for
  /// relative judgments like "latest patch of its minor"
  /// (`prefer-lts-like`, docs/03 §4.2). Rules stay order-independent.
  final List<FlutterRelease> candidates;
}

/// A policy rule (docs/03 §4). Evaluated independently per candidate;
/// deny wins over everything; order-independence keeps rules composable.
/// Registered via config — team policies are just rules (docs/02 §10.1).
abstract interface class Rule {
  /// Stable id used in config and explanations, e.g. `channel-policy`.
  String get id;

  RuleVerdict evaluate(FlutterRelease release, RuleContext context);
}
