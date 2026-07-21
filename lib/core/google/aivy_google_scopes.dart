/// OAuth 2.0 scope URLs for Google Sign-In + REST APIs.
///
/// Must match scopes on the Cloud Console OAuth consent screen.
class AivyGoogleScopes {
  AivyGoogleScopes._();

  /// Beyond [email] / [profile] on first sign-in — requested via
  /// [GoogleSignIn.requestScopes] after login (Android / iOS).
  static const List<String> workspaceApiScopes = <String>[
    'https://www.googleapis.com/auth/contacts.readonly',
    'https://www.googleapis.com/auth/contacts.other.readonly',
    'https://www.googleapis.com/auth/calendar',
    'https://www.googleapis.com/auth/spreadsheets',
    'https://www.googleapis.com/auth/gmail.send',
    'https://www.googleapis.com/auth/gmail.readonly',
  ];
}
