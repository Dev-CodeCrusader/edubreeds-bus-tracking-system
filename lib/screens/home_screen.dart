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
      _pickDefaultRoute();
      _resumeActiveTrip();
    } catch (e) {
      setState(() {
        _error = 'Could not load your routes. Pull down to retry.';
        _loading = false;
      });
    }
  }

  /// If the driver already has a trip running (page refreshed, app closed and reopened),
  /// go straight back to it instead of starting over.
  Future<void> _resumeActiveTrip() async {
    if (_resumeChecked) return;
    _resumeChecked = true;
    try {
      final t = await Api.activeTrip();
      if (t == null || !mounted) return;
      await LocationService.ensurePermission();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Resuming your trip...')));
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RideScreen(
            tripId: t['id'] as String, mode: t['mode'] as String, photosEnabled: _me?.photosEnabled ?? true),
      ));
    } catch (_) {
      // If the check fails the driver can still start normally.
    }
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
      _route != null && _selfie != null && (_mode == 'pickup' || _inVan.isNotEmpty) && !_starting;

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
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
            onPressed: () => Supabase.instance.client.auth.signOut(),
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
              ),
            ),
    );
  }
}
