// The app's version, build number and commit, for the About box, backups
// and band sync (so bandmates can see which build the leader runs).
//
// Pure Dart (no Flutter imports). The version comes from pubspec.yaml; the
// build number is the git commit count and the commit is the short hash,
// both set by tool/flutter_versioned.sh at build time (plain `flutter run`
// leaves the commit empty: a dev build).

/// The commit the build came from, e.g. "6742208" or "6742208-dirty".
const String buildCommit = String.fromEnvironment('BETH_COMMIT');

/// The build number passed to `flutter run` (which has no --build-number),
/// or 0 when the platform's own build number is to be used.
const int buildNumberOverride = int.fromEnvironment('BETH_BUILD');

class AppVersion {
  const AppVersion(this.version, {this.build, this.commit});

  /// From the platform's version name and build number (package_info), plus
  /// the defines set at build time.
  factory AppVersion.fromPlatform(String version, String buildNumber) =>
      AppVersion(
        version,
        build: buildNumberOverride > 0
            ? buildNumberOverride
            : int.tryParse(buildNumber),
        commit: buildCommit.isEmpty ? null : buildCommit,
      );

  /// Parses [short] ("1.0.0+129"); null if it isn't one.
  static AppVersion? tryParse(Object? short) {
    if (short is! String) return null;
    final m = RegExp(r'^(\d+(?:\.\d+)*)(?:\+(\d+))?$').firstMatch(short.trim());
    if (m == null) return null;
    return AppVersion(m[1]!, build: m[2] == null ? null : int.parse(m[2]!));
  }

  /// "1.0.0", from pubspec.yaml.
  final String version;

  /// The git commit count the build was made at; null if unknown.
  final int? build;

  /// Short commit hash, "-dirty" if built with uncommitted changes; null for
  /// a dev build (not built through the script).
  final String? commit;

  /// Version and build number, "1.0.0+129": what backups and band sync
  /// carry.
  String get short => build == null ? version : '$version+$build';

  /// For people: "1.0.0 (build 129, 6742208)", "1.0.0 (build 129, dev)".
  String get label {
    final parts = [if (build != null) 'build $build', commit ?? 'dev'];
    return '$version (${parts.join(', ')})';
  }

  /// Same version and build (the commit isn't compared: it isn't sent).
  bool sameBuildAs(AppVersion other) =>
      other.version == version && other.build == build;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.version == version &&
      other.build == build &&
      other.commit == commit;

  @override
  int get hashCode => Object.hash(version, build, commit);

  @override
  String toString() => 'AppVersion($label)';
}
