/// Single source of truth for the version strings shown in the UI.
///
/// Keep [version] in sync with `version:` in pubspec.yaml — `build_release.sh`
/// reads this file when bumping a release.
class AppInfo {
  const AppInfo._();

  static const String version = '0.6.0';
  static const String channel = 'pre-alpha';
}
