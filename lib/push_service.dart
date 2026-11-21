import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api.dart';

/// Push alerts on Android (works with the app closed). Needs the Firebase file added at build time
/// (see SETUP-UPDATE-4.md). If it is missing, this quietly does nothing and in-app alerts still work.
class Push {
  static bool _started = false;

  static Future<void> register() async {
    if (kIsWeb || _started) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      final m = FirebaseMessaging.instance;
      await m.requestPermission();
      final token = await m.getToken();
      if (token != null) await _save(token);
      m.onTokenRefresh.listen(_save);
    } catch (_) {
      // no Firebase configuration in this build: skip
    }
  }

  static Future<void> _save(String token) async {
    try {
      await db.rpc('register_device', params: {'p_token': token, 'p_platform': 'android'});
    } catch (_) {}
  }
}
