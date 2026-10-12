import 'road_graph.dart';

/// One observable event of the search, used by the visual simulation to
/// replay the algorithm step by step. [openIds]/[closedIds] are snapshots
/// taken at the moment the event fired.
class AstarStep {
  final int index;
  final String kind; // 'pop', 'neighbor', 'better', 'skip', 'done', 'nopath'
  final String nodeId;
  final double g;
  final double h;
  final double f;
  final String? via;
  final List<String> openIds;
  final List<String> closedIds;
  final String note;

  const AstarStep({
    required this.index,
    required this.kind,
    required this.nodeId,
    required this.g,
    required this.h,
    required this.f,
    this.via,
    this.openIds = const [],
    this.closedIds = const [],
    this.note = '',
  });
}

/// Result of an A* search: the optimal path plus the full execution trace.
/// The live apps use [path]/[cost]; the simulation replays [trace].
/// Same [AStarService], same code path, different consumers.
class AstarResult {
  final bool found;
  final List<String> path;
  final double cost;
  final int nodesExpanded;
  final int relaxations;
  final List<AstarStep> trace;
  final Map<String, double> gScores;
  final Map<String, double> hScores;
  final Map<String, double> fScores;

  const AstarResult({
    required this.found,
    required this.path,
    required this.cost,
    required this.nodesExpanded,
    required this.relaxations,
    required this.trace,
    required this.gScores,
    required this.hScores,
    required this.fScores,
  });
}

/// Genuine A* implementation: f(n) = g(n) + h(n).
///
/// * g(n): cheapest known travel-time from start to n (edge costs).
/// * h(n): haversine straight-line time from n to goal at [maxSpeedMps]
///   (admissible: never overestimates, so the path is optimal).
/// * open set: frontier ordered by lowest f; closed set: settled nodes.
/// * [cameFrom] map enables path reconstruction.
///
/// Set [recordTrace] false in production loops for zero overhead; the
/// simulation keeps it true and animates [AstarResult.trace].
class AStarService {
  final double maxSpeedMps;

  const AStarService({this.maxSpeedMps = 15.0});

  double _heuristic(RoadGraph graph, String nodeId, RoadNode goal) {
    final n = graph.nodes[nodeId]!;
    return RoadGraph.haversineM(n.lat, n.lon, goal.lat, goal.lon) / maxSpeedMps;
  }

  AstarResult findPath(
    RoadGraph graph,
    String startId,
    String goalId, {
    bool recordTrace = true,
  }) {
    final trace = <AstarStep>[];
    final g = <String, double>{};
    final h = <String, double>{};
    final f = <String, double>{};
    final cameFrom = <String, String?>{};
    final open = <String>[];
    final closed = <String>{};
    var expanded = 0;
    var relaxations = 0;

    void snap(String kind, String node, {String? via, String note = ''}) {
      if (!recordTrace) return;
      trace.add(AstarStep(
        index: trace.length,
        kind: kind,
        nodeId: node,
        g: g[node] ?? double.infinity,
        h: h[node] ?? double.infinity,
        f: f[node] ?? double.infinity,
        via: via,
        openIds: List.of(open),
        closedIds: List.of(closed),
        note: note,
      ));
    }

    if (!graph.nodes.containsKey(startId) || !graph.nodes.containsKey(goalId)) {
      snap('nopath', startId, note: 'start or goal missing from graph');
      return AstarResult(
        found: false, path: const [], cost: double.infinity,
        nodesExpanded: 0, relaxations: 0, trace: trace,
        gScores: g, hScores: h, fScores: f,
      );
    }

    final goal = graph.nodes[goalId]!;
    g[startId] = 0;
    h[startId] = startId == goalId ? 0 : _heuristic(graph, startId, goal);
    f[startId] = h[startId]!;
    cameFrom[startId] = null;
    open.add(startId);

    String popLowestF() {
      var best = 0;
      for (var i = 1; i < open.length; i++) {
        if ((f[open[i]] ?? double.infinity) < (f[open[best]] ?? double.infinity)) {
          best = i;
        }
      }
      return open.removeAt(best);
    }

    while (open.isNotEmpty) {
      final current = popLowestF();
      expanded++;
      snap('pop', current, via: cameFrom[current], note: 'expand lowest-f node');

      if (current == goalId) {
        // Reconstruct via cameFrom chain.
        final path = <String>[current];
        var c = cameFrom[current];
        while (c != null) {
          path.insert(0, c);
          c = cameFrom[c];
        }
        snap('done', current, note: 'goal reached, optimal cost ${g[current]!.toStringAsFixed(1)}s');
        return AstarResult(
          found: true, path: path, cost: g[current]!,
          nodesExpanded: expanded, relaxations: relaxations, trace: trace,
          gScores: g, hScores: h, fScores: f,
        );
      }

      closed.add(current);
      for (final edge in graph.neighbors(current)) {
        final nb = edge.to;
        if (closed.contains(nb)) {
          snap('skip', nb, via: current, note: 'already settled');
          continue;
        }
        relaxations++;
        final tentativeG = g[current]! + edge.cost;
        h.putIfAbsent(nb, () => _heuristic(graph, nb, goal));
        if (!open.contains(nb)) {
          g[nb] = tentativeG;
          f[nb] = tentativeG + h[nb]!;
          cameFrom[nb] = current;
          open.add(nb);
          snap('neighbor', nb, via: current, note: 'discovered via $current');
        } else if (tentativeG < (g[nb] ?? double.infinity)) {
          g[nb] = tentativeG;
          f[nb] = tentativeG + h[nb]!;
          cameFrom[nb] = current;
          snap('better', nb, via: current, note: 'cheaper route via $current');
        } else {
          snap('skip', nb, via: current, note: 'no improvement');
        }
      }
    }

    snap('nopath', goalId, note: 'open set exhausted, goal unreachable');
    return AstarResult(
      found: false, path: const [], cost: double.infinity,
      nodesExpanded: expanded, relaxations: relaxations, trace: trace,
      gScores: g, hScores: h, fScores: f,
    );
  }
}
