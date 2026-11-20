import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class RoutePoint {
  final double lat;
  final double lng;
  const RoutePoint(this.lat, this.lng);
}

class RouteStep {
  final String text; // e.g. "Turn left onto Station Road"
  final RoutePoint at; // where the manoeuvre happens
  const RouteStep(this.text, this.at);
}

class RouteResult {
  final List<RoutePoint> points;
  final double distanceM;
  final double durationS;
  final List<RouteStep> steps;
  const RouteResult(this.points, this.distanceM, this.durationS, this.steps);

  /// Metres from a position to the nearest point on the drawn route (vertex based, good enough
  /// to notice that the driver has left the route).
  double distanceFromRoute(double lat, double lng) {
    var best = double.infinity;
    for (final p in points) {
      final d = Geolocator.distanceBetween(lat, lng, p.lat, p.lng);
      best = math.min(best, d);
    }
    return best;
  }
}

/// Road routing from the free public OSRM demo server (fine for a small pilot; it has no
/// uptime promise, so move to your own Valhalla/OSRM before many schools depend on it).
class Routing {
  static const _base = 'https://router.project-osrm.org/route/v1/driving';

  static Future<RouteResult> route(double fromLat, double fromLng, double toLat, double toLng) async {
    final url = Uri.parse('$_base/$fromLng,$fromLat;$toLng,$toLat'
        '?overview=full&geometries=geojson&steps=true');
    final res = await http.get(url).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw 'Routing server answered ${res.statusCode}';
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = body['routes'] as List?;
    if (body['code'] != 'Ok' || routes == null || routes.isEmpty) throw 'No road route found';
    final r = routes.first as Map<String, dynamic>;

    final coords = (r['geometry']['coordinates'] as List)
        .map<RoutePoint>((c) => RoutePoint((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();

    final steps = <RouteStep>[];
    for (final leg in (r['legs'] as List)) {
      for (final s in (leg['steps'] as List)) {
        final loc = s['maneuver']['location'] as List;
        steps.add(RouteStep(_instruction(s), RoutePoint((loc[1] as num).toDouble(), (loc[0] as num).toDouble())));
      }
    }
    return RouteResult(coords, (r['distance'] as num).toDouble(), (r['duration'] as num).toDouble(), steps);
  }

  static String _instruction(Map s) {
    final m = s['maneuver'] as Map;
    final type = (m['type'] ?? '') as String;
    final mod = m['modifier'] as String?;
    final name = ((s['name'] ?? '') as String).trim();
    final onto = name.isEmpty ? '' : ' onto $name';
    switch (type) {
      case 'depart':
        return 'Head ${mod ?? 'ahead'}${name.isEmpty ? '' : ' on $name'}';
      case 'arrive':
        return 'You have arrived at the stop';
      case 'roundabout':
      case 'rotary':
        final exit = m['exit'];
        return exit == null ? 'Enter the roundabout' : 'At the roundabout take exit $exit';
      case 'exit roundabout':
      case 'exit rotary':
        return 'Leave the roundabout$onto';
      case 'merge':
        return 'Merge ${mod ?? 'ahead'}$onto';
      case 'fork':
        return 'Keep ${mod ?? 'ahead'} at the fork$onto';
      case 'end of road':
        return 'At the end of the road turn ${mod ?? 'ahead'}$onto';
      case 'continue':
      case 'new name':
        return 'Continue${mod == null || mod == 'straight' ? '' : ' $mod'}$onto';
      default:
        if (mod == null || mod == 'straight') return 'Continue straight$onto';
        if (mod == 'uturn') return 'Make a U-turn$onto';
        return 'Turn $mod$onto';
    }
  }
}
