# AI Algorithms in MACTMS (CSP + Backtracking, A* Search)

## 0. Jury summary (30 seconds)

"CSP + Backtracking dynamically allocates stops among the buses scheduled for
a particular operating slot while satisfying capacity and route constraints.
A* then finds the lowest-cost road path between the bus's assigned stops.
Both algorithms are used by the live application and the same implementations
power an interactive visual simulation for demonstrating their decisions."

## 1. Modified files

- `student_app/lib/main.dart` — BusInfo/StopInfo extended (slot, bus, sequence);
  assignment loading + realtime (`stop_assignments`); departed-stop progress;
  AI panel in bus details (assigned stops, NEXT highlight, AI status line);
  🧠 header button opening the simulation.
- `driver_app/lib/main.dart` — slot picker; `AI Plan Stops (CSP)` flow; AI
  panel (stats, my stops, next stop, A* info); `trips.slot_id` on start;
  A* path compute on first fix / next-stop change / >150 m deviation only;
  boarding advances to next assigned stop; guarded notification calls.
- `student_app/web/cesium/map.html`, `driver_app/web/cesium/map.html` —
  fixed `flyToBus` (was diving into the globe); added `drawPath`/`clearPath`
  polyline overlay for the A* path.
- `update_schema.sql` — fixed invalid `DROP TABLE IF EXISTS` inside
  `ALTER PUBLICATION` (rewrite is idempotent and applied).
- `demo/check_realtime.py` — covers the new AI tables + publication.

## 2. New files

- `ai_transport_schema.sql` — migration (slots, slot buses, assignments,
  `trips.slot_id`, road graph, RLS, realtime, seeds). Already applied.
- `extra_stops.sql`, `fix_ambattur_order.sql` — route data fixes (applied).
- `student_app/lib/ai/road_graph.dart` — RoadNode/RoadEdge/RoadGraph,
  `fromStops()` builder, `textbook()` demo graph, haversine costs.
- `student_app/lib/ai/astar.dart` — `AStarService` (f=g+h, open/closed sets,
  cameFrom, trace recording).
- `student_app/lib/ai/csp.dart` — `CspAssignmentService` (recursive
  backtracking, MRV, load-ordered values, solution scoring).
- `student_app/lib/ai/demand.dart` — `DemandEstimationService`
  (recency-weighted average × safety factor; expected vs actual separated).
- `driver_app/lib/ai/*.dart` — byte-identical copies (verified by diff).
- `student_app/lib/ai_sim_screen.dart` — AI Algorithm Simulation
  (CSP tab, A* tab, Combined tab, scenarios S0–S4 + roadblock).
- `student_app/test/ai_test.dart` — 9 unit tests, all passing.
- `demo/seed_road_graph.py` — seeds DB road graph from stops (36 nodes,
  120 directed edges). Already applied.

## 3. Database migrations (all applied)

`ai_transport_schema.sql`: `operating_slots` (8 seeded: 07:00/07:30 AM per
route), `slot_buses` (14 seeded), `stop_assignments` (empty until first plan),
`trips.slot_id`, `road_nodes`/`road_edges`, RLS (public read; auth writes),
realtime publication for the 3 new tables (verified by health check).

## 4. New services/classes

`RoadGraph`, `AStarService`/`AstarResult`/`AstarStep`,
`CspAssignmentService`/`CspResult`/`CspSolution`/`CspStep`,
`DemandEstimationService`/`DemandEstimate`. Pure Dart, zero Flutter
imports — imported by driver code, student code, simulation, and tests.

## 5–7. CSP variables / domains / constraints

- Variables: each route stop (`CspStop` with expected demand + sequence).
- Domains: buses scheduled for the slot (`slot_buses`, unavailable excluded).
- C1 availability, C2 capacity (expected load ≤ capacity), C3 route (one
  route/slot per run), C4 coverage (all stops assigned), C5 direction (stops
  served in sequence order; skips allowed, backward travel impossible),
  C6 invalid buses excluded, C7 no transfers (stop→bus→college only).

## 8. Backtracking explanation

`CspAssignmentService.solve` picks the unassigned stop with Minimum
Remaining Values (fewest capacity-feasible buses, ties by route order),
tries buses least-loaded-first, checks capacity, recurses; on dead end it
undoes the assignment (emitting a `backtrack` trace event) and tries the next
bus. Up to 200 solutions are collected; each TRY/VALID/VIOLATION/BACKTRACK is
recorded with loads and partial assignment — the simulation replays this
exact list with PLAY/PAUSE/NEXT/PREV/RESET/RUN ALL.

## 9. Demand estimation explanation

Expected demand = recency-weighted average of ACTUAL `stop_boardings`
headcounts (last 14 days, half-life 7 days) × 1.1 safety factor; stops with
no history get fallback 5 (flagged, 0 samples). Actuals keep flowing into
`stop_boardings` via the driver headcount pad, improving future estimates.

## 10. A* implementation explanation

`f(n)=g(n)+h(n)`; g = travel-time seconds along edges, h = haversine time at
15 m/s max (admissible → optimal). Open list by lowest f, closed set,
`cameFrom` reconstruction, neighbor expansion with blocked-edge exclusion.
Live graph = stop chain + skip-one edges + temporary GPS node linked to the 2
nearest stops. Recomputed only on trip start / next-stop change / >150 m
deviation (15 s throttle) — never per GPS frame.

## 11. Real-time event flow

ADMIN slots → slot buses → demand → CSP → `stop_assignments` → Driver App
(slot dropdown → AI Plan → assigned stops + next stop + A* path overlay) →
GPS/geofencing → actual boarding → history. `slot_buses` UPDATE pre-trip
auto re-plans; `stop_assignments` changes push "Trip assignment updated".
Students get bus location, assigned stops, NEXT highlight, occupancy,
arrival alerts via existing realtime channels.

## 11b. Google-style route overlay in the demo (on the map itself)

The in-app bus demo now runs BOTH algorithms visibly on the Cesium map:

- Pick any bus → the REAL `CspAssignmentService` plans its slot (real
  history demand, else labeled sample demand). The demo bus serves ONLY its
  assigned stops; the overlay card lists `Serves: …`, `Skips: … → Bus 102`,
  and the CSP stats (tried / backtracks / score).
- Every leg, the REAL `AStarService` computes best + alternative (best path's
  middle edge blocked and re-run). Best draws **blue thick**, alternative
  **gray thin**, with a best/alt legend and a live ETA line
  (`A* → S5: best 2.1 km ~4 min (12 nodes) • alt +0.6 km`).
- Road-hugging shapes come from `lib/ai/route_geometry.dart` (free OSRM
  shape API, 8 s timeout, cached per leg, straight-line fallback offline).
  Routing DECISIONS never leave `AStarService` — geometry is display only.
- Arrival alerts + driver headcount pad + occupancy work as before; a
  `Steps ›` button jumps to the full 🧠 step player for the same run logic.

## 12. Demo/simulation flow

Student app → 🧠 → CSP tab (scenario S0–S4 → step player + stats) → A* tab
(start/goal → step player with g/h/f + open set → roadblock replan) →
Combined tab (11-phase pipeline: slot→buses→demand→CSP→per-leg A*→block→
replan→College, animated bus dot). Scenarios: S1 normal, S2 backtrack,
S3 unavailable bus, S4 demand spike, S0 infeasible, S5 normal A*,
S6 roadblock, S7 combined.

## 13. Test scenarios (§24)

Covered as presets + unit tests: normal CSP (balanced best), capacity
violation (backtracks > 0 asserted), bus unavailable (excluded asserted),
demand spike (different allocation), normal A* (A-F-G-Goal = 24 s asserted),
roadblock (reroute A-B-D-E-Goal = 33 s asserted), unreachable (nopath),
infeasible CSP (nosolution), combined (scripted pipeline).

## 14. How the Driver App uses the result

Slot picker → AI Plan Stops writes `stop_assignments` → panel shows
"Your stops: A → C → D" + tried/backtracks/score → START TRIP stores
`slot_id` → green A* path drawn GPS→next stop with "x.x km, ~y min (N nodes
explored)" → each boarding advances NEXT and replans. Assignment updates
arrive pre-trip only ("Trip assignment updated."); live trips never change
silently.

## 15. How the Student App uses the result

Bus details show the AI card when a plan exists: served stops struck
through (from `departed` events), NEXT highlighted amber, status line
"AI: allocation optimized • live path". Assignment changes stream live via
the `stop_assignments` channel. No CSP internals exposed beyond this card.

## 16. Known limitations

- Push-notification trigger (`notify_trip_status_change`) not installed:
  needs `pg_net` + real FCM keys; `send-push` still has YOUR_PROJECT_ID.
- Geofence arrival prompts fire for every route stop, including CSP-skipped
  ones (driver enters 0/Skip); assignment-aware geofencing is future work.
- Road graph follows stop geometry (chain + skip edges), not full street
  topology; DB `road_edges.is_blocked` is respected but live block reporting
  UI is not included (simulated in the demo).
- `driver_app/lib/ai/*` are manual copies of `student_app/lib/ai/*`
  (verified identical); a shared Dart package would remove the sync step.
- CSP enumerates up to 200 solutions; fine for ≤9 stops/≤3 buses per slot,
  would need heuristics-first + time caps for much larger slots.
