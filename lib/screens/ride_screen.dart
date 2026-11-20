import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../api.dart';
import '../config.dart';
import '../location_service.dart';

/// The 50/50 ride screen: map on top, control deck below.
/// Pickup: [Picked Up] [Student Absent] [Alert (time-gated)]
/// Drop:   [Dropped]   [Nobody at stop]  [Alert (always on)]
class RideScreen extends StatefulWidget {
  final String tripId;
  final String mode;
  final bool photosEnabled;
  const RideScreen({super.key, required this.tripId, required this.mode, required this.photosEnabled});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {
  List<TripStop> _stops = [];
  final Set<String> _arrivedStops = {};
  DateTime? _countdownEnd;
  bool _promptShown = false;
  bool _busy = false;
  Position? _pos;
  late final LocationService _loc;
  Timer? _ticker;

  MapLibreMapController? _map;
  bool _styleReady = false;
  Circle? _vehicle;

  bool get _isPickup => widget.mode == 'pickup';

  TripStop? get _current {
    for (final s in _stops) {
      if (s.state == 'pending') return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loc = LocationService(widget.tripId, _onPosition)..start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _refresh();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _loc.stop();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await Api.tripStops(widget.tripId);
      if (!mounted) return;
      setState(() => _stops = s);
      if (_styleReady) _drawRoute();
    } catch (_) {
      _toast('Could not refresh the list. Check your internet.');
    }
  }

  // ------------------------------------------------------------------ location + arrival

  void _onPosition(Position p) {
    if (!mounted) return;
    setState(() => _pos = p);
    _moveVehicle(p);
    _checkArrival(p);
  }

  void _checkArrival(Position p) {
    final cur = _current;
    final loc = cur?.stop.location;
    if (cur == null || loc == null || _arrivedStops.contains(cur.stop.id)) return;
    final d = Geolocator.distanceBetween(p.latitude, p.longitude, loc.lat, loc.lng);
    if (d <= cur.stop.radiusM) {
      _arrivedStops.add(cur.stop.id);
      // Server notifies the parent(s): arrival buzz.
      Api.markArrived(widget.tripId, cur.stop.id).catchError((_) {
        _arrivedStops.remove(cur.stop.id); // retry on the next position fix
      });
    }
  }

  /// Runs every second: starts the 2-minute countdown, and raises the
  /// "Student Not Available/Ready" prompt when it runs out.
  void _tick() {
    if (!mounted) return;
    final cur = _current;
    if (_isPickup && cur != null && _arrivedStops.contains(cur.stop.id) && _countdownEnd == null) {
      final due = cur.stop.scheduledToday;
      // Early arrival: no countdown until the scheduled time is reached.
      if (due == null || !DateTime.now().isBefore(due)) {
        _countdownEnd = DateTime.now().add(const Duration(seconds: countdownSeconds));
      }
    }
    if (_countdownEnd != null && !_promptShown && !DateTime.now().isBefore(_countdownEnd!)) {
      _promptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptNotAvailable());
    }
    setState(() {});
  }

  void _resetForNextStudent() {
    _countdownEnd = null;
    _promptShown = false;
  }

  // ------------------------------------------------------------------ driver actions

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final m = e.toString();
    if (m.contains('before the scheduled')) return 'Alert is not available before the scheduled pickup time.';
    return 'That did not go through. Check your internet and try again.';
  }

  Future<void> _complete(String state) => _run(() async {
        final cur = _current;
        if (cur == null) return;
        await Api.markStop(cur.id, state);
        _resetForNextStudent();
        await _refresh();
      });

  Future<void> _confirmAbsent() async {
    final cur = _current;
    if (cur == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Student absent?'),
        content: Text('Skip ${cur.student.name}. Use this only when the parent told you beforehand.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark absent')),
        ],
      ),
    );
    if (ok == true) await _complete('absent');
  }

  bool get _alertEnabled {
    final cur = _current;
    if (cur == null) return false;
    if (!_isPickup) return true; // drop: always on
    final due = cur.stop.scheduledToday;
    return due == null || !DateTime.now().isBefore(due);
  }

  Future<void> _sendAlert() => _run(() async {
        await Api.alert(_current!.id);
        _toast('Alert sent to the parent.');
      });

  Future<void> _promptNotAvailable() async {
    if (!mounted) return;
    final cur = _current;
    if (cur == null) return;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Student Not Available/Ready'),
        content: Text('${cur.student.name} has not boarded after 2 minutes. '
            'Take a photo of the stop as proof and move on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'boarded'), child: const Text('Picked up now')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(c, 'proof'),
            icon: const Icon(Icons.photo_camera),
            label: const Text('Take proof photo'),
          ),
        ],
      ),
    );
    if (choice == 'boarded') {
      await _complete('picked_up');
    } else if (choice == 'proof') {
      await _captureProof(cur);
    } else {
      _promptShown = false;
    }
  }

  Future<void> _captureProof(TripStop cur) => _run(() async {
        final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70, maxWidth: 1280);
        if (x == null) {
          _promptShown = false; // photo is required; ask again
          _countdownEnd = DateTime.now();
          return;
        }
        final pos = _pos ?? await Geolocator.getCurrentPosition();
        final path = await Api.uploadPhoto(x, 'proof');
        // GPS and time are stored with the photo on the server; the parent is notified at once.
        await Api.markNotAvailable(cur.id, path, pos.latitude, pos.longitude);
        _resetForNextStudent();
        await _refresh();
      });

  Future<void> _finish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End this trip?'),
        content: const Text('Live tracking will stop for parents.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('End trip')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _loc.stop();
      await Api.finishTrip(widget.tripId);
      if (mounted) Navigator.of(context).pop();
    });
  }

  // ------------------------------------------------------------------ map

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    await _drawRoute();
  }

  Future<void> _drawRoute() async {
    final c = _map;
    if (c == null) return;
    await c.clearLines();
    await c.clearCircles();
    _vehicle = null;
    final seen = <String>{};
    final pts = <LatLng>[];
    for (final s in _stops) {
      final l = s.stop.location;
      if (l != null && seen.add(s.stop.id)) pts.add(LatLng(l.lat, l.lng));
    }
    if (pts.length > 1) {
      // Straight segments between stops for now; road-following polyline comes with the routing engine.
      await c.addLine(LineOptions(geometry: pts, lineColor: '#1B5E9E', lineWidth: 4, lineOpacity: 0.8));
    }
    for (final p in pts) {
      await c.addCircle(CircleOptions(
          geometry: p, circleRadius: 6, circleColor: '#FFFFFF', circleStrokeColor: '#1B5E9E', circleStrokeWidth: 3));
    }
    if (pts.isNotEmpty && _pos == null) {
      await c.animateCamera(CameraUpdate.newLatLngZoom(pts.first, 14));
    }
    if (_pos != null) await _moveVehicle(_pos!);
  }

  Future<void> _moveVehicle(Position p) async {
    final c = _map;
    if (c == null || !_styleReady) return;
    final at = LatLng(p.latitude, p.longitude);
    if (_vehicle == null) {
      _vehicle = await c.addCircle(CircleOptions(
          geometry: at, circleRadius: 9, circleColor: '#E53935', circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3));
    } else {
      await c.updateCircle(_vehicle!, CircleOptions(geometry: at));
    }
    await c.animateCamera(CameraUpdate.newLatLng(at));
  }

  // ------------------------------------------------------------------ UI

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _clock(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _statusLine(TripStop cur) {
    final due = cur.stop.scheduledToday;
    final arrived = _arrivedStops.contains(cur.stop.id);
    String text;
    Color? color;
    if (_countdownEnd != null) {
      final left = _countdownEnd!.difference(DateTime.now()).inSeconds.clamp(0, 9999);
      text = 'Waiting for student  ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
      color = Colors.orange.shade800;
    } else if (_isPickup && arrived && due != null) {
      text = 'Arrived early. Countdown starts at ${_clock(due)}';
    } else if (arrived) {
      text = 'At the stop';
    } else if (_pos != null && cur.stop.location != null) {
      final d = Geolocator.distanceBetween(
          _pos!.latitude, _pos!.longitude, cur.stop.location!.lat, cur.stop.location!.lng);
      text = d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km away' : '${d.round()} m away';
    } else {
      text = 'Finding your location...';
    }
    return Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: color));
  }

  Widget _avatar(StudentInfo s) {
    final initials = s.name.trim().isEmpty ? '?' : s.name.trim()[0].toUpperCase();
    final fallback = CircleAvatar(radius: 32, child: Text(initials, style: const TextStyle(fontSize: 24)));
    if (!widget.photosEnabled || s.photoPath == null) return fallback; // privacy toggle off: initials only
    return FutureBuilder<String?>(
      future: Api.signedUrl('student-photos', s.photoPath),
      builder: (context, snap) => snap.data == null
          ? fallback
          : CircleAvatar(radius: 32, backgroundImage: NetworkImage(snap.data!)),
    );
  }

  Widget _deck() {
    final cur = _current;
    if (_stops.isEmpty) return const Center(child: CircularProgressIndicator());
    if (cur == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 56, color: Colors.green),
            const SizedBox(height: 8),
            Text(_isPickup ? 'All students handled. Head to school.' : 'All drops are done.',
                style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _finish, child: const Text('End trip')),
          ],
        ),
      );
    }
    final remaining = _stops.where((s) => s.state == 'pending').length;
    final due = cur.stop.scheduledToday;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _avatar(cur.student),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cur.student.name, style: Theme.of(context).textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${cur.student.className ?? ''}  ·  ${cur.stop.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                if (due != null) Text('Scheduled ${_clock(due)}'),
              ]),
            ),
            Text('$remaining left'),
          ]),
          const SizedBox(height: 8),
          _statusLine(cur),
          const Spacer(),
          Row(children: [
            Expanded(
              flex: 2,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: _busy ? null : () => _complete(_isPickup ? 'picked_up' : 'dropped'),
                child: Text(_isPickup ? 'Picked Up' : 'Dropped'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: _busy ? null : (_isPickup ? _confirmAbsent : () => _complete('no_one_at_stop')),
                child: Text(_isPickup ? 'Absent' : 'Nobody at stop', textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                // Greyed out before the scheduled pickup time; always on in drop mode.
                onPressed: (_busy || !_alertEnabled) ? null : _sendAlert,
                icon: const Icon(Icons.notifications_active),
                label: const Text('Alert'),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toast('Use "End trip" to leave the ride screen.');
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isPickup ? 'Pickup in progress' : 'Drop in progress'),
          actions: [
            TextButton(onPressed: _busy ? null : _finish, child: const Text('End trip')),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              flex: 1,
              child: MapLibreMap(
                styleString: mapStyleUrl,
                initialCameraPosition: const CameraPosition(target: LatLng(20.2961, 85.8245), zoom: 12),
                onMapCreated: (c) => _map = c,
                onStyleLoadedCallback: _onStyleLoaded,
                compassEnabled: false,
              ),
            ),
            const Divider(height: 1),
            Expanded(flex: 1, child: _deck()),
          ],
        ),
      ),
    );
  }
}
