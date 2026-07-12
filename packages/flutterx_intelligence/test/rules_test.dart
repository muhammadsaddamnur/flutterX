import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

FlutterRelease release(
  String version, {
  Channel channel = Channel.stable,
  bool retracted = false,
  DateTime? releasedAt,
}) => FlutterRelease(
  version: SemVer.parse(version),
  channel: channel,
  gitTag: version,
  frameworkSha: 'sha',
  dartVersion: SemVer.parse('3.4.3'),
  releasedAt: releasedAt ?? DateTime.utc(2026, 6, 1),
  artifacts: const {},
  retracted: retracted,
);

final now = DateTime.utc(2026, 7, 11);

RuleContext context(List<FlutterRelease> candidates) => RuleContext(
  evidence: ProjectEvidence(),
  newestKnown: candidates.isEmpty ? null : candidates.first,
  now: now,
  candidates: candidates,
);

void main() {
  group('RuleEngine aggregation (T2.3.1)', () {
    test('deny wins over prefer; modifiers accumulate for survivors', () {
      final candidates = [
        release('3.22.3', retracted: true), // denied despite being latest
        release('3.22.2'),
        release('3.22.1'),
      ];
      final engine = RuleEngine([DenyRetractedRule(), PreferLtsLikeRule()]);
      final result = engine.apply(candidates, context(candidates));

      expect(result.allowed.map((r) => '${r.version}'), ['3.22.2', '3.22.1']);
      expect(result.denials.single.ruleId, 'deny-retracted');
      // prefer-lts-like judges against the full candidate set: retracted
      // 3.22.3 still counts as the newest 3.22.x, so no survivor earns the
      // latest-patch bonus.
      expect(result.modifiers, isEmpty);
    });

    test('prefer-lts-like boosts the latest patch of each minor (+5)', () {
      final candidates = [
        release('3.24.1'),
        release('3.24.0'),
        release('3.22.2'),
      ];
      final engine = RuleEngine([PreferLtsLikeRule()]);
      final result = engine.apply(candidates, context(candidates));
      expect(result.modifiers, {
        SemVer.parse('3.24.1'): 5,
        SemVer.parse('3.22.2'): 5,
      });
      expect(
        result.modifierReasons[SemVer.parse('3.24.1')]!.single.text,
        contains('latest patch'),
      );
    });

    test('is order-independent', () {
      final candidates = [release('3.24.1'), release('3.22.2')];
      final a = RuleEngine([
        ChannelPolicyRule(),
        PreferLtsLikeRule(),
        DenyRetractedRule(),
      ]).apply(candidates, context(candidates));
      final b = RuleEngine([
        PreferLtsLikeRule(),
        DenyRetractedRule(),
        ChannelPolicyRule(),
      ]).apply(candidates, context(candidates));
      expect(a.allowed, b.allowed);
      expect(a.modifiers, b.modifiers);
    });
  });

  group('built-in rules (T2.3.2)', () {
    final beta = release('3.27.0-0.1.pre', channel: Channel.beta);
    final stable = release('3.22.2');

    test('channel-policy: stable / beta / any ladder', () {
      expect(
        ChannelPolicyRule().evaluate(beta, context([beta])).action,
        RuleAction.deny,
      );
      expect(
        ChannelPolicyRule(allow: 'beta').evaluate(beta, context([beta])).action,
        RuleAction.allow,
      );
      final dev = release('2.13.0-0.1.pre', channel: Channel.dev);
      expect(
        ChannelPolicyRule(allow: 'beta').evaluate(dev, context([dev])).action,
        RuleAction.deny,
        reason: 'archived dev channel needs `any`',
      );
      expect(
        ChannelPolicyRule(allow: 'any').evaluate(dev, context([dev])).action,
        RuleAction.allow,
      );
    });

    test('min-version-floor denies below the baseline', () {
      final rule = MinVersionFloorRule(floor: SemVer.parse('3.16.0'));
      expect(
        rule.evaluate(release('3.10.6'), context(const [])).action,
        RuleAction.deny,
      );
      expect(rule.evaluate(stable, context(const [])).action, RuleAction.allow);
    });

    test('deny-list and allow-list', () {
      expect(
        DenyListRule(
          versions: const {'3.22.2'},
        ).evaluate(stable, context(const [])).action,
        RuleAction.deny,
      );
      final allowOnly = AllowListRule(versions: const {'3.19.6'});
      expect(
        allowOnly.evaluate(stable, context(const [])).action,
        RuleAction.deny,
      );
      expect(
        allowOnly.evaluate(release('3.19.6'), context(const [])).action,
        RuleAction.allow,
      );
    });

    test('freshness-window uses the injected clock', () {
      final rule = FreshnessWindowRule(maxAge: const Duration(days: 30));
      final old = release('3.19.6', releasedAt: DateTime.utc(2026, 1, 1));
      final verdict = rule.evaluate(old, context(const []));
      expect(verdict.action, RuleAction.deny);
      expect(verdict.reason, contains('freshness window'));
      final fresh = release('3.24.1', releasedAt: DateTime.utc(2026, 7, 1));
      expect(
        rule.evaluate(fresh, context(const [])).action,
        RuleAction.allow,
        reason: 'released 10 days before the injected now',
      );
    });
  });

  group('policy layering (T2.3.3)', () {
    test('specific layers may tighten but never loosen', () {
      final merged = mergePolicyLayers([
        PolicyLayer(
          source: 'global config',
          settings: const {'rules.channel-policy.allow': 'beta'},
        ),
        PolicyLayer(
          source: 'project flutterx.yaml',
          settings: const {'rules.channel-policy.allow': 'stable'}, // tighten
        ),
        PolicyLayer(
          source: 'rogue layer',
          settings: const {'rules.channel-policy.allow': 'any'}, // loosen!
        ),
      ]);
      expect(merged.settings['rules.channel-policy.allow'], 'stable');
      final warning = merged.warnings.single;
      expect(warning.code, 'loosening-ignored');
      expect(warning.origin, 'rogue layer');
    });

    test('lockdown freezes a rule for later layers', () {
      final merged = mergePolicyLayers([
        PolicyLayer(
          source: 'org policy',
          settings: const {'rules.min-version-floor.version': '3.16.0'},
          lockedRules: const {'min-version-floor'},
        ),
        PolicyLayer(
          source: 'project',
          settings: const {'rules.min-version-floor.version': '3.24.0'},
        ),
      ]);
      expect(merged.settings['rules.min-version-floor.version'], '3.16.0');
      expect(merged.warnings.single.code, 'locked-rule');
    });

    test('unknown rule ids warn and are ignored (forward compat)', () {
      final merged = mergePolicyLayers([
        PolicyLayer(
          source: 'config',
          settings: const {'rules.quantum-policy.enabled': 'true'},
        ),
      ]);
      expect(merged.settings, isEmpty);
      expect(merged.warnings.single.code, 'unknown-rule');
    });

    test('deny-retracted can never be disabled by a later layer', () {
      final merged = mergePolicyLayers([
        PolicyLayer(
          source: 'global',
          settings: const {'rules.deny-retracted.enabled': 'true'},
        ),
        PolicyLayer(
          source: 'project',
          settings: const {'rules.deny-retracted.enabled': 'false'},
        ),
      ]);
      expect(merged.settings['rules.deny-retracted.enabled'], 'true');
    });

    test('buildRules honors defaults and merged settings', () {
      final defaults = buildRules(const {});
      expect(
        defaults.map((r) => r.id),
        containsAll(['deny-retracted', 'channel-policy', 'prefer-lts-like']),
      );
      expect(defaults.map((r) => r.id), isNot(contains('min-version-floor')));

      final configured = buildRules(const {
        'rules.min-version-floor.version': '3.16.0',
        'rules.freshness-window.days': '180',
      });
      expect(
        configured.map((r) => r.id),
        containsAll(['min-version-floor', 'freshness-window']),
      );
    });
  });

  group('all-denied explanation (T2.3.4)', () {
    test('denial table + single-relaxation unblock suggestion', () {
      final candidates = [
        release('3.27.0-0.1.pre', channel: Channel.beta),
        release('3.26.0-0.1.pre', channel: Channel.beta),
      ];
      final engine = RuleEngine([ChannelPolicyRule(), DenyRetractedRule()]);
      final ctx = context(candidates);
      final result = engine.apply(candidates, ctx);
      expect(result.allDenied, isTrue);

      final denied = engine.explainAllDenied(candidates, ctx, result);
      expect(denied.denials, hasLength(2));
      expect(denied.details.first, contains('denied by channel-policy'));
      expect(
        denied.nextActions.single,
        contains('relaxing channel-policy would unblock 2'),
      );
    });

    test('no single relaxation helps → says so honestly', () {
      final candidates = [release('3.10.0', retracted: true)];
      final engine = RuleEngine([
        DenyRetractedRule(),
        MinVersionFloorRule(floor: SemVer.parse('3.16.0')),
      ]);
      final ctx = context(candidates);
      final denied = engine.explainAllDenied(
        candidates,
        ctx,
        engine.apply(candidates, ctx),
      );
      expect(denied.nextActions.single, contains('no single rule'));
    });
  });
}
