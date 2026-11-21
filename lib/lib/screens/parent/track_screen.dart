import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../api.dart';
import '../../config.dart';
import '../../util.dart';

/// Parent's live view of the bus: bus position on the map, the child's stop, distance and status.
/// Position arrives through Realtime; a slow poll every 8 seconds is the safety net.
class TrackScreen extends StatefulWidget {
  final String tripId;
  final String? tripStopId; // null for staff (no single child)
  final String? childName; // null for staff
  final String stopName;
  final double? stopLat;
  final double? stopLng;
  const TrackScreen({
    super.key,
    required this.tripId,
    this.tripStopId,
    this.childName,
    this.stopName = 'the stop',
    this.stopLat,
    this.stopLng,
  });

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  MapLibreMapController? _map;
  bool _styleReady = false;
  RealtimeChannel? _channel;
  Timer? _poll;

  LatLng? _bus;
  double? _speedKmh;
  DateTime? _updatedAt;
  String _childState = 'pending';
  String _tripState = 'active';

  Circle? _busCircle;
  bool _drawing = false;
  LatLng? _want;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _channel = db
        .channel('live_${widget.tripId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'live_positions',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'trip_id', value: widget.tripId),
          callback: (payload) => _applyRow(payload.newRecord),
        )
        .subscribe();
    _fetch();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _fetch());
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_channel != null) db.removeChannel(_channel!);
    super.dispose();
  }

  void _applyRow(Map<String, dynamic> r) {
    final lat = (r['lat'] as num?)?.toDouble();
    final lng = (r['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    if (!mounted) return;
    setState(() {
      _bus = LatLng(lat, lng);
      _speedKmh = (r['speed_kmh'] as num?)?.toDouble();
      _updatedAt = parseTime(r['updated_at']);
    });
    _setBus(LatLng(lat, lng));
  }

  Future<void> _fetch() async {
    try {
      final pos = await db.from('live_positions').select('lat, lng, speed_kmh, updated_at').eq('trip_id', widget.tripId).maybeSingle();
      if (pos != null) _applyRow(Map<String, dynamic>.from(pos));
      final ts = widget.tripStopId == null ? null : await db.from('trip_stops').select('state').eq('id', widget.tripStopId!).maybeSingle();
      final tr = await db.from('trips').select('state').eq('id', widget.tripId).maybeSingle();
      if (!mounted) return;
      setState(() {
        if (ts != null) _childState = ts['state'].toString();
        if (tr != null) _tripState = tr['state'].toString();
      });
    } catch (_) {
      // offline for a moment; the next poll retries
    }
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    final c = _map;
    if (c == null) return;
    if (widget.stopLat != null && widget.stopLng != null) {
      try {
        await c.addCircle(CircleOptions(
            geometry: LatLng(widget.stopLat!, widget.stopLng!),
            circleRadius: 9,
            circleColor: '#2E7D32',
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 3));
      } catch (_) {}
      if (_bus == null) {
        await c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(widget.stopLat!, widget.stopLng!), 14));
      }
    }
    if (_bus != null) _setBus(_bus!);
  }

  Future<void> _setBus(LatLng p) async {
    _want = p;
    if (_drawing || _map == null || !_styleReady) return;
    _drawing = true;
    try {
      while (_want != null) {
        final at = _want!;
        _want = null;
        final opts = CircleOptions(
            geometry: at, circleRadius: 9, circleColor: '#E53935', circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3);
        if (_busCircle == null) {
          _busCircle = await _map!.addCircle(opts);
        } else {
          await _map!.updateCircle(_busCircle!, opts);
        }
        if (!_fitted) {
          _fitted = true;
          await _fit(at);
        }
      }
    } catch (_) {
      // ignore: the next update redraws
    } finally {
      _drawing = false;
    }
  }

  Future<void> _fit(LatLng bus) async {
    final c = _map;
    if (c == null) return;
    if (widget.stopLat == null || widget.stopLng == null) {
      await c.animateCamera(CameraUpdate.newLatLngZoom(bus, 15));
      return;
    }
    final s = LatLng(widget.stopLat!, widget.stopLng!);
    final sw = LatLng(bus.latitude < s.latitude ? bus.latitude : s.latitude, bus.longitude < s.longitude ? bus.longitude : s.longitude);
    final ne = LatLng(bus.latitude > s.latitude ? bus.latitude : s.latitude, bus.longitude > s.longitude ? bus.longitude : s.longitude);
    await c.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: sw, northeast: ne),
        left: 60, right: 60, top: 60, bottom: 60));
  }

  String _statusText() {
    if (_tripState != 'active') return 'This trip has ended.';
    final name = widget.childName;
    if (name == null) return 'Trip in progress.';
    switch (_childState) {
      case 'picked_up':
        return '$name is on the bus.';
      case 'dropped':
        return '$name has been dropped.';
      case 'absent':
        return '$name is marked absent for this trip.';
      case 'not_available':
      case 'no_one_at_stop':
        return 'The van could not meet $name at the stop.';
      default:
        return 'The bus is on its way to ${widget.stopName}.';
    }
  }

  @override
  Widget build(BuildContext context) {
    String distance = 'Waiting for the bus location...';
    Color? warn;
    if (_bus != null && widget.stopLat != null && widget.stopLng != null) {
      final d = Geolocator.distanceBetween(_bus!.latitude, _bus!.longitude, widget.stopLat!, widget.stopLng!);
      distance = d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km from the stop' : '${d.round()} m from the stop';
      if (_speedKmh != null && _speedKmh! > 3) distance += '  |  ${_speedKmh!.round()} km/h';
    } else if (_bus != null) {
      distance = 'Bus location received';
    }
    String? stale;
    if (_updatedAt != null && _tripState == 'active') {
      final secs = DateTime.now().difference(_updatedAt!).inSeconds;
      if (secs > 90) {
        stale = 'Bus location last updated ${secs ~/ 60} min ago (phone may be offline or out of coverage).';
        warn = Colors.orange.shade800;
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.childName == null ? 'Live bus' : 'Bus for ${widget.childName}'), actions: [
        IconButton(
          tooltip: 'Show bus and stop',
          icon: const Icon(Icons.center_focus_strong),
          onPressed: () {
            if (_bus != null) _fit(_bus!);
          },
        ),
      ]),
      body: Column(children: [
        Expanded(
          child: MapLibreMap(
            styleString: mapStyleUrl,
            initialCameraPosition: CameraPosition(
                target: LatLng(widget.stopLat ?? 20.2961, widget.stopLng ?? 85.8245), zoom: 13),
            onMapCreated: (c) => _map = c,
            onStyleLoadedCallback: _onStyleLoaded,
            compassEnabled: false,
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_statusText(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            Text(distance),
            if (stale != null) Text(stale, style: TextStyle(color: warn, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(widget.stopLat == null ? 'Red: bus' : 'Red: bus   Green: ${widget.stopName}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      ]),
    );
  }
}
