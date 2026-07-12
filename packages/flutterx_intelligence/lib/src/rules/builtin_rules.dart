import 'package:flutterx_domain/flutterx_domain.dart';

/// The built-in rule set (docs/03 §4.2). Each rule is pure and judges one
/// candidate at a time; relative judgments read [RuleContext.candidates].

/// `deny-retracted` (default on): known-bad releases never resolve
/// automatically — `install --force` is the only way in.
final class DenyRetractedRule implements Rule {
  @override
  String get id => 'deny-retracted';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) =>
      release.retracted
      ? RuleVerdict.deny(
          release.retractionReason == null
              ? 'retracted release'
              : 'retracted: ${release.retractionReason}',
        )
      : const RuleVerdict.allow();
}

/// `channel-policy` (default `stable`): deny releases outside the allowed
/// channels. `stable` < `beta` (= stable+beta) < `any`.
final class ChannelPolicyRule implements Rule {
  ChannelPolicyRule({this.allow = 'stable'});

  /// `stable`, `beta`, or `any`.
  final String allow;

  @override
  String get id => 'channel-policy';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) {
    final allowed = switch (allow) {
      'any' => true,
      'beta' =>
        release.channel == Channel.stable || release.channel == Channel.beta,
      _ => release.channel == Channel.stable,
    };
    return allowed
        ? const RuleVerdict.allow()
        : RuleVerdict.deny(
            '${release.channel.name} channel not allowed (policy: $allow)',
          );
  }
}

/// `min-version-floor` (off by default): an org security baseline —
/// releases below the floor are denied (docs/03 §4.2).
final class MinVersionFloorRule implements Rule {
  MinVersionFloorRule({required this.floor});

  final SemVer floor;

  @override
  String get id => 'min-version-floor';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) =>
      release.version < floor
      ? RuleVerdict.deny('below the version floor $floor')
      : const RuleVerdict.allow();
}

/// `deny-list` (off by default): explicitly banned versions.
final class DenyListRule implements Rule {
  DenyListRule({required Set<String> versions})
    : versions = Set.unmodifiable(versions);

  final Set<String> versions;

  @override
  String get id => 'deny-list';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) =>
      versions.contains('${release.version}')
      ? const RuleVerdict.deny('on the team deny-list')
      : const RuleVerdict.allow();
}

/// `allow-list` (off by default): when present, *only* listed versions
/// pass.
final class AllowListRule implements Rule {
  AllowListRule({required Set<String> versions})
    : versions = Set.unmodifiable(versions);

  final Set<String> versions;

  @override
  String get id => 'allow-list';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) =>
      versions.contains('${release.version}')
      ? const RuleVerdict.allow()
      : const RuleVerdict.deny('not on the team allow-list');
}

/// `freshness-window` (off by default): compliance — releases older than
/// the window are denied. Uses the injected clock, never wall time.
final class FreshnessWindowRule implements Rule {
  FreshnessWindowRule({required this.maxAge});

  final Duration maxAge;

  @override
  String get id => 'freshness-window';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) {
    final age = context.now.difference(release.releasedAt);
    return age > maxAge
        ? RuleVerdict.deny(
            'released ${age.inDays} days ago — outside the '
            '${maxAge.inDays}-day freshness window',
          )
        : const RuleVerdict.allow();
  }
}

/// `prefer-lts-like` (default on, +5): stability bias — the latest patch
/// of a minor is preferred over mid-series patches (docs/03 §4.2).
final class PreferLtsLikeRule implements Rule {
  @override
  String get id => 'prefer-lts-like';

  @override
  RuleVerdict evaluate(FlutterRelease release, RuleContext context) {
    final isLatestPatch = !context.candidates.any(
      (other) =>
          other.channel == release.channel &&
          other.version.sameMinorAs(release.version) &&
          other.version > release.version,
    );
    return isLatestPatch
        ? const RuleVerdict.prefer(5, 'latest patch of its minor')
        : const RuleVerdict.allow();
  }
}
