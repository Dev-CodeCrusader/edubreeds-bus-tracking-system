import 'dart:convert';

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

/// The road between two consecutive stops (or from the bus to the first stop).
class RouteLeg {
  final List<RoutePoint> points;
  final double distanceM;
  final double durationS;
  final List<RouteStep> steps;
  final List<double> _cum = []; // metres from the start of the leg to each point

  RouteLeg(this.points, this.distanceM, this.durationS, this.steps) {
    var total = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0) {
        total += Geolocator.distanceBetween(points[i - 1].lat, points[i - 1].lng, points[i].lat, points[i].lng);
      }
      _cum.add(total);
    }
  }

  /// Nearest drawn point to a position: its distance in metres and its index.
  ({double dist, int idx}) nearest(double lat, double lng) {
    var best = double.infinity;
    var bi = 0;
    for (var i = 0; i < points.length; i++) {
      final d = Geolocator.distanceBetween(lat, lng, points[i].lat, points[i].lng);
      if (d < best) {
        best = d;
        bi = i;
      }
    }
    return (dist: best, idx: bi);
  }

  /// Metres of road still ahead from point [idx] to the end of the leg.
  double remainingFrom(int idx) => _cum.isEmpty ? distanceM : _cum.last - _cum[idx];
}

/// One route through every remaining stop, in order. legs[i] ends at stopIds[i].
class RoutePlan {
  final List<String> stopIds;
  final List<RouteLeg> legs;
  const RoutePlan(this.stopIds, this.legs);

  /// The line to draw: from leg [from] to the last stop.
  List<RoutePoint> pointsFrom(int from) {
    final out = <RoutePoint>[];
    for (var i = from; i < legs.length; i++) {
      out.addAll(legs[i].points);
    }
    return out;
  }
}

/// Road routing from the free public OSRM demo server (fine for a small pilot; it has no
/// uptime promise, so move to your own OSRM/Valhalla before many schools depend on it).
class Routing {
  static const _base = 'https://router.project-osrm.org/route/v1/driving';

  /// ONE request for the whole journey: bus -> stop 1 -> stop 2 -> ...
  static Future<List<RouteLeg>> plan(RoutePoint from, List<RoutePoint> stops) async {
    final all = [from, ...stops];
    final coords = all.map((p) => '${p.lng},${p.lat}').join(';');
    final url = Uri.parse('$_base/$coords?overview=false&geometries=geojson&steps=true');
    final res = await http.get(url).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw 'Routing server answered ${res.statusCode}';
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = body['routes'] as List?;
    if (body['code'] != 'Ok' || routes == null || routes.isEmpty) throw 'No road route found';
    final legsJson = (routes.first as Map<String, dynamic>)['legs'] as List;

    final legs = <RouteLeg>[];
    for (final leg in legsJson) {
      final pts = <RoutePoint>[];
      final steps = <RouteStep>[];
      for (final s in (leg['steps'] as List)) {
        for (final c in (s['geometry']['coordinates'] as List)) {
          pts.add(RoutePoint((c[1] as num).toDouble(), (c[0] as num).toDouble()));
        }
        final loc = s['maneuver']['location'] as List;
        steps.add(RouteStep(_instruction(s), RoutePoint((loc[1] as num).toDouble(), (loc[0] as num).toDouble())));
      }
      legs.add(RouteLeg(pts, (leg['distance'] as num).toDouble(), (leg['duration'] as num).toDouble(), steps));
    }
    return legs;
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
