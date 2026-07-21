import 'package:flutter/widgets.dart';

import 'aivy_auth_controller.dart';

class AivyAuthScope extends InheritedNotifier<AivyAuthController> {
  const AivyAuthScope({
    super.key,
    required AivyAuthController super.notifier,
    required super.child,
  });

  static AivyAuthController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AivyAuthScope>();
    assert(scope != null, 'AivyAuthScope not found above this context');
    return scope!.notifier!;
  }
}
