import 'package:flutterx_domain/flutterx_domain.dart';

/// The git progress phases we surface, with friendlier labels. `git
/// fetch`/`checkout` write CR-delimited lines like
/// `Receiving objects:  45% (5000/11000), 12.50 MiB | 3.20 MiB/s` to
/// stderr with `--progress`.
const _phaseLabels = {
  'Counting objects': 'counting objects',
  'Compressing objects': 'compressing',
  'Receiving objects': 'downloading',
  'Resolving deltas': 'resolving',
  'Updating files': 'checking out',
};

final _progressPattern = RegExp(
  r'^(Counting objects|Compressing objects|Receiving objects|'
  r'Resolving deltas|Updating files):\s+(\d+)%',
);

/// Parses one git stderr progress line into a [ProgressEvent], or `null`
/// when the line is not a progress update. Pure — unit-testable without
/// spawning git.
ProgressEvent? parseGitProgressLine(String line, {required String phase}) {
  final match = _progressPattern.firstMatch(line.trim());
  if (match == null) return null;
  final label = _phaseLabels[match.group(1)!]!;
  final percent = int.parse(match.group(2)!);
  // Keep the byte/rate tail if present — it is the useful part.
  final tail = line.trim().replaceFirst(RegExp(r'^[^,]*,\s*'), '');
  final hasRate = tail.contains('|');
  return ProgressEvent(
    phase: phase,
    message: hasRate ? '$label — $tail' : '$label $percent%',
    fraction: percent / 100,
  );
}
