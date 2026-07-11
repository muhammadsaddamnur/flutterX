import 'package:flutterx_domain/src/entities/diagnosis.dart';

/// Matches health probes against the failure catalogue (docs/03 §9.1) and
/// emits diagnoses with fix plans, ordered by severity then dependency
/// (e.g. bare repo before worktrees).
///
/// Pure: probing (I/O) happens in the application layer; `doctor` prints
/// these diagnoses, `repair` additionally executes the plans
/// (docs/03 §9.2).
abstract interface class RepairPlanner {
  List<Diagnosis> diagnose(HealthProbes probes);
}
