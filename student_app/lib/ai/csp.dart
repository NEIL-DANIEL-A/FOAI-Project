/// A bus available for assignment in the current operating slot.
class CspBus {
  final String id;
  final String label;
  final int capacity;
  final bool available;
  const CspBus({required this.id, required this.label, required this.capacity, this.available = true});
}

/// One CSP variable: a route stop needing a bus, with EXPECTED demand
/// (forecast — see DemandEstimationService, never the actual headcount).
class CspStop {
  final String id;
  final String label;
  final double demand;
  final int sequence;
  const CspStop({required this.id, required this.label, required this.demand, required this.sequence});
}

/// One observable event of the backtracking search. [partial] maps
/// stopId -> busId for assignments made so far; [loads] maps busId ->
/// current assigned demand. The simulation replays these; the live app
/// ignores them and uses [CspResult.best].
class CspStep {
  final int index;
  final String kind; // 'try','valid','violation','backtrack','solution','done','nosolution'
  final String stopId;
  final String stopLabel;
  final String? busId;
  final String? busLabel;
  final double demand;
  final double load;
  final double capacity;
  final String reason;
  final Map<String, String> partial;
  final Map<String, double> loads;

  const CspStep({
    required this.index,
    required this.kind,
    required this.stopId,
    required this.stopLabel,
    this.busId,
    this.busLabel,
    required this.demand,
    required this.load,
    required this.capacity,
    this.reason = '',
    this.partial = const {},
    this.loads = const {},
  });
}

/// One complete feasible assignment with its explainable score.
class CspSolution {
  final Map<String, String> assignment; // stopId -> busId
  final Map<String, double> loads; // busId -> assigned demand
  final int busesUsed;
  final double maxUtilization;
  final double score; // lower is better
  const CspSolution({
    required this.assignment,
    required this.loads,
    required this.busesUsed,
    required this.maxUtilization,
    required this.score,
  });
}

/// Full outcome of the search.
class CspResult {
  final bool feasible;
  final List<CspSolution> solutions;
  final CspSolution? best;
  final int assignmentsTried;
  final int backtracks;
  final List<CspStep> trace;
  const CspResult({
    required this.feasible,
    required this.solutions,
    required this.best,
    required this.assignmentsTried,
    required this.backtracks,
    required this.trace,
  });
}

/// Genuine CSP + recursive backtracking for stop-to-bus allocation.
///
/// Variables: each route stop. Domains: buses scheduled for the slot.
/// Constraints enforced during search:
///  1. availability — only [CspBus.available] buses are in any domain;
///  2. capacity — a bus's assigned EXPECTED demand must stay <= capacity;
///  3. route — callers only pass stops/buses of one route/slot;
///  4. coverage — a solution must assign every stop;
///  5. direction — preserved by serving stops in [sequence] order downstream;
///  6. no transfers — one bus takes the student stop -> college.
///
/// Heuristics: MRV (stop with fewest currently-feasible buses first),
/// buses tried least-loaded-first (drives toward balanced solutions).
/// Up to [maxSolutions] feasible assignments are collected and scored by
/// [scoreSolution]; the best is returned. Live callers pass
/// recordTrace=false; the simulation replays [trace] with the SAME code.
class CspAssignmentService {
  final int maxSolutions;

  const CspAssignmentService({this.maxSolutions = 200});

  /// Explainable score (lower wins):
  /// busesUsed (fleet economy) + worst-bus utilization (avoid overload)
  /// + spread of utilization (prefer balanced, e.g. 25/40+17/30 over 38/40+4/30).
  static double scoreSolution(Map<String, double> loads, Map<String, CspBus> buses) {
    final used = loads.entries.where((e) => e.value > 0).toList();
    if (used.isEmpty) return double.infinity;
    final utils = used.map((e) => e.value / buses[e.key]!.capacity).toList();
    final maxU = utils.reduce((a, b) => a > b ? a : b);
    final mean = utils.reduce((a, b) => a + b) / utils.length;
    var variance = 0.0;
    for (final u in utils) {
      variance += (u - mean) * (u - mean);
    }
    variance /= utils.length;
    return used.length + maxU + 0.5 * variance;
  }

  CspResult solve({
    required List<CspStop> stops,
    required List<CspBus> buses,
    bool recordTrace = true,
  }) {
    final trace = <CspStep>[];
    final solutions = <CspSolution>[];
    final pool = buses.where((b) => b.available).toList();
    final busById = {for (final b in pool) b.id: b};
    var tried = 0;
    var backtracks = 0;

    final assignment = <String, String>{};
    final loads = <String, double>{for (final b in pool) b.id: 0.0};

    void snap(
      String kind,
      CspStop stop,
      CspBus? bus,
      double load,
      double cap, [
      String reason = '',
    ]) {
      if (!recordTrace) return;
      trace.add(CspStep(
        index: trace.length,
        kind: kind,
        stopId: stop.id,
        stopLabel: stop.label,
        busId: bus?.id,
        busLabel: bus?.label,
        demand: stop.demand,
        load: load,
        capacity: cap,
        reason: reason,
        partial: Map.of(assignment),
        loads: Map.of(loads),
      ));
    }

    // MRV: unassigned stop with fewest capacity-feasible buses; ties by route order.
    CspStop? selectUnassigned() {
      CspStop? bestStop;
      var bestOptions = 1 << 30;
      for (final s in stops) {
        if (assignment.containsKey(s.id)) continue;
        var options = 0;
        for (final b in pool) {
          if (loads[b.id]! + s.demand <= b.capacity) options++;
        }
        if (options < bestOptions ||
            (options == bestOptions &&
                (bestStop == null || s.sequence < bestStop.sequence))) {
          bestOptions = options;
          bestStop = s;
        }
      }
      return bestStop;
    }

    List<CspBus> orderBuses(CspStop stop) {
      final feasible = pool.where((b) => loads[b.id]! + stop.demand <= b.capacity).toList();
      // Least-loaded first: steers toward balanced solutions early.
      feasible.sort((a, b) => loads[a.id]!.compareTo(loads[b.id]!));
      final infeasible = pool.where((b) => loads[b.id]! + stop.demand > b.capacity).toList();
      return [...feasible, ...infeasible];
    }

    final emptyStop = const CspStop(id: '', label: '', demand: 0, sequence: 0);

    bool backtrack() {
      if (solutions.length >= maxSolutions) return true; // stop everything
      final stop = selectUnassigned();
      if (stop == null) {
        // Coverage complete: every stop assigned -> feasible solution.
        final solLoads = Map<String, double>.of(loads);
        final used = solLoads.values.where((l) => l > 0).length;
        final utils = solLoads.entries
            .where((e) => e.value > 0)
            .map((e) => e.value / busById[e.key]!.capacity)
            .toList();
        final maxU = utils.reduce((a, b) => a > b ? a : b);
        solutions.add(CspSolution(
          assignment: Map.of(assignment),
          loads: solLoads,
          busesUsed: used,
          maxUtilization: maxU,
          score: scoreSolution(solLoads, busById),
        ));
        snap('solution', emptyStop, null, 0, 0, 'all ${stops.length} stops covered');
        return solutions.length >= maxSolutions;
      }
      for (final bus in orderBuses(stop)) {
        tried++;
        final newLoad = loads[bus.id]! + stop.demand;
        snap('try', stop, bus, newLoad, bus.capacity.toDouble(),
            '${stop.label} (${stop.demand}) -> ${bus.label} would load ${newLoad.toStringAsFixed(1)}/${bus.capacity}');
        if (newLoad > bus.capacity) {
          // Constraint 2 violated: capacity. Reject, do not recurse.
          snap('violation', stop, bus, newLoad, bus.capacity.toDouble(),
              'CAPACITY: ${newLoad.toStringAsFixed(1)} exceeds ${bus.capacity}');
          continue;
        }
        // Tentatively assign and recurse (direction preserved downstream
        // because each bus serves its stops in route-sequence order).
        assignment[stop.id] = bus.id;
        loads[bus.id] = newLoad;
        snap('valid', stop, bus, newLoad, bus.capacity.toDouble(), 'constraints hold, recursing');
        final stopAll = backtrack();
        // Undo (BACKTRACK) and try the next bus.
        assignment.remove(stop.id);
        loads[bus.id] = loads[bus.id]! - stop.demand;
        backtracks++;
        snap('backtrack', stop, bus, loads[bus.id]!, bus.capacity.toDouble(),
            'undo ${stop.label} -> ${bus.label}, load back to ${loads[bus.id]!.toStringAsFixed(1)}');
        if (stopAll) return true;
      }
      return false;
    }

    if (pool.isEmpty || stops.isEmpty) {
      snap('nosolution', emptyStop, null, 0, 0, pool.isEmpty ? 'no available buses in slot' : 'no stops');
    } else {
      backtrack();
    }

    solutions.sort((a, b) => a.score.compareTo(b.score));
    final best = solutions.isEmpty ? null : solutions.first;
    if (recordTrace) {
      trace.add(CspStep(
        index: trace.length,
        kind: best == null ? 'nosolution' : 'done',
        stopId: '',
        stopLabel: best == null ? 'No feasible allocation' : 'Best of ${solutions.length} solution(s)',
        demand: 0,
        load: 0,
        capacity: 0,
        reason: best == null
            ? 'search exhausted: demand cannot fit available capacity'
            : 'score ${best.score.toStringAsFixed(3)} (${best.busesUsed} bus(es), worst load ${(best.maxUtilization * 100).toStringAsFixed(0)}%)',
        partial: best == null ? const {} : Map.of(best.assignment),
        loads: best == null ? const {} : Map.of(best.loads),
      ));
    }
    return CspResult(
      feasible: best != null,
      solutions: solutions,
      best: best,
      assignmentsTried: tried,
      backtracks: backtracks,
      trace: trace,
    );
  }
}
