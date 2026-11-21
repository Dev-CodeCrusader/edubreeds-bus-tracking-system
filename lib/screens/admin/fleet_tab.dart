import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../admin_api.dart';
import '../../api.dart';
import '../../util.dart';
import 'location_picker.dart';

String _hhmm(dynamic t) => t == null ? '' : t.toString().split(':').take(2).join(':');

TimeOfDay? _toTime(dynamic t) {
  if (t == null) return null;
  final p = t.toString().split(':');
  if (p.length < 2) return null;
  return TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: int.tryParse(p[1].split('.').first) ?? 0);
}

String _fromTime(TimeOfDay t) => '${two(t.hour)}:${two(t.minute)}:00';

/// School admin: buses (with driver) and routes (with ordered stops).
class FleetTab extends StatefulWidget {
  final DriverProfile me;
  const FleetTab({super.key, required this.me});

  @override
  State<FleetTab> createState() => _FleetTabState();
}

class _FleetTabState extends State<FleetTab> {
  int _part = 0; // 0 = routes, 1 = buses
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _routes = [];
  List<Map<String, dynamic>> _buses = [];
  List<Map<String, dynamic>> _drivers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final sid = widget.me.schoolId!;
      final r = await db
          .from('routes')
          .select('id, name, mode, bus_id, start_time, days, school_arrival, school_lat, school_lng, buses(reg_no), stops(count)')
          .eq('school_id', sid)
          .order('name');
      final b = await db.from('buses').select('id, reg_no, capacity, driver_id, profiles(full_name)').eq('school_id', sid).order('reg_no');
      final d = await db.from('profiles').select('id, full_name').eq('school_id', sid).eq('role', 'driver').eq('active', true).order('full_name');
      if (!mounted) return;
      List<Map<String, dynamic>> cast(List l) => l.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
      setState(() {
        _routes = cast(r);
        _buses = cast(b);
        _drivers = cast(d);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errText(e);
      });
    }
  }

  Future<void> _editBus([Map<String, dynamic>? bus]) async {
    final reg = TextEditingController(text: bus?['reg_no']?.toString() ?? '');
    final cap = TextEditingController(text: bus?['capacity']?.toString() ?? '');
    String? driver = bus?['driver_id']?.toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: Text(bus == null ? 'Add bus / van' : 'Edit bus / van'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: reg, decoration: const InputDecoration(labelText: 'Registration number'), textCapitalization: TextCapitalization.characters),
              TextField(controller: cap, decoration: const InputDecoration(labelText: 'Seats (optional)'), keyboardType: TextInputType.number),
              DropdownButtonFormField<String?>(
                decoration: const InputDecoration(labelText: 'Driver'),
                value: driver,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No driver yet')),
                  for (final d in _drivers) DropdownMenuItem<String?>(value: d['id'].toString(), child: Text(d['full_name'].toString())),
                ],
                onChanged: (v) => setS(() => driver = v),
              ),
            ]),
          ),
          actions: [
            if (bus != null)
              TextButton(
                  onPressed: () async {
                    if (await confirm(c, 'Delete this bus?', 'Routes using it will have no bus.', yes: 'Delete')) {
                      Navigator.pop(c, false);
                      try {
                        await db.from('buses').delete().eq('id', bus['id']);
                        _load();
                      } catch (e) {
                        if (mounted) toast(context, errText(e));
                      }
                    }
                  },
                  child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (reg.text.trim().isEmpty) {
      if (mounted) toast(context, 'Enter the registration number');
      return;
    }
    try {
      final data = {
        'reg_no': reg.text.trim().toUpperCase(),
        'capacity': int.tryParse(cap.text.trim()),
        'driver_id': driver,
      };
      if (bus == null) {
        await db.from('buses').insert({...data, 'school_id': widget.me.schoolId});
      } else {
        await db.from('buses').update(data).eq('id', bus['id']);
      }
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _openRoute([Map<String, dynamic>? r]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RouteScreen(me: widget.me, route: r, buses: _buses)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Routes'), icon: Icon(Icons.alt_route)),
                ButtonSegment(value: 1, label: Text('Buses'), icon: Icon(Icons.directions_bus)),
              ],
              selected: {_part},
              onSelectionChanged: (s) => setState(() => _part = s.first),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: () => _part == 0 ? _openRoute() : _editBus(), icon: const Icon(Icons.add), label: const Text('Add')),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Could not load: $_error'))
                : RefreshIndicator(onRefresh: _load, child: _part == 0 ? _routeList() : _busList()),
      ),
    ]);
  }

  Widget _routeList() {
    if (_routes.isEmpty) return ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No routes yet.')))]);
    return ListView.separated(
      itemCount: _routes.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = _routes[i];
        final n = (r['stops'] is List && (r['stops'] as List).isNotEmpty) ? (r['stops'] as List).first['count'] : 0;
        final bus = (r['buses'] as Map?)?['reg_no'];
        return ListTile(
          leading: Icon(r['mode'] == 'drop' ? Icons.home : Icons.school),
          title: Text(r['name'].toString()),
          subtitle: Text('${r['mode'] == 'drop' ? 'Drop' : 'Pickup'}  |  ${r['start_time'] == null ? 'no start time' : _hhmm(r['start_time'])}  |  $n stops  |  ${bus ?? 'no bus'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openRoute(r),
        );
      },
    );
  }

  Widget _busList() {
    if (_buses.isEmpty) return ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No buses yet.')))]);
    return ListView.separated(
      itemCount: _buses.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final b = _buses[i];
        final drv = (b['profiles'] as Map?)?['full_name'];
        return ListTile(
          leading: const Icon(Icons.directions_bus),
          title: Text(b['reg_no'].toString()),
          subtitle: Text('Driver: ${drv ?? 'none'}${b['capacity'] == null ? '' : '  |  ${b['capacity']} seats'}'),
          trailing: const Icon(Icons.edit),
          onTap: () => _editBus(b),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------

class RouteScreen extends StatefulWidget {
  final DriverProfile me;
  final Map<String, dynamic>? route;
  final List<Map<String, dynamic>> buses;
  const RouteScreen({super.key, required this.me, this.route, required this.buses});

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  String? _id;
  late final TextEditingController _name = TextEditingController(text: widget.route?['name']?.toString() ?? '');
  String _mode = 'pickup';
  String? _bus;
  TimeOfDay? _arrival;
  TimeOfDay? _startT; // scheduled start of the trip
  Set<int> _days = {1, 2, 3, 4, 5, 6}; // 1 = Monday ... 7 = Sunday
  LatLng? _school;
  bool _saving = false;
  List<Map<String, dynamic>> _stops = [];

  @override
  void initState() {
    super.initState();
    final r = widget.route;
    if (r != null) {
      _id = r['id'].toString();
      _mode = r['mode'].toString();
      _bus = r['bus_id']?.toString();
      _arrival = _toTime(r['school_arrival']);
      _startT = _toTime(r['start_time']);
      if (r['days'] is List) _days = (r['days'] as List).map((e) => (e as num).toInt()).toSet();
      if (r['school_lat'] != null) _school = LatLng((r['school_lat'] as num).toDouble(), (r['school_lng'] as num).toDouble());
      _loadStops();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadStops() async {
    try {
      final r = await db
          .from('stops')
          .select('id, seq, name, lat, lng, radius_m, scheduled_time, stop_students(students(full_name))')
          .eq('route_id', _id!)
          .order('seq');
      if (!mounted) return;
      setState(() => _stops = r.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList());
    } catch (e) {
      if (mounted) toast(context, 'Could not load stops: ${errText(e)}');
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Enter a route name');
      return;
    }
    setState(() => _saving = true);
    try {
      final data = {
        'name': _name.text.trim(),
        'mode': _mode,
        'bus_id': _bus,
        'school_arrival': _arrival == null ? null : _fromTime(_arrival!),
        'start_time': _startT == null ? null : _fromTime(_startT!),
        'days': (_days.toList()..sort()),
        'school_location': _school == null ? null : AdminApi.point(_school!.latitude, _school!.longitude),
      };
      if (_id == null) {
        final row = await db.from('routes').insert({...data, 'school_id': widget.me.schoolId}).select('id').single();
        _id = row['id'].toString();
      } else {
        await db.from('routes').update(data).eq('id', _id!);
      }
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, 'Saved. Now add the stops.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, errText(e));
    }
  }

  Future<void> _deleteRoute() async {
    if (!await confirm(context, 'Delete this route?', 'Its stops and trip history will be removed.', yes: 'Delete')) return;
    try {
      await db.from('routes').delete().eq('id', _id!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _pickSchool() async {
    final p = await Navigator.of(context).push<LatLng>(
        MaterialPageRoute(builder: (_) => LocationPicker(initial: _school, title: 'School location')));
    if (p != null) setState(() => _school = p);
  }

  Future<void> _editStop([Map<String, dynamic>? stop]) async {
    final name = TextEditingController(text: stop?['name']?.toString() ?? '');
    final radius = TextEditingController(text: (stop?['radius_m'] ?? 60).toString());
    TimeOfDay? time = _toTime(stop?['scheduled_time']);
    LatLng? at = stop != null && stop['lat'] != null ? LatLng((stop['lat'] as num).toDouble(), (stop['lng'] as num).toDouble()) : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: Text(stop == null ? 'Add stop' : 'Edit stop'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Stop name'), textCapitalization: TextCapitalization.words),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.place),
                label: Text(at == null ? 'Choose location on map' : '${at!.latitude.toStringAsFixed(5)}, ${at!.longitude.toStringAsFixed(5)}'),
                onPressed: () async {
                  final p = await Navigator.of(context).push<LatLng>(
                      MaterialPageRoute(builder: (_) => LocationPicker(initial: at ?? _school, title: 'Stop location')));
                  if (p != null) setS(() => at = p);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(time == null ? 'Scheduled time' : 'Scheduled time ${two(time!.hour)}:${two(time!.minute)}'),
                onPressed: () async {
                  final t = await showTimePicker(context: c, initialTime: time ?? const TimeOfDay(hour: 7, minute: 30));
                  if (t != null) setS(() => time = t);
                },
              ),
              TextField(
                  controller: radius,
                  decoration: const InputDecoration(labelText: 'Arrival radius in metres'),
                  keyboardType: TextInputType.number),
            ]),
          ),
          actions: [
            if (stop != null)
              TextButton(
                  onPressed: () async {
                    if (await confirm(c, 'Delete this stop?', 'Students on it will have no stop on this route.', yes: 'Delete')) {
                      Navigator.pop(c, false);
                      try {
                        await db.from('stops').delete().eq('id', stop['id']);
                        _loadStops();
                      } catch (e) {
                        if (mounted) toast(context, errText(e));
                      }
                    }
                  },
                  child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty || at == null) {
      if (mounted) toast(context, 'A stop needs a name and a location');
      return;
    }
    try {
      final data = {
        'name': name.text.trim(),
        'location': AdminApi.point(at!.latitude, at!.longitude),
        'radius_m': int.tryParse(radius.text.trim()) ?? 60,
        'scheduled_time': time == null ? null : _fromTime(time!),
      };
      if (stop == null) {
        final next = _stops.isEmpty ? 1 : (_stops.map((s) => s['seq'] as int).reduce((a, b) => a > b ? a : b) + 1);
        await db.from('stops').insert({...data, 'route_id': _id, 'seq': next});
      } else {
        await db.from('stops').update(data).eq('id', stop['id']);
      }
      _loadStops();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  /// Moves a stop up or down and renumbers all stops (two passes, because seq must stay unique).
  Future<void> _move(int index, int delta) async {
    final to = index + delta;
    if (to < 0 || to >= _stops.length) return;
    final order = List<Map<String, dynamic>>.from(_stops);
    final item = order.removeAt(index);
    order.insert(to, item);
    try {
      for (var i = 0; i < order.length; i++) {
        await db.from('stops').update({'seq': 10000 + i}).eq('id', order[i]['id']);
      }
      for (var i = 0; i < order.length; i++) {
        await db.from('stops').update({'seq': i + 1}).eq('id', order[i]['id']);
      }
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
    _loadStops();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_id == null ? 'New route' : 'Route'), actions: [
        if (_id != null) IconButton(tooltip: 'Delete route', icon: const Icon(Icons.delete_outline), onPressed: _deleteRoute),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Route name (e.g. Morning route A)')),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'pickup', label: Text('Pickup'), icon: Icon(Icons.school)),
            ButtonSegment(value: 'drop', label: Text('Drop'), icon: Icon(Icons.home)),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          decoration: const InputDecoration(labelText: 'Bus'),
          value: _bus,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('No bus yet')),
            for (final b in widget.buses) DropdownMenuItem<String?>(value: b['id'].toString(), child: Text(b['reg_no'].toString())),
          ],
          onChanged: (v) => setState(() => _bus = v),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.alarm),
          label: Text(_startT == null ? 'Trip start time (when the driver leaves)' : 'Trip starts ${two(_startT!.hour)}:${two(_startT!.minute)}'),
          onPressed: () async {
            final t = await showTimePicker(context: context, initialTime: _startT ?? const TimeOfDay(hour: 7, minute: 0));
            if (t != null) setState(() => _startT = t);
          },
        ),
        const SizedBox(height: 8),
        const Text('Runs on', style: TextStyle(fontWeight: FontWeight.w600)),
        Wrap(spacing: 6, children: [
          for (final e in const {1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun'}.entries)
            FilterChip(
              label: Text(e.value),
              selected: _days.contains(e.key),
              onSelected: (v) => setState(() => v ? _days.add(e.key) : _days.remove(e.key)),
            ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule),
            label: Text(_arrival == null ? 'School arrival time' : 'Arrives ${two(_arrival!.hour)}:${two(_arrival!.minute)}'),
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: _arrival ?? const TimeOfDay(hour: 8, minute: 30));
              if (t != null) setState(() => _arrival = t);
            },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.school),
            label: Text(_school == null ? 'School location' : 'School: ${_school!.latitude.toStringAsFixed(4)}, ${_school!.longitude.toStringAsFixed(4)}'),
            onPressed: _pickSchool,
          ),
        ]),
        const SizedBox(height: 12),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : (_id == null ? 'Create route' : 'Save route'))),
        if (_id != null) ...[
          const SizedBox(height: 8),
          Section(
            title: 'Stops (in driving order)',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_stops.isEmpty) const Text('No stops yet.', style: TextStyle(color: Colors.grey)),
              for (var i = 0; i < _stops.length; i++) _stopTile(i),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: () => _editStop(), icon: const Icon(Icons.add_location_alt), label: const Text('Add stop')),
              const SizedBox(height: 4),
              const Text('Assign students to stops from the Students tab.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _stopTile(int i) {
    final s = _stops[i];
    final names = ((s['stop_students'] as List?) ?? [])
        .map((x) => ((x as Map)['students'] as Map?)?['full_name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: CircleAvatar(radius: 14, child: Text('${s['seq']}')),
        title: Text(s['name'].toString()),
        subtitle: Text([
          if (s['scheduled_time'] != null) _hhmm(s['scheduled_time']),
          if (names.isNotEmpty) names else 'no students yet',
        ].join('  |  ')),
        onTap: () => _editStop(s),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.arrow_upward, size: 20), onPressed: i == 0 ? null : () => _move(i, -1)),
          IconButton(icon: const Icon(Icons.arrow_downward, size: 20), onPressed: i == _stops.length - 1 ? null : () => _move(i, 1)),
        ]),
      ),
    );
  }
}
