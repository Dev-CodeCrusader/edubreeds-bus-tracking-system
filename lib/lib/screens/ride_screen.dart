import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../api.dart';
import '../config.dart';
import '../location_service.dart';
import '../routing.dart';

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
  String? _loadError;
  String? _locError;
  String? _mapError;
  Position? _pos;
  late final LocationService _loc;
  Timer? _ticker;
  int _ticks = 0;
  LatLng? _lastCamera;
  DateTime _lastCameraAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, Future<String?>> _photoUrls = {};

  MapLibreMapController? _map;
  bool _styleReady = false;
  Circle? _vehicle;
  // navigation (see the navigation section below)
  Line? _routeLine;
  RoutePlan? _plan;
  bool _planning = false;
  int _dirtyVersion = 0; // bumped when a new plan is needed (stop skipped, left the route)
  int _planVersion = 0;
  DateTime _lastPlanAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _planError;
  int _stepIdx = 0;
  int _stepLeg = -1;
  double? _remainM;
  double? _remainS;
  DateTime? _offRouteSince;
  bool _drawingLine = false;
  bool _lineDirty = false;
  final List<Circle> _stopCircles = [];
  String _stopSig = '';
  bool _stopsBusy = false;
  bool _stopsAgain = false;
  bool _cameraSet = false;

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
    _loc = LocationService(widget.tripId, _onPosition, onError: (m) {
      if (mounted) setState(() => _locError = m);
    })
      ..start();
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
      setState(() {
        _stops = s;
        _loadError = null;
      });
      _restoreProgress();
      if (_styleReady) _drawRoute();
    } catch (e) {
      // Show the real reason, not a guess about the internet.
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  // ------------------------------------------------------------------ location + arrival

  void _onPosition(Position p) {
    if (!mounted) return;
    _onNavPosition(p);
    setState(() {
      _pos = p;
      _locError = null;
    });
    _moveVehicle(p);
    _checkArrival(p);
    _ensurePlan();
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
    _ensurePlan();
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
    _ticks++;
    if (_countdownEnd != null || _ticks % 5 == 0) setState(() {});
  }

  /// After a refresh or reopen the screen has forgotten which stops the van reached and any
  /// running countdown. Rebuild both from the arrival times the server saved.
  void _restoreProgress() {
    for (final s in _stops) {
      if (s.state == 'pending' && s.vanArrivedAt != null) _arrivedStops.add(s.stop.id);
    }
    final cur = _current;
    if (cur != null && _isPickup && cur.vanArrivedAt != null && _countdownEnd == null) {
      final due = cur.stop.scheduledToday;
      final arrived = cur.vanArrivedAt!;
      final start = (due == null || arrived.isAfter(due)) ? arrived : due; // early arrival waits for the scheduled time
      if (!DateTime.now().isBefore(start)) {
        _countdownEnd = start.add(const Duration(seconds: countdownSeconds));
      }
    }
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
        if (state != 'picked_up' && state != 'dropped') _afterSkip(cur); // absent etc.: plan again
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
        _afterSkip(cur);
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
    if (_map == null || !_styleReady) return;
    await _drawStops();
    await _drawRouteLine();
    if (!_cameraSet && _pos == null) {
      for (final s in _stops) {
        final l = s.stop.location;
        if (l != null) {
          _cameraSet = true;
          await _map!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(l.lat, l.lng), 14));
          break;
        }
      }
    }
    if (_pos != null) await _moveVehicle(_pos!);
  }

  // ------------------------------------------------------------------ stop markers

  List<String> get _pendingStopIds {
    final seen = <String>{};
    final out = <String>[];
    for (final s in _stops) {
      if (s.state == 'pending' && seen.add(s.stop.id)) out.add(s.stop.id);
    }
    return out;
  }

  /// Draws only the stops still to visit (the next one larger and green). Redraws only when
  /// that set changes, so finishing a student does not wipe and rebuild the whole map.
  Future<void> _drawStops() async {
    final c = _map;
    if (c == null || !_styleReady) return;
    if (_stopsBusy) {
      _stopsAgain = true;
      return;
    }
    _stopsBusy = true;
    try {
      do {
        _stopsAgain = false;
        final cur = _current;
        final pending = _pendingStopIds;
        final sig = '${cur?.stop.id}|${pending.join(',')}';
        if (sig == _stopSig) continue;
        _stopSig = sig;
        final old = List<Circle>.of(_stopCircles);
        _stopCircles.clear();
        await Future.wait(old.map((o) => c.removeCircle(o).catchError((_) {})));
        for (final id in pending) {
          final st = _stops.firstWhere((x) => x.stop.id == id).stop;
          final l = st.location;
          if (l == null) continue;
          final isNext = id == cur?.stop.id;
          try {
            _stopCircles.add(await c.addCircle(CircleOptions(
                geometry: LatLng(l.lat, l.lng),
                circleRadius: isNext ? 9 : 6,
                circleColor: isNext ? '#2E7D32' : '#FFFFFF',
                circleStrokeColor: '#1B5E9E',
                circleStrokeWidth: 3)));
          } catch (e) {
            if (mounted) setState(() => _mapError = e.toString());
          }
        }
      } while (_stopsAgain);
    } finally {
      _stopsBusy = false;
    }
  }

  // ------------------------------------------------------------------ navigation
  //
  // The whole journey (bus -> every pending stop, in order) is planned ONCE, with a single request.
  // Finishing a student just moves to the next leg of that plan, so nothing is fetched after a pickup
  // and the screen stays fast. A new plan is made only when:
  //   - there is no plan yet,
  //   - a stop was skipped (absent / not available / nobody at the stop), or
  //   - the driver has left the planned route.

  int get _legIdx {
    final cur = _current;
    final plan = _plan;
    if (cur == null || plan == null) return -1;
    return plan.stopIds.indexOf(cur.stop.id);
  }

  RouteLeg? get _leg {
    final i = _legIdx;
    return i < 0 ? null : _plan!.legs[i];
  }

  void _markPlanDirty() => _dirtyVersion++;

  void _ensurePlan() {
    final p = _pos;
    if (p == null || _current == null || _planning) return;
    final need = _plan == null || _planVersion != _dirtyVersion || _legIdx < 0;
    if (!need) return;
    final since = DateTime.now().difference(_lastPlanAt).inSeconds;
    if (since < (_planError == null ? 3 : 20)) return; // be gentle with the free routing server

    final stops = <StopInfo>[];
    for (final id in _pendingStopIds) {
      final st = _stops.firstWhere((x) => x.stop.id == id).stop;
      if (st.location != null) stops.add(st);
    }
    if (stops.isEmpty) return;

    _planning = true;
    _lastPlanAt = DateTime.now();
    final version = _dirtyVersion;
    final ids = [for (final s in stops) s.id];
    Routing.plan(RoutePoint(p.latitude, p.longitude), [for (final s in stops) RoutePoint(s.location!.lat, s.location!.lng)])
        .then((legs) {
      if (!mounted) return;
      setState(() {
        _plan = RoutePlan(ids, legs);
        _planVersion = version;
        _planError = null;
        _stepIdx = 0;
        _stepLeg = -1;
        _offRouteSince = null;
      });
      _drawRouteLine();
    }).catchError((Object e) {
      if (mounted) setState(() => _planError = e.toString());
    }).whenComplete(() => _planning = false);
  }

  /// Called for every GPS fix: remaining distance/time, the next turn, and the off-route check.
  /// Only reads the saved plan, so it costs no network.
  void _onNavPosition(Position p) {
    final leg = _leg;
    if (leg == null) return;
    if (_stepLeg != _legIdx) {
      _stepLeg = _legIdx;
      _stepIdx = 0;
    }
    final n = leg.nearest(p.latitude, p.longitude);
    final left = leg.remainingFrom(n.idx);
    _remainM = left;
    _remainS = leg.distanceM > 0 ? leg.durationS * (left / leg.distanceM) : leg.durationS;

    if (n.dist > 60) {
      _offRouteSince ??= DateTime.now();
      final longEnough = DateTime.now().difference(_offRouteSince!).inSeconds >= 10;
      final planOldEnough = DateTime.now().difference(_lastPlanAt).inSeconds >= 15;
      if (longEnough && planOldEnough) {
        _markPlanDirty(); // left the route: plan again from here
        _offRouteSince = null;
      }
    } else {
      _offRouteSince = null;
    }

    while (_stepIdx + 1 < leg.steps.length - 1) {
      final next = leg.steps[_stepIdx + 1].at;
      if (Geolocator.distanceBetween(p.latitude, p.longitude, next.lat, next.lng) < 25) {
        _stepIdx++;
      } else {
        break;
      }
    }
  }

  /// Draws the blue road line from the current leg to the last stop. Always clears and re-adds
  /// (updating in place was unreliable on the web map), one redraw at a time.
  Future<void> _drawRouteLine() async {
    final c = _map;
    if (c == null || !_styleReady) return;
    if (_drawingLine) {
      _lineDirty = true;
      return;
    }
    _drawingLine = true;
    try {
      do {
        _lineDirty = false;
        await c.clearLines();
        _routeLine = null;
        final plan = _plan;
        final i = _legIdx;
        if (plan != null && i >= 0) {
          final pts = [for (final p in plan.pointsFrom(i)) LatLng(p.lat, p.lng)];
          if (pts.length > 1) {
            _routeLine = await c.addLine(LineOptions(geometry: pts, lineColor: '#1B5E9E', lineWidth: 5, lineOpacity: 0.85));
          }
        }
      } while (_lineDirty);
    } catch (e) {
      if (mounted) setState(() => _mapError = e.toString());
    } finally {
      _drawingLine = false;
    }
  }

  /// After a student is skipped, a new plan is needed only if nobody else is waiting at that stop
  /// (the stop drops out of the journey). A normal pickup never needs one.
  void _afterSkip(TripStop skipped) {
    final stillWaiting = _stops.any((s) => s.stop.id == skipped.stop.id && s.state == 'pending');
    if (!stillWaiting) _markPlanDirty();
  }

  Widget _navBanner() {
    final cur = _current;
    if (cur == null) return const SizedBox.shrink();
    final leg = _leg;
    String title;
    String sub = '';
    if (leg == null) {
      title = _planError != null ? 'Road route unavailable' : 'Planning the route for all stops...';
      if (_planError != null) sub = 'Drive to the green stop on the map';
    } else {
      final idx = (_stepIdx + 1 < leg.steps.length) ? _stepIdx + 1 : leg.steps.length - 1;
      final step = leg.steps[idx];
      title = step.text;
      if (_pos != null) {
        final d = Geolocator.distanceBetween(_pos!.latitude, _pos!.longitude, step.at.lat, step.at.lng);
        sub = 'in ${d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km' : '${(d / 10).round() * 10} m'}  ·  ';
      }
      final km = (_remainM ?? leg.distanceM) / 1000;
      final mins = ((_remainS ?? leg.durationS) / 60).ceil();
      sub += '${km.toStringAsFixed(1)} km, about $mins min to the stop  ·  ${_pendingStopIds.length} stops left';
    }
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          const Icon(Icons.navigation),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (sub.isNotEmpty) Text(sub, style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _moveVehicle(Position p) async {
    final c = _map;
    if (c == null || !_styleReady) return;
    final at = LatLng(p.latitude, p.longitude);
    if (_vehicle == null) {
      _vehicle = await c.addCircle(CircleOptions(
          geometry: at, circleRadius: 9, circleColor: '#E53935', circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3));
    } else {
      await c.updateCircle(_vehicle!, CircleOptions(
          geometry: at, circleRadius: 9, circleColor: '#E53935', circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3));
    }
    // Follow the bus, but not on every fix: a move needs 10 m and 2 s since the last one.
    final last = _lastCamera;
    final moved = last == null ? 999.0 : Geolocator.distanceBetween(last.latitude, last.longitude, p.latitude, p.longitude);
    if (moved >= 10 && DateTime.now().difference(_lastCameraAt).inSeconds >= 2) {
      _lastCamera = at;
      _lastCameraAt = DateTime.now();
      await c.animateCamera(CameraUpdate.newLatLng(at));
    }
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
    } else if (cur.stop.location == null) {
      text = 'This stop has no map position yet (its latitude / longitude are empty).';
      color = Theme.of(context).colorScheme.error;
    } else if (_pos != null) {
      final d = Geolocator.distanceBetween(
          _pos!.latitude, _pos!.longitude, cur.stop.location!.lat, cur.stop.location!.lng);
      text = d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km away' : '${d.round()} m away';
    } else if (_locError != null) {
      text = 'Location problem: $_locError\nAllow location for this site (browser lock icon) or app, and make sure GPS is on.';
      color = Theme.of(context).colorScheme.error;
    } else {
      text = 'Finding your location...';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      if (_mapError != null)
        Text('Map problem: $_mapError', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.error)),
    ]);
  }

  Widget _avatar(StudentInfo s) {
    final initials = s.name.trim().isEmpty ? '?' : s.name.trim()[0].toUpperCase();
    final fallback = CircleAvatar(radius: 32, child: Text(initials, style: const TextStyle(fontSize: 24)));
    if (!widget.photosEnabled || s.photoPath == null) return fallback; // privacy toggle off: initials only
    return FutureBuilder<String?>(
      future: _photoUrls.putIfAbsent(s.photoPath!, () => Api.signedUrl('student-photos', s.photoPath)),
      builder: (context, snap) => snap.data == null
          ? fallback
          : CircleAvatar(radius: 32, backgroundImage: NetworkImage(snap.data!)),
    );
  }

  Widget _deck() {
    final cur = _current;
    if (_stops.isEmpty && _loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('Could not load the stops for this trip.', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Flexible(child: SingleChildScrollView(child: Text(_loadError!, textAlign: TextAlign.center))),
          const SizedBox(height: 8),
          FilledButton(onPressed: _refresh, child: const Text('Try again')),
          TextButton(onPressed: _finish, child: const Text('End trip')),
        ]),
      );
    }
    if (_stops.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
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
              child: Stack(children: [
                MapLibreMap(
                  styleString: mapStyleUrl,
                  initialCameraPosition: const CameraPosition(target: LatLng(20.2961, 85.8245), zoom: 12),
                  onMapCreated: (c) => _map = c,
                  onStyleLoadedCallback: _onStyleLoaded,
                  compassEnabled: false,
                ),
                Positioned(top: 8, left: 8, right: 8, child: _navBanner()),
              ]),
            ),
            const Divider(height: 1),
            Expanded(flex: 1, child: _deck()),
          ],
        ),
      ),
    );
  }
}
