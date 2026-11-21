import 'dart:convert';

import 'api.dart';

/// Admin actions that need the server-side `manage-user` function (it holds the service key).
class AdminApi {
  static Future<String> createUser({
    required String phone,
    required String password,
    required String fullName,
    required String role,
    String? schoolId,
  }) async {
    final r = await db.functions.invoke('manage-user', body: {
      'action': 'create',
      'phone': phone,
      'password': password,
      'full_name': fullName,
      'role': role,
      'school_id': schoolId,
    });
    dynamic d = r.data;
    if (d is String) {
      try {
        d = jsonDecode(d);
      } catch (_) {}
    }
    if (d is Map && d['user_id'] != null) return d['user_id'].toString();
    if (d is Map && d['error'] != null) throw d['error'].toString();
    // Not our function's answer: show what came back so the problem can be found.
    throw 'The manage-user function did not create the account. It answered: $d. '
        'Check that the function named manage-user contains the code from manage-user/index.ts.';
  }

  static Future<void> setPassword(String userId, String password) async {
    await db.functions.invoke('manage-user', body: {'action': 'set_password', 'user_id': userId, 'password': password});
  }

  static Future<void> setActive(String userId, bool active) async {
    await db.functions.invoke('manage-user', body: {'action': 'set_active', 'user_id': userId, 'active': active});
  }

  /// PostGIS text for a point, accepted by Supabase for `geography` columns.
  static String point(double lat, double lng) => 'SRID=4326;POINT($lng $lat)';
}
