import 'package:flutter/material.dart';

import '../core/auth/aivy_auth_controller.dart';
import '../core/auth/aivy_auth_scope.dart';
import '../core/theme/aivy_theme.dart';
import '../features/bootstrap/bootstrap_gate.dart';

class AivyApp extends StatefulWidget {
  const AivyApp({super.key});

  @override
  State<AivyApp> createState() => _AivyAppState();
}

class _AivyAppState extends State<AivyApp> {
  late final AivyAuthController _auth = AivyAuthController();

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AivyAuthScope(
      notifier: _auth,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Aivy',
        theme: AivyTheme.light(),
        home: BootstrapGate(auth: _auth),
      ),
    );
  }
}
