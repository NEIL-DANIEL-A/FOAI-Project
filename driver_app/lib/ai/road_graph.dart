import 'dart:math' as math;

/// Minimal stop view used to build a road graph. The apps map their own
/// StopInfo models onto this so the AI core stays dependency-free.
class GraphStop {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final int sequence;
  const GraphStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.sequence,
  });
}

/// A road-network node: an intersection / stop with a geographic position.
class RoadNode {
  final String id;
  final String label;
  final double lat;
  final double lon;
  const RoadNode({
    required this.id,
    required this.label,
    required this.lat,
    required this.lon,
  });
}

/// A directed road segment. [cost] is travel time in seconds; [blocked]
/// marks closures (accidents, diversions) that A* must route around.
class RoadEdge {
  final String id;
  final String from;
  final String to;
  final double cost;
  final double distanceM;
  bool blocked;
  RoadEdge({
    required this.id,
    required this.from,
    required this.to,
    required this.cost,
    required this.distanceM,
    this.blocked = false,
  });
}

/// Road graph shared by the live apps and the visual simulation.
/// The SAME [AStarService] runs on whatever graph instance it is given:
/// a stop-chain graph in production, a textbook graph in the demo.
class RoadGraph {
  final Map<String, RoadNode> nodes = {};
  final Map<String, List<RoadEdge>> _adj = {};

  RoadGraph();

  /// Read-only adjacency for renderers (the simulation canvas).
  Map<String, List<RoadEdge>> get adjacency => _adj;

  void addNode(RoadNode node) {
    nodes[node.id] = node;
    _adj.putIfAbsent(node.id, () => []);
  }

  /// Adds an undirected road (both directions) between two nodes.
  void addUndirectedEdge({
    required String id,
    required String a,
    required String b,
    required double cost,
    required double distanceM,
    bool blocked = false,
  }) {
    _adj.putIfAbsent(a, () => []);
    _adj.putIfAbsent(b, () => []);
    _adj[a]!.add(RoadEdge(id: '$id:fwd', from: a, to: b, cost: cost, distanceM: distanceM, blocked: blocked));
    _adj[b]!.add(RoadEdge(id: '$id:rev', from: b, to: a, cost: cost, distanceM: distanceM, blocked: blocked));
  }

  void setBlocked(String edgeIdPrefix, bool blocked) {
    for (final edges in _adj.values) {
      for (final e in edges) {
        if (e.id == edgeIdPrefix || e.id.startsWith('$edgeIdPrefix:')) {
          e.blocked = blocked;
        }
      }
    }
  }

  /// Traversable outgoing edges (blocked segments excluded).
  List<RoadEdge> neighbors(String id) {
    return _adj[id]?.where((e) => !e.blocked && nodes.containsKey(e.to)).toList() ?? [];
  }

  /// Builds a road graph from ordered route stops: chain edges between
  /// consecutive stops plus skip-one edges (direct road that bypasses the
  /// intermediate stop) so A* has a genuine routing choice.
  /// [speedMps] converts distance to travel-time cost.
  factory RoadGraph.fromStops(List<GraphStop> stops, {double speedMps = 8.0}) {
    final g = RoadGraph();
    final ordered = List<GraphStop>.of(stops)
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    for (final s in ordered) {
      g.addNode(RoadNode(id: 'stop:${s.id}', label: s.name, lat: s.lat, lon: s.lon));
    }
    for (var i = 0; i < ordered.length - 1; i++) {
      final a = ordered[i];
      final b = ordered[i + 1];
      final dM = haversineM(a.lat, a.lon, b.lat, b.lon);
      g.addUndirectedEdge(
        id: 'chain:$i',
        a: 'stop:${a.id}',
        b: 'stop:${b.id}',
        cost: dM / speedMps,
        distanceM: dM,
      );
      if (i + 2 < ordered.length) {
        final c = ordered[i + 2];
        final dSkip = haversineM(a.lat, a.lon, c.lat, c.lon);
        g.addUndirectedEdge(
          id: 'skip:$i',
          a: 'stop:${a.id}',
          b: 'stop:${c.id}',
          cost: dSkip / speedMps,
          distanceM: dSkip,
        );
      }
    }
    return g;
  }

  /// Textbook demo graph used by the visual A* simulation (spec section 17).
  /// Coordinates are schematic (for the canvas painter), costs are seconds.
  factory RoadGraph.textbook() {
    final g = RoadGraph();
    const coords = {
      'A': [0.0, 2.0],
      'B': [1.0, 2.0],
      'C': [2.0, 2.0],
      'D': [1.5, 1.0],
      'E': [2.5, 1.0],
      'F': [0.0, 0.0],
      'G': [1.5, 0.0],
      'Goal': [2.5, 0.0],
    };
    coords.forEach((id, p) {
      g.addNode(RoadNode(id: id, label: id, lat: p[1], lon: p[0]));
    });
    void link(String a, String b, double cost, double dist) {
      g.addUndirectedEdge(id: '$a-$b', a: a, b: b, cost: cost, distanceM: dist);
    }

    link('A', 'B', 10, 1000);
    link('B', 'C', 10, 1000);
    link('B', 'D', 9, 900);
    link('C', 'E', 12, 1200);
    link('C', 'Goal', 30, 3000);
    link('D', 'E', 4, 400);
    link('D', 'G', 9, 900);
    link('A', 'F', 8, 800);
    link('F', 'G', 8, 800);
    link('G', 'Goal', 8, 800);
    link('E', 'Goal', 10, 1000);
    return g;
  }

  /// Straight-line distance in metres (haversine). Used for edge costs and
  /// as the admissible A* heuristic (divided by max plausible speed).
  static double haversineM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180.0;
    final dLat = rad(lat2 - lat1);
    final dLon = rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }
}
