/// Gemini Live audio playback, picked per platform.
///
/// Native builds use `flutter_soloud`; the web uses the Web Audio API, because
/// SoLoud needs SharedArrayBuffer (and therefore COOP/COEP headers that would
/// break the app's other cross-origin resources).
library;

export 'gemini_live_pcm_audio_output_native.dart'
    if (dart.library.html) 'gemini_live_pcm_audio_output_web.dart';
