import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../util.dart';
import '../parent/track_screen.dart';

/// Today's trips of the school: running ones first, then finished ones.
/// Used by the school admin and the caretaker.
class LiveTripsView extends StatefulWidget {
  final DriverProfile me;
  const LiveTripsView({super.key, required this.me});

  @override
  State<LiveTripsView> createState() => _LiveTripsViewState();
}

class _LiveTripsViewState extends State<LiveTripsView> {
  List<Map<String, dynamic>> _trips = [];
  Map<String, Map<String, int>> _counts = {};
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final since = DateTime(now.year, now.month, now.day).toUtc().toIso8601String();
      final t = await db
          .from('trips')
          .select('id, mode, state, started_at, ended_at, profiles(full_name), routes(name, buses(reg_no))')
          .eq('school_id', widget.me.schoolId!)
          .gte('started_at', since)
          .order('started_at', ascending: false);
      final trips = t.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
      final counts = <String, Map<String, int>>{};
      if (trips.isNotEmpty) {
        final ids = trips.map((e) => e['id'].toString()).toList();
        final ts = await db.from('trip_stops').select('trip_id, state').inFilter('trip_id', ids);
        for (final r in ts) {
          final m = counts.putIfAbsent(r['trip_id'].toString(), () => {});
          final s = r['state'].toString();
          m[s] = (m[s] ?? 0) + 1;
        }
      }
      if (!mounted) return;
      setState(() {
        _trips = trips;
        _counts = counts;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!quiet) _error = errText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Could not load: $_error'));
    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No trips today yet.')))]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _trips.length,
        itemBuilder: (context, i) {
          final t = _trips[i];
          final c = _counts[t['id'].toString()] ?? {};
          final active = t['state'] == 'active';
          final route = t['routes'] as Map?;
          final bus = (route?['buses'] as Map?)?['reg_no'];
          final driver = (t['profiles'] as Map?)?['full_name'];
          final total = c.values.fold<int>(0, (a, b) => a + b);
          final done = (c['picked_up'] ?? 0) + (c['dropped'] ?? 0);
          final started = parseTime(t['started_at']);
          return Card(
            child: ListTile(
              leading: Icon(t['mode'] == 'drop' ? Icons.home : Icons.school,
                  color: active ? Colors.green.shade700 : Colors.grey),
              title: Text('${route?['name'] ?? 'Route'}  (${t['mode'] == 'drop' ? 'Drop' : 'Pickup'})'),
              subtitle: Text('${active ? 'RUNNING' : 'Finished'}  |  ${driver ?? ''}  |  ${bus ?? ''}\n'
                  'Started ${started == null ? '' : clockOf(started)}  |  $done of $total done'
                  '${(c['absent'] ?? 0) > 0 ? '  |  ${c['absent']} absent' : ''}'),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TripDetailScreen(trip: t))),
            ),
          );
        },
      ),
    );
  }
}

class TripDetailScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  const TripDetailScreen({super.key, required this.trip});

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String? _selfieUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.trip['id'].toString();
      final r = await db
          .from('trip_stops')
          .select('id, state, done_at, van_arrived_at, remark, students(full_name, class_name), stops(name, seq), proof_photos(image_url)')
          .eq('trip_id', id);
      final tr = await db.from('trips').select('selfie_url').eq('id', id).maybeSingle();
      final selfie = await Api.signedUrl('trip-photos', tr?['selfie_url'] as String?);
      final rows = r.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList()
        ..sort((a, b) => ((a['stops'] as Map)['seq'] as int).compareTo((b['stops'] as Map)['seq'] as int));
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selfieUrl = selfie;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errText(e);
      });
    }
  }

  String _label(String s) {
    switch (s) {
      case 'picked_up':
        return 'Picked up';
      case 'dropped':
        return 'Dropped';
      case 'absent':
        return 'Absent';
      case 'not_available':
        return 'Not available at stop';
      case 'no_one_at_stop':
        return 'Nobody at stop';
      default:
        return 'Waiting';
    }
  }

  Color _color(String s) {
    switch (s) {
      case 'picked_up':
      case 'dropped':
        return Colors.green.shade700;
      case 'absent':
      case 'not_available':
      case 'no_one_at_stop':
        return Colors.red.shade700;
      default:
        return Colors.grey;
    }
  }

  Future<void> _showProof(String path) async {
    final url = await Api.signedUrl('trip-photos', path);
    if (url == null || !mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Photo taken at the stop'),
        content: Image.network(url),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trip;
    final active = t['state'] == 'active';
    return Scaffold(
      appBar: AppBar(title: Text((t['routes'] as Map?)?['name']?.toString() ?? 'Trip'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load: $_error'))
              : ListView(padding: const EdgeInsets.all(12), children: [
                  if (active)
                    FilledButton.icon(
                      icon: const Icon(Icons.map),
                      label: const Text('Open live map'),
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => TrackScreen(tripId: t['id'].toString()))),
                    ),
                  if (_selfieUrl != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        CircleAvatar(radius: 28, backgroundImage: NetworkImage(_selfieUrl!)),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Driver selfie at the start of the shift\n${(t['profiles'] as Map?)?['full_name'] ?? ''}')),
                      ]),
                    ),
                  for (final r in _rows)
                    Card(
                      child: ListTile(
                        title: Text((r['students'] as Map)['full_name'].toString()),
                        subtitle: Text('${(r['stops'] as Map)['seq']}. ${(r['stops'] as Map)['name']}'
                            '${r['done_at'] == null ? '' : '  |  ${clockOf(parseTime(r['done_at'])!)}'}'
                            '${r['remark'] == null ? '' : '  |  ${r['remark']}'}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if ((r['proof_photos'] as List?)?.isNotEmpty ?? false)
                            IconButton(
                              icon: const Icon(Icons.photo_camera),
                              onPressed: () => _showProof((r['proof_photos'] as List).first['image_url'].toString()),
                            ),
                          Text(_label(r['state'].toString()),
                              style: TextStyle(color: _color(r['state'].toString()), fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                ]),
    );
  }
}
