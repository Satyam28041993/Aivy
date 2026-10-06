import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/agent_service.dart';
import '../models/agent_models.dart';
import 'voice_intent.dart';
import 'voice_recorder.dart';
import 'voice_service.dart';

/// Talking to Aivy face to face: a dark sky, a living orb, and a conversation
/// that keeps going on its own — she listens, answers out loud, and listens
/// again, like Gemini Live.
///
/// It is the same Aivy as the chat, not a second assistant (the retired voice
/// home's mistake): every turn goes through `aivyAgent` into the same
/// conversation, so whatever is said here is in the chat afterwards.
class AivyVoiceScreen extends StatefulWidget {
  const AivyVoiceScreen({
    super.key,
    this.chatId,
    this.onChatId,
    this.service,
  });

  final String? chatId;

  /// Called when the first turn starts a conversation, so the chat behind
  /// shows it.
  final ValueChanged<String>? onChatId;

  final AgentService? service;

  static Future<void> open(
    BuildContext context, {
    String? chatId,
    ValueChanged<String>? onChatId,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => AivyVoiceScreen(chatId: chatId, onChatId: onChatId),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  State<AivyVoiceScreen> createState() => _AivyVoiceScreenState();
}

enum _Phase { idle, listening, thinking, speaking }

class _AivyVoiceScreenState extends State<AivyVoiceScreen> with TickerProviderStateMixin {
  late final AgentService _service = widget.service ?? AgentService();
  final VoiceRecorder _recorder = VoiceRecorder();
  final VoiceService _voice = VoiceService();

  late final AnimationController _sky = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 90),
  )..repeat();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  _Phase _phase = _Phase.idle;
  String? _chatId;
  String _heard = '';
  String _reply = '';
  AgentDraft? _card;
  String? _armedDeleteId;

  /// Keeps the conversation going: after she speaks, listen again.
  bool _live = true;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _chatId = widget.chatId;
    _voice.speaking.addListener(_onSpeakingChanged);
    // Open the way Gemini Live does: already listening.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_listen()));
  }

  @override
  void dispose() {
    _closing = true;
    _voice.speaking.removeListener(_onSpeakingChanged);
    unawaited(_recorder.dispose());
    unawaited(_voice.dispose());
    _sky.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (mounted && !_closing) {
      setState(fn);
    }
  }

  void _onSpeakingChanged() {
    if (_voice.speaking.value) {
      _set(() => _phase = _Phase.speaking);
      return;
    }
    if (_phase == _Phase.speaking) {
      _set(() => _phase = _Phase.idle);
      if (_live && !_closing) {
        // A beat of quiet before listening, so her last word is not heard
        // as the start of his.
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (_live && !_closing && _phase == _Phase.idle) {
            unawaited(_listen());
          }
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // The conversation
  // ---------------------------------------------------------------------------

  Future<void> _listen() async {
    if (_phase == _Phase.listening || _phase == _Phase.thinking || _closing) {
      return;
    }
    await _voice.stop();
    HapticFeedback.lightImpact();
    _set(() => _phase = _Phase.listening);
    Uint8List? wav;
    try {
      wav = await _recorder.record();
    } catch (e) {
      _set(() {
        _phase = _Phase.idle;
        _reply = 'I need the microphone — please allow it in settings.';
      });
      return;
    }
    if (_closing) {
      return;
    }
    if (wav == null) {
      // Nothing said: rest rather than loop on silence.
      _set(() => _phase = _Phase.idle);
      return;
    }
    _set(() => _phase = _Phase.thinking);
    String said = '';
    try {
      said = await _voice.transcribe(wav);
    } catch (_) {}
    if (_closing) {
      return;
    }
    if (said.isEmpty) {
      _set(() {
        _phase = _Phase.idle;
        _reply = "Sorry, I didn't catch that. Tap and say it again?";
      });
      unawaited(_voice.speak(_reply));
      return;
    }
    _set(() => _heard = said);
    await _answer(said);
  }

  Future<void> _answer(String said) async {
    final card = _card;
    final answer = readVoiceAnswer(said);
    if (card != null && answer == VoiceAnswer.yes) {
      if (card.kind == 'delete_record' && _armedDeleteId != card.id) {
        _armedDeleteId = card.id;
        await _say('Delete it for sure? Say yes once more.');
        return;
      }
      await _confirm(card);
      return;
    }
    if (card != null && answer == VoiceAnswer.no) {
      await _dismiss(card);
      return;
    }
    _armedDeleteId = null;
    _set(() => _phase = _Phase.thinking);
    try {
      final res = await _service.send(text: said, chatId: _chatId, spoken: true);
      if (res.chatId.isNotEmpty && res.chatId != _chatId) {
        _chatId = res.chatId;
        widget.onChatId?.call(res.chatId);
      }
      final waiting = res.drafts.where((d) => d.isPending).toList(growable: false);
      _set(() => _card = waiting.length == 1 ? waiting.first : null);
      await _say(res.reply.isNotEmpty ? res.reply : "I'm here — say that once more?");
    } catch (_) {
      await _say("I couldn't reach the server just now. Try again in a moment?");
    }
  }

  Future<void> _confirm(AgentDraft card) async {
    _armedDeleteId = null;
    _set(() => _phase = _Phase.thinking);
    try {
      final res = await _service.commit(draftId: card.id, chatId: _chatId);
      _set(() => _card = res.ok ? null : _card);
      await _say(res.message.isNotEmpty ? res.message : (res.ok ? 'Done.' : 'That did not save.'));
    } catch (_) {
      await _say('That did not save — try once more?');
    }
  }

  Future<void> _dismiss(AgentDraft card) async {
    _armedDeleteId = null;
    _set(() => _card = null);
    unawaited(_service.cancelDraft(draftId: card.id).then((_) {}, onError: (_) {}));
    await _say('Okay, cancelled.');
  }

  Future<void> _say(String text) async {
    _set(() {
      _reply = text;
      _phase = _Phase.thinking;
    });
    await _voice.speak(text);
    // speak() returns when playback starts; if no audio came, settle.
    if (!_voice.speaking.value && _phase == _Phase.thinking) {
      _set(() => _phase = _Phase.idle);
    }
  }

  /// The orb is the one big control: talk, stop talking, or interrupt her.
  Future<void> _onOrb() async {
    switch (_phase) {
      case _Phase.listening:
        await _recorder.stop();
        break;
      case _Phase.speaking:
        await _voice.stop();
        _set(() => _phase = _Phase.idle);
        unawaited(_listen());
        break;
      case _Phase.idle:
        _set(() => _live = true);
        unawaited(_listen());
        break;
      case _Phase.thinking:
        break;
    }
  }

  Future<void> _togglePause() async {
    if (_live) {
      _set(() => _live = false);
      await _recorder.cancel();
      await _voice.stop();
      _set(() => _phase = _Phase.idle);
    } else {
      _set(() => _live = true);
      unawaited(_listen());
    }
  }

  void _close() {
    _closing = true;
    unawaited(_recorder.cancel());
    unawaited(_voice.stop());
    Navigator.of(context).maybePop();
  }

  String get _status {
    switch (_phase) {
      case _Phase.listening:
        return "I'm listening…";
      case _Phase.thinking:
        return 'Thinking…';
      case _Phase.speaking:
        return 'Aivy';
      case _Phase.idle:
        return _live ? 'Tap the orb and talk to me' : 'Paused — tap the orb when you are ready';
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final orbSize = math.min(size.width * 0.62, 280.0);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF03040B),
        body: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _sky,
              builder: (_, __) => CustomPaint(painter: _SpacePainter(_sky.value)),
            ),
            SafeArea(
              child: Column(
                children: [
                  _topBar(),
                  const Spacer(flex: 2),
                  GestureDetector(
                    onTap: () => unawaited(_onOrb()),
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_pulse, _recorder.level]),
                      builder: (_, __) => SizedBox(
                        width: orbSize * 1.5,
                        height: orbSize * 1.5,
                        child: CustomPaint(
                          painter: _OrbPainter(
                            t: _pulse.value,
                            phase: _phase,
                            level: _recorder.level.value,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      _status,
                      key: ValueKey(_status),
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 15,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  const Spacer(),
                  _captions(),
                  if (_card != null) _cardPanel(_card!),
                  const SizedBox(height: 12),
                  _controls(),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [Color(0xFFC4B5FD), Color(0xFF67E8F9), Color(0xFFF9A8D4)],
            ).createShader(r),
            child: const Text(
              'Aivy',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF8B5CF6).withValues(alpha: 0.5)),
              color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _live ? const Color(0xFF34D399) : const Color(0xFF64748B),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _live ? 'Live' : 'Paused',
                  style: const TextStyle(color: Color(0xFFDDD6FE), fontSize: 11.5),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Back to chat',
            onPressed: _close,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFFCBD5E1), size: 30),
          ),
        ],
      ),
    );
  }

  Widget _captions() {
    if (_heard.isEmpty && _reply.isEmpty) {
      return const SizedBox(height: 40);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_heard.isNotEmpty)
            Text(
              '“$_heard”',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14, fontStyle: FontStyle.italic),
            ),
          if (_reply.isNotEmpty) ...[
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                _reply,
                key: ValueKey(_reply),
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFF1F5F9), fontSize: 17, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cardPanel(AgentDraft card) {
    final lines = card.lines.take(3).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: const Color(0xFF0F172A).withValues(alpha: 0.72),
          border: Border.all(color: const Color(0xFF8B5CF6).withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(color: const Color(0xFF8B5CF6).withValues(alpha: 0.18), blurRadius: 24),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${card.icon}  ${card.title}',
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${l.label}: ${l.value}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                ),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Say “haan” to save',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(_dismiss(card)),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
                  onPressed: () => unawaited(_confirm(card)),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _roundButton(
          icon: _live ? Icons.pause_rounded : Icons.play_arrow_rounded,
          label: _live ? 'Pause' : 'Resume',
          onTap: () => unawaited(_togglePause()),
        ),
        const SizedBox(width: 28),
        _roundButton(
          icon: _phase == _Phase.listening ? Icons.stop_rounded : Icons.mic_rounded,
          label: _phase == _Phase.listening ? 'Done' : 'Talk',
          big: true,
          onTap: () => unawaited(_onOrb()),
        ),
        const SizedBox(width: 28),
        _roundButton(
          icon: Icons.close_rounded,
          label: 'End',
          danger: true,
          onTap: _close,
        ),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool big = false,
    bool danger = false,
  }) {
    final d = big ? 68.0 : 54.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: danger
              ? const Color(0xFFEF4444).withValues(alpha: 0.85)
              : big
                  ? const Color(0xFF8B5CF6)
                  : Colors.white.withValues(alpha: 0.10),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: d,
              height: d,
              child: Icon(icon, color: Colors.white, size: big ? 30 : 24),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5)),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// The sky: slow-drifting, twinkling stars over two faint nebulae.
// -----------------------------------------------------------------------------

class _Star {
  const _Star(this.x, this.y, this.r, this.speed, this.phase, this.depth);
  final double x;
  final double y;
  final double r;
  final double speed;
  final double phase;
  final double depth;
}

final List<_Star> _stars = () {
  final rnd = math.Random(7);
  return List<_Star>.generate(
    170,
    (_) => _Star(
      rnd.nextDouble(),
      rnd.nextDouble(),
      0.4 + rnd.nextDouble() * 1.4,
      0.5 + rnd.nextDouble() * 2.5,
      rnd.nextDouble() * math.pi * 2,
      0.2 + rnd.nextDouble() * 0.8,
    ),
  );
}();

class _SpacePainter extends CustomPainter {
  _SpacePainter(this.t);

  /// 0..1 over the sky's slow cycle.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF05061A), Color(0xFF070B24), Color(0xFF02030A)],
        ).createShader(rect),
    );
    void nebula(Offset c, double radius, Color color) {
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(
            Rect.fromCircle(center: c, radius: radius),
          ),
      );
    }

    final drift = math.sin(t * math.pi * 2);
    nebula(Offset(size.width * (0.15 + 0.03 * drift), size.height * 0.22), size.width * 0.75,
        const Color(0xFF6D28D9).withValues(alpha: 0.20));
    nebula(Offset(size.width * (0.9 - 0.03 * drift), size.height * 0.78), size.width * 0.7,
        const Color(0xFF0E7490).withValues(alpha: 0.16));
    nebula(Offset(size.width * 0.5, size.height * 0.45), size.width * 0.5,
        const Color(0xFFDB2777).withValues(alpha: 0.06));

    final star = Paint();
    final seconds = t * 90;
    for (final s in _stars) {
      final x = ((s.x + t * 0.05 * s.depth) % 1.0) * size.width;
      final y = s.y * size.height;
      final twinkle = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(seconds * s.speed + s.phase));
      star.color = Colors.white.withValues(alpha: twinkle * s.depth);
      canvas.drawCircle(Offset(x, y), s.r * s.depth, star);
    }
  }

  @override
  bool shouldRepaint(_SpacePainter old) => old.t != t;
}

// -----------------------------------------------------------------------------
// The orb: breathes when idle, swells with his voice, swirls while thinking,
// sends out ripples while she speaks.
// -----------------------------------------------------------------------------

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.phase, required this.level});

  final double t;
  final _Phase phase;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.shortestSide / 3;
    final wave = math.sin(t * math.pi * 2);

    double scale;
    switch (phase) {
      case _Phase.listening:
        scale = 1.0 + level * 0.28 + 0.02 * wave;
        break;
      case _Phase.thinking:
        scale = 0.94 + 0.03 * math.sin(t * math.pi * 8);
        break;
      case _Phase.speaking:
        scale = 1.04 + 0.05 * math.sin(t * math.pi * 10).abs();
        break;
      case _Phase.idle:
        scale = 1.0 + 0.03 * wave;
        break;
    }
    final r = base * scale;

    // Ripples while she speaks.
    if (phase == _Phase.speaking) {
      for (var i = 0; i < 3; i++) {
        final p = (t * 2 + i / 3) % 1.0;
        canvas.drawCircle(
          c,
          r * (1.05 + p * 0.6),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF67E8F9).withValues(alpha: (1 - p) * 0.35),
        );
      }
    }

    // Outer glow.
    canvas.drawCircle(
      c,
      r * 1.45,
      Paint()
        ..shader = RadialGradient(colors: [
          (phase == _Phase.listening ? const Color(0xFFF472B6) : const Color(0xFF8B5CF6)).withValues(alpha: 0.45),
          const Color(0xFF8B5CF6).withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r * 1.45)),
    );

    // The body: a turning sweep of violet, cyan and pink.
    final spin = t * math.pi * 2 * (phase == _Phase.thinking ? 3 : 1);
    final body = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          transform: GradientRotation(spin),
          colors: const [
            Color(0xFF7C3AED),
            Color(0xFF22D3EE),
            Color(0xFFF472B6),
            Color(0xFF6366F1),
            Color(0xFF7C3AED),
          ],
        ).createShader(body),
    );
    // Soft light from the top-left, so it reads as a sphere.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.9,
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.05),
            const Color(0xFF020617).withValues(alpha: 0.35),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(body),
    );
    // A thin rim.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.phase != phase || old.level != level;
}
