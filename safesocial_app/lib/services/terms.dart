import 'package:shared_preferences/shared_preferences.dart';

/// The terms of use a person agrees to before they can post. Plain
/// preference: whether this install agreed, and to which version.
class Terms {
  Terms._();

  static const version = 1;
  static const url = 'https://spheres.dev/terms';
  static const childSafetyUrl = 'https://spheres.dev/child-safety';
  static const _key = 'terms_accepted_version';

  static Future<bool> accepted() async =>
      ((await SharedPreferences.getInstance()).getInt(_key) ?? 0) >= version;

  static Future<void> accept() async => (await SharedPreferences.getInstance()).setInt(_key, version);

  /// The rules in a few lines, for the gate and the onboarding screen.
  static const summary =
      'No content that sexualises or endangers children, no threats, harassment or hate, '
      'nothing illegal, no scams or impersonation. Reports reach the people who run '
      'Spheres, who can stop an identity being found or added, and who report child '
      'sexual abuse material to the authorities as the law requires.';
}
