import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/src/rules/builtin_rules.dart';

/// One source of rule settings (docs/03 §4.3): org file, workspace,
/// project `flutterx.yaml`, or global config. Settings are flat
/// dot-notation entries under `rules.<id>.<key>`.
final class PolicyLayer {
  PolicyLayer({
    required this.source,
    Map<String, String> settings = const {},
    Set<String> lockedRules = const {},
  }) : settings = Map.unmodifiable(settings),
       lockedRules = Set.unmodifiable(lockedRules);

  final String source;
  final Map<String, String> settings;

  /// Rules this layer freezes: later (more specific) layers may not touch
  /// them at all (`lockdown`, docs/03 §4.3).
  final Set<String> lockedRules;
}

/// The merged outcome: effective settings plus warnings for ignored
/// entries (loosening attempts, locked rules, unknown rule ids).
final class MergedPolicy {
  MergedPolicy({
    required Map<String, String> settings,
    required List<ScanWarning> warnings,
  }) : settings = Map.unmodifiable(settings),
       warnings = List.unmodifiable(warnings);

  final Map<String, String> settings;
  final List<ScanWarning> warnings;
}

const _knownRuleIds = {
  'deny-retracted',
  'channel-policy',
  'min-version-floor',
  'deny-list',
  'allow-list',
  'freshness-window',
  'prefer-lts-like',
};

int _channelRank(String value) => switch (value) {
  'any' => 3,
  'beta' => 2,
  _ => 1, // stable
};

/// Merges layers ordered broad → specific (docs/03 §4.3 precedence chain
/// reversed): a more specific layer may only *tighten* what an earlier
/// layer set, and may never touch a rule an earlier layer locked.
/// Violations are ignored with a warning — policy is enforced, not
/// crashed on.
MergedPolicy mergePolicyLayers(List<PolicyLayer> broadToSpecific) {
  final settings = <String, String>{};
  final settingSource = <String, String>{};
  final locked = <String, String>{}; // rule id → locking layer source
  final warnings = <ScanWarning>[];

  for (final layer in broadToSpecific) {
    for (final entry in layer.settings.entries) {
      final parts = entry.key.split('.');
      if (parts.length < 3 || parts.first != 'rules') {
        warnings.add(
          ScanWarning(
            code: 'bad-policy-key',
            message: '"${entry.key}" is not rules.<id>.<key>',
            origin: layer.source,
          ),
        );
        continue;
      }
      final ruleId = parts[1];
      if (!_knownRuleIds.contains(ruleId)) {
        // Forward compatibility (docs/03 §4.3): warn + ignore.
        warnings.add(
          ScanWarning(
            code: 'unknown-rule',
            message: 'unknown rule "$ruleId" — ignored',
            origin: layer.source,
          ),
        );
        continue;
      }
      if (locked.containsKey(ruleId)) {
        warnings.add(
          ScanWarning(
            code: 'locked-rule',
            message:
                '"$ruleId" is locked by ${locked[ruleId]} — '
                'setting from ${layer.source} ignored',
            origin: layer.source,
          ),
        );
        continue;
      }
      final existing = settings[entry.key];
      if (existing != null && !_tightens(entry.key, existing, entry.value)) {
        warnings.add(
          ScanWarning(
            code: 'loosening-ignored',
            message:
                '"${entry.key}: ${entry.value}" would loosen the value '
                'set by ${settingSource[entry.key]} ("$existing") — ignored',
            origin: layer.source,
          ),
        );
        continue;
      }
      settings[entry.key] = entry.value;
      settingSource[entry.key] = layer.source;
    }
    for (final ruleId in layer.lockedRules) {
      locked.putIfAbsent(ruleId, () => layer.source);
    }
  }
  return MergedPolicy(settings: settings, warnings: warnings);
}

/// Whether [next] is at least as strict as [current] for a known key
/// (docs/03 §4.3 "may only tighten").
bool _tightens(String key, String current, String next) {
  switch (key) {
    case 'rules.channel-policy.allow':
      return _channelRank(next) <= _channelRank(current);
    case 'rules.min-version-floor.version':
      try {
        return SemVer.parse(next) >= SemVer.parse(current);
      } on FormatException {
        return false;
      }
    case 'rules.freshness-window.days':
      final currentDays = int.tryParse(current);
      final nextDays = int.tryParse(next);
      return currentDays != null && nextDays != null && nextDays <= currentDays;
    case 'rules.deny-list.versions':
      return _csv(next).containsAll(_csv(current)); // may only grow
    case 'rules.allow-list.versions':
      return _csv(current).containsAll(_csv(next)); // may only shrink
    case 'rules.deny-retracted.enabled':
      return !(current == 'true' && next == 'false'); // never disable below
    default:
      return true; // preferences (prefer-lts-like) are not gates
  }
}

Set<String> _csv(String value) =>
    value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

/// Instantiates the built-in rule set from merged settings (docs/03 §4.2
/// defaults: deny-retracted and prefer-lts-like on, everything else off).
List<Rule> buildRules(Map<String, String> settings) {
  final rules = <Rule>[];
  if (settings['rules.deny-retracted.enabled'] != 'false') {
    rules.add(DenyRetractedRule());
  }
  rules.add(
    ChannelPolicyRule(
      allow: settings['rules.channel-policy.allow'] ?? 'stable',
    ),
  );
  final floor = settings['rules.min-version-floor.version'];
  if (floor != null) {
    try {
      rules.add(MinVersionFloorRule(floor: SemVer.parse(floor)));
    } on FormatException {
      // Invalid floor: config validation surfaces it; no rule added.
    }
  }
  final denyList = settings['rules.deny-list.versions'];
  if (denyList != null) rules.add(DenyListRule(versions: _csv(denyList)));
  final allowList = settings['rules.allow-list.versions'];
  if (allowList != null) rules.add(AllowListRule(versions: _csv(allowList)));
  final freshnessDays = int.tryParse(
    settings['rules.freshness-window.days'] ?? '',
  );
  if (freshnessDays != null) {
    rules.add(FreshnessWindowRule(maxAge: Duration(days: freshnessDays)));
  }
  if (settings['rules.prefer-lts-like.enabled'] != 'false') {
    rules.add(PreferLtsLikeRule());
  }
  return rules;
}
