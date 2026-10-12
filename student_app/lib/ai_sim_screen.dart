import 'dart:async';
import 'package:flutter/material.dart';
import 'ai/astar.dart';
import 'ai/csp.dart';
import 'ai/road_graph.dart';

/// AI Algorithm Simulation: step-by-step visual replay of the SAME
/// [CspAssignmentService] and [AStarService] the live apps call.
/// Nothing here is a fake animation: each tab runs the real service with
/// recordTrace=true and animates the recorded trace.
class AiSimScreen extends StatefulWidget {
  const AiSimScreen({super.key});

  @override
  State<AiSimScreen> createState() => _AiSimScreenState();
}

class _CspPreset {
  final String id;
  final String title;
  final String desc;
  final List<double> demands;
  final List<CspBus> buses;
  const _CspPreset({
    required this.id,
    required this.title,
    required this.desc,
    required this.demands,
    required this.buses,
  });
}

const _cspPresets = [
  _CspPreset(
    id: 's1',
    title: 'S1 · Normal',
    desc: '5 stops, 2 buses, comfortable capacity. Expect a valid plan with ~0 backtracks.',
    demands: [10, 8, 15, 5, 12],
    buses: [CspBus(id: 'b101', label: '101', capacity: 40), CspBus(id: 'b102', label: '102', capacity: 30)],
  ),
  _CspPreset(
    id: 's2',
    title: 'S2 · Tight capacity',
    desc: 'Demands barely fit. Watch VALID choices collapse into VIOLATION + BACKTRACK.',
    demands: [20, 20, 20],
    buses: [CspBus(id: 'b101', label: '101', capacity: 40), CspBus(id: 'b102', label: '102', capacity: 30)],
  ),
  _CspPreset(
    id: 's3',
    title: 'S3 · Bus unavailable',
    desc: 'Bus 103 is scheduled but unavailable: CSP must exclude it entirely.',
    demands: [10, 8, 15, 5, 12],
    buses: [
      CspBus(id: 'b101', label: '101', capacity: 40),
      CspBus(id: 'b102', label: '102', capacity: 30),
      CspBus(id: 'b103', label: '103', capacity: 35, available: false),
    ],
  ),
  _CspPreset(
    id: 's4',
    title: 'S4 · Demand spike',
    desc: 'S2 and S5 surge. The best allocation differs from S1.',
    demands: [10, 18, 15, 5, 19],
    buses: [CspBus(id: 'b101', label: '101', capacity: 40), CspBus(id: 'b102', label: '102', capacity: 30)],
  ),
  _CspPreset(
    id: 's0',
    title: 'S0 · Infeasible',
    desc: 'Demand (90) exceeds all capacity (40). The search exhausts and proves NO solution.',
    demands: [30, 30, 30],
    buses: [CspBus(id: 'b101', label: '101', capacity: 40)],
  ),
];

class _Phase {
  final String title;
  final String detail;
  const _Phase(this.title, this.detail);
}

class _AiSimScreenState extends State<AiSimScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;

  // ---------- CSP player state ----------
  String _cspScenarioId = 's1';
  CspResult? _cspResult;
  List<CspStop> _cspStops = [];
  int _cspIndex = 0;
  Timer? _cspTimer;
  bool _cspPlaying = false;

  // ---------- A* player state ----------
  String _astarStart = 'A';
  String _astarGoal = 'Goal';
  final Set<String> _blockedPairs = {};
  AstarResult? _astarResult;
  int _astarIndex = 0;
  Timer? _astarTimer;
  bool _astarPlaying = false;
  String? _astarCompare;

  // ---------- Combined pipeline state ----------
  List<_Phase> _comboPhases = [];
  int _comboIndex = 0;
  Timer? _comboTimer;
  bool _comboPlaying = false;
  RoadGraph? _comboGraph;
  List<String> _comboBusTrail = [];
  String? _comboBlockedPair;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _runCsp();
    _runAstar();
    _buildCombined();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _cspTimer?.cancel();
    _astarTimer?.cancel();
    _comboTimer?.cancel();
    super.dispose();
  }

  // ================= CSP =================

  _CspPreset get _cspPreset => _cspPresets.firstWhere((p) => p.id == _cspScenarioId);

  void _runCsp() {
    _cspTimer?.cancel();
    final preset = _cspPreset;
    _cspStops = [
      for (var i = 0; i < preset.demands.length; i++)
        CspStop(id: 'S${i + 1}', label: 'S${i + 1}', demand: preset.demands[i], sequence: i + 1),
    ];
    final result = const CspAssignmentService().solve(stops: _cspStops, buses: preset.buses);
    setState(() {
      _cspResult = result;
      _cspIndex = 0;
      _cspPlaying = false;
    });
  }

  void _cspGoto(int i) {
    final n = _cspResult?.trace.length ?? 0;
    if (n == 0) return;
    setState(() => _cspIndex = i.clamp(0, n - 1));
  }

  void _cspTogglePlay() {
    if (_cspPlaying) {
      _cspTimer?.cancel();
      setState(() => _cspPlaying = false);
      return;
    }
    final n = _cspResult?.trace.length ?? 0;
    if (_cspIndex >= n - 1) _cspIndex = 0;
    setState(() => _cspPlaying = true);
    _cspTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (_cspIndex >= n - 1) {
        _cspTimer?.cancel();
        setState(() => _cspPlaying = false);
      } else {
        setState(() => _cspIndex++);
      }
    });
  }

  Color _busColor(String? busId) {
    if (busId == 'b101') return const Color(0xFF6366F1);
    if (busId == 'b102') return const Color(0xFF22C55E);
    if (busId == 'b103') return const Color(0xFFF59E0B);
    return const Color(0xFF64748B);
  }

  Color _stepColor(String kind) {
    switch (kind) {
      case 'valid':
      case 'done':
      case 'solution':
        return const Color(0xFF22C55E);
      case 'violation':
      case 'nosolution':
        return const Color(0xFFEF4444);
      case 'backtrack':
        return const Color(0xFFF59E0B);
      default:
        return const Color(0xFF6366F1);
    }
  }

  String _stepLabel(String kind) {
    switch (kind) {
      case 'try':
        return 'TRY';
      case 'valid':
        return 'VALID';
      case 'violation':
        return 'VIOLATION';
      case 'backtrack':
        return 'BACKTRACK';
      case 'solution':
        return 'SOLUTION';
      case 'done':
        return 'BEST';
      case 'nosolution':
        return 'NO SOLUTION';
      default:
        return kind.toUpperCase();
    }
  }

  Widget _playerControls({
    required VoidCallback onReset,
    required VoidCallback onPrev,
    required VoidCallback onPlayPause,
    required VoidCallback onNext,
    required VoidCallback onRunAll,
    required bool playing,
    required String position,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(onPressed: onReset, icon: const Icon(Icons.restart_alt), tooltip: 'Reset'),
            IconButton.filledTonal(onPressed: onPrev, icon: const Icon(Icons.skip_previous), tooltip: 'Previous step'),
            IconButton.filled(
              onPressed: onPlayPause,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing ? 'Pause' : 'Play',
            ),
            IconButton.filledTonal(onPressed: onNext, icon: const Icon(Icons.skip_next), tooltip: 'Next step'),
            IconButton.filledTonal(onPressed: onRunAll, icon: const Icon(Icons.fast_forward), tooltip: 'Run all'),
          ],
        ),
        const SizedBox(height: 2),
        Text(position, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
      ],
    );
  }

  Widget _buildCspTab() {
    final result = _cspResult;
    final step = (result != null && result.trace.isNotEmpty) ? result.trace[_cspIndex] : null;
    final busById = {for (final b in _cspPreset.buses) b.id: b};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('CSP + Backtracking: which bus serves which stops?',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey(_cspScenarioId),
          initialValue: _cspScenarioId,
          dropdownColor: const Color(0xFF1E293B),
          decoration: const InputDecoration(
            labelText: 'Test scenario (§24)',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: _cspPresets
              .map((p) => DropdownMenuItem(value: p.id, child: Text(p.title, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => _cspScenarioId = v);
            _runCsp();
          },
        ),
        const SizedBox(height: 6),
        Text(_cspPreset.desc, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
        const SizedBox(height: 12),
        // Stop chips with live partial assignment.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _cspStops)
              Builder(builder: (_) {
                final assigned = step?.partial[s.id];
                final isCurrent = step != null && step.stopId == s.id && step.kind != 'done' && step.kind != 'nosolution';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: assigned != null
                        ? _busColor(assigned).withValues(alpha: 0.25)
                        : const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isCurrent ? const Color(0xFFF8FAFC) : const Color(0xFF334155),
                      width: isCurrent ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(s.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      Text('~${s.demand.toStringAsFixed(0)} riders',
                          style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                      Text(assigned == null ? '—' : '→ ${busById[assigned]?.label ?? assigned}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: assigned == null ? const Color(0xFF64748B) : _busColor(assigned))),
                    ],
                  ),
                );
              }),
          ],
        ),
        const SizedBox(height: 12),
        // Bus load cards.
        Row(
          children: [
            for (final b in _cspPreset.buses.where((x) => x.available))
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _busColor(b.id).withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bus ${b.label}',
                          style: TextStyle(fontWeight: FontWeight.bold, color: _busColor(b.id), fontSize: 13)),
                      const SizedBox(height: 4),
                      Builder(builder: (_) {
                        final load = step?.loads[b.id] ?? 0.0;
                        final over = load > b.capacity;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: (load / b.capacity).clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: const Color(0xFF334155),
                                color: over ? const Color(0xFFEF4444) : _busColor(b.id),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text('${load.toStringAsFixed(0)} / ${b.capacity}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: over ? const Color(0xFFEF4444) : const Color(0xFFF8FAFC))),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (_cspPreset.buses.any((b) => !b.available)) ...[
          const SizedBox(height: 6),
          Text('Excluded (unavailable): ${_cspPreset.buses.where((b) => !b.available).map((b) => b.label).join(', ')}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFF59E0B))),
        ],
        const SizedBox(height: 12),
        // Current step card.
        if (step != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _stepColor(step.kind).withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _stepColor(step.kind).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_stepLabel(step.kind),
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w800, color: _stepColor(step.kind))),
                    ),
                    const SizedBox(width: 8),
                    Text('STEP ${_cspIndex + 1} / ${result!.trace.length}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  ],
                ),
                const SizedBox(height: 6),
                if (step.stopId.isNotEmpty)
                  Text('Variable ${step.stopLabel} (demand ${step.demand.toStringAsFixed(0)})'
                      '${step.busLabel != null ? ' → trying Bus ${step.busLabel}' : ''}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                if (step.reason.isNotEmpty)
                  Text(step.reason, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (result != null)
          Wrap(
            spacing: 12,
            children: [
              _stat('Variables', '${_cspStops.length}'),
              _stat('Buses', '${_cspPreset.buses.where((b) => b.available).length}'),
              _stat('Tried', '${result.assignmentsTried}'),
              _stat('Backtracks', '${result.backtracks}'),
              _stat('Solutions', '${result.solutions.length}'),
              if (result.best != null) _stat('Best score', result.best!.score.toStringAsFixed(2)),
            ],
          ),
        if (result?.best != null) ...[
          const SizedBox(height: 8),
          Text(
            'Final: ${result!.best!.assignment.entries.map((e) => '${e.key}→${busById[e.value]?.label}').join('  ')}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF22C55E), fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 12),
        _playerControls(
          onReset: () => _cspGoto(0),
          onPrev: () => _cspGoto(_cspIndex - 1),
          onPlayPause: _cspTogglePlay,
          onNext: () => _cspGoto(_cspIndex + 1),
          onRunAll: () => _cspGoto((result?.trace.length ?? 1) - 1),
          playing: _cspPlaying,
          position: result == null ? '' : 'step ${_cspIndex + 1} of ${result.trace.length}',
        ),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
      ],
    );
  }

  // ================= A* =================

  void _runAstar() {
    _astarTimer?.cancel();
    final graph = _textbookWithBlocks();
    final result =
        const AStarService().findPath(graph, _astarStart, _astarGoal, recordTrace: true);
    setState(() {
      _astarResult = result;
      _astarIndex = 0;
      _astarPlaying = false;
    });
  }

  RoadGraph _textbookWithBlocks() {
    final graph = RoadGraph.textbook();
    for (final pair in _blockedPairs) {
      graph.setBlocked(pair, true);
    }
    return graph;
  }

  void _astarGoto(int i) {
    final n = _astarResult?.trace.length ?? 0;
    if (n == 0) return;
    setState(() => _astarIndex = i.clamp(0, n - 1));
  }

  void _astarTogglePlay() {
    if (_astarPlaying) {
      _astarTimer?.cancel();
      setState(() => _astarPlaying = false);
      return;
    }
    final n = _astarResult?.trace.length ?? 0;
    if (_astarIndex >= n - 1) _astarIndex = 0;
    setState(() => _astarPlaying = true);
    _astarTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (_astarIndex >= n - 1) {
        _astarTimer?.cancel();
        setState(() => _astarPlaying = false);
      } else {
        setState(() => _astarIndex++);
      }
    });
  }

  /// Stored edge-id prefix for the segment a–b in either direction.
  String? _storedEdgePrefix(RoadGraph g, String a, String b) {
    for (final e in [...g.adjacency[a] ?? [], ...g.adjacency[b] ?? []]) {
      if ((e.from == a && e.to == b) || (e.from == b && e.to == a)) {
        return e.id.split(':').first; // strip :fwd/:rev suffix
      }
    }
    return null;
  }

  void _simulateRoadblock() {
    // Genuine re-run: record the current (old) path, block an edge ON it,
    // re-run the SAME service, and compare.
    final before = _astarResult;
    if (before == null || !before.found || before.path.length < 2) return;
    final mid = before.path[before.path.length ~/ 2];
    final prev = before.path[before.path.indexOf(mid) - 1];
    final pair = _storedEdgePrefix(_textbookWithBlocks(), prev, mid) ?? '$prev-$mid';
    setState(() {
      _astarCompare =
          'OLD PATH: ${before.path.join(' → ')} (${before.cost.toStringAsFixed(0)}s). Blocked $prev–$mid…';
      _blockedPairs.add(pair);
    });
    _runAstar();
    final after = _astarResult;
    if (after != null && after.found) {
      final oldMsg = _astarCompare;
      setState(() {
        _astarCompare = '$oldMsg\nNEW PATH: ${after.path.join(' → ')} '
            '(${after.cost.toStringAsFixed(0)}s, ${after.nodesExpanded} nodes explored).';
      });
    } else {
      final oldMsg = _astarCompare;
      setState(() => _astarCompare = '$oldMsg\nNo alternative route exists.');
    }
  }

  Widget _buildAstarTab() {
    final result = _astarResult;
    final step = (result != null && result.trace.isNotEmpty) ? result.trace[_astarIndex] : null;
    const nodeIds = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'Goal'];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('A*: what road path should the bus take?',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('f(n) = g(n) + h(n): g = travel time so far, h = straight-line time to goal.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('start-$_astarStart'),
                initialValue: _astarStart,
                dropdownColor: const Color(0xFF1E293B),
                decoration: const InputDecoration(
                    labelText: 'Start', border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: nodeIds
                    .map((n) => DropdownMenuItem(value: n, child: Text(n, style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _astarStart = v;
                    _astarCompare = null;
                  });
                  _runAstar();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('goal-$_astarGoal'),
                initialValue: _astarGoal,
                dropdownColor: const Color(0xFF1E293B),
                decoration: const InputDecoration(
                    labelText: 'Goal', border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: nodeIds
                    .map((n) => DropdownMenuItem(value: n, child: Text(n, style: const TextStyle(fontSize: 13))))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _astarGoal = v;
                    _astarCompare = null;
                  });
                  _runAstar();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton.icon(
              onPressed: _simulateRoadblock,
              icon: const Icon(Icons.construction, size: 16),
              label: const Text('Simulate road block', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB45309)),
            ),
            OutlinedButton(
              onPressed: _blockedPairs.isEmpty
                  ? null
                  : () {
                      setState(() {
                        _blockedPairs.clear();
                        _astarCompare = null;
                      });
                      _runAstar();
                    },
              child: Text('Clear blocks (${_blockedPairs.length})', style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_astarCompare != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
            ),
            child: Text(_astarCompare!, style: const TextStyle(fontSize: 12)),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          height: 300,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: CustomPaint(
            painter: _GraphPainter(
              graph: _textbookWithBlocks(),
              openIds: step?.openIds.toSet() ?? {},
              closedIds: step?.closedIds.toSet() ?? {},
              currentId: step?.nodeId,
              path: (step?.kind == 'done' || _astarIndex == (result?.trace.length ?? 1) - 1)
                  ? (result?.path ?? [])
                  : const [],
              finalPath: result?.path ?? [],
              showFinalPath: step?.kind == 'done',
              startId: _astarStart,
              goalId: _astarGoal,
              busNode: null,
            ),
            child: Container(),
          ),
        ),
        const SizedBox(height: 8),
        if (step != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_stepLabel(step.kind),
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF6366F1))),
                    ),
                    const SizedBox(width: 8),
                    Text('STEP ${_astarIndex + 1} / ${result!.trace.length}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Current ${step.nodeId}: g=${_fmtScore(step.g)}  h=${_fmtScore(step.h)}  f=${_fmtScore(step.f)}'
                  '${step.via != null ? '  (via ${step.via})' : ''}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (step.note.isNotEmpty)
                  Text(step.note, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                if (step.openIds.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text('Open set (lowest f expands next):',
                      style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final id in _sortedOpen(result, step.openIds))
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: id == step.openIds.first ||
                                    (result.fScores[id] ?? double.infinity) ==
                                        _minF(result, step.openIds)
                                ? const Color(0xFF22C55E).withValues(alpha: 0.25)
                                : const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF475569)),
                          ),
                          child: Text('$id  f=${_fmtScore(result.fScores[id] ?? double.infinity)}',
                              style: const TextStyle(fontSize: 11)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (result != null)
          Wrap(
            spacing: 12,
            children: [
              _stat('Explored', '${result.nodesExpanded}'),
              _stat('Relaxations', '${result.relaxations}'),
              _stat('Path cost', result.found ? '${result.cost.toStringAsFixed(0)}s' : '—'),
              _stat('Path', result.found ? result.path.join('→') : 'unreachable'),
            ],
          ),
        const SizedBox(height: 12),
        _playerControls(
          onReset: () => _astarGoto(0),
          onPrev: () => _astarGoto(_astarIndex - 1),
          onPlayPause: _astarTogglePlay,
          onNext: () => _astarGoto(_astarIndex + 1),
          onRunAll: () => _astarGoto((result?.trace.length ?? 1) - 1),
          playing: _astarPlaying,
          position: result == null ? '' : 'step ${_astarIndex + 1} of ${result.trace.length}',
        ),
      ],
    );
  }

  String _fmtScore(double v) => v.isInfinite ? '∞' : v.toStringAsFixed(1);

  double _minF(AstarResult result, List<String> ids) {
    var m = double.infinity;
    for (final id in ids) {
      final v = result.fScores[id] ?? double.infinity;
      if (v < m) m = v;
    }
    return m;
  }

  List<String> _sortedOpen(AstarResult result, List<String> ids) {
    final copy = List<String>.of(ids);
    copy.sort((a, b) => (result.fScores[a] ?? double.infinity)
        .compareTo(result.fScores[b] ?? double.infinity));
    return copy;
  }

  // ================= Combined =================

  RoadGraph _combinedGraph() {
    // Mini road network for the end-to-end run: the 5 CSP stops + College,
    // linked by direct roads and slightly quicker junction bypasses.
    final g = RoadGraph();
    const pos = {
      'S1': [0.0, 1.0], 'J12': [0.7, 1.4], 'S2': [1.4, 1.0], 'J23': [2.1, 1.4],
      'S3': [2.8, 1.0], 'J34': [3.5, 1.4], 'S4': [4.2, 1.0], 'J45': [4.9, 1.4],
      'S5': [5.6, 1.0], 'J5C': [6.3, 1.4], 'College': [7.0, 1.0],
    };
    pos.forEach((id, p) {
      g.addNode(RoadNode(id: id, label: id, lat: p[1], lon: p[0]));
    });
    void link(String a, String b, double cost) {
      g.addUndirectedEdge(id: '$a-$b', a: a, b: b, cost: cost, distanceM: cost * 8);
    }

    for (final seq in [
      ['S1', 'J12', 'S2'],
      ['S2', 'J23', 'S3'],
      ['S3', 'J34', 'S4'],
      ['S4', 'J45', 'S5'],
      ['S5', 'J5C', 'College'],
    ]) {
      link(seq[0], seq[1], 4);
      link(seq[1], seq[2], 4);
      link(seq[0], seq[2], 10); // direct road (slower than the bypass)
    }
    return g;
  }

  void _buildCombined() {
    _comboTimer?.cancel();
    final phases = <_Phase>[];
    // Steps 1-4: slot, buses, demand, CSP.
    const demands = [10.0, 8.0, 15.0, 5.0, 12.0];
    const buses = [CspBus(id: 'b101', label: '101', capacity: 40), CspBus(id: 'b102', label: '102', capacity: 30)];
    phases.add(const _Phase('STEP 1 · Slot selected', 'Route R1 · 7:30 AM operating slot.'));
    phases.add(const _Phase('STEP 2 · Scheduled buses loaded', 'Bus 101 (40 seats), Bus 102 (30 seats) from slot_buses.'));
    phases.add(const _Phase('STEP 3 · Demand estimated',
        'S1=10 S2=8 S3=15 S4=5 S5=12 (recency-weighted history × 1.1 safety).'));
    final cspStops = [
      for (var i = 0; i < demands.length; i++)
        CspStop(id: 'S${i + 1}', label: 'S${i + 1}', demand: demands[i], sequence: i + 1),
    ];
    final csp = const CspAssignmentService().solve(stops: cspStops, buses: buses);
    if (!csp.feasible || csp.best == null) {
      phases.add(const _Phase('STEP 4 · CSP infeasible', 'No allocation fits. Demo stops here.'));
      setState(() {
        _comboPhases = phases;
        _comboIndex = 0;
        _comboPlaying = false;
        _comboGraph = _combinedGraph();
        _comboBusTrail = [];
      });
      return;
    }
    final best = csp.best!;
    final byBus = <String, List<String>>{};
    best.assignment.forEach((stop, bus) => byBus.putIfAbsent(bus, () => []).add(stop));
    phases.add(_Phase('STEP 4 · CSP solved',
        'Tried ${csp.assignmentsTried}, backtracks ${csp.backtracks}, score ${best.score.toStringAsFixed(2)}: '
        '${byBus.entries.map((e) => '${e.key == 'b101' ? 101 : 102}→${e.value.join(',')}').join('  ')}'));
    // Steps 5+: follow bus 101's legs (or whichever bus serves S1).
    final focusBus = best.assignment['S1'] ?? best.assignment.values.first;
    final legs = (byBus[focusBus] ?? []).toList()
      ..sort((a, b) => int.parse(a.substring(1)).compareTo(int.parse(b.substring(1))));
    legs.add('College');
    final graph = _combinedGraph();
    var from = legs.first;
    var fullTrail = <String>[from];
    var legNo = 0;
    for (var i = 1; i < legs.length; i++) {
      legNo++;
      final to = legs[i];
      phases.add(_Phase('STEP ${4 + legNo} · Bus ${focusBus == 'b101' ? 101 : 102} at $from, next $to',
          'Running A* $from → $to…'));
      var res = const AStarService().findPath(graph, from, to, recordTrace: false);
      if (!res.found) {
        phases.add(_Phase('A* failed', '$from → $to unreachable.Demo stops.'));
        break;
      }
      // Roadblock on the second leg: block the middle edge of the chosen path.
      if (legNo == 2 && res.path.length >= 3) {
        final a = res.path[1];
        final b = res.path[2];
        graph.setBlocked(_storedEdgePrefix(graph, a, b) ?? '$a-$b', true);
        _comboBlockedPair = '$a–$b';
        phases.add(_Phase('ROAD BLOCK DETECTED', 'Edge $a–$b closed. OLD PATH: ${res.path.join(' → ')}. Recalculating…'));
        res = const AStarService().findPath(graph, from, to, recordTrace: false);
        phases.add(_Phase('A* replanned',
            res.found ? 'NEW PATH: ${res.path.join(' → ')} (${res.cost.toStringAsFixed(0)}s).' : 'No alternative!'));
        if (!res.found) break;
      }
      phases.add(_Phase('Bus moving', '${res.path.join(' → ')} (${res.cost.toStringAsFixed(0)}s, ${res.nodesExpanded} nodes).'));
      fullTrail.addAll(res.path.skip(1));
      from = to;
    }
    phases.add(const _Phase('STEP 11 · College reached', 'All assigned stops served. Actual boardings feed tomorrow\'s demand estimates.'));
    setState(() {
      _comboPhases = phases;
      _comboIndex = 0;
      _comboPlaying = false;
      _comboGraph = graph;
      _comboBusTrail = fullTrail;
    });
  }

  void _comboGoto(int i) {
    if (_comboPhases.isEmpty) return;
    setState(() => _comboIndex = i.clamp(0, _comboPhases.length - 1));
  }

  void _comboTogglePlay() {
    if (_comboPlaying) {
      _comboTimer?.cancel();
      setState(() => _comboPlaying = false);
      return;
    }
    if (_comboIndex >= _comboPhases.length - 1) _comboIndex = 0;
    setState(() => _comboPlaying = true);
    _comboTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (_comboIndex >= _comboPhases.length - 1) {
        _comboTimer?.cancel();
        setState(() => _comboPlaying = false);
      } else {
        setState(() => _comboIndex++);
      }
    });
  }

  Widget _buildCombinedTab() {
    // Bus dot: furthest trail node "reached" by current phase.
    var reached = 0;
    for (var i = 0; i <= _comboIndex && i < _comboPhases.length; i++) {
      final t = _comboPhases[i].title;
      if (t.startsWith('Bus moving') || t.startsWith('STEP 1')) reached++;
    }
    final trailNode = _comboBusTrail.isEmpty
        ? null
        : _comboBusTrail[reached.clamp(0, _comboBusTrail.length - 1)];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('End-to-end: CSP → A* → drive → roadblock → replan → College',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('One pipeline, same services: CSP assigns the stops, A* routes each leg.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
        if (_comboBlockedPair != null) ...[
          const SizedBox(height: 4),
          Text('⛔ Road closed during run: ${_comboBlockedPair!}',
              style: const TextStyle(fontSize: 12, color: Color(0xFFF59E0B), fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 8),
        Container(
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: CustomPaint(
            painter: _GraphPainter(
              graph: _comboGraph ?? _combinedGraph(),
              openIds: const {},
              closedIds: const {},
              currentId: null,
              path: _comboBusTrail,
              finalPath: _comboBusTrail,
              showFinalPath: true,
              startId: _comboBusTrail.isEmpty ? '' : _comboBusTrail.first,
              goalId: 'College',
              busNode: trailNode,
            ),
            child: Container(),
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _comboPhases.length; i++)
          Opacity(
            opacity: i <= _comboIndex ? 1.0 : 0.45,
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: i == _comboIndex ? const Color(0xFF6366F1).withValues(alpha: 0.15) : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: i == _comboIndex ? const Color(0xFF6366F1) : const Color(0xFF334155)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        i < _comboIndex
                            ? Icons.check_circle
                            : (i == _comboIndex ? Icons.play_circle : Icons.radio_button_unchecked),
                        size: 16,
                        color: i < _comboIndex
                            ? const Color(0xFF22C55E)
                            : (i == _comboIndex ? const Color(0xFF6366F1) : const Color(0xFF64748B)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_comboPhases[i].title,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_comboPhases[i].detail, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        _playerControls(
          onReset: () => _comboGoto(0),
          onPrev: () => _comboGoto(_comboIndex - 1),
          onPlayPause: _comboTogglePlay,
          onNext: () => _comboGoto(_comboIndex + 1),
          onRunAll: () => _comboGoto(_comboPhases.length - 1),
          playing: _comboPlaying,
          position: _comboPhases.isEmpty ? '' : 'phase ${_comboIndex + 1} of ${_comboPhases.length}',
        ),
      ],
    );
  }

  // ================= shell =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Algorithm Simulation'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.groups), text: 'CSP'),
            Tab(icon: Icon(Icons.route), text: 'A*'),
            Tab(icon: Icon(Icons.playlist_play), text: 'Combined'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildCspTab(),
          _buildAstarTab(),
          _buildCombinedTab(),
        ],
      ),
    );
  }
}

/// Canvas renderer for road graphs: nodes, edges, open/closed sets, the
/// current node, the final path and (combined tab) the bus marker.
class _GraphPainter extends CustomPainter {
  final RoadGraph graph;
  final Set<String> openIds;
  final Set<String> closedIds;
  final String? currentId;
  final List<String> path;
  final List<String> finalPath;
  final bool showFinalPath;
  final String startId;
  final String goalId;
  final String? busNode;

  _GraphPainter({
    required this.graph,
    required this.openIds,
    required this.closedIds,
    required this.currentId,
    required this.path,
    required this.finalPath,
    required this.showFinalPath,
    required this.startId,
    required this.goalId,
    required this.busNode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (graph.nodes.isEmpty) return;
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final n in graph.nodes.values) {
      if (n.lon < minX) minX = n.lon;
      if (n.lon > maxX) maxX = n.lon;
      if (n.lat < minY) minY = n.lat;
      if (n.lat > maxY) maxY = n.lat;
    }
    if (maxX == minX) maxX = minX + 1;
    if (maxY == minY) maxY = minY + 1;
    const pad = 44.0;
    Offset pos(RoadNode n) => Offset(
          pad + (n.lon - minX) / (maxX - minX) * (size.width - 2 * pad),
          // Canvas y grows downward: flip so higher lat is up.
          pad + (1 - (n.lat - minY) / (maxY - minY)) * (size.height - 2 * pad),
        );

    final pathEdges = <String>{};
    final shown = showFinalPath ? finalPath : path;
    for (var i = 0; i + 1 < shown.length; i++) {
      pathEdges.add('${shown[i]}>${shown[i + 1]}');
      pathEdges.add('${shown[i + 1]}>${shown[i]}');
    }

    // Edges (dedupe undirected pairs).
    final drawn = <String>{};
    for (final edges in graph.adjacency.values) {
      for (final e in edges) {
        final key = '${e.from}<>${e.to}';
        final rev = '${e.to}<>${e.from}';
        if (drawn.contains(key) || drawn.contains(rev)) continue;
        drawn.add(key);
        final a = graph.nodes[e.from];
        final b = graph.nodes[e.to];
        if (a == null || b == null) continue;
        final onPath = pathEdges.contains('${e.from}>${e.to}');
        final paint = Paint()
          ..color = e.blocked
              ? const Color(0xFFEF4444)
              : (onPath ? const Color(0xFF22C55E) : const Color(0xFF475569))
          ..strokeWidth = onPath ? 4 : 2
          ..style = PaintingStyle.stroke;
        canvas.drawLine(pos(a), pos(b), paint);
        if (e.blocked) {
          _text(canvas, '✕ BLOCKED', (pos(a) + pos(b)) / 2, const Color(0xFFEF4444), 10);
          _text(canvas, '${e.cost.toStringAsFixed(0)}s', (pos(a) + pos(b)) / 2 + const Offset(0, 12),
              const Color(0xFF64748B), 9);
        } else if (onPath) {
          _text(canvas, '${e.cost.toStringAsFixed(0)}s', (pos(a) + pos(b)) / 2, const Color(0xFF22C55E), 9);
        }
      }
    }

    // Nodes.
    for (final n in graph.nodes.values) {
      final p = pos(n);
      Color fill = const Color(0xFF1E293B);
      Color ring = const Color(0xFF475569);
      if (closedIds.contains(n.id)) {
        fill = const Color(0xFF334155);
      }
      if (openIds.contains(n.id)) {
        ring = const Color(0xFFF59E0B);
      }
      if (n.id == currentId) {
        fill = const Color(0xFF6366F1);
        ring = const Color(0xFFF8FAFC);
      }
      if (shown.contains(n.id)) {
        fill = const Color(0xFF22C55E);
        ring = const Color(0xFF22C55E);
      }
      if (n.id == startId) ring = const Color(0xFF22C55E);
      if (n.id == goalId) ring = const Color(0xFFEF4444);
      canvas.drawCircle(p, 15, Paint()..color = fill);
      canvas.drawCircle(
          p, 15, Paint()..color = ring..style = PaintingStyle.stroke..strokeWidth = 2.5);
      _text(canvas, n.label, p + const Offset(0, -1), const Color(0xFFF8FAFC), 11, bold: true);
      if (n.id == busNode) {
        canvas.drawCircle(p, 22, Paint()..color = const Color(0xFF6366F1).withValues(alpha: 0.3));
        _text(canvas, '🚌', p + const Offset(0, -20), const Color(0xFFF8FAFC), 13);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    tp.layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => true;
}
