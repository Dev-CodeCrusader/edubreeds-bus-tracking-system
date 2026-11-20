import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';

/// Streams the phone's position while a trip is active (foreground service keeps it
/// alive when the screen is off), publishes it to `live_positions` every few seconds
/// for parents, and stores a history ping about every 30 seconds.
class LocationService {
  final String tripId;
  final void Function(Position) onPosition;
  final void Function(String)? onError;
  StreamSubscription<Position>? _sub;
  DateTime _lastLive = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPing = DateTime.fromMillisecondsSinceEpoch(0);

  LocationService(this.tripId, this.onPosition, {this.onError});

  static Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  void start() {
    // Android: foreground service keeps tracking alive with the screen off.
    // Web: the browser only tracks while the tab is open and the screen is on.
    final LocationSettings settings = kIsWeb
        ? const LocationSettings(accuracy: LocationAccuracy.high)
        : AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
            intervalDuration: const Duration(seconds: 3),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'EDUBREEDS trip in progress',
              notificationText: 'Sharing the bus location with parents',
              enableWakeLock: true,
              setOngoing: true,
            ),
          );
    // One quick fix first so the screen does not sit on "finding your location".
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
    ).then(_handle).catchError((Object e) {
      onError?.call(e.toString());
    });
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _handle,
      onError: (Object e) => onError?.call(e.toString()),
    );
  }

  void _handle(Position p) {
    onPosition(p);
    final now = DateTime.now();
    // Ignore very poor fixes so the bus does not jump on the parents' map.
    if (p.accuracy > 60) return;
    final point = 'SRID=4326;POINT(${p.longitude} ${p.latitude})';

    if (now.difference(_lastLive).inSeconds >= 4) {
      _lastLive = now;
      db.from('live_positions').upsert({
        'trip_id': tripId,
        'location': point,
        'speed_kmh': p.speed * 3.6,
        'heading': p.heading,
        'updated_at': now.toUtc().toIso8601String(),
      }).catchError((_) {}); // offline: the next fix will retry
    }
    if (now.difference(_lastPing).inSeconds >= 30) {
      _lastPing = now;
      db.from('location_pings').insert({'trip_id': tripId, 'location': point}).catchError((_) {});
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
