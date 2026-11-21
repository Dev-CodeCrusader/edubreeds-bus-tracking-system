import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../location_service.dart';
import 'ride_screen.dart';

/// Shift start: choose Pickup or Drop, choose the route, (Drop only) tick the students
/// who are in the van, take a live selfie, and start. Starting the trip notifies parents.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DriverProfile? _me;
  List<RouteInfo> _routes = [];
  String _mode = 'pickup';
  RouteInfo? _route;
  List<StudentInfo> _students = [];
  final Set<String> _inVan = {};
  XFile? _selfie;
  Uint8List? _selfieBytes;
  bool _loading = true;
  bool _starting = false;
  bool _resumeChecked = false;
  Map<String, dynamic>? _active; // the trip already running on the server for this driver
  String? _activeError;
  String? _holiday; // reason text when today is a school holiday
  Map<String, String> _todayTrips = {}; // route id -> trip state, for trips this driver started today
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await Api.myProfile();
      final routes = await Api.myRoutes();
      setState(() {
        _me = me;
        _routes = routes;
        _loading = false;
      });
      try {
        _holiday = await Api.holidayToday();
      } catch (_) {}
      try {
        _todayTrips = await Api.tripsToday();
      } catch (_) {}
      await _autoSelectNext();
      await _loadActive(autoOpen: true);
    } catch (e) {
      setState(() {
        _error = 'Could not load your routes. Pull down to retry.';
        _loading = false;
      });
    }
  }

  /// The trip lives on the server, so it survives a refresh, a closed app, a sign-out and a different phone.
  /// Whenever this screen opens it asks the server for the driver's running trip and offers to continue it.
  Future<void> _loadActive({bool autoOpen = false}) async {
    try {
      final t = await Api.activeTrip();
      try {
        _todayTrips = await Api.tripsToday();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _active = t;
        _activeError = null;
      });
      if (t == null && !autoOpen) await _autoSelectNext(); // a trip just ended: line up the next one
      if (t != null && autoOpen && !_resumeChecked) {
        _resumeChecked = true;
        await _openActive();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _activeError = 'Could not check for a running trip. $e');
    }
  }

  Future<void> _openActive() async {
    final t = _active;
    if (t == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RideScreen(
          tripId: t['id'] as String, mode: t['mode'] as String, photosEnabled: _me?.photosEnabled ?? true),
    ));
    if (mounted) _loadActive();
  }

  Future<void> _endActive() async {
    final t = _active;
    if (t == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End the running trip?'),
        content: const Text('Use this only if the trip was started by mistake or is already over. '
            'Parents will stop seeing the bus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('End trip')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.finishTrip(t['id'] as String);
      if (mounted) setState(() => _active = null);
    } catch (e) {
      if (mounted) setState(() => _activeError = 'Could not end the trip. $e');
    }
  }

  Future<void> _signOut() async {
    if (_active != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sign out?'),
          content: const Text('Your trip stays open. Sign in again on this or another phone to continue it. '
              'Parents will not see live bus movement while nobody is signed in on the trip.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await Supabase.instance.client.auth.signOut();
  }

  /// Weekday in India, 1 = Monday ... 7 = Sunday.
  int get _weekdayIst => DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)).weekday;

  /// Today's trips for this driver in time order (only routes that run on today's weekday).
  List<RouteInfo> get _todayRoutes {
    final list = _routes.where((r) => r.days.contains(_weekdayIst)).toList();
    list.sort((a, b) => (a.startTime ?? '99:99').compareTo(b.startTime ?? '99:99'));
    return list;
  }

  /// Opens with the next trip that has not been done today already selected.
  Future<void> _autoSelectNext() async {
    final next = _todayRoutes.where((r) => _todayTrips[r.id] != 'completed').toList();
    final pick = next.isEmpty ? null : next.first;
    if (pick == null) {
      await _pickDefaultRoute();
      return;
    }
    if (mounted) {
      setState(() {
        _mode = pick.mode;
        _route = pick;
        _students = [];
        _inVan.clear();
      });
    }
    if (pick.mode == 'drop') {
      final s = await Api.routeStudents(pick.id);
      if (mounted) setState(() => _students = s);
    }
  }

  List<Widget> _scheduleWidgets() {
    final w = <Widget>[];
    if (_holiday != null) {
      w.add(Card(
        color: Colors.red.shade50,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.beach_access, color: Colors.red),
            const SizedBox(width: 10),
            Expanded(child: Text('Today is a holiday: $_holiday.\nNo trips are scheduled today.', style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
      ));
      return w;
    }
    final today = _todayRoutes;
    if (today.isEmpty) {
      w.add(const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('No trips are scheduled for you today.')));
      return w;
    }
    w.add(Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Today's trips", style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final r in today)
            InkWell(
              onTap: _active != null
                  ? null
                  : () async {
                      setState(() {
                        _mode = r.mode;
                        _route = r;
                        _students = [];
                        _inVan.clear();
                      });
                      if (r.mode == 'drop') {
                        final s = await Api.routeStudents(r.id);
                        if (mounted) setState(() => _students = s);
                      }
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Icon(r.mode == 'drop' ? Icons.home : Icons.school, size: 20),
                  const SizedBox(width: 8),
                  SizedBox(width: 48, child: Text(r.startLabel.isEmpty ? '--:--' : r.startLabel, style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(child: Text('${r.name} (${r.mode == 'drop' ? 'Drop' : 'Pickup'})')),
                  _statusChip(r),
                ]),
              ),
            ),
        ]),
      ),
    ));
    return w;
  }

  Widget _statusChip(RouteInfo r) {
    final st = _todayTrips[r.id];
    final selected = _route?.id == r.id && _active == null;
    if (st == 'completed') return const Chip(label: Text('Done'), avatar: Icon(Icons.check, size: 16), visualDensity: VisualDensity.compact);
    if (st == 'active') return Chip(label: const Text('Running'), backgroundColor: Colors.green.shade100, visualDensity: VisualDensity.compact);
    return Chip(
        label: Text(selected ? 'Next' : 'Scheduled'),
        backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        visualDensity: VisualDensity.compact);
  }

  List<RouteInfo> get _modeRoutes => _routes.where((r) => r.mode == _mode).toList();

  Future<void> _pickDefaultRoute() async {
    final list = _modeRoutes;
    setState(() {
      _route = list.isEmpty ? null : list.first;
      _students = [];
      _inVan.clear();
    });
    if (_route != null && _mode == 'drop') {
      final s = await Api.routeStudents(_route!.id);
      if (mounted) setState(() => _students = s);
    }
  }

  Future<void> _takeSelfie() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 70,
      maxWidth: 1080,
    );
    if (x != null) {
      final bytes = await x.readAsBytes();
      setState(() {
        _selfie = x;
        _selfieBytes = bytes;
      });
    }
  }

  bool get _ready =>
      _active == null && _activeError == null && _holiday == null && _route != null && _selfie != null && (_mode == 'pickup' || _inVan.isNotEmpty) && !_starting;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      if (_active != null) throw 'A trip is already running. Continue it or end it first.';
      if (!await LocationService.ensurePermission()) {
        throw 'Location permission is needed to share the bus position. Allow it in Settings.';
      }
      final selfiePath = await Api.uploadPhoto(_selfie!, 'selfies');
      final tripId = await Api.startTrip(
        _route!.id,
        selfiePath,
        _mode == 'drop' ? _inVan.toList() : null,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RideScreen(tripId: tripId, mode: _mode, photosEnabled: _me?.photosEnabled ?? true),
      ));
      setState(() {
        _selfie = null;
        _selfieBytes = null;
      });
      _loadActive();
    } catch (e) {
      setState(() => _error = e is String ? e : 'Could not start the trip. Please try again.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_me?.schoolName.isNotEmpty == true ? _me!.schoolName : 'EDUBREEDS Driver'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_me != null) Text('Hello, ${_me!.fullName}', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  ..._scheduleWidgets(),
                  if (_activeError != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_activeError!),
                          const SizedBox(height: 8),
                          OutlinedButton(onPressed: () => _loadActive(), child: const Text('Try again')),
                        ]),
                      ),
                    ),
                  if (_active != null) ...[
                    Card(
                      color: Colors.orange.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Trip in progress', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text('${(_active!['routes'] as Map?)?['name'] ?? 'Route'}  (${_active!['mode'] == 'drop' ? 'Drop' : 'Pickup'})'),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _openActive,
                            icon: const Icon(Icons.play_arrow),
                            label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Continue trip')),
                          ),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _endActive, child: const Text('End this trip')),
                        ]),
                      ),
                    ),
                  ] else ...[
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'pickup', label: Text('Pickup'), icon: Icon(Icons.login)),
                      ButtonSegment(value: 'drop', label: Text('Drop'), icon: Icon(Icons.logout)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) {
                      setState(() => _mode = s.first);
                      _pickDefaultRoute();
                    },
                  ),
                  const SizedBox(height: 16),
                  if (_modeRoutes.isEmpty)
                    const Text('No route is assigned to you for this mode. Ask the school admin.')
                  else
                    DropdownButtonFormField<RouteInfo>(
                      value: _route,
                      decoration: const InputDecoration(labelText: 'Route', border: OutlineInputBorder()),
                      items: [for (final r in _modeRoutes) DropdownMenuItem(value: r, child: Text(r.name))],
                      onChanged: (r) async {
                        setState(() {
                          _route = r;
                          _students = [];
                          _inVan.clear();
                        });
                        if (r != null && _mode == 'drop') {
                          final s = await Api.routeStudents(r.id);
                          if (mounted) setState(() => _students = s);
                        }
                      },
                    ),
                  if (_mode == 'drop' && _students.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Students in the van', style: Theme.of(context).textTheme.titleMedium),
                    for (final s in _students)
                      CheckboxListTile(
                        dense: true,
                        value: _inVan.contains(s.id),
                        title: Text(s.name),
                        subtitle: s.className == null ? null : Text(s.className!),
                        onChanged: (v) => setState(() => v == true ? _inVan.add(s.id) : _inVan.remove(s.id)),
                      ),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _takeSelfie,
                    icon: const Icon(Icons.camera_front),
                    label: Text(_selfie == null ? 'Take live selfie' : 'Retake selfie'),
                  ),
                  if (_selfie != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(_selfieBytes!, height: 180, fit: BoxFit.cover),
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _ready ? _start : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: _starting
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_mode == 'pickup' ? 'Start pickup' : 'Start drop'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Starting notifies parents that school transportation has started.',
                      textAlign: TextAlign.center),
                  ],
                ],
              ),
            ),
    );
  }
}
