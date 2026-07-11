// Architecture dependency-rule check (docs/06 §1, docs/08 §1).
//
// Enforces, over every Dart file under packages/*/lib and packages/*/bin:
//   1. Inward-only package imports per the allowed-dependency matrix.
//   2. No `dart:io` (or other I/O SDK libraries) inside flutterx_intelligence
//      or flutterx_domain — engines are pure (docs/02 ADR-4).
//   3. No importing another package's `src/` — barrels only.
//   4. flutterx_cli may import infrastructure packages only from its
//      composition root (docs/06 §9).
//
// Run: dart run tool/check_dependency_rule.dart
// Exit code 0 = clean, 1 = violations found (printed one per line).

import 'dart:io';

/// Allowed `flutterx_*` package imports per package (docs/06 §1 graph).
const allowedDeps = <String, Set<String>>{
  'flutterx_domain': {},
  'flutterx_intelligence': {'flutterx_domain'},
  'flutterx_application': {'flutterx_domain', 'flutterx_intelligence'},
  'flutterx_git': {'flutterx_domain'},
  // storage composes GitEngine into its SdkRepository impl (docs/06 §5).
  'flutterx_storage': {'flutterx_domain', 'flutterx_git'},
  'flutterx_registry': {'flutterx_domain'},
  'flutterx_platform': {'flutterx_domain'},
  'flutterx_cli': {
    'flutterx_domain',
    'flutterx_application',
    'flutterx_git',
    'flutterx_storage',
    'flutterx_registry',
    'flutterx_platform',
  },
};

/// Packages whose engines must stay pure: no I/O SDK libraries.
const purePackages = {'flutterx_domain', 'flutterx_intelligence'};

/// SDK libraries considered I/O for the purity rule.
const ioSdkLibs = {'dart:io', 'dart:ffi', 'dart:isolate'};

/// Infrastructure packages the CLI may only touch in its composition root.
const infraPackages = {
  'flutterx_git',
  'flutterx_storage',
  'flutterx_registry',
  'flutterx_platform',
};

final importPattern = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  final packagesDir = Directory('packages');
  if (!packagesDir.existsSync()) {
    stderr.writeln('check_dependency_rule: run from the repository root.');
    exit(2);
  }

  final violations = <String>[];

  for (final pkgDir in packagesDir.listSync().whereType<Directory>()) {
    final pkgName = pkgDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final allowed = allowedDeps[pkgName];
    if (allowed == null) {
      violations.add(
        '$pkgName: unknown package — add it to the matrix in '
        'tool/check_dependency_rule.dart and docs/06 §1.',
      );
      continue;
    }

    for (final sub in const ['lib', 'bin']) {
      final dir = Directory('${pkgDir.path}/$sub');
      if (!dir.existsSync()) continue;
      for (final file
          in dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        checkFile(file, pkgName, allowed, violations);
      }
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('dependency-rule check: OK');
    return;
  }
  stderr.writeln('dependency-rule check: ${violations.length} violation(s)');
  for (final v in violations) {
    stderr.writeln('  ✗ $v');
  }
  exit(1);
}

void checkFile(
  File file,
  String pkgName,
  Set<String> allowed,
  List<String> violations,
) {
  final content = file.readAsStringSync();
  final isCompositionRoot =
      pkgName == 'flutterx_cli' && file.path.endsWith('composition_root.dart');

  for (final match in importPattern.allMatches(content)) {
    final uri = match.group(1)!;

    if (uri.startsWith('dart:')) {
      if (purePackages.contains(pkgName) && ioSdkLibs.contains(uri)) {
        violations.add(
          '${file.path}: imports $uri — $pkgName must stay pure '
          '(docs/02 ADR-4, docs/08 §1 rule 2).',
        );
      }
      continue;
    }

    if (!uri.startsWith('package:')) continue; // relative import, same package
    final target = uri.substring('package:'.length).split('/').first;

    if (target.startsWith('flutterx_')) {
      if (target == pkgName) continue;
      if (!allowed.contains(target)) {
        violations.add(
          '${file.path}: imports $uri — $pkgName may only depend on '
          '{${allowed.join(', ')}} (docs/06 §1).',
        );
      } else if (pkgName == 'flutterx_cli' &&
          infraPackages.contains(target) &&
          !isCompositionRoot) {
        violations.add(
          '${file.path}: imports infrastructure $uri outside '
          'composition_root.dart (docs/06 §9).',
        );
      }
      if (uri.contains('/src/')) {
        violations.add(
          '${file.path}: imports $uri — cross-package src/ imports are '
          'forbidden; use the barrel (docs/08 §2).',
        );
      }
    }
  }
}
