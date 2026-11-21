import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final db = Supabase.instance.client;

/// A point read from a PostGIS `geography` column (PostgREST returns GeoJSON).
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  static GeoPoint? from(dynamic json) {
    if (json is Map && json['coordinates'] is List) {
      final c = json['coordinates'] as List;
      return GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble());
    }
    return null;
  }
}

class DriverProfile {
  final String id;
  final String role; // driver | parent | caretaker | school_admin | super_admin
  final String fullName;
  final String? schoolId;
  final String schoolName;
  final bool photosEnabled;
  final String? brandHex; // the school group's app colour, e.g. #1B5E9E
  DriverProfile(this.id, this.role, this.fullName, this.schoolId, this.schoolName, this.photosEnabled, {this.brandHex});
}

class RouteInfo {
  final String id;
  final String name;
  final String mode; // pickup | drop
  RouteInfo(this.id, this.name, this.mode);
}

class StudentInfo {
  final String id;
  final String name;
  final String? className;
  final String? photoPath;
  StudentInfo(this.id, this.name, this.className, this.photoPath);
}

class StopInfo {
  final String id;
  final int seq;
  final String name;
  final int radiusM;
  final String? scheduledTime; // "HH:MM:SS" in India time
  final GeoPoint? location;
  StopInfo(this.id, this.seq, this.name, this.radiusM, this.scheduledTime, this.location);

  /// Today's scheduled moment on the phone's clock (the phone is assumed to be on India time).
  DateTime? get scheduledToday {
    final t = scheduledTime;
    if (t == null) return null;
    // Seconds may carry a fraction ("05.415158"), so cut it off before reading.
    final p = t.split(':').map((x) => int.parse(x.split('.').first)).toList();
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, p[0], p[1], p.length > 2 ? p[2] : 0);
  }
}

class TripStop {
  final String id; // trip_stops.id
  final String state;
  final StopInfo stop;
  final StudentInfo student;
  final DateTime? vanArrivedAt; // saved on the server when the van reached the stop
  TripStop(this.id, this.state, this.stop, this.student, this.vanArrivedAt);
}

class Api {
  static Future<DriverProfile> myProfile() async {
    final uid = db.auth.currentUser!.id;
    final row = await db
        .from('profiles')
        .select('id, role, full_name, school_id, active')
        .eq('id', uid)
        .single();
    if (row['active'] == false) throw 'This account has been deactivated. Please contact your school.';
    // The school lookup is separate so a problem there never blocks sign-in.
    Map? school;
    if (row['school_id'] != null) {
      try {
        school = await db
            .from('schools')
            .select('name, photos_enabled, group_id')
            .eq('id', row['school_id'])
            .maybeSingle();
      } catch (_) {}
    }
    String? hex;
    if (school?['group_id'] != null) {
      try {
        final g = await db.from('app_groups').select('theme').eq('id', school!['group_id']).maybeSingle();
        final theme = g?['theme'];
        if (theme is Map && theme['color'] != null) hex = theme['color'].toString();
      } catch (_) {}
    }
    return DriverProfile(
      row['id'],
      row['role'].toString(),
      row['full_name'] ?? '',
      row['school_id'],
      school?['name'] ?? '',
      (school?['photos_enabled'] ?? true) as bool,
      brandHex: hex,
    );
  }

  /// Routes of the buses assigned to this driver.
  static Future<List<RouteInfo>> myRoutes() async {
    final uid = db.auth.currentUser!.id;
    final rows = await db
        .from('routes')
        .select('id, name, mode, buses!inner(driver_id)')
        .eq('buses.driver_id', uid)
        .order('name');
    return rows.map<RouteInfo>((r) => RouteInfo(r['id'], r['name'], r['mode'])).toList();
  }

  /// Students assigned to a route (used to pick who is in the van for DROP).
  static Future<List<StudentInfo>> routeStudents(String routeId) async {
    final rows = await db
        .from('stop_students')
        .select('students(id, full_name, class_name, photo_url), stops!inner(route_id)')
        .eq('stops.route_id', routeId);
    return rows.map<StudentInfo>((r) {
      final s = r['students'] as Map;
      return StudentInfo(s['id'], s['full_name'], s['class_name'], s['photo_url']);
    }).toList();
  }

  // Works on Android and on the web (bytes, not dart:io files).
  static Future<String> uploadPhoto(XFile file, String folder) async {
    final uid = db.auth.currentUser!.id;
    final path = '$folder/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final bytes = await file.readAsBytes();
    await db.storage
        .from('trip-photos')
        .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    return path;
  }

  static Future<String?> signedUrl(String bucket, String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      return await db.storage.from(bucket).createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  static Future<String> startTrip(String routeId, String selfiePath, List<String>? studentIds) async {
    final id = await db.rpc('start_trip', params: {
      'p_route': routeId,
      'p_selfie_path': selfiePath,
      'p_student_ids': studentIds,
    });
    return id as String;
  }

  /// The driver's unfinished trip (started in the last 14 hours), if any. Used to resume
  /// after the page is refreshed or the app is closed and reopened.
  static Future<Map<String, dynamic>?> activeTrip() async {
    final uid = db.auth.currentUser!.id;
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 14)).toIso8601String();
    final rows = await db
        .from('trips')
        .select('id, mode, started_at, routes(name)')
        .eq('driver_id', uid)
        .eq('state', 'active')
        .gte('started_at', since)
        .order('started_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// 'active' | 'completed' | 'cancelled', or null if the trip cannot be read.
  static Future<String?> tripState(String tripId) async {
    final r = await db.from('trips').select('state').eq('id', tripId).maybeSingle();
    return r?['state']?.toString();
  }

  static Future<List<TripStop>> tripStops(String tripId) async {
    final rows = await db
        .from('trip_stops')
        .select('id, state, van_arrived_at, '
            'students(id, full_name, class_name, photo_url), '
            'stops(id, seq, name, radius_m, scheduled_time, lat, lng)')
        .eq('trip_id', tripId);
    final list = rows.map<TripStop>((r) {
      final s = r['students'] as Map;
      final st = r['stops'] as Map;
      return TripStop(
        r['id'],
        r['state'],
        StopInfo(st['id'], st['seq'], st['name'], st['radius_m'], st['scheduled_time'],
            st['lat'] == null ? null : GeoPoint((st['lat'] as num).toDouble(), (st['lng'] as num).toDouble())),
        StudentInfo(s['id'], s['full_name'], s['class_name'], s['photo_url']),
        r['van_arrived_at'] == null ? null : DateTime.parse(r['van_arrived_at'] as String).toLocal(),
      );
    }).toList();
    list.sort((a, b) {
      final c = a.stop.seq.compareTo(b.stop.seq);
      return c != 0 ? c : a.student.name.compareTo(b.student.name);
    });
    return list;
  }

  static Future<void> markArrived(String tripId, String stopId) =>
      db.rpc('mark_arrived', params: {'p_trip': tripId, 'p_stop': stopId});

  static Future<void> markStop(String tripStopId, String state) =>
      db.rpc('mark_stop', params: {'p_trip_stop': tripStopId, 'p_state': state});

  static Future<void> markNotAvailable(String tripStopId, String imagePath, double lat, double lng) =>
      db.rpc('mark_not_available', params: {
        'p_trip_stop': tripStopId,
        'p_image_path': imagePath,
        'p_lat': lat,
        'p_lng': lng,
      });

  static Future<void> alert(String tripStopId) => db.rpc('driver_alert', params: {'p_trip_stop': tripStopId});

  static Future<void> finishTrip(String tripId) => db.rpc('finish_trip', params: {'p_trip': tripId});
}
