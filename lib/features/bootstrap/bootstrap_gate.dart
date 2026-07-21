import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';

import '../../core/auth/aivy_auth_controller.dart';
import '../../core/firebase/firebase_session.dart';
import '../home/presentation/home_shell.dart';

class BootstrapGate extends StatefulWidget {
  const BootstrapGate({super.key, required this.auth});

  final AivyAuthController auth;

  @override
  State<BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends State<BootstrapGate> {
  String? _authError;
  bool _busy = false;

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _authError = null;
    });
    try {
      await body();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Aivy] bootstrap auth: $e\n$st');
      }
      if (mounted) {
        setState(() => _authError = FirebaseSession.describeAuthFailure(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final uid = widget.auth.uid;
        if (uid != null) {
          return HomeShell(userId: uid);
        }

        final theme = Theme.of(context);
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Aivy',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in with Google to sync chats, meetings, and memory '
                      'across devices. Your Firebase user id is the same everywhere '
                      'you use this account.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                    const SizedBox(height: 24),
                    if (_authError != null) ...[
                      Text(
                        _authError!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await FirebaseSession.signInWithGoogle();
                              }),
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Continue with Google'),
                      ),
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
