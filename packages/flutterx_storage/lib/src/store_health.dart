import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/src/file_journal.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:path/path.dart' as p;

/// [StoreHealthPort] over the store layout (docs/03 §9.2): read-only
/// observations; the probe kinds line up with the repair catalogue ids so
/// M2.7's RepairPlanner can match them 1:1.
final class StoreHealth implements StoreHealthPort {
  StoreHealth({required this.layout, required this.git, required this.journal});

  final StoreLayout layout;
  final GitEngine git;
  final FileJournal journal;

  @override
  Future<List<Probe>> probeStore() async {
    final probes = <Probe>[];

    // state.json readable + schema supported (fatal when not).
    final state = await layout.loadState();
    switch (state) {
      case Err(:final failure):
        probes.add(
          Probe(
            kind: 'store-state',
            subject: layout.stateFile,
            ok: false,
            detail: failure.message,
            severity: Severity.error,
          ),
        );
        return probes; // nothing else is trustworthy
      case Ok():
        probes.add(
          Probe(kind: 'store-state', subject: layout.stateFile, ok: true),
        );
    }

    // Bare repo integrity (FX-R04). Absent repo = clean cold store.
    if (Directory(layout.bareRepoDir).existsSync()) {
      final health = await git.fsck();
      probes.add(
        Probe(
          kind: 'bare-repo',
          subject: layout.bareRepoDir,
          ok: health.healthy,
          detail: health.healthy ? 'fsck clean' : health.issues.join('; '),
          severity: Severity.error,
        ),
      );
    } else {
      probes.add(
        Probe(
          kind: 'bare-repo',
          subject: layout.bareRepoDir,
          ok: true,
          detail: 'not created yet (no SDKs installed)',
        ),
      );
    }

    // Half-installed versions: worktree without manifest (FX-R03 family).
    final versionsDir = Directory(layout.versionsDir);
    if (versionsDir.existsSync()) {
      await for (final dir in versionsDir.list()) {
        if (dir is! Directory) continue;
        final version = p.basename(dir.path);
        final hasManifest = File(layout.versionManifest(version)).existsSync();
        probes.add(
          Probe(
            kind: 'version-manifest',
            subject: version,
            ok: hasManifest,
            detail: hasManifest ? null : 'worktree without manifest',
          ),
        );
      }
    }

    // Interrupted operations (FX-R08).
    final uncommitted = await journal.uncommitted();
    probes.add(
      Probe(
        kind: 'journal',
        subject: layout.journalDir,
        ok: uncommitted.isEmpty,
        detail: uncommitted.isEmpty
            ? null
            : '${uncommitted.length} interrupted operation(s): '
                  '${uncommitted.map((e) => '${e.operation} ${e.target}').join(', ')}',
      ),
    );

    // Orphaned versions (FX-R06): installed but referenced by no live
    // project.
    final referenced = (state.valueOrNull!.projects)
        .where((ref) => Directory(ref.path).existsSync())
        .map((ref) => ref.version)
        .toSet();
    if (versionsDir.existsSync()) {
      await for (final dir in versionsDir.list()) {
        if (dir is! Directory) continue;
        final version = p.basename(dir.path);
        if (!referenced.contains(version)) {
          probes.add(
            Probe(
              kind: 'orphan-version',
              subject: version,
              ok: false,
              detail:
                  'no project references it — `flutterx cache gc` '
                  '(from M2.8) reclaims',
            ),
          );
        }
      }
    }
    return probes;
  }

  @override
  Future<List<Probe>> probeProject(Project project) async {
    final probes = <Probe>[];
    final lockFile = File(
      p.join(project.rootPath, '.flutterx', 'resolution.lock'),
    );
    if (!lockFile.existsSync()) {
      probes.add(
        Probe(
          kind: 'project-lock',
          subject: project.rootPath,
          ok: true,
          detail: 'unresolved — run `flutterx use <version>`',
        ),
      );
      return probes;
    }

    final link = Link(p.join(project.rootPath, '.flutterx', 'sdk'));
    final linkOk =
        link.existsSync() && Directory(link.targetSync()).existsSync();
    probes.add(
      Probe(
        kind: 'project-link',
        subject: link.path,
        ok: linkOk,
        detail: linkOk ? null : 'missing or dangling (FX-R01)',
      ),
    );
    return probes;
  }
}
