import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;

import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/aivy_build_id.dart';
import '../../../core/firebase/aivy_app_check_debug_token.dart';
import '../../../core/voice/home_voice_qa_session.dart';

/// Voice-first home: listen → report/memory Q&A → spoken answer (loop until stop).
class AivyVoiceHomeScreen extends StatefulWidget {
  const AivyVoiceHomeScreen({super.key, required this.userId});

  final String userId;

  @override
  State<AivyVoiceHomeScreen> createState() => _AivyVoiceHomeScreenState();
}

class _AivyVoiceHomeScreenState extends State<AivyVoiceHomeScreen>
    with TickerProviderStateMixin {
  /// One full turn ≈ 90s — readable, cinematic, low CPU.
  late final AnimationController _spiralRotation;
  late final AnimationController _twinkle;
  late final AnimationController _ringBreath;
  late final AnimationController _voiceSim;
  late final AnimationController _livePulse;
  final _stars = <_Star>[];
  final _math = math.Random(17);

  late final HomeVoiceQaSession _qa;

  /// Shown so a sideloaded build can be registered without a computer.
  String? _appCheckDebugToken;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAppCheckDebugToken());
    for (var i = 0; i < 260; i++) {
      _stars.add(
        _Star(
          x: _math.nextDouble(),
          y: _math.nextDouble(),
          r: 0.25 + _math.nextDouble() * 1.85,
          phase: _math.nextDouble() * math.pi * 2,
        ),
      );
    }
    _spiralRotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 90),
    )..repeat();
    _twinkle = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _ringBreath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);
    _voiceSim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 780),
    )..repeat(reverse: true);
    _livePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _qa = HomeVoiceQaSession(userId: widget.userId)
      ..onPhaseChanged = (_) {
        if (mounted) {
          setState(() {});
        }
      }
      ..onError = (msg) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
            backgroundColor: const Color(0xFF1E293B),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: Duration(seconds: msg.length > 80 ? 8 : 4),
          ),
        );
        setState(() {});
      };
  }

  @override
  void dispose() {
    unawaited(_qa.dispose());
    _spiralRotation.dispose();
    _twinkle.dispose();
    _ringBreath.dispose();
    _voiceSim.dispose();
    _livePulse.dispose();
    super.dispose();
  }

  double _simulatedVoiceLevel() {
    final a = _voiceSim.value;
    final b = Curves.easeInOut.transform(_ringBreath.value);
    return (0.38 + 0.5 * a * b).clamp(0.22, 0.98);
  }

  double _effectiveVoiceLevel() {
    if (_qa.phase == HomeVoiceQaPhase.speaking) {
      final a = _voiceSim.value;
      return (0.62 + 0.35 * a).clamp(0.52, 1.0);
    }
    if (_qa.phase == HomeVoiceQaPhase.listening) {
      final n = ((_qa.lastDb + 48).clamp(0.0, 48.0) / 48.0);
      return (0.45 + 0.5 * n).clamp(0.35, 1.0);
    }
    return _simulatedVoiceLevel();
  }

  String get _subtitle {
    if (!HomeVoiceQaSession.isSupportedOnThisPlatform) {
      return 'Voice sirf mobile app me chalti hai. Web par Chat use karein.';
    }
    if (_qa.isLegacyVoiceMode) {
      switch (_qa.phase) {
        case HomeVoiceQaPhase.idle:
          return 'Purana voice mode — mic dabakar boliye. Live ke liye naya session shuru karein.';
        case HomeVoiceQaPhase.listening:
          return 'Sun rahi hoon — bolne ke baad mic band karein ya 1–2s chup rahein.';
        case HomeVoiceQaPhase.processing:
          return 'Soch rahi hoon…';
        case HomeVoiceQaPhase.speaking:
          return 'Jawaab de rahi hoon…';
      }
    }
    if (!_qa.handsFreeEnabled) {
      switch (_qa.phase) {
        case HomeVoiceQaPhase.idle:
          return 'Mic dabayein, boliye, phir mic band karein.';
        case HomeVoiceQaPhase.listening:
          return 'Sun rahi hoon — bolne ke baad mic band karein.';
        case HomeVoiceQaPhase.processing:
          return 'Soch rahi hoon…';
        case HomeVoiceQaPhase.speaking:
          return 'Jawaab de rahi hoon…';
      }
    }
    switch (_qa.phase) {
      case HomeVoiceQaPhase.idle:
        return _qa.isGeminiLiveActive
            ? 'Live connected — boliye, mai sun rahi hoon.'
            : (_qa.turns.isEmpty
                ? 'Mic dabayein — Gemini Live jaisi continuous baat shuru hogi.'
                : 'Mic dabayein — conversation continue karein.');
      case HomeVoiceQaPhase.listening:
        return 'Sun rahi hoon… boliye; rukne par khud samajh lungi.';
      case HomeVoiceQaPhase.processing:
        return 'Soch rahi hoon…';
      case HomeVoiceQaPhase.speaking:
        return 'Jawaab de rahi hoon — mic dabakar interrupt kar sakte hain.';
    }
  }

  Future<void> _onMicTap() => _qa.toggleMic();

  Future<void> _loadAppCheckDebugToken() async {
    // The provider logs the secret while App Check activates, so the buffer may
    // not hold it yet on the very first frame.
    for (final wait in const [Duration.zero, Duration(seconds: 3)]) {
      await Future<void>.delayed(wait);
      final token = await AivyAppCheckDebugToken.read();
      if (!mounted) {
        return;
      }
      if (token != null) {
        setState(() => _appCheckDebugToken = token);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final listenGalaxy = Listenable.merge([_spiralRotation, _twinkle]);

    return Scaffold(
      backgroundColor: const Color(0xFF01040C),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Deep space base
          const ColoredBox(color: Color(0xFF01040C)),
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: listenGalaxy,
              builder: (context, _) {
                final rot = _spiralRotation.value * math.pi * 2;
                return CustomPaint(
                  painter: _SpiralGalaxyPainter(
                    rotation: rot,
                    twinkle: _twinkle.value,
                    stars: _stars,
                    phase: _qa.phase,
                  ),
                );
              },
            ),
          ),
          // Shifting atmospheric nebula glow
          ListenableBuilder(
            listenable: _spiralRotation,
            builder: (context, _) {
              final u = _spiralRotation.value;
              final t = u * math.pi * 2;
              
              Color nebulaColor;
              if (_qa.phase == HomeVoiceQaPhase.listening) {
                nebulaColor = const Color(0xFF059669).withValues(alpha: 0.16); // Green
              } else if (_qa.phase == HomeVoiceQaPhase.processing) {
                nebulaColor = const Color(0xFF7C3AED).withValues(alpha: 0.18); // Purple
              } else if (_qa.phase == HomeVoiceQaPhase.speaking) {
                nebulaColor = const Color(0xFFD97706).withValues(alpha: 0.16); // Amber
              } else {
                nebulaColor = const Color(0xFF0EA5E9).withValues(alpha: 0.14); // Blue
              }

              return IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 800),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(
                        math.cos(t * 0.55) * 0.42,
                        math.sin(t * 0.38) * 0.36,
                      ),
                      radius: 1.05,
                      colors: [
                        nebulaColor,
                        const Color(0xFF312E81).withValues(alpha: 0.08),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              );
            },
          ),
          // Dual layer sound wave visualization
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_ringBreath, _voiceSim, _spiralRotation]),
              builder: (context, _) {
                final level = _effectiveVoiceLevel();
                final breath = Curves.easeInOut.transform(_ringBreath.value);
                final sz = MediaQuery.sizeOf(context);
                final side = math.max(sz.width, sz.height) * 0.95;
                return SizedBox(
                  width: side,
                  height: side,
                  child: CustomPaint(
                    painter: _VoiceRingsPainter(
                      breath: breath,
                      voiceLevel: level,
                      tick: _spiralRotation.value,
                      warmLayer: true,
                      phase: _qa.phase,
                    ),
                  ),
                );
              },
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_ringBreath, _voiceSim, _spiralRotation]),
              builder: (context, _) {
                final level = _effectiveVoiceLevel();
                final breath = Curves.easeInOut.transform(_ringBreath.value);
                final sz = MediaQuery.sizeOf(context);
                final side = math.max(sz.width, sz.height) * 0.88;
                return SizedBox(
                  width: side,
                  height: side,
                  child: CustomPaint(
                    painter: _VoiceRingsPainter(
                      breath: breath,
                      voiceLevel: level,
                      tick: -_spiralRotation.value * 1.15,
                      warmLayer: false,
                      phase: _qa.phase,
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _VignettePainter(),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              // Large bottom padding (140) to guarantee the transcript card never overlaps the mic bar
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Symmetrical Premium Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Live mode pill (default ON)
                      GestureDetector(
                        onTap: () async {
                          await HapticFeedback.selectionClick();
                          setState(() {
                            _qa.handsFreeEnabled = !_qa.handsFreeEnabled;
                          });
                        },
                        onLongPress: () async {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          await HapticFeedback.heavyImpact();
                          _qa.useLegacyVoiceMode();
                          if (!mounted) return;
                          messenger?.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Purana slow voice mode ON. Gemini Live ke liye App Check debug token register karein.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              duration: Duration(seconds: 6),
                            ),
                          );
                          setState(() {});
                        },
                        child: AnimatedBuilder(
                          animation: _livePulse,
                          builder: (context, _) {
                            final live = _qa.handsFreeEnabled;
                            final pulse = live
                                ? 0.55 + 0.45 * _livePulse.value
                                : 0.35;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: live
                                    ? const Color(0xFF10B981).withValues(alpha: 0.12)
                                    : Colors.white.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: live
                                      ? const Color(0xFF10B981).withValues(alpha: 0.45)
                                      : Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: live
                                          ? const Color(0xFF34D399)
                                              .withValues(alpha: pulse)
                                          : Colors.white38,
                                      boxShadow: live
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFF34D399)
                                                    .withValues(alpha: 0.55 * pulse),
                                                blurRadius: 8,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Live',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: live
                                              ? const Color(0xFF6EE7B7)
                                              : Colors.white54,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.4,
                                        ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      // Title in the Center
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Aivy',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.94),
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                ),
                          ),
                          ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [
                                Color(0xFFE0F2FE),
                                Color(0xFF7DD3FC),
                                Color(0xFFA78BFA),
                              ],
                            ).createShader(bounds),
                            child: Text(
                              'Voice',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5,
                                    height: 1.0,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      // Reset Button on the Right (swapped to match user instruction)
                      IconButton(
                        tooltip: 'Clear conversation',
                        icon: const Icon(Icons.refresh_rounded, color: Colors.white38),
                        onPressed: () async {
                          await HapticFeedback.heavyImpact();
                          _qa.reset();
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _subtitle,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.52),
                          height: 1.4,
                        ),
                  ),
                  // Without a moving indicator the screen reads as frozen while
                  // the model is working.
                  if (_qa.phase != HomeVoiceQaPhase.idle) ...[
                    const SizedBox(height: 12),
                    _PhaseDots(phase: _qa.phase),
                    if (_qa.isGeminiLiveActive) ...[
                      const SizedBox(height: 8),
                      Text(
                        'mic ${_qa.liveMicChunksSeen}/${_qa.liveMicChunks}'
                        ' · server ${_qa.liveServerMessages}'
                        ' · ${_qa.lastDb.toStringAsFixed(0)}dB'
                        ' · $kAivyBuildId',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Colors.white38,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                    ],
                  ],

                  // Registering this in Firebase Console is what lets a
                  // sideloaded build past App Check enforcement.
                  if (_appCheckDebugToken != null) ...[
                    const SizedBox(height: 8),
                    _AppCheckDebugTokenRow(token: _appCheckDebugToken!),
                  ],

                  // Running conversation transcript (Gemini-style)
                  if (_qa.turns.isNotEmpty ||
                      (_qa.lastTranscript != null &&
                          _qa.lastTranscript!.isNotEmpty) ||
                      (_qa.lastAnswer != null && _qa.lastAnswer!.isNotEmpty) ||
                      _qa.phase == HomeVoiceQaPhase.processing) ...[
                    const SizedBox(height: 16),
                    Expanded(
                      child: _VoiceConversationTranscript(
                        turns: _qa.turns,
                        pendingTranscript: _qa.lastTranscript,
                        pendingAnswer: _qa.lastAnswer,
                        pendingSources: _qa.lastSources,
                        phase: _qa.phase,
                      ),
                    ),
                  ] else
                    const Spacer(),
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 16 + bottomInset,
            child: _VoiceConversationBar(
              ringBreath: _ringBreath,
              voiceSim: _voiceSim,
              voiceLevel: _effectiveVoiceLevel,
              phase: _qa.phase,
              onMicTap: _onMicTap,
              onCancelTap: _qa.cancelRecording,
              onStopSpeaking: _qa.stopSpeaking,
            ),
          ),
        ],
      ),
    );
  }
}

class _Star {
  const _Star({required this.x, required this.y, required this.r, required this.phase});
  final double x;
  final double y;
  final double r;
  final double phase;
}

class _SpiralGalaxyPainter extends CustomPainter {
  _SpiralGalaxyPainter({
    required this.rotation,
    required this.twinkle,
    required this.stars,
    required this.phase,
  });

  final double rotation;
  final double twinkle;
  final List<_Star> stars;
  final HomeVoiceQaPhase phase;

  static const _armCount = 3;
  static const _k = 0.175;
  static const _r0 = 2.8;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.48;
    final c = Offset(cx, cy);
    final maxR = math.min(size.width, size.height) * 0.52;

    final rect = Offset.zero & size;
    
    // Galactic background shifts slightly based on active phase
    Color baseCoreColor;
    if (phase == HomeVoiceQaPhase.listening) {
      baseCoreColor = const Color(0xFF042F1A); // Emerald depth
    } else if (phase == HomeVoiceQaPhase.processing) {
      baseCoreColor = const Color(0xFF2E1065); // Violet depth
    } else if (phase == HomeVoiceQaPhase.speaking) {
      baseCoreColor = const Color(0xFF451A03); // Gold/Bronze depth
    } else {
      baseCoreColor = const Color(0xFF082F49); // Blue depth
    }

    final deep = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.15),
        radius: 1.05,
        colors: [
          baseCoreColor,
          const Color(0xFF020617),
          const Color(0xFF00040A),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, deep);

    // Bright galactic core
    final core = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.95),
          const Color(0xFFE0F2FE).withValues(alpha: 0.55),
          const Color(0xFF38BDF8).withValues(alpha: 0.22),
          Colors.transparent,
        ],
        stops: const [0.0, 0.12, 0.35, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: maxR * 0.14));
    canvas.drawCircle(c, maxR * 0.11, core);

    // Spiral arms: dense points along log spiral
    for (var arm = 0; arm < _armCount; arm++) {
      final armBase = rotation + arm * (math.pi * 2 / _armCount);
      for (var theta = -0.35 * math.pi; theta < 4.6 * math.pi; theta += 0.045) {
        final r = _r0 * math.exp(_k * theta);
        if (r > maxR * 1.02) {
          break;
        }
        final ang = theta + armBase;
        final p = Offset(cx + math.cos(ang) * r, cy + math.sin(ang) * r);
        final tNorm = (r / maxR).clamp(0.0, 1.0);
        final dust = 0.18 * math.sin(theta * 3.1 + arm * 1.7);
        final bright = (1 - tNorm) * (0.55 + dust * 0.25);
        
        Color armParticleColor;
        if (phase == HomeVoiceQaPhase.listening) {
          armParticleColor = const Color(0xFF34D399); // Emerald
        } else if (phase == HomeVoiceQaPhase.processing) {
          armParticleColor = const Color(0xFFC084FC); // Purple
        } else if (phase == HomeVoiceQaPhase.speaking) {
          armParticleColor = const Color(0xFFFBBF24); // Gold
        } else {
          armParticleColor = const Color(0xFF0369A1); // Sky blue
        }

        final col = Color.lerp(
          const Color(0xFFFFFFFF),
          armParticleColor,
          tNorm * 0.92,
        )!
            .withValues(alpha: (0.06 + bright * 0.42).clamp(0.04, 0.72));
        final pr = 0.6 + (1 - tNorm) * 2.4 + dust.abs() * 0.8;
        canvas.drawCircle(p, pr, Paint()..color = col);
      }
    }

    // Distant stars
    final cosR = math.cos(rotation * 0.12);
    final sinR = math.sin(rotation * 0.12);
    for (final s in stars) {
      final lx = s.x * size.width - cx;
      final ly = s.y * size.height - cy;
      final rx = lx * cosR - ly * sinR + cx;
      final ry = lx * sinR + ly * cosR + cy;
      final tw = 0.42 +
          0.58 *
              (0.5 +
                  0.5 * math.sin(twinkle * math.pi * 2 + s.phase));
      final p = Paint()
        ..color = Colors.white.withValues(
          alpha: (0.06 + tw * 0.62).clamp(0.04, 0.9),
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.35);
      canvas.drawCircle(Offset(rx, ry), s.r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _SpiralGalaxyPainter oldDelegate) {
    return oldDelegate.rotation != rotation ||
        oldDelegate.twinkle != twinkle ||
        oldDelegate.phase != phase;
  }
}

class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.92,
        colors: [
          Colors.transparent,
          const Color(0xFF000008).withValues(alpha: 0.5),
          const Color(0xFF000008).withValues(alpha: 0.78),
        ],
        stops: const [0.42, 0.78, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _VignettePainter oldDelegate) => false;
}

class _VoiceRingsPainter extends CustomPainter {
  _VoiceRingsPainter({
    required this.breath,
    required this.voiceLevel,
    required this.tick,
    required this.warmLayer,
    required this.phase,
  });

  final double breath;
  final double voiceLevel;
  final double tick;
  final bool warmLayer;
  final HomeVoiceQaPhase phase;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final dim = math.min(size.width, size.height);
    final base = dim * (warmLayer ? 0.14 : 0.12);
    final rings = warmLayer ? 14 : 12;

    for (var i = 0; i < rings; i++) {
      final t = i / (rings - 1);
      final wobble = 0.055 * math.sin(tick * math.pi * 2 * 1.4 + i * 0.65 + (warmLayer ? 0 : 1.1));
      final radius = base *
          (1.02 + t * (warmLayer ? 2.85 : 2.45)) *
          (1 + breath * 0.09 + voiceLevel * 0.2 + wobble);

      final opacity = lerpDouble(0.58, 0.05, t)! *
          (warmLayer ? 0.62 + voiceLevel * 0.38 : 0.48 + voiceLevel * 0.42);

      Color ringColor;
      if (phase == HomeVoiceQaPhase.listening) {
        // Shifting Teal/Emerald green (Listening)
        ringColor = Color.lerp(
          const Color(0xFF10B981),
          const Color(0xFF14B8A6),
          t * 0.9 + 0.1 * math.sin(tick * math.pi * 2 + i),
        )!;
      } else if (phase == HomeVoiceQaPhase.processing) {
        // Shifting Purple/Magenta (Thinking)
        ringColor = Color.lerp(
          const Color(0xFF8B5CF6),
          const Color(0xFFEC4899),
          t * 0.9,
        )!;
      } else if (phase == HomeVoiceQaPhase.speaking) {
        // Shifting Gold/Orange (Replying)
        ringColor = Color.lerp(
          const Color(0xFFF59E0B),
          const Color(0xFFEF4444),
          t * 0.85 + 0.08 * math.sin(tick * math.pi * 2 + i),
        )!;
      } else {
        // Shifting Blues/Indigos (Idle/Breathing)
        if (warmLayer) {
          ringColor = Color.lerp(
            const Color(0xFFFFB4A2),
            const Color(0xFF7DD3FC),
            t * 0.85 + 0.08 * math.sin(tick * math.pi * 2 + i),
          )!;
        } else {
          ringColor = Color.lerp(
            const Color(0xFFBAE6FD),
            const Color(0xFFC4B5FD),
            t * 0.9,
          )!;
        }
      }

      final stroke = (warmLayer ? 3.2 : 2.4) +
          voiceLevel * (warmLayer ? 5.5 : 4.2) -
          t * (warmLayer ? 0.95 : 0.75);

      final paint = Paint()
        ..color = ringColor.withValues(alpha: opacity.clamp(0.03, 0.62))
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.clamp(1.1, warmLayer ? 9.0 : 7.5)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          warmLayer ? 1.2 + voiceLevel * 2.8 : 0.8 + voiceLevel * 2.0,
        );

      canvas.drawCircle(c, radius, paint);

      // Premium shimmer echo ring
      if (i % 3 == 0 && warmLayer) {
        final echo = Paint()
          ..color = Colors.white.withValues(alpha: 0.08 + voiceLevel * 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1;
        canvas.drawCircle(c, radius + 3 + voiceLevel * 6, echo);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceRingsPainter oldDelegate) {
    return oldDelegate.breath != breath ||
        oldDelegate.voiceLevel != voiceLevel ||
        oldDelegate.tick != tick ||
        oldDelegate.warmLayer != warmLayer ||
        oldDelegate.phase != phase;
  }
}

/// Floating Transcript & Response Card (Glassmorphic look)
/// Scrollable multi-turn transcript — older turns static, latest answer typewriter.
class _VoiceConversationTranscript extends StatefulWidget {
  const _VoiceConversationTranscript({
    required this.turns,
    required this.pendingTranscript,
    required this.pendingAnswer,
    required this.pendingSources,
    required this.phase,
  });

  final List<VoiceConversationTurn> turns;
  final String? pendingTranscript;
  final String? pendingAnswer;
  final List<dynamic>? pendingSources;
  final HomeVoiceQaPhase phase;

  @override
  State<_VoiceConversationTranscript> createState() =>
      _VoiceConversationTranscriptState();
}

class _VoiceConversationTranscriptState extends State<_VoiceConversationTranscript> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _VoiceConversationTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showPending = widget.phase == HomeVoiceQaPhase.processing ||
        widget.phase == HomeVoiceQaPhase.speaking ||
        (widget.pendingAnswer != null && widget.pendingAnswer!.isNotEmpty);

    return ListView.builder(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: widget.turns.length + (showPending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < widget.turns.length) {
          final turn = widget.turns[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _VoiceTranscriptCard(
              transcript: turn.userText,
              answer: turn.assistantText,
              phase: HomeVoiceQaPhase.idle,
              sources: turn.sources,
              animateAnswer: false,
            ),
          );
        }
        return _VoiceTranscriptCard(
          transcript: widget.pendingTranscript ?? '',
          answer: widget.pendingAnswer ?? '',
          phase: widget.phase,
          sources: widget.pendingSources,
          animateAnswer: widget.phase == HomeVoiceQaPhase.speaking,
        );
      },
    );
  }
}

class _VoiceTranscriptCard extends StatelessWidget {
  const _VoiceTranscriptCard({
    required this.transcript,
    required this.answer,
    required this.phase,
    this.sources,
    this.animateAnswer = true,
  });

  final String transcript;
  final String answer;
  final HomeVoiceQaPhase phase;
  final List<dynamic>? sources;
  final bool animateAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: width,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 32,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (transcript.isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.record_voice_over_rounded, color: Color(0xFF38BDF8), size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Aapka Sawaal:',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: const Color(0xFF38BDF8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    transcript,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                if (transcript.isNotEmpty && answer.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Divider(color: Colors.white12, height: 1),
                  ),
                if (answer.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [Color(0xFFA78BFA), Color(0xFFFBCFE8)],
                            ).createShader(bounds),
                            child: const Icon(Icons.psychology_rounded, size: 18),
                          ),
                          const SizedBox(width: 8),
                          ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [Color(0xFFE0F2FE), Color(0xFFA78BFA)],
                            ).createShader(bounds),
                            child: Text(
                              'Aivy:',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (sources != null && sources!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF10B981).withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.language_rounded, color: Color(0xFF10B981), size: 10),
                              const SizedBox(width: 4),
                              Text(
                                'Google Searched',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFF10B981),
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (animateAnswer)
                    _TypingText(
                      text: answer,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.25,
                      ),
                    )
                  else
                    Text(
                      answer,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.25,
                      ),
                    ),
                  if (sources != null && sources!.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(color: Colors.white12, height: 1),
                    ),
                    Text(
                      'Sources Checked:',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: sources!.map((src) {
                        final title = src['title']?.toString() ?? 'Web Result';
                        final url = src['link']?.toString() ?? '';
                        String domain = '';
                        try {
                          final uri = Uri.parse(url);
                          domain = uri.host.replaceFirst('www.', '');
                        } catch (_) {
                          domain = 'link';
                        }

                        return InkWell(
                          onTap: url.isEmpty
                              ? null
                              : () async {
                                  await HapticFeedback.selectionClick();
                                  final uri = Uri.parse(url);
                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                                  }
                                },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.07),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.link_rounded, color: Colors.white38, size: 10),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    domain.isNotEmpty ? domain : title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white54,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
                if (phase == HomeVoiceQaPhase.processing) ...[
                  if (transcript.isNotEmpty) const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1B4B).withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFFA78BFA).withValues(alpha: 0.25),
                          ),
                        ),
                        child: const Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFC4B5FD),
                              ),
                            ),
                            SizedBox(width: 10),
                            Text(
                              'Soch rahi hoon…',
                              style: TextStyle(
                                color: Color(0xFFE9D5FF),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Character-by-character typwriter effect for premium conversational flow
class _TypingText extends StatefulWidget {
  const _TypingText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_TypingText> createState() => _TypingTextState();
}

class _TypingTextState extends State<_TypingText> {
  String _visibleText = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTyping();
  }

  @override
  void didUpdateWidget(covariant _TypingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _startTyping();
    }
  }

  void _startTyping() {
    _timer?.cancel();
    // Show full answer immediately so text stays in sync with spoken audio.
    // (Character typewriter lagged far behind TTS on long replies.)
    _visibleText = widget.text;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _visibleText,
      style: widget.style,
    );
  }
}

/// Bottom bar: Cancel (while recording) · Mic ON/OFF (center).
class _VoiceConversationBar extends StatelessWidget {
  const _VoiceConversationBar({
    required this.ringBreath,
    required this.voiceSim,
    required this.voiceLevel,
    required this.phase,
    required this.onMicTap,
    required this.onCancelTap,
    required this.onStopSpeaking,
  });

  final AnimationController ringBreath;
  final AnimationController voiceSim;
  final double Function() voiceLevel;
  final HomeVoiceQaPhase phase;
  final VoidCallback onMicTap;
  final Future<void> Function() onCancelTap;
  final Future<void> Function() onStopSpeaking;

  @override
  Widget build(BuildContext context) {
    final busy = phase == HomeVoiceQaPhase.processing;
    final listening = phase == HomeVoiceQaPhase.listening;
    final speaking = phase == HomeVoiceQaPhase.speaking;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (listening)
          _BarIconButton(
            icon: Icons.close_rounded,
            label: 'Cancel',
            highlight: const Color(0xFFFCA5A5),
            onTap: () async {
              await HapticFeedback.selectionClick();
              await onCancelTap();
            },
          )
        else if (speaking || busy)
          _BarIconButton(
            icon: Icons.volume_off_rounded,
            label: 'Stop',
            highlight: const Color(0xFFFCD34D),
            onTap: () async {
              await HapticFeedback.mediumImpact();
              await onStopSpeaking();
            },
          )
        else
          const SizedBox(width: 56),
        const Spacer(),
        _VoiceHomeMic(
          ringBreath: ringBreath,
          voiceSim: voiceSim,
          voiceLevel: voiceLevel,
          busy: busy,
          listening: listening,
          speaking: speaking,
          onTap: onMicTap, // Don't block click so user can cancel processing
        ),
        const Spacer(),
        const SizedBox(width: 56),
      ],
    );
  }
}

class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: highlight ?? Colors.white.withValues(alpha: 0.88),
                size: 28,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceHomeMic extends StatelessWidget {
  const _VoiceHomeMic({
    required this.ringBreath,
    required this.voiceSim,
    required this.voiceLevel,
    required this.busy,
    required this.listening,
    required this.speaking,
    required this.onTap,
  });

  final AnimationController ringBreath;
  final AnimationController voiceSim;
  final double Function() voiceLevel;
  final bool busy;
  final bool listening;
  final bool speaking;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([ringBreath, voiceSim]),
      builder: (context, _) {
        final v = Curves.easeInOut.transform(ringBreath.value);
        final lv = voiceLevel();
        final s = 1.0 + v * 0.07 + lv * 0.1;
        final icon = listening
            ? Icons.stop_circle_rounded
            : busy
            ? Icons.hourglass_top_rounded
            : speaking
            ? Icons.mic_rounded
            : Icons.mic_rounded;
        final label = listening
            ? 'End'
            : busy
            ? 'Cancel'
            : speaking
            ? 'Interrupt'
            : 'Start';
            
        Color micGradientStart;
        Color micGradientEnd;
        if (listening) {
          micGradientStart = const Color(0xFFEF4444);
          micGradientEnd = const Color(0xFFB91C1C);
        } else if (busy) {
          micGradientStart = const Color(0xFF8B5CF6);
          micGradientEnd = const Color(0xFF6D28D9);
        } else {
          micGradientStart = const Color(0xFF0EA5E9);
          micGradientEnd = const Color(0xFF4F46E5);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.scale(
              scale: s,
              child: Opacity(
                opacity: busy ? 0.8 : 1,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFFBAE6FD).withValues(alpha: 0.55),
                            const Color(0xFFA78BFA).withValues(alpha: 0.52),
                            const Color(0xFF38BDF8).withValues(alpha: 0.48),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (listening 
                                    ? const Color(0xFFEF4444)
                                    : busy
                                      ? const Color(0xFF8B5CF6)
                                      : const Color(0xFF38BDF8))
                                .withValues(alpha: 0.35 + lv * 0.35),
                            blurRadius: 48 + lv * 32,
                            spreadRadius: 2 + lv * 8,
                          ),
                        ],
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [
                              micGradientStart.withValues(alpha: 0.35),
                              micGradientStart,
                              micGradientEnd,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: onTap,
                            child: SizedBox(
                              width: 96,
                              height: 96,
                              child: Icon(
                                icon,
                                color: Colors.white,
                                size: 44,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (busy)
                      const SizedBox(
                        width: 110,
                        height: 110,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Color(0xFFA78BFA),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: listening
                        ? const Color(0xFFFCA5A5)
                        : Colors.white.withValues(alpha: 0.88),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        );
      },
    );
  }
}

/// Three dots that travel in a wave, tinted per phase.
///
/// The orb alone does not read as progress — users reported the screen looking
/// hung while Gemini was still working.
class _PhaseDots extends StatefulWidget {
  const _PhaseDots({required this.phase});

  final HomeVoiceQaPhase phase;

  @override
  State<_PhaseDots> createState() => _PhaseDotsState();
}

class _PhaseDotsState extends State<_PhaseDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  /// Lighter tints of the nebula colours this screen already uses per phase.
  Color get _tint {
    switch (widget.phase) {
      case HomeVoiceQaPhase.listening:
        return const Color(0xFF4ADE80);
      case HomeVoiceQaPhase.processing:
        return const Color(0xFFA78BFA);
      case HomeVoiceQaPhase.speaking:
        return const Color(0xFFFBBF24);
      case HomeVoiceQaPhase.idle:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tint = _tint;
    return AnimatedBuilder(
      animation: _wave,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            // Stagger each dot a third of a cycle apart.
            final t = (_wave.value + i / 3) % 1.0;
            final lift = math.sin(t * 2 * math.pi);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Transform.translate(
                offset: Offset(0, -3 * lift),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(
                      alpha: 0.35 + 0.45 * ((lift + 1) / 2),
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// The App Check debug secret, with a copy button.
///
/// A sideloaded APK cannot use Play Integrity, so App Check accepts it only
/// once this secret is on the allow list in Firebase Console -> App Check ->
/// Apps -> Manage debug tokens. It is normally reachable only over adb.
class _AppCheckDebugTokenRow extends StatelessWidget {
  const _AppCheckDebugTokenRow({required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white38,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text('App Check debug token', style: style),
          const SizedBox(height: 2),
          SelectableText(
            token,
            textAlign: TextAlign.center,
            style: style?.copyWith(color: Colors.white60),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
              if (!context.mounted) {
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Copied — Firebase Console → App Check → Apps → '
                    'Manage debug tokens me paste karein.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy'),
            style: TextButton.styleFrom(foregroundColor: Colors.white54),
          ),
        ],
      ),
    );
  }
}
