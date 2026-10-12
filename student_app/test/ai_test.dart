import 'package:flutter_test/flutter_test.dart';
import 'package:student_app/ai/astar.dart';
import 'package:student_app/ai/csp.dart';
import 'package:student_app/ai/demand.dart';
import 'package:student_app/ai/road_graph.dart';
import 'package:student_app/ai/route_geometry.dart';

void main() {
  group('AStarService (textbook graph)', () {
    test('finds optimal path A -> Goal', () {
      final g = RoadGraph.textbook();
      final r = const AStarService().findPath(g, 'A', 'Goal');
      expect(r.found, isTrue);
      // A-F-G-Goal = 8+8+8 = 24 is optimal (A-B-D-E-Goal = 33, A-B-C-E-Goal = 42).
      expect(r.path, ['A', 'F', 'G', 'Goal']);
      expect(r.cost, 24);
      expect(r.nodesExpanded, lessThan(8));
      expect(r.trace.isNotEmpty, isTrue);
      expect(r.trace.last.kind, 'done');
    });

    test('reroutes around a blocked edge', () {
      final g = RoadGraph.textbook();
      g.setBlocked('F-G', true);
      final r = const AStarService().findPath(g, 'A', 'Goal');
      expect(r.found, isTrue);
      expect(r.path, isNot(contains('F')));
      // Next best: A-B-D-E-Goal = 10+9+4+10 = 33.
      expect(r.path, ['A', 'B', 'D', 'E', 'Goal']);
      expect(r.cost, 33);
    });

    test('reports unreachable goal', () {
      final g = RoadGraph.textbook();
      g.setBlocked('F-G', true);
      g.setBlocked('D-G', true);
      g.setBlocked('E-Goal', true);
      g.setBlocked('C-Goal', true);
      g.setBlocked('G-Goal', true);
      final r = const AStarService().findPath(g, 'A', 'Goal');
      expect(r.found, isFalse);
      expect(r.trace.last.kind, 'nopath');
    });
  });

  group('CspAssignmentService', () {
    List<CspStop> stops(List<double> demands) => [
          for (var i = 0; i < demands.length; i++)
            CspStop(id: 'S${i + 1}', label: 'S${i + 1}', demand: demands[i], sequence: i + 1),
        ];

    test('normal scenario: feasible, balanced best', () {
      final r = const CspAssignmentService().solve(
        stops: stops([10, 8, 15, 5, 12]),
        buses: const [CspBus(id: 'b1', label: '101', capacity: 40), CspBus(id: 'b2', label: '102', capacity: 30)],
      );
      expect(r.feasible, isTrue);
      expect(r.best, isNotNull);
      expect(r.best!.assignment.length, 5);
      // Every bus load within capacity.
      r.best!.loads.forEach((id, load) {
        final cap = id == 'b1' ? 40 : 30;
        expect(load, lessThanOrEqualTo(cap));
      });
      expect(r.trace.any((s) => s.kind == 'done'), isTrue);
    });

    test('tight capacity forces visible backtracking', () {
      final r = const CspAssignmentService().solve(
        stops: stops([20, 20, 20]),
        buses: const [CspBus(id: 'b1', label: '101', capacity: 40), CspBus(id: 'b2', label: '102', capacity: 30)],
      );
      expect(r.feasible, isTrue);
      expect(r.backtracks, greaterThan(0));
      expect(r.trace.any((s) => s.kind == 'backtrack'), isTrue);
      expect(r.trace.any((s) => s.kind == 'violation'), isTrue);
    });

    test('infeasible demand reports no solution', () {
      final r = const CspAssignmentService().solve(
        stops: stops([30, 30, 30]),
        buses: const [CspBus(id: 'b1', label: '101', capacity: 40)],
      );
      expect(r.feasible, isFalse);
      expect(r.best, isNull);
      expect(r.trace.last.kind, 'nosolution');
    });

    test('unavailable buses are excluded', () {
      final r = const CspAssignmentService().solve(
        stops: stops([10, 8]),
        buses: const [
          CspBus(id: 'b1', label: '101', capacity: 40, available: false),
          CspBus(id: 'b2', label: '102', capacity: 30),
        ],
      );
      expect(r.feasible, isTrue);
      expect(r.best!.assignment.values.toSet(), {'b2'});
    });
  });

  group('DemandEstimationService', () {
    test('averages history with safety factor', () {
      final now = DateTime.now();
      final est = DemandEstimationService.estimate({
        's1': [BoardingSample(stopId: 's1', count: 10, date: now), BoardingSample(stopId: 's1', count: 10, date: now)],
      }, safetyFactor: 1.1);
      expect(est['s1']!.expected, closeTo(11.0, 0.001));
      expect(est['s1']!.samples, 2);
    });

    test('empty history falls back', () {
      final est = DemandEstimationService.estimate({'s9': []});
      expect(est['s9']!.expected, 5.0);
      expect(est['s9']!.samples, 0);
    });
  });

  group('RouteGeometry (drawing helper, not routing)', () {
    test('decodes Google polyline example', () {
      // Canonical example from the polyline algorithm specification.
      const encoded = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
      final pts = RouteGeometry.decodePolyline(encoded);
      expect(pts.length, 3);
      expect(pts[0][0], closeTo(38.5, 1e-4));
      expect(pts[0][1], closeTo(-120.2, 1e-4));
      expect(pts[1][0], closeTo(40.7, 1e-4));
      expect(pts[1][1], closeTo(-120.95, 1e-4));
      expect(pts[2][0], closeTo(43.252, 1e-4));
      expect(pts[2][1], closeTo(-126.453, 1e-4));
    });

    test('downsample keeps endpoints', () {
      final pts = [
        for (var i = 0; i < 200; i++) [i.toDouble(), i.toDouble()]
      ];
      final thin = RouteGeometry.downsample(pts, 80);
      expect(thin.length, 80);
      expect(thin.first, [0.0, 0.0]);
      expect(thin.last, [199.0, 199.0]);
    });
  });
}
