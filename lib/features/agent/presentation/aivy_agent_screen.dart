import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/design/aivy_ui.dart';
import '../../../core/firebase/firebase_session.dart';
import '../../../core/location/device_location.dart';
import '../../../core/theme/aivy_theme.dart';
import '../data/agent_service.dart';
import '../models/agent_attachment.dart';
import '../models/agent_models.dart';
import 'widgets/agent_history_drawer.dart';
import 'widgets/agent_message_bubble.dart';

/// The agent screen: one input, no menus, no numbered commands.
///
/// Everything the user says goes to `aivyAgent`, which decides on its own
/// whether to chat, look something up, search the web, or propose a record. The
/// screen's only jobs are showing the conversation, rendering confirm cards, and
/// keeping history reachable.
class AivyAgentScreen extends StatefulWidget {
  const AivyAgentScreen({
    super.key,
    required this.userId,
    this.service,
    this.prefill,
  });

  final String userId;

  /// Text pushed in from elsewhere — a news item, a Google Alert — to be put in
  /// the message box ready to send.
  final ValueNotifier<String?>? prefill;

  /// Injectable for tests.
  final AgentService? service;

  @override
  State<AivyAgentScreen> createState() => _AivyAgentScreenState();
}

class _AivyAgentScreenState extends State<AivyAgentScreen> {
  late final AgentService _service;
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  StreamSubscription<List<AgentMessage>>? _messageSub;
  StreamSubscription<List<AgentChatSummary>>? _chatSub;

  List<AgentMessage> _messages = const [];
  List<AgentChatSummary> _chats = const [];

  /// Live draft statuses, so a card flips to "saved" without a stream per card.
  final Map<String, String> _draftStatus = {};

  String? _chatId;
  bool _sending = false;
  String? _busyDraftId;
  String? _error;

  /// Shown immediately so the user sees their own line before the round trip.
  String? _pendingUserText;

  final List<AgentPendingFile> _pendingFiles = [];
  final ImagePicker _images = ImagePicker();

  /// Whether Gmail/Calendar/Sheets are reachable from this device. Null until
  /// checked; always false on web, where the Google REST stack does not run.
  bool? _googleReady;

  @override
  void initState() {
    super.initState();
    widget.prefill?.addListener(_applyPrefill);
    _service = widget.service ?? AgentService();
    _chatSub = _service.watchChats(widget.userId).listen((chats) {
      if (!mounted) {
        return;
      }
      setState(() {
        _chats = chats;
        // First run: drop into the most recent conversation.
        if (_chatId == null && chats.isNotEmpty) {
          _bindChat(chats.first.id);
        }
      });
    });
    // Both drive the composer's appearance: the send button enables on text,
    // and the border lifts on focus.
    _input.addListener(_repaintComposer);
    _inputFocus.addListener(_repaintComposer);
    unawaited(_refreshGoogleStatus());
    // Asked here rather than at launch, so the system dialog arrives with the
    // screen that actually uses the answer. Declining costs nothing: location
    // simply stays unknown and "paas me" asks for an area instead.
    unawaited(DeviceLocation.ensurePermission());
  }

  /// Silent check — a missing Google connection is not an error, it just means
  /// the calendar and mail tools stay out of reach.
  Future<void> _refreshGoogleStatus() async {
    final token = await FirebaseSession.googleAccessTokenOrNull();
    if (!mounted) {
      return;
    }
    setState(() => _googleReady = token != null);
  }

  Future<void> _connectGoogle() async {
    if (_googleReady == true) {
      _snack('Google juda hua hai — Calendar, Gmail aur Sheets chaalu hain.');
      return;
    }
    if (kIsWeb) {
      _snack('Calendar/Gmail sirf Android app me chalte hain.');
      return;
    }
    try {
      await FirebaseSession.ensureWorkspaceScopes();
    } catch (_) {
      // The status refresh below is the real answer either way.
    }
    await _refreshGoogleStatus();
    if (!mounted) {
      return;
    }
    _snack(
      _googleReady == true
          ? 'Google connected — meetings will go to Calendar too.'
          : 'Google permission was not granted.',
    );
  }

  /// Puts the text in the box and opens the keyboard, but does not send it:
  /// the user may want to ask it differently, and a message fired by a tap
  /// they did not mean is worse than one they have to press send on.
  void _applyPrefill() {
    final text = widget.prefill?.value?.trim() ?? '';
    if (text.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    });
    // Cleared so returning to this tab later does not re-fill the box with a
    // question that was already asked.
    widget.prefill?.value = null;
    _inputFocus.requestFocus();
  }

  void _repaintComposer() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_messageSub?.cancel());
    unawaited(_chatSub?.cancel());
    widget.prefill?.removeListener(_applyPrefill);
    _input.removeListener(_repaintComposer);
    _inputFocus.removeListener(_repaintComposer);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Conversation binding
  // -------------------------------------------------------------------------

  void _bindChat(String chatId) {
    if (_chatId == chatId && _messageSub != null) {
      return;
    }
    _chatId = chatId;
    unawaited(_messageSub?.cancel());
    _messageSub = _service.watchMessages(widget.userId, chatId).listen((msgs) {
      if (!mounted) {
        return;
      }
      setState(() {
        _messages = msgs;
        // The real row has arrived; drop the optimistic copy.
        if (_pendingUserText != null &&
            msgs.any((m) => m.isUser && m.text == _pendingUserText)) {
          _pendingUserText = null;
        }
      });
      _scrollToEnd();
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  Future<void> _send() async {
    final text = _input.text.trim();
    final files = List<AgentPendingFile>.from(_pendingFiles);
    if (!canSendAgentTurn(text: text, attachmentCount: files.length) || _sending) {
      return;
    }
    _input.clear();
    setState(() {
      _sending = true;
      _error = null;
      _pendingFiles.clear();
      _pendingUserText = _optimisticLine(text, files);
    });
    _scrollToEnd();

    try {
      final res = await _service.send(text: text, chatId: _chatId, files: files);
      if (!mounted) {
        return;
      }
      if (res.chatId.isNotEmpty && res.chatId != _chatId) {
        _bindChat(res.chatId);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = _describeSendFailure(error);
        // Put the text and files back so nothing is lost.
        _input.text = text;
        _pendingFiles
          ..clear()
          ..addAll(files);
        _pendingUserText = null;
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  String _optimisticLine(String text, List<AgentPendingFile> files) {
    final pins = files.map((f) => '📎 ${f.name}').join('\n');
    if (text.isNotEmpty && pins.isNotEmpty) {
      return '$text\n$pins';
    }
    return pins.isNotEmpty ? pins : text;
  }

  Future<void> _pickFrom({required String source}) async {
    if (_sending || _pendingFiles.length >= kAgentMaxAttachments) {
      return;
    }
    try {
      if (source == 'pdf') {
        final pick = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          withData: true,
        );
        final file = pick?.files.single;
        final bytes = file?.bytes;
        if (file == null || bytes == null || bytes.isEmpty) {
          return;
        }
        _addPending(file.name, 'application/pdf', bytes);
        return;
      }
      final shot = await _images.pickImage(
        source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2048,
      );
      if (shot == null) {
        return;
      }
      final bytes = await shot.readAsBytes();
      _addPending(
        shot.name,
        shot.mimeType ?? 'image/jpeg',
        bytes,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _snack(
        source == 'camera'
            ? 'Could not open the camera — pick a photo or a PDF instead.'
            : 'Could not attach that file.',
      );
      if (kDebugMode) {
        debugPrint('[AivyAgent] attach failed: $error');
      }
    }
  }

  void _addPending(String name, String rawMime, Uint8List bytes) {
    final mime = normalizeAgentMime(rawMime, fileName: name);
    if (mime == null) {
      _snack('Send a photo or a PDF — JPEG, PNG or PDF.');
      return;
    }
    if (bytes.length > kAgentMaxAttachmentBytes) {
      _snack('That file is too large — keep it under 8 MB.');
      return;
    }
    if (_pendingFiles.length >= kAgentMaxAttachments) {
      _snack('Three files at a time.');
      return;
    }
    setState(() {
      _pendingFiles.add(AgentPendingFile(name: name, mimeType: mime, bytes: bytes));
    });
  }

  Future<void> _showAttachSheet() async {
    if (_sending) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AivyUi.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Attach', style: AivyUi.title(context)),
                const SizedBox(height: 4),
                Text(
                  'A visiting card, a rate card, a brochure, a training PDF.',
                  style: AivyUi.soft(context),
                ),
                const SizedBox(height: 14),
                _attachTile(
                  icon: Icons.photo_camera_outlined,
                  label: 'Take a photo',
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_pickFrom(source: 'camera'));
                  },
                ),
                _attachTile(
                  icon: Icons.photo_outlined,
                  label: 'Choose a photo',
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_pickFrom(source: 'gallery'));
                  },
                ),
                _attachTile(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'Choose a PDF',
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_pickFrom(source: 'pdf'));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _attachTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AivyUi.brand),
      title: Text(label, style: const TextStyle(color: AivyUi.ink)),
      onTap: onTap,
    );
  }

  /// Names the actual cause rather than reporting every failure the same way.
  ///
  /// The three causes need different responses from whoever sees them — a
  /// missing deploy, a permission problem, and a dropped connection all look
  /// identical behind one "try again", which makes a backend that was never
  /// deployed indistinguishable from a flaky signal.
  String _describeSendFailure(Object error) {
    if (error is FirebaseFunctionsException) {
      switch (error.code) {
        case 'not-found':
          return 'Aivy\'s backend is not deployed yet. '
              '(aivyAgent function not found)';
        case 'permission-denied':
          return 'Could not reach the backend — check the function permissions. '
              '(permission-denied)';
        case 'unauthenticated':
          return 'Your sign-in looks expired — sign in again.';
        case 'unavailable':
        case 'deadline-exceeded':
          return 'No connection. Check the network and send again.';
        case 'resource-exhausted':
          return 'Rate limit hit — try again in a little while.';
        default:
          final detail = error.message?.trim();
          return 'Could not send (${error.code})'
              '${detail == null || detail.isEmpty ? '' : ' — $detail'}';
      }
    }
    return 'Could not send — try again.';
  }

  Future<void> _confirmDraft(AgentDraft draft) async {
    if (_busyDraftId != null) {
      return;
    }
    setState(() => _busyDraftId = draft.id);
    try {
      final res = await _service.commit(draftId: draft.id, chatId: _chatId);
      if (!mounted) {
        return;
      }
      setState(() {
        _draftStatus[draft.id] = res.ok ? 'committed' : 'pending';
      });
      if (!res.ok && res.message.isNotEmpty) {
        _snack(res.message);
      }
    } catch (_) {
      if (mounted) {
        _snack('Could not save — try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _busyDraftId = null);
      }
    }
  }

  /// "Badlo" hands the correction back to speech rather than a field picker —
  /// correcting by saying "12 baje kar do" is the point of the screen.
  void _editDraft(AgentDraft draft) {
    _inputFocus.requestFocus();
    _snack('${draft.title} me kya badalna hai? Jaise "12 baje kar do"');
  }

  void _cancelDraft(AgentDraft draft) {
    setState(() => _draftStatus[draft.id] = 'cancelled');
    unawaited(_dismissDraft(draft.id));
  }

  Future<void> _dismissDraft(String draftId) async {
    try {
      await _service.cancelDraft(draftId: draftId);
    } catch (_) {
      // The card already reads cancelled; a failed dismissal is not worth a
      // banner, and the draft simply stays pending server-side.
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // -------------------------------------------------------------------------
  // History actions
  // -------------------------------------------------------------------------

  Future<void> _newChat() async {
    Navigator.of(context).maybePop();
    try {
      final id = await _service.newChat();
      if (!mounted || id == null) {
        return;
      }
      setState(() {
        _messages = const [];
        _pendingUserText = null;
      });
      _bindChat(id);
    } catch (_) {
      if (mounted) {
        _snack('Could not start a new chat.');
      }
    }
  }

  Future<void> _renameChat(AgentChatSummary chat) async {
    Navigator.of(context).maybePop();
    final controller = TextEditingController(text: chat.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B29),
        title: const Text(
          'Naam badlo',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Color(0xFFE2E8F0)),
          decoration: const InputDecoration(hintText: 'Naya naam'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Rehne do'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty) {
      return;
    }
    try {
      await _service.renameChat(chat.id, trimmed);
    } catch (_) {
      if (mounted) {
        _snack('Could not rename it.');
      }
    }
  }

  Future<void> _deleteChat(AgentChatSummary chat) async {
    Navigator.of(context).maybePop();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B29),
        title: const Text(
          'Delete this chat?',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: Text(
          '"${chat.title}" will be gone for good.',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Rehne do'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFF87171)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _service.deleteChat(chat.id);
      if (!mounted) {
        return;
      }
      if (_chatId == chat.id) {
        setState(() {
          _messages = const [];
          _chatId = null;
        });
        unawaited(_messageSub?.cancel());
        _messageSub = null;
      }
    } catch (_) {
      if (mounted) {
        _snack('Could not delete it.');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  bool get _canSend =>
      canSendAgentTurn(text: _input.text, attachmentCount: _pendingFiles.length) &&
      !_sending;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AivyTheme.darkDashboard(),
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: const Color(0xFF080B12),
        drawer: AgentHistoryDrawer(
          chats: _chats,
          activeChatId: _chatId,
          onSelect: (id) {
            Navigator.of(context).maybePop();
            setState(() {
              _messages = const [];
              _pendingUserText = null;
            });
            _bindChat(id);
          },
          onNewChat: _newChat,
          onRename: _renameChat,
          onDelete: _deleteChat,
        ),
        body: SafeArea(
          child: Column(
            children: [
              _appBar(context),
              if (_error != null) _errorStrip(),
              Expanded(child: _conversation()),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Color(0xFF94A3B8)),
            tooltip: 'Purani baatein',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Aivy',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFFF1F5F9),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                ),
                const Text(
                  'say it however you like',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              _googleReady == true
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              color: _googleReady == true
                  ? const Color(0xFF34D399)
                  : const Color(0xFF64748B),
              size: 20,
            ),
            tooltip: _googleReady == true
                ? 'Google connected'
                : 'Google jodein (Calendar, Gmail, Sheets)',
            onPressed: _connectGoogle,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined,
                color: Color(0xFF94A3B8), size: 21),
            tooltip: 'Nayi baat',
            onPressed: _newChat,
          ),
        ],
      ),
    );
  }

  Widget _errorStrip() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFF7F1D1D).withValues(alpha: 0.25),
        border: Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
      ),
      child: Text(
        _error!,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12.5),
      ),
    );
  }

  Widget _conversation() {
    final showEmpty = _messages.isEmpty && _pendingUserText == null && !_sending;
    if (showEmpty) {
      return _emptyState();
    }
    final itemCount =
        _messages.length + (_pendingUserText != null ? 1 : 0) + (_sending ? 1 : 0);

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          final msg = _messages[index];
          // The date sits above the first message of each day, so every time
          // below it says which day it belongs to. A chat that ran past
          // midnight has two "7:19 PM"s in it otherwise.
          final newDay = index == 0
              ? msg.createdAtMs > 0
              : AgentDayDivider.needed(
                  _messages[index - 1].createdAtMs,
                  msg.createdAtMs,
                );
          final bubble = AgentMessageBubble(
            message: msg,
            busyDraftId: _busyDraftId,
            draftOverrides: _draftStatus,
            onConfirmDraft: _confirmDraft,
            onEditDraft: _editDraft,
            onCancelDraft: _cancelDraft,
          );
          if (!newDay) {
            return bubble;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AgentDayDivider(atMs: msg.createdAtMs),
              bubble,
            ],
          );
        }
        final afterMessages = index - _messages.length;
        if (_pendingUserText != null && afterMessages == 0) {
          return AgentMessageBubble(
            message: AgentMessage(
              id: '_pending',
              role: AgentRole.user,
              text: _pendingUserText!,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
            onConfirmDraft: (_) {},
            onEditDraft: (_) {},
            onCancelDraft: (_) {},
          );
        }
        return const AgentTypingIndicator();
      },
    );
  }

  Widget _emptyState() {
    const prompts = [
      'kal 11 baje rohan ke saath meeting hai new labels ke regarding',
      'aaj kisko call karna hai?',
      'koi important cheez hai kya?',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('✨', style: TextStyle(fontSize: 34)),
            const SizedBox(height: 14),
            Text(
              'Boliye, kya chal raha hai?',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFFE2E8F0),
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tell me a job, ask a question, or just talk.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B), height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 22),
            for (final p in prompts) _promptChip(p),
          ],
        ),
      ),
    );
  }

  Widget _promptChip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _input.text = text;
            _inputFocus.requestFocus();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pendingFiles.isNotEmpty) _attachmentChips(),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: const Color(0xFF10141F),
              border: Border.all(
                color: _inputFocus.hasFocus
                    ? const Color(0xFF22D3EE).withValues(alpha: 0.45)
                    : const Color(0xFF1E293B),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: IconButton(
                    tooltip: 'Attach a photo or PDF',
                    onPressed: _sending ? null : _showAttachSheet,
                    icon: Icon(
                      Icons.attach_file_rounded,
                      color: _pendingFiles.isNotEmpty
                          ? AivyUi.brand
                          : const Color(0xFF94A3B8),
                      size: 22,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      color: Color(0xFFE7EDF5),
                      fontSize: 15,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Type anything, or attach a file…',
                      hintStyle: TextStyle(color: Color(0xFF475569), fontSize: 15),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _sendButton(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachmentChips() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final file in _pendingFiles)
            InputChip(
              avatar: Icon(
                file.isPdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
                size: 16,
                color: AivyUi.brand,
              ),
              label: Text(
                file.name,
                overflow: TextOverflow.ellipsis,
              ),
              labelStyle: const TextStyle(color: AivyUi.ink, fontSize: 12),
              backgroundColor: AivyUi.surfaceHigh,
              side: const BorderSide(color: AivyUi.line),
              onDeleted: _sending
                  ? null
                  : () => setState(() => _pendingFiles.remove(file)),
            ),
        ],
      ),
    );
  }

  Widget _sendButton() {
    final enabled = _canSend;
    return Material(
      color: enabled ? const Color(0xFF22D3EE) : const Color(0xFF1E293B),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                unawaited(_send());
              }
            : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: _sending
              ? const Padding(
                  padding: EdgeInsets.all(11),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Color(0xFF64748B)),
                  ),
                )
              : Icon(
                  Icons.arrow_upward_rounded,
                  size: 20,
                  color: enabled ? const Color(0xFF06202B) : const Color(0xFF475569),
                ),
        ),
      ),
    );
  }
}
