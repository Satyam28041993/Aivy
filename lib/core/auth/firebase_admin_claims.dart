import 'package:firebase_auth/firebase_auth.dart';

/// `admin: true` must be set on the user via Firebase Admin SDK custom claims.
Future<bool> currentUserIsFirebaseAdmin() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    return false;
  }
  final token = await user.getIdTokenResult();
  return token.claims?['admin'] == true;
}
