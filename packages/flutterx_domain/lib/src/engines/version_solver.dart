import 'package:flutterx_domain/src/entities/candidate_set.dart';
import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/registry_snapshot.dart';

/// Narrows the registry to releases that can satisfy the evidence
/// (docs/03 §3): honors pins, intersects hard constraints (translating Dart
/// constraints through the registry mapping), and records a provenance
/// trace. An empty result carries the conflict trace for the minimal
/// conflicting pair explanation.
abstract interface class VersionSolver {
  CandidateSet solve(ProjectEvidence evidence, RegistrySnapshot snapshot);
}
