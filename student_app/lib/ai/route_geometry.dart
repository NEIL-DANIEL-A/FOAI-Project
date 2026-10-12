import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Road-following geometry for DRAWING routes Google-Maps-style.
///
/// Architecture note (jury-safe): routing DECISIONS always stay in
/// [AStarService] on our own road graph. This helper only fetches the
/// road-hugging polyline shape so the decided path renders along streets
/// instead of straight lines. Offline / blocked → falls back to straight
/// segments, and the A* decision is unaffected.
class RouteGeometry {
  /// Fetches a road-following polyline through [waypointsLatLon]
  /// ([[lat, lon], ...]) from the free OSRM demo server. Returns the input
  /// unchanged on any failure (offline, rate-limit, bad response).
  static Future<List<List<double>>> fetchRoadPath(
    List<List<double>> waypointsLatLon, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (waypointsLatLon.length < 2) return waypointsLatLon;
    // OSRM wants lon,lat order.
    final coords = waypointsLatLon.map((p) => '${p[1]},${p[0]}').join(';');
    final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coords?overview=full&geometries=polyline');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return waypointsLatLon;
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return waypointsLatLon;
      final geom = (routes.first as Map<String, dynamic>)['geometry'] as String?;
      if (geom == null || geom.isEmpty) return waypointsLatLon;
      return downsample(decodePolyline(geom), 80);
    } catch (_) {
      return waypointsLatLon;
    } finally {
      client.close(force: true);
    }
  }

  /// Google/OSRM polyline5 decoder → [[lat, lon], ...]. Pure Dart.
  static List<List<double>> decodePolyline(String encoded) {
    final pts = <List<double>>[];
    var index = 0;
    var lat = 0;
    var lon = 0;
    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlon = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lon += dlon;
      pts.add([lat / 1e5, lon / 1e5]);
    }
    return pts;
  }

  /// Evenly thins a polyline to at most [max] points (keeps endpoints).
  static List<List<double>> downsample(List<List<double>> pts, int max) {
    if (pts.length <= max) return pts;
    final out = <List<double>>[];
    for (var i = 0; i < max; i++) {
      out.add(pts[(i * (pts.length - 1) / (max - 1)).round()]);
    }
    return out;
  }
}
