import 'package:flutter_tts/flutter_tts.dart';

/// Spoken turn-by-turn directions (Android text-to-speech, and the browser voice on the web).
class Voice {
  static final FlutterTts _tts = FlutterTts();
  static bool enabled = true;
  static bool _ready = false;

  static Future<void> speak(String text) async {
    if (!enabled) return;
    try {
      if (!_ready) {
        _ready = true;
        await _tts.setLanguage('en-IN');
        await _tts.setSpeechRate(0.5);
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // speech is a bonus; never break driving because of it
    }
  }

  static Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
