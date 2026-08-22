import 'package:flutter/material.dart';

import '../onboarding/meta_embedded_signup_result.dart';
import '../onboarding/meta_embedded_signup_service.dart';
import '../onboarding/whatsapp_onboarding_repository.dart';

/// Launches Meta Embedded Signup and completes OAuth code exchange on the backend.
class ConnectWhatsAppButton extends StatefulWidget {
  const ConnectWhatsAppButton({
    super.key,
    this.onCompleted,
    this.onConnectionStored,
    this.compact = false,
    WhatsappOnboardingRepository? repository,
  }) : _repository = repository;

  final ValueChanged<MetaEmbeddedSignupResult>? onCompleted;
  final ValueChanged<WhatsappConnectionMetadata>? onConnectionStored;
  final bool compact;
  final WhatsappOnboardingRepository? _repository;

  @override
  State<ConnectWhatsAppButton> createState() => _ConnectWhatsAppButtonState();
}

class _ConnectWhatsAppButtonState extends State<ConnectWhatsAppButton> {
  bool _busy = false;
  late final WhatsappOnboardingRepository _repository =
      widget._repository ?? WhatsappOnboardingRepository();

  Future<void> _launch() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final session = await _repository.launchAndComplete(
        MetaEmbeddedSignupService.instance.launch,
      );
      widget.onCompleted?.call(session.launch);
      if (session.connection != null) {
        widget.onConnectionStored?.call(session.connection!);
      }
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      if (session.connection != null) {
        final c = session.connection!;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'WhatsApp connected${c.displayPhoneNumber.isNotEmpty ? ': ${c.displayPhoneNumber}' : ''}.',
            ),
          ),
        );
        return;
      }
      switch (session.launch.status) {
        case MetaEmbeddedSignupStatus.completed:
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Signup finished but backend exchange did not complete.',
              ),
            ),
          );
        case MetaEmbeddedSignupStatus.cancelled:
          messenger.showSnackBar(
            const SnackBar(content: Text('Embedded Signup cancelled.')),
          );
        case MetaEmbeddedSignupStatus.error:
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                session.launch.errorMessage ?? 'Embedded Signup failed.',
              ),
            ),
          );
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = MetaEmbeddedSignupService.instance.isSupported;
    if (widget.compact) {
      return OutlinedButton.icon(
        onPressed: supported && !_busy ? _launch : null,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.link_rounded),
        label: const Text('Connect WhatsApp Business'),
      );
    }
    return FilledButton.icon(
      onPressed: supported && !_busy ? _launch : null,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chat_rounded),
      label: const Text('Connect WhatsApp Business'),
    );
  }
}
