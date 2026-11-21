import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../../config.dart';
import '../../util.dart';

/// Full-screen map: tap to drop a pin, or use the current location. Returns the chosen LatLng.
class LocationPicker extends StatefulWidget {
  final LatLng? initial;
  final String title;
  const LocationPicker({super.key, this.initial, this.title = 'Choose location'});

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  MapLibreMapController? _map;
  LatLng? _picked;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _picked = widget.initial;
  }

  Future<void> _pin(LatLng at, {bool move = false}) async {
    setState(() => _picked = at);
    final c = _map;
    if (c == null || !_ready) return;
    try {
      await c.clearCircles();
      await c.addCircle(CircleOptions(
          geometry: at, circleRadius: 9, circleColor: '#E53935', circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3));
      if (move) await c.animateCamera(CameraUpdate.newLatLngZoom(at, 16));
    } catch (_) {}
  }

  Future<void> _useMyLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location (GPS) first';
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw 'Location permission is off';
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
      await _pin(LatLng(pos.latitude, pos.longitude), move: true);
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.initial ?? const LatLng(20.2961, 85.8245);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(children: [
        MapLibreMap(
          styleString: mapStyleUrl,
          initialCameraPosition: CameraPosition(target: start, zoom: widget.initial == null ? 12 : 16),
          onMapCreated: (c) => _map = c,
          onStyleLoadedCallback: () {
            _ready = true;
            if (_picked != null) _pin(_picked!);
          },
          onMapClick: (point, latLng) => _pin(latLng),
          compassEnabled: false,
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_picked == null
                    ? 'Tap the map to place the pin'
                    : '${_picked!.latitude.toStringAsFixed(6)}, ${_picked!.longitude.toStringAsFixed(6)}'),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                        onPressed: _useMyLocation, icon: const Icon(Icons.my_location), label: const Text('My location')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _picked == null ? null : () => Navigator.pop(context, _picked),
                      child: const Text('Use this place'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
