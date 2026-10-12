/// Historical boarding sample for one stop (actual headcounts recorded
/// by drivers via the existing stop_boardings flow).
class BoardingSample {
  final String stopId;
  final double count;
  final DateTime date;
  const BoardingSample({required this.stopId, required this.count, required this.date});
}

/// Expected demand for a stop plus how much history backs it.
class DemandEstimate {
  final String stopId;
  final double expected;
  final int samples;
  const DemandEstimate({required this.stopId, required this.expected, required this.samples});
}

/// Demand estimation: EXPECTED demand (forecast for CSP) is derived from
/// ACTUAL boarding history, never confused with it. Uses a recency-weighted
/// average (recent days weigh more) multiplied by a safety factor, so the
/// forecast hedges against under-capacity assignments.
class DemandEstimationService {
  /// [history] maps stopId -> samples. [safetyFactor] (e.g. 1.1) hedges up.
  /// Stops with no history get [fallbackDemand] and 0 samples (flagged in UI).
  static Map<String, DemandEstimate> estimate(
    Map<String, List<BoardingSample>> history, {
    double safetyFactor = 1.1,
    double fallbackDemand = 5.0,
    double recencyHalfLifeDays = 7.0,
  }) {
    final now = DateTime.now();
    final out = <String, DemandEstimate>{};
    history.forEach((stopId, samples) {
      if (samples.isEmpty) {
        out[stopId] = DemandEstimate(stopId: stopId, expected: fallbackDemand, samples: 0);
        return;
      }
      var wSum = 0.0;
      var wTotal = 0.0;
      for (final s in samples) {
        final ageDays = now.difference(s.date).inHours / 24.0;
        // Exponential recency decay: weight halves every [recencyHalfLifeDays].
        var w = 1.0;
        if (ageDays > 0) {
          w = 1.0 / (1.0 + ageDays / recencyHalfLifeDays);
        }
        wSum += s.count * w;
        wTotal += w;
      }
      out[stopId] = DemandEstimate(
        stopId: stopId,
        expected: (wSum / wTotal) * safetyFactor,
        samples: samples.length,
      );
    });
    return out;
  }

  /// Groups raw boarding rows (from stop_boardings + trip dates) per stop.
  static Map<String, List<BoardingSample>> group(
    List<Map<String, dynamic>> rows, {
    required String stopIdKey,
    required String countKey,
    required String dateKey,
  }) {
    final map = <String, List<BoardingSample>>{};
    for (final r in rows) {
      final stopId = r[stopIdKey] as String;
      final count = (r[countKey] as num).toDouble();
      final date = DateTime.tryParse('${r[dateKey]}') ?? DateTime.now();
      map.putIfAbsent(stopId, () => []).add(BoardingSample(stopId: stopId, count: count, date: date));
    }
    return map;
  }
}
