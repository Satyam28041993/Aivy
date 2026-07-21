import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/auth/firebase_admin_claims.dart';

/// Configure WhatsApp Cloud API credentials stored in Firestore `app_config/whatsapp`.
class WhatsappSettingsScreen extends StatefulWidget {
  const WhatsappSettingsScreen({super.key});

  @override
  State<WhatsappSettingsScreen> createState() => _WhatsappSettingsScreenState();
}

class _WhatsappSettingsScreenState extends State<WhatsappSettingsScreen> {
  final _tokenCtrl = TextEditingController();
  final _phoneIdCtrl = TextEditingController();
  final _webhookVerifyTokenCtrl = TextEditingController();
  final _appSecretCtrl = TextEditingController();
  final _templateNameCtrl = TextEditingController();
  final _templateLangCtrl = TextEditingController();

  bool _loaded = false;
  bool _saving = false;
  bool _healthLoading = false;
  String? _healthSeverity;
  String? _healthMessage;
  bool _tokenConfigured = false;
  bool _verifyTokenConfigured = false;
  bool _appSecretConfigured = false;

  int _templateBodyParamCount = 0;

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _phoneIdCtrl.dispose();
    _webhookVerifyTokenCtrl.dispose();
    _appSecretCtrl.dispose();
    _templateNameCtrl.dispose();
    _templateLangCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadDoc();
  }

  Future<void> _loadDoc() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('whatsapp')
          .get();
      if (!mounted) {
        return;
      }
      final d = snap.data();
      if (d != null) {
        _phoneIdCtrl.text = '${d['phoneId'] ?? ''}'.trim();
        _templateNameCtrl.text = '${d['outboundTemplateName'] ?? ''}'.trim();
        final lang = '${d['outboundTemplateLanguage'] ?? ''}'.trim();
        _templateLangCtrl.text = lang.isEmpty ? 'en' : lang;
        final pc = d['outboundTemplateBodyParamCount'];
        if (pc is num) {
          _templateBodyParamCount = pc.toInt().clamp(0, 3);
        } else {
          _templateBodyParamCount = 0;
        }
        _tokenConfigured = d['tokenConfigured'] == true;
        _verifyTokenConfigured = d['webhookVerifyTokenConfigured'] == true;
        _appSecretConfigured = d['appSecretConfigured'] == true;
        if (!_tokenConfigured) {
          final legacyToken = '${d['token'] ?? ''}'.trim();
          _tokenConfigured = legacyToken.isNotEmpty;
        }
        if (!_verifyTokenConfigured) {
          final legacy = '${d['webhookVerifyToken'] ?? ''}'.trim();
          _verifyTokenConfigured = legacy.isNotEmpty;
        }
        if (!_appSecretConfigured) {
          final legacy = '${d['appSecret'] ?? ''}'.trim();
          _appSecretConfigured = legacy.isNotEmpty;
        }
        _tokenCtrl.clear();
        _webhookVerifyTokenCtrl.clear();
        _appSecretCtrl.clear();
      } else {
        _tokenConfigured = false;
        _verifyTokenConfigured = false;
        _appSecretConfigured = false;
        _tokenCtrl.clear();
        _webhookVerifyTokenCtrl.clear();
        _appSecretCtrl.clear();
        _templateNameCtrl.clear();
        _templateLangCtrl.text = 'en';
        _templateBodyParamCount = 0;
      }
      if (_tokenConfigured) {
        _checkHealth(silent: true);
      }
    } catch (e) {
      if (mounted) {
        _toast(e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loaded = true);
      }
    }
  }

  Future<void> _checkHealth({bool silent = false}) async {
    if (_healthLoading) {
      return;
    }
    setState(() {
      _healthLoading = true;
      if (!silent) {
        _healthMessage = null;
        _healthSeverity = null;
      }
    });
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('checkWhatsappHealth');
      final result = await callable.call();
      final data = result.data is Map
          ? Map<String, dynamic>.from(result.data as Map)
          : const <String, dynamic>{};
      if (!mounted) {
        return;
      }
      setState(() {
        _healthSeverity = '${data['severity'] ?? ''}'.trim().toLowerCase();
        _healthMessage = '${data['message'] ?? ''}'.trim();
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _healthSeverity = 'error';
        _healthMessage = e.message ?? e.code;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _healthSeverity = 'error';
        _healthMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _healthLoading = false);
      }
    }
  }

  void _toast(String m) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _save() async {
    if (!(await currentUserIsFirebaseAdmin())) {
      _toast('Only administrators can update WhatsApp settings.');
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _toast('Sign in to save.');
      return;
    }

    final token = _tokenCtrl.text.trim();
    final phoneId = _phoneIdCtrl.text.trim();
    final webhookVerifyToken = _webhookVerifyTokenCtrl.text.trim();
    final appSecret = _appSecretCtrl.text.trim();
    final hasNewToken = token.isNotEmpty;
    final hasNewVerifyToken = webhookVerifyToken.isNotEmpty;
    final hasNewAppSecret = appSecret.isNotEmpty;

    if (!hasNewToken && !_tokenConfigured) {
      _toast('Access token is required for first-time setup.');
      return;
    }
    if (!hasNewVerifyToken && !_verifyTokenConfigured) {
      _toast('Webhook verify token is required for first-time setup.');
      return;
    }
    if (!hasNewAppSecret && !_appSecretConfigured) {
      _toast('App secret is required for first-time setup.');
      return;
    }
    if (phoneId.isEmpty) {
      _toast('Phone Number ID is required.');
      return;
    }
    if (hasNewToken && token.length <= 50) {
      _toast('Access token must be longer than 50 characters.');
      return;
    }

    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        'phoneId': phoneId,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      };
      if (hasNewToken) {
        payload['token'] = token;
        payload['tokenConfigured'] = true;
      }
      if (hasNewVerifyToken) {
        payload['webhookVerifyToken'] = webhookVerifyToken;
        payload['webhookVerifyTokenConfigured'] = true;
      }
      if (hasNewAppSecret) {
        payload['appSecret'] = appSecret;
        payload['appSecretConfigured'] = true;
      }
      payload['outboundTemplateName'] = _templateNameCtrl.text.trim();
      payload['outboundTemplateLanguage'] = _templateLangCtrl.text.trim().isEmpty
          ? 'en'
          : _templateLangCtrl.text.trim();
      payload['outboundTemplateBodyParamCount'] = _templateBodyParamCount;
      await FirebaseFirestore.instance
          .collection('app_config')
          .doc('whatsapp')
          .set(
            payload,
            SetOptions(merge: true),
          );
      if (!mounted) {
        return;
      }
      if (hasNewToken) {
        _tokenConfigured = true;
      }
      if (hasNewVerifyToken) {
        _verifyTokenConfigured = true;
      }
      if (hasNewAppSecret) {
        _appSecretConfigured = true;
      }
      _tokenCtrl.clear();
      _webhookVerifyTokenCtrl.clear();
      _appSecretCtrl.clear();
      _toast('WhatsApp settings saved successfully');
    } on FirebaseException catch (e) {
      _toast(e.message ?? e.code);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat.yMMMd().add_jm();

    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp'),
        backgroundColor: theme.colorScheme.surface,
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Access token and Phone Number ID are stored in Firestore. '
                  'Cloud Functions read them at send time (no redeploy). '
                  'Only users with the admin custom claim can save changes.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
                const SizedBox(height: 20),
                if (_healthMessage != null && _healthMessage!.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _healthSeverity == 'warning'
                          ? Colors.orange.withValues(alpha: 0.14)
                          : _healthSeverity == 'error'
                          ? Colors.red.withValues(alpha: 0.12)
                          : Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _healthSeverity == 'warning'
                            ? Colors.orange
                            : _healthSeverity == 'error'
                            ? Colors.red
                            : Colors.green,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _healthSeverity == 'warning'
                              ? Icons.warning_amber_rounded
                              : _healthSeverity == 'error'
                              ? Icons.error_outline_rounded
                              : Icons.verified_outlined,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_healthMessage!)),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _healthLoading ? null : _checkHealth,
                    icon: _healthLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.health_and_safety_outlined),
                    label: const Text('Check token health'),
                  ),
                ),
                const SizedBox(height: 8),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('app_config')
                      .doc('whatsapp')
                      .snapshots(),
                  builder: (context, snap) {
                    final d = snap.data?.data();
                    final ts = d?['updatedAt'];
                    String? updatedLine;
                    if (ts is Timestamp) {
                      updatedLine =
                          'Last updated: ${dateFmt.format(ts.toDate())}';
                      final by = d?['updatedBy'];
                      if (by is String && by.isNotEmpty) {
                        updatedLine = '$updatedLine · $by';
                      }
                    }
                    if (updatedLine == null) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        updatedLine,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
                if (_tokenConfigured)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Access token already configured. Leave blank to keep current token, or paste a new one to rotate.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                TextField(
                  controller: _tokenCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: _tokenConfigured
                        ? 'Access token (optional)'
                        : 'Access token',
                  ),
                  obscureText: true,
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _phoneIdCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Phone Number ID',
                  ),
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 28),
                Text(
                  'Outbound template (new contacts / 24h window)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Jab customer ne pehle message nahi bheja, Meta sirf approved template allow karti hai. '
                  'Yahan wahi template ka naam aur language likho jo WhatsApp Manager → Message templates me approved ho. '
                  'Body placeholders: 1 = aapka message (truncate), 2 = contact naam, 3 = "-" (agar template me 3 variables hon).',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _templateNameCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Template name (e.g. hello_world)',
                    hintText: 'Meta dashboard jaisa exact naam',
                  ),
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _templateLangCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Template language code',
                    hintText: 'en, en_US, hi …',
                  ),
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: _templateBodyParamCount,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Body variable count ({{1}}, {{2}}…)',
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('0 — body me variable nahi')),
                    DropdownMenuItem(value: 1, child: Text('1 — pehla: message text')),
                    DropdownMenuItem(
                      value: 2,
                      child: Text('2 — message + contact name'),
                    ),
                    DropdownMenuItem(
                      value: 3,
                      child: Text('3 — message + name + placeholder'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) {
                          if (v != null) {
                            setState(() => _templateBodyParamCount = v);
                          }
                        },
                ),
                const SizedBox(height: 24),
                if (_verifyTokenConfigured)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Webhook verify token already configured. Leave blank to keep current value.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                TextField(
                  controller: _webhookVerifyTokenCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: _verifyTokenConfigured
                        ? 'Webhook verify token (optional)'
                        : 'Webhook verify token',
                  ),
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                if (_appSecretConfigured)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'App secret already configured. Leave blank to keep current value.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                TextField(
                  controller: _appSecretCtrl,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: _appSecretConfigured
                        ? 'App secret (optional)'
                        : 'App secret',
                  ),
                  obscureText: true,
                  enabled: !_saving,
                  autocorrect: false,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
    );
  }
}
