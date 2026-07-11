import 'package:flutterx_domain/src/entities/candidate_set.dart';
import 'package:flutterx_domain/src/entities/recommendation.dart';

/// Ranks allowed candidates into an explainable recommendation
/// (docs/03 §5): weighted additive scoring, every contribution recorded as
/// a `Reason`, deterministic version-descending tiebreak, confidence from
/// score gap and evidence strength.
abstract interface class RecommendationEngine {
  /// [candidates] must be non-empty — an empty set never reaches ranking
  /// (the solver's conflict explanation short-circuits, docs/03 §5 edge
  /// cases).
  Recommendation rank(CandidateSet candidates, Signals signals);
}
