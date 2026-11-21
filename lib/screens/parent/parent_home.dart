import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../api.dart';
import '../../util.dart';
import 'progress_bar.dart';
import 'track_screen.dart';

/// Parent app: my children with today's trip status, live tracking, "absent today",
/// and the alert list. New alerts arrive live; "buzz" alerts vibrate until acknowledged.
class ParentHome extends StatefulWidget {
  final DriverProfile me;
  const ParentHome({super.key, required this.me});

  @override
  State<ParentHome> createState() => _ParentHomeState();
}

class _ParentHomeState extends State<ParentHome> {
  int _tab = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _kids = [];
  List<Map<String, dynamic>> _tripStops = [];
  List<Map<String, dynamic>> _absences = [];
  List<Map<String, dynamic>> _notes = [];
  List<Map<String, dynamic>> _plans = []; // stop_students -> stop -> route, per child
  String? _holiday;
  RealtimeChannel? _channel;
  Timer? _refresh;
  bool _buzzOpen = false;

  String get _uid => db.auth.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = db
        .channel('parent_$_uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'recipient_id', value: _uid),
          callback: (p) {
            _load(quiet: true);
            final r = p.newRecord;
            final payload = r['payload'];
            if (payload is Map && payload['buzz'] == true) {
              _buzz(r['id'].toString(), (payload['text'] ?? 'Alert').toString(),
                  (payload['buzz_seconds'] as num?)?.toInt() ?? 8);
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'trip_stops',
          callback: (_) => _load(quiet: true),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'trips',
          callback: (_) => _load(quiet: true),
        )
        .subscribe();
    // safety net if Realtime drops
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    if (_channel != null) db.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final g = await db.from('guardians').select('students(id, full_name, class_name, photo_url)').eq('parent_id', _uid);
      final kids = g.map<Map<String, dynamic>>((r) => Map<String, dynamic>.from(r['students'] as Map)).toList();
      final now = DateTime.now();
      final since = DateTime(now.year, now.month, now.day).toUtc().toIso8601String();
      final ts = await db
          .from('trip_stops')
          .select('id, state, done_at, van_arrived_at, student_id, arriving_at, trips!inner(id, route_id, mode, state, started_at, school_reached_at, left_school_at), stops(name, lat, lng)')
          .gte('trips.started_at', since);
      final pl = await db
          .from('stop_students')
          .select('student_id, stops(name, scheduled_time, lat, lng, routes(id, name, mode, start_time, days))');
      final hol = await db.from('holidays').select('reason').eq('on_date', istDate()).maybeSingle();
      final ab = await db.from('absence_notices').select('id, student_id, mode').eq('on_date', istDate());
      final nt = await db.from('notifications').select().eq('recipient_id', _uid).order('sent_at', ascending: false).limit(60);
      if (!mounted) return;
      setState(() {
        _kids = kids;
        _plans = pl.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _holiday = hol == null ? null : (hol['reason'] ?? 'Holiday').toString();
        _tripStops = ts.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _absences = ab.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _notes = nt.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
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

  // ------------------------------------------------------------------ buzz

  Future<void> _buzz(String noteId, String text, int seconds) async {
    if (_buzzOpen || !mounted) return;
    _buzzOpen = true;
    final timer = Timer.periodic(const Duration(milliseconds: 800), (t) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
      if (t.tick * 0.8 >= seconds) t.cancel();
    });
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.notifications_active, size: 40, color: Colors.orange),
        title: const Text('EDUBREEDS alert'),
        content: Text(text, style: const TextStyle(fontSize: 18)),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    timer.cancel();
    _buzzOpen = false;
    _ack(noteId);
  }

  Future<void> _ack(String id) async {
    try {
      await db.from('notifications').update({'acknowledged_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);
      _load(quiet: true);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ absence

  Future<void> _markAbsent(Map<String, dynamic> kid) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('${kid['full_name']} will be absent today'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'both'), child: const Text('Both pickup and drop')),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'pickup'), child: const Text('Pickup only (morning)')),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'drop'), child: const Text('Drop only (afternoon)')),
        ],
      ),
    );
    if (choice == null) return;
    try {
      await db.from('absence_notices').insert({
        'student_id': kid['id'],
        'on_date': istDate(),
        'mode': choice == 'both' ? null : choice,
        'created_by': _uid,
      });
      if (mounted) toast(context, 'Done. The driver will skip ${kid['full_name']} today.');
      _load(quiet: true);
    } on PostgrestException catch (e) {
      if (mounted) toast(context, e.code == '23505' ? 'Already marked absent for that trip.' : errText(e));
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _cancelAbsence(Map<String, dynamic> a) async {
    if (!await confirm(context, 'Cancel this absence?', 'The child will be expected at the stop again.', yes: 'Cancel absence')) return;
    try {
      await db.from('absence_notices').delete().eq('id', a['id']);
      _load(quiet: true);
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  // ------------------------------------------------------------------ build

  int get _unread => _notes.where((n) => n['acknowledged_at'] == null).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? 'My children' : 'Alerts'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _load()),
          signOutButton(),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load: $_error')))
              : _tab == 0
                  ? _childrenTab()
                  : _alertsTab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.directions_bus), label: 'Children'),
          NavigationDestination(
            icon: Badge(isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.notifications)),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }

  Widget _childrenTab() {
    if (_kids.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No children are linked to your number yet.\nPlease ask the school office to add you as a guardian.',
              textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: _kids.map(_kidCard).toList(),
      ),
    );
  }

  String _stateText(String state, Map<String, dynamic> trip, Map<String, dynamic> ts) {
    final done = parseTime(ts['done_at']);
    final at = done == null ? '' : ' at ${clockOf(done)}';
    final active = trip['state'] == 'active';
    switch (state) {
      case 'picked_up':
        return 'On the bus (picked up$at)';
      case 'dropped':
        return 'Dropped$at';
      case 'absent':
        return 'Marked absent';
      case 'not_available':
        return 'Not at the stop when the van came';
      case 'no_one_at_stop':
        return 'Nobody at the stop';
      default:
        return active ? 'Waiting. The bus is on its way' : 'Trip ended';
    }
  }

  Widget _kidCard(Map<String, dynamic> kid) {
    final sid = kid['id'];
    final rows = _tripStops.where((t) => t['student_id'] == sid).toList()
      ..sort((a, b) => (parseTime(a['trips']['started_at']) ?? DateTime(2000))
          .compareTo(parseTime(b['trips']['started_at']) ?? DateTime(2000)));
    final abs = _absences.where((a) => a['student_id'] == sid).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StudentAvatar(
                name: kid['full_name'].toString(),
                photoPath: kid['photo_url'] as String?,
                photosEnabled: widget.me.photosEnabled),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(kid['full_name'].toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (kid['class_name'] != null) Text(kid['class_name'].toString()),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          ..._progressSections(kid, rows, abs),
          if (abs.isNotEmpty) const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final a in abs)
              InputChip(
                avatar: const Icon(Icons.event_busy, size: 18),
                label: Text('Absent today: ${a['mode'] == null ? 'pickup + drop' : a['mode']}'),
                onDeleted: () => _cancelAbsence(a),
              ),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _markAbsent(kid),
            icon: const Icon(Icons.event_busy),
            label: const Text('Mark absent today'),
          ),
        ]),
      ),
    );
  }

  static const _pickupSteps = [
    'Scheduled',
    'Van started',
    'Van is arriving at your stop. Get ready and wait for the van',
    'Student boarded the van',
    'Van reached school',
  ];
  static const _dropSteps = [
    'Scheduled',
    'Students boarded the van',
    'Van left the school',
    'Van is arriving at your stop',
    'Student dropped',
  ];

  String _hhmm(dynamic t) {
    final s = t?.toString();
    if (s == null || s.length < 5) return '';
    return s.substring(0, 5);
  }

  List<Widget> _progressSections(Map<String, dynamic> kid, List<Map<String, dynamic>> rows, List<Map<String, dynamic>> abs) {
    final sid = kid['id'];
    final wd = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)).weekday;
    final out = <Widget>[];
    final plans = _plans.where((p) => p['student_id'] == sid && p['stops'] is Map && (p['stops'] as Map)['routes'] is Map).toList();
    final seen = <String>{};
    for (final p in plans) {
      final stop = Map<String, dynamic>.from(p['stops'] as Map);
      final route = Map<String, dynamic>.from(stop['routes'] as Map);
      if (!seen.add(route['id'].toString())) continue;
      final mode = route['mode'] == 'drop' ? 'drop' : 'pickup';
      final days = route['days'] is List ? (route['days'] as List).map((e) => (e as num).toInt()).toList() : <int>[1, 2, 3, 4, 5, 6];
      final runsToday = days.contains(wd);
      final absent = abs.any((a) => a['mode'] == null || a['mode'] == mode);
      // today's trip_stop of this child on this route (latest)
      final mine = rows.where((r) => (r['trips'] as Map)['route_id'].toString() == route['id'].toString()).toList();
      final t = mine.isEmpty ? null : mine.last;
      final trip = t == null ? null : Map<String, dynamic>.from(t['trips'] as Map);
      final state = t?['state']?.toString() ?? 'pending';
      final labels = mode == 'drop' ? _dropSteps : _pickupSteps;
      final details = List<String?>.filled(labels.length, null);
      var step = 0;
      String? note;
      var holiday = false;
      final sched = _hhmm(stop['scheduled_time'] ?? route['start_time']);
      if (trip == null) {
        if (_holiday != null) {
          holiday = true;
          note = "It's a holiday: $_holiday";
        } else if (!runsToday) {
          note = 'No trip today.';
        } else if (absent) {
          note = 'Marked absent today.';
        }
        details[0] = holiday || !runsToday ? null : (sched.isEmpty ? null : 'Stop time $sched');
      } else {
        final active = trip['state'] == 'active';
        final arriving = t!['arriving_at'] != null || t['van_arrived_at'] != null;
        if (mode == 'drop') {
          if (state == 'dropped') {
            step = 4;
          } else if (state == 'pending') {
            step = arriving ? 3 : (trip['left_school_at'] != null ? 2 : 1);
          } else {
            step = 4;
          }
        } else {
          if (state == 'picked_up' || state == 'dropped') {
            step = trip['school_reached_at'] != null ? 4 : 3;
          } else if (state == 'pending') {
            step = arriving ? 2 : 1;
          }
        }
        if (state == 'absent') note = 'Marked absent for this trip.';
        if (state == 'not_available') note = 'The child was not at the stop when the van came.';
        if (state == 'no_one_at_stop') note = 'Nobody was at the stop when the van came.';
        if (!active && state == 'pending') note = 'The trip ended before reaching your stop.';
        final done = parseTime(t['done_at']);
        if (done != null && (state == 'picked_up' || state == 'dropped')) {
          details[mode == 'drop' ? 4 : 3] = 'At ${clockOf(done)}';
        }
        final started = parseTime(trip['started_at']);
        if (started != null) details[1] = mode == 'drop' ? null : 'At ${clockOf(started)}';
        final sr = parseTime(trip['school_reached_at']);
        if (sr != null && mode == 'pickup') details[4] = 'At ${clockOf(sr)}';
        final ls = parseTime(trip['left_school_at']);
        if (ls != null && mode == 'drop') details[2] = 'At ${clockOf(ls)}';
        if (note == null && step < 4 && active) {
          out.add(const SizedBox(height: 0));
        }
      }
      out.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Row(children: [
          Icon(mode == 'drop' ? Icons.home : Icons.school, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${mode == 'drop' ? 'Drop' : 'Pickup'}  |  ${route['name']}  |  ${stop['name'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (trip != null && trip['state'] == 'active' && (state == 'pending' || state == 'picked_up'))
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TrackScreen(
                  tripId: trip['id'].toString(),
                  tripStopId: t!['id'].toString(),
                  childName: kid['full_name'].toString(),
                  stopName: (stop['name'] ?? 'your stop').toString(),
                  stopLat: (stop['lat'] as num?)?.toDouble(),
                  stopLng: (stop['lng'] as num?)?.toDouble(),
                ),
              )),
              child: const Text('Track bus'),
            ),
        ]),
      ));
      if (note != null) {
        out.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: holiday ? Colors.red.shade50 : Colors.orange.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(note, style: TextStyle(color: holiday ? Colors.red.shade800 : Colors.orange.shade900)),
        ));
      }
      if (!(holiday || (trip == null && (!runsToday || absent)))) {
        out.add(TripProgress(labels: labels, details: details, step: step));
      }
    }
    if (plans.isEmpty) {
      if (rows.isEmpty) out.add(const Text('No route is set for this child yet.', style: TextStyle(color: Colors.grey)));
      for (final t in rows) {
        out.add(_tripRow(kid, t));
      }
    }
    return out;
  }

  Widget _tripRow(Map<String, dynamic> kid, Map<String, dynamic> t) {
    final trip = Map<String, dynamic>.from(t['trips'] as Map);
    final stop = t['stops'] is Map ? Map<String, dynamic>.from(t['stops'] as Map) : <String, dynamic>{};
    final state = t['state'].toString();
    final live = trip['state'] == 'active' && (state == 'pending' || state == 'picked_up');
    final label = trip['mode'] == 'drop' ? 'Drop' : 'Pickup';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(trip['mode'] == 'drop' ? Icons.home : Icons.school, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$label${stop['name'] == null ? '' : ' - ${stop['name']}'}', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(_stateText(state, trip, t)),
          ]),
        ),
        if (live)
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TrackScreen(
                tripId: trip['id'].toString(),
                tripStopId: t['id'].toString(),
                childName: kid['full_name'].toString(),
                stopName: (stop['name'] ?? 'your stop').toString(),
                stopLat: (stop['lat'] as num?)?.toDouble(),
                stopLng: (stop['lng'] as num?)?.toDouble(),
              ),
            )),
            child: const Text('Track bus'),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------------ alerts

  IconData _kindIcon(String kind) {
    switch (kind) {
      case 'trip_started':
        return Icons.directions_bus;
      case 'stop_before':
        return Icons.near_me;
      case 'arrived':
        return Icons.place;
      case 'alert':
        return Icons.notifications_active;
      case 'absent_proof':
        return Icons.photo_camera;
      case 'picked_up':
        return Icons.login;
      case 'dropped':
        return Icons.home;
      case 'arriving':
        return Icons.near_me;
      case 'left_school':
        return Icons.logout;
      case 'school_reached':
        return Icons.school;
      default:
        return Icons.info;
    }
  }

  Widget _alertsTab() {
    if (_notes.isEmpty) return const Center(child: Text('No alerts yet.'));
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView.separated(
        itemCount: _notes.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final n = _notes[i];
          final payload = n['payload'] is Map ? Map<String, dynamic>.from(n['payload'] as Map) : <String, dynamic>{};
          final unread = n['acknowledged_at'] == null;
          final when = parseTime(n['sent_at']);
          return ListTile(
            leading: Icon(_kindIcon(n['kind'].toString()), color: unread ? Theme.of(context).colorScheme.primary : Colors.grey),
            title: Text((payload['text'] ?? n['kind']).toString(),
                style: TextStyle(fontWeight: unread ? FontWeight.w700 : FontWeight.normal)),
            subtitle: when == null ? null : Text(stampOf(when)),
            trailing: payload['image'] != null ? const Icon(Icons.image) : null,
            onTap: () async {
              if (unread) _ack(n['id'].toString());
              if (payload['image'] != null) {
                final url = await Api.signedUrl('trip-photos', payload['image'].toString());
                if (url != null && mounted) {
                  showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Photo taken at the stop'),
                      content: Image.network(url),
                      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
                    ),
                  );
                }
              }
            },
          );
        },
      ),
    );
  }
}
