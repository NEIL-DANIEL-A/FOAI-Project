# MACTMS — Verified Project Documentation

> Every statement in this file was checked directly against the source code
> (`driver_app/`, `student_app/`, `supabase/`, `demo/`, and the root `*.sql`
> scripts). Where the older `README.md` / `AI_ALGORITHMS.md` differed from
> the code, the discrepancy is listed in §13.

---

## Contents

1. [Project overview](#1-project-overview)
2. [Multi-agent architecture (verified)](#2-multi-agent-architecture-verified)
3. [Repository layout](#3-repository-layout)
4. [Database schema & SQL scripts](#4-database-schema--sql-scripts)
5. [Backend triggers (the "agents" in PostgreSQL)](#5-backend-triggers-the-agents-in-postgresql)
6. [Edge Function: send-push](#6-edge-function-send-push)
7. [Driver App](#7-driver-app)
8. [Student App](#8-student-app)
9. [AI algorithms (CSP + A*)](#9-ai-algorithms-csp--a)
10. [AI simulation screen](#10-ai-simulation-screen)
11. [Road graph database & seed tooling](#11-road-graph-database--seed-tooling)
12. [Demo/simulator tooling](#12-demosimulator-tooling)
13. [Corrections to previous documentation](#13-corrections-to-previous-documentation)
14. [Setup & run order](#14-setup--run-order)
15. [Environment variables](#15-environment-variables)
16. [Known limitations](#16-known-limitations)

---

## 1. Project overview

Multi-Agent Campus Transport Management System (MACTMS) — a college bus
tracking platform built as:

- **Two Flutter apps** (driver + student) targeting Android.
- **Supabase backend**: PostgreSQL + PostGIS, Auth, Realtime, Edge Functions (Deno).
- **Database triggers** that do geofencing, occupancy and notification
  dispatch with zero app-side logic.
- **AI planning layer** in pure Dart: CSP + backtracking (stop→bus allocation),
  demand estimation (boarding-history forecast) and A* search (path to the
  next stop), with a visual simulator.
- **Python demo tooling** (`demo/`) for simulating a driver and inspecting the
  live realtime pipeline.
- Built with the OpenCode multi-agent workflow configured in `opencode.json`.

Environments read at runtime: `Api_url`, `Anon_key`, `CESIUM_ION_ACCESS_TOKEN`
(exact spelling). Two `.env` files are required: one in `driver_app/`, one in
`student_app/`, both declared as Flutter assets in their `pubspec.yaml`.
The root `.env` additionally carries `Service_role` for the simulator.

---

## 2. Multi-agent architecture (verified)

### Layer 1 — Development-time agents (`opencode.json`)

| Agent | Mode | Model (exact ID) |
|---|---|---|
| `architect` | primary | `opencode/nemotron-3-ultra-free` |
| `builder` | subagent | `opencode/mimo-v2.5-free` |
| `researcher` | subagent | `opencode/deepseek-v4-flash-free` |
| `debugger` | subagent | `opencode/nemotron-3.5-lightning-free` |
| `reviewer` | subagent | `ollama-cloud/gpt-oss:120b` |

`default_agent` is `architect`.

### Layer 2 — Runtime agents (deployed system)

| # | Agent | Lives in | Trigger | What it does |
|---|---|---|---|---|
| 1 | Telemetry | `driver_app/` (Flutter+geolocator) | Driver taps START TRIP; position stream with **`distanceFilter: 10`** (10 m) | INSERTs `location_pings` **and** upserts `bus_positions` per fix |
| 2 | Geofence Detection | `geofence_trigger.sql` (PostGIS) | INSERT/UPDATE on `bus_positions` | `ST_DWithin` (geography, metres) vs every route stop; inserts `arrived`/`departed` into `stop_events`; updates `trips.running_status` (`on_time`/`late` >10 min grace, `arrived` when a stop named exactly `College Gate` is reached) |
| 3 | Occupancy Tracking | `occupancy_trigger.sql` | INSERT on `stop_boardings` | Adds `boarding_count` to `trips.current_occupancy` (increment only) |
| 4 | Notification Dispatch | `notification_setup.sql` + `supabase/functions/send-push` | UPDATE of `trips.running_status` (value actually changed, non-null) | Collects distinct FCM tokens of route subscribers and calls the `send-push` Edge Function via `net.http_post` (**requires `pg_net`**) |
| 5 | Visualization & Intelligence | `student_app/` (Flutter) | Supabase Realtime events on 5 channels | Live Cesium map, occupancy, arrival alerts, transfer suggestions, AI stop-plan display |

The runtime agents never call each other; the shared PostgreSQL state is the
event bus (verified: no direct service-to-service calls in either app).

---

## 3. Repository layout

```
.
├── AGENTS.md                     # coding-assistant instructions
├── README.md                     # original narrative README
├── AI_ALGORITHMS.md              # AI feature changelog / notes
├── PROJECT_DOCUMENTATION.md      # this file
├── opencode.json                 # dev-time agent config
├── schema.sql                    # core tables + RLS
├── seed_data.sql                 # Bangalore demo dataset (3 routes, 6 buses)
├── geofence_trigger.sql          # PostGIS geofence trigger
├── occupancy_trigger.sql         # occupancy increment trigger
├── notification_setup.sql        # user_devices, route_subscriptions, FCM trigger
├── update_schema.sql             # stops.members_count + realtime publication
├── fix_rls.sql                   # UPDATE/DELETE policies for driver_bus_assignments
├── fix_student_role.sql          # role CHECK allows 'student'
├── ai_transport_schema.sql       # slots, slot_buses, stop_assignments, road graph
├── extra_stops.sql               # Chennai-area stop extensions (routes ...0001–0004)
├── fix_ambattur_order.sql        # reorders Route 1 (Campus→Ambattur) geographically
├── .env                          # root env (simulator + demo scripts)
├── driver_app/                   # Flutter driver app (+ lib/ai/ mirrors)
├── student_app/                  # Flutter student app (+ lib/ai/, lib/ai_sim_screen.dart)
├── supabase/functions/send-push/ # Deno edge function (FCM HTTP v1)
└── demo/                         # python simulator, realtime checker, seeders
```

---

## 4. Database schema & SQL scripts

### `schema.sql` — core tables

| Table | Key columns | Notes |
|---|---|---|
| `users` | `id` (PK → `auth.users`), `name`, `role` (`driver`\|`student` check), `phone` | RLS enabled |
| `routes` | `id`, `name` | |
| `stops` | `route_id`, `name`, `lat`, `lon`, `geofence_radius_m` (default 100), `sequence_no`, `scheduled_time` | `members_count` added later by `update_schema.sql` |
| `buses` | `bus_number` (unique), `route_id`, `capacity` | capacity values seeded: 40/40/35/35/30/30 |
| `driver_bus_assignments` | (`driver_id`,`bus_id`) PK | |
| `trips` | `bus_id`, `driver_id`, `route_id`, `trip_date`, `status` (`scheduled`/`in_progress`/`completed`), `running_status` (`on_time`/`late`/`arrived`), `current_occupancy`, `started_at`, `ended_at` | `slot_id` added by `ai_transport_schema.sql` |
| `stop_boardings` | `trip_id`, `stop_id`, `boarding_count ≥ 0` | |
| `location_pings` | `trip_id`, `lat`, `lon`, `speed` | append-only breadcrumb |
| `bus_positions` | `trip_id` PK, `bus_id`, `lat`, `lon`, `updated_at` | one row per trip |
| `stop_events` | `trip_id`, `stop_id`, `event_type` (`arrived`/`departed`), `actual_time` | |

RLS: everything is publicly readable (`select using (true)`); writes are
restricted to the owning driver (`auth.uid() = driver_id` or via trip
ownership subquery). `fix_rls.sql` additionally adds **UPDATE** and **DELETE**
policies on `driver_bus_assignments` (needed for upsert), and
`fix_student_role.sql` recreates the `users.role` CHECK to allow `student`.

### `notification_setup.sql`

- `user_devices` (`user_id`, `fcm_token`) — per-user FCM tokens.
- `route_subscriptions` (`user_id`, `route_id`, unique pair).
- Trigger `notify_trip_status_change()` on `trips.running_status` UPDATE:
  only fires when value actually changed and is non-null; builds messages
  (late / back on time / arrived at College Gate); posts to
  `<supabase_url>/functions/v1/send-push` for each subscribed FCM token using
  `net.http_post` and the `app.settings.supabase_url` /
  `app.settings.service_role_key` settings — **requires the `pg_net`
  extension**.

### `ai_transport_schema.sql` (idempotent migration)

| Object | Definition |
|---|---|
| `operating_slots` | `route_id`, `label`, `slot_time`, `is_active`, unique (`route_id`,`label`) — seeded: two slots per route (`07:00 AM`, `07:30 AM`) |
| `slot_buses` | (`slot_id`,`bus_id`) PK, `is_available`, `note` — seeded from each route's buses |
| `stop_assignments` | (`slot_id`,`stop_id`) unique + `bus_id` — CSP output, one bus per stop per slot |
| `trips.slot_id` | nullable FK → operating_slots |
| `road_nodes` | `id` (text PK), `label`, `lat`, `lon` |
| `road_edges` | `from_node`/`to_node` FK, `distance_m`, `travel_time_s`, `is_blocked`, unique (`from_node`,`to_node`) |

RLS: public read; `slot_buses` updatable and `stop_assignments` fully
manageable by any authenticated user (`auth.uid() is not null`).
Realtime publication: `operating_slots`, `slot_buses`, `stop_assignments`
are added (and re-added idempotently). `road_nodes`/`road_edges` are **not**
in the realtime publication.

### `seed_data.sql`

Bangalore demo dataset: Routes A/B/C (Electronic City, Whitefield,
Koramangala), 6 buses numbered `1`–`6`, College Main Gate as stop 1 on each
route. This is the dataset the demo simulator and app demos use.

### `extra_stops.sql` / `fix_ambattur_order.sql`

Applied route-data fixes for a separate live dataset (route IDs
`11111111-0000-0000-0000-00000000000{1..4}`, Chennai geography):
- `extra_stops.sql`: extends each route from 4 to 9 stops (Ambattur,
  Kancheepuram, Medavakkam/Guindy, Pallavaram corridors) and trims a trailing
  newline from one route name.
- `fix_ambattur_order.sql`: renumbers Route `...0001` stops geographically
  east→west (T.I Miller → Dunlop → Cycle shop → Church → Ayapakkam Lake →
  ICMR → Ayapakkam park → Selvi mahal → Ganesh Bhavan).

---

## 5. Backend triggers (the "agents" in PostgreSQL)

### Geofence Detection — `geofence_trigger.sql`

Function `handle_bus_position_update()`, attached as
`after insert or update on bus_positions for each row`:

1. Looks up the trip's `route_id`.
2. Loops over the route's stops ordered by `sequence_no`.
3. Uses `ST_DWithin(ST_MakePoint(lon,lat)::geography, stop::geography, geofence_radius_m)`.
4. Inserts `arrived` on first entry (or after leaving), `departed` on exit.
5. On `arrived`: compares `updated_at::time` with `stops.scheduled_time`;
   >10-minute grace ⇒ `running_status = 'late'`, else `'on_time'`; if the
   stop name matches the literal `College Gate` it sets `'arrived'`.

### Occupancy Tracking — `occupancy_trigger.sql`

`handle_boarding_insert()`: `trips.current_occupancy = current_occupancy +
new.boarding_count` on every `stop_boardings` insert. There is no trickle
(occupCount only ever grows during a trip).

---

## 6. Edge Function: send-push

`supabase/functions/send-push/index.ts` (Deno, `std@0.177.0` +
`@supabase/supabase-js@2`):

1. Reads `{ token, title, body }` JSON.
2. Reads `FCM_SERVICE_ACCOUNT_KEY` secret; JSON-parses the service account.
3. Builds and signs an RS256 JWT, exchanges it for an OAuth2 access token.
4. POSTs the notification to **FCM HTTP v1**
   (`https://fcm.googleapis.com/v1/projects/YOUR_PROJECT_ID/messages:send`)
   with Android priority `high`, channel `bus_updates`, and APNs
   content-available payload.

> ⚠ The project URL segment is still the `YOUR_PROJECT_ID` placeholder —
> paste your real Firebase project ID before deploying.

---

## 7. Driver App

`driver_app/lib/main.dart` (~1.7k lines) + `driver_app/lib/ai/*`.

### Auth & assignment

- Supabase email/password signup with bus number; validates the number
  against `buses.bus_number`; upserts `users` row (`role: 'driver'`) and
  **upserts `driver_bus_assignments`** (UPDATE/DELETE enabled by
  `fix_rls.sql`). Sign-in fetches the assignment joined with `buses`.
- AuthGate resumes any `trips` row with `driver_id = user.id AND status =
  'in_progress'` and restarts tracking.

### Telemetry

- `geolocator.getPositionStream`, high accuracy, `distanceFilter: 10`.
- Every fix: INSERT `location_pings` (with speed) + UPSERT `bus_positions`.
- Trip start INSERTs `trips` with `slot_id` (from the slot picker) and
  `status: 'in_progress'`; trip end sets `completed` + `ended_at`.
- Ongoing local notification (ID 888, channel `bus_tracking`):
  "Bus tracking active" (this is the app's foreground-service mechanism;
  there is no `workmanager` or `firebase_messaging` dependency).

### Geofence arrival → headcount

- Realtime channel `arrivals:<trip_id>` — INSERTs on `stop_events`.
- `event_type == 'arrived'` opens a non-dismissable "Boarding at <stop>"
  dialog with a 12-key numpad (0–9, ⌫, C).
- Submit INSERTs `stop_boardings`; **arrival decisions come from the server
  trigger only** — no client-side geofencing.

### AI features

- **Slot picker** from `operating_slots` (only active ones, ordered by time).
- **AI Plan Stops (CSP)** button: reads `slot_buses` for the slot, estimates
  demand from the last 14 days of `stop_boardings`
  (`DemandEstimationService`, safety factor 1.1; missing bus capacity falls
  back to 30 seats), runs `CspAssignmentService.solve`, then rewrites
  `stop_assignments` for the slot (DELETE-all + bulk INSERT) and shows stats
  (assignments tried, backtracks, score).
- **Your stops / Next stop** panel; boarding at a stop advances NEXT to the
  next assigned stop (fallback: all route stops when no assignment exists).
- **A\*** path from the live GPS position to the next assigned stop:
  built from `RoadGraph.fromStops` (chain + skip-one edges, 8 m/s cost) plus
  a temporary `gps:live` node linked to the 2 nearest stops; recomputed on
  first fix / next-stop change **/ deviation >150 m, with a 15-second
  throttle** — never per GPS frame.
- Realtime (while NOT tracking): `slot-assign:<slotId>` on `stop_assignments`
  and `slot-buses:<slotId>` on `slot_buses` — an availability change triggers
  a silent automatic re-plan.
- Map: Cesium in a WebView (`web/cesium/map.html`); messages `init`,
  `addStop`, `addBus`, `updateBusPosition`, `flyToBus`, `flyToStops`,
  `flyToLocation`, `drawPath` (trip path overlay), incoming `ready`.

### Dependencies (`pubspec.yaml`)

`supabase_flutter ^2.17.1`, `flutter_dotenv ^6.0.1`, `geolocator ^14.0.3`,
`flutter_local_notifications ^18.0.1`, `webview_flutter ^4.10.0`,
`webview_flutter_android ^4.14.0`, `cupertino_icons`.

---

## 8. Student App

`student_app/lib/main.dart` (~3.4k lines) + `lib/ai/*` +
`lib/ai_sim_screen.dart`.

### Auth

- Email/password sign-in/up (min 6 chars client-side); upserts a
  `users` row with `role: 'student'` (also on sign-in if profile missing).
- **"Continue as Guest (Demo)"** button — no auth; enters a demo mode with a
  scripted route overlay (see §9/§10).

### Realtime (5 channels, all `public`)

| Channel (table) | Events | Action |
|---|---|---|
| `bus_positions` | all | move markers |
| `trips` | all | upsert/remove bus by status (`in_progress` only stays) |
| `stops` | all | refresh stops (incl. `members_count`) |
| `stop_events` | INSERT | `arrived` → SnackBar arrival alert (5 s); `departed` → AI progress (strikethrough) |
| `stop_assignments` | all | re-fetch AI stop plan |

Zero polling — everything is Postgres-change-driven.

### Live map (Cesium)

- `web/cesium/map.html` in a WebView (mixed content allowed; loaded via
  `loadHtmlString` with `baseUrl: https://localhost`).
- `Cesium.Ion.defaultAccessToken` is set only when
  `CESIUM_ION_ACCESS_TOKEN` is longer than 10 chars; otherwise the map falls
  back to ArcGIS World Imagery.
- Message protocol: `init`(+token), `addBus`, `updateBusPosition`,
  `updateBusStatus`, `removeBus`, `addStop`, `drawPath`, `clearPath`,
  `flyToBus`, `flyToLocation`, `trackBus`, `untrackBus`; inbound `ready`,
  `clickBus`.

### Features (exact thresholds)

- Occupancy badge colors: ≥90% red, ≥70% yellow, else green.
- Running-status colors: `late` red `#EF4444`, `arrived` green `#22C55E`,
  `stopped` amber `#F59E0B`, `on_time`/default indigo `#6366F1`.
- **Transfer suggestion**: ≥2 active buses on one route AND one bus ≥90%
  full while another is ≤50% ⇒ dismissible orange banner suggesting the
  emptier bus.
- "where is bus": nearest stop (squared-distance over all stops) + haversine
  distance text ("Near X" <150 m, meters <1 km, else km).
- Bottom sheet: route timeline with progress highlights, waiting counts.
- Camera follow: `trackBus`/`untrackBus` + floating stop-tracking badge.
- Route subscriptions: bell-icon bottom sheet toggling
  `route_subscriptions` rows. **The student app itself does not register FCM
  device tokens or receive push directly** — `user_devices` is backend
  infrastructure only (see §13).

### AI display

- When a plan exists for the trip's `(slot_id, bus_id)`, bus details show the
  AI card: served stops struck through (from `departed` events), NEXT stop
  highlighted amber, status line "AI: allocation optimized • live path".
- Green psychology-icon header button opens the AI simulation screen
  (`ai_sim_screen.dart`); the demo overlay has a "Steps ›" link to it.

### Dependencies (`pubspec.yaml`)

`supabase_flutter ^2.17.1`, `flutter_dotenv ^6.0.1`, `geolocator ^14.0.3`,
`webview_flutter ^4.10.0`, `webview_flutter_android ^4.14.0`,
`cupertino_icons`. (`webview_flutter` is used by both apps; the student app
also carries `linux`/`macos`/`web` platform folders from `flutter create`,
though Android is the primary target.)

---

## 9. AI algorithms (CSP + A*)

Shared pure-Dart modules (zero Flutter imports) in `student_app/lib/ai/`,
mirrored by content-identical files in `driver_app/lib/ai/`
(`astar.dart`, `csp.dart`, `demand.dart`, `road_graph.dart` — same byte
sizes; the student copy additionally has `route_geometry.dart`).

### Demand estimation — `demand.dart`

- EXPECTED demand = recency-weighted average of actual `stop_boardings`
  headcounts × `safetyFactor` (1.1).
- Weight formula: `1 / (1 + ageDays / 7)` (harmonic recency decay — recent
  samples weigh more; note the code comment calls it "half-life", but the
  implemented formula is `1/(1+x)`).
- Stops with no history get `fallbackDemand` 5.0 with `samples = 0`
  (flagged in UI). Driver app queries the **last 14 days** of boardings.

### CSP + backtracking — `csp.dart`

- **Variables**: route stops (`CspStop`: expected demand + sequence).
- **Domains**: buses scheduled to the slot; only `available` ones enter the
  pool.
- **Constraints**: (1) availability, (2) capacity — assigned expected demand
  ≤ capacity, (3) route/slot scoping (caller-provided), (4) coverage of all
  stops, (5) direction (buses serve stops in sequence order downstream),
  (6) one bus per student stop→college (no transfers), (7) unavailable buses
  excluded.
- **Heuristics**: MRV — the unassigned stop with the fewest capacity-feasible
  buses goes first (ties broken by route order); buses tried
  least-loaded-first (steers toward balance).
- Search collects up to `maxSolutions = 200` feasible assignments and scores
  them: `score = busesUsed + maxUtilization + 0.5 × variance(utilization)`
  — lower wins (fleet economy, no overload, balance).
- Full trace (`try`/`valid`/`violation`/`backtrack`/`solution`/`done`/
  `nosolution` steps with partial assignments and loads) is recorded for the
  simulation; live callers pass `recordTrace: false`.

### A\* — `astar.dart`

- `f(n) = g(n) + h(n)`; `g` = cheapest travel-time along edges;
  `h` = haversine(n, goal) / **15 m/s** (admissible → optimal path).
- Open frontier by lowest `f`, closed set, `cameFrom` path reconstruction;
  blocked edges excluded from neighbor expansion.
- Returns `{found, path, cost, nodesExpanded, relaxations, trace,
  g/h/fScores}` — the live apps use path+cost, the simulation animates the
  trace (same code path).

### Road graph — `road_graph.dart`

- `RoadGraph.fromStops`: one node per stop + chain edges between consecutive
  stops + **skip-one edges** (direct bypass giving A* a genuine choice);
  undirected edges; cost = haversine distance / `speedMps` (**8.0 m/s**).
- `RoadGraph.textbook()`: schematic A/B/C/D/E/F/G/Goal demo graph for the
  simulation canvas.
- `setBlocked` toggles closures; `neighbors()` filters blocked edges.

### Route geometry — `route_geometry.dart` (student app only)

- Fetches road-hugging polylines from the **free OSRM demo server** for
  DISPLAY only (8 s timeout, polyline5 decoding, downsample to 80 points,
  straight-line fallback on any failure). Routing decisions never leave
  `AStarService`. Used by the demo-mode overlay; live buses don't call OSRM.

---

## 10. AI simulation screen

`student_app/lib/ai_sim_screen.dart` — 3 tabs; **every tab runs the real
services with `recordTrace: true`** (no fake animation):

1. **CSP tab** — scenario presets:
   S1 normal, S2 tight capacity (forces backtracking), S3 bus unavailable,
   S4 demand spike, S0 infeasible; a step player (PLAY/PAUSE/NEXT/PREV/RESET/
   RUN ALL) replays the CspStep trace plus per-run stats.
2. **A\* tab** — schematic 5-stop city graph (S1…S5, J junctions, College);
   runs A* start→goal; a roadblock button blocks the middle edge of the
   discovered path and re-runs to show replanning; step player shows g/h/f,
   open/closed sets.
3. **Combined tab** — end-to-end pipeline: slots → slot buses → demand →
   CSP → per-leg A\* → drive animation → roadblock → replan → College.

Unit tests: `student_app/test/ai_test.dart` contains **11 tests**
(3× A*: optimal path, blocked-edge reroute, unreachable; 4× CSP: feasible
best, forced backtracking, infeasible, unavailable exclusion; 2× demand:
safety-factor average, fallback; 2× geometry: polyline decode, downsample).

---

## 11. Road graph database & seed tooling

`demo/seed_road_graph.py` seeds `road_nodes`/`road_edges` straight from the
route stops (chain + skip-one edges, `travel_time_s = d / SPEED_MPS`) and
prints `len(nodes)` nodes / `len(edges) × 2` directed edges. For the
applied dataset (4 routes × 9 stops): **36 nodes, 120 directed edges**.
Live A* in the apps does NOT read these tables — it builds the graph in
memory; the DB copy exists for inspection/extensibility and honors
`road_edges.is_blocked` as simulated block reporting.

`demo/check_realtime.py` verifies tables via the anon key and deeply checks
trigger presence and `supabase_realtime` publication membership over a
direct Postgres connection.

---

## 12. Demo/simulator tooling

`demo/simulate_trip.py` — headless fake driver:

- Pipeline: `bus_positions`/`location_pings`/`stop_boardings` → DB triggers →
  `stop_events` + `trips.running_status`/`current_occupancy` → Supabase
  Realtime → student app maps live.
- Flags: `--list`, `--route`, `--bus`, `--interval`, `--steps-per-leg`,
  `--boarding-max 0`, `--loop`, `--dry-run`, `--complete-others`.
- Requires root `.env` keys `Api_url`, `Anon_key`, `Service_role`
  (service role bypasses RLS).
- Route data shown matches `seed_data.sql` (Bangalore). Geofence events fire
  since the simulator travels exactly through each stop coordinate.
- Trips must be `in_progress` with a `bus_positions` row to render — both
  are created by the simulator.

---

## 13. Corrections to previous documentation

Found while re-verifying `README.md` and `AI_ALGORITHMS.md` against the code:

| # | Previous claim | Reality (code) |
|---|---|---|
| 1 | Demand forecast uses a "half-life 7 days" (exponential) recency weighting | `demand.dart` weights `1/(1 + ageDays/7)` — harmonic decay, not exponential halving (even the code comment mislabels it) |
| 2 | "9 unit tests, all passing" | `ai_test.dart` now has **11** tests (polyline decode + downsample were added) |
| 3 | Student app "receives FCM push notifications" / device registration implied via `user_devices` | The student app has **no** FCM/device-registration code; it only writes/reads `route_subscriptions`. `user_devices` + the trigger + edge function are backend-only infrastructure (the trigger itself still needs `pg_net` to be enabled) |
| 4 | `send-push` "dispatches" pushes in production | The FCM API URL still contains the `YOUR_PROJECT_ID` placeholder; the trigger requires `pg_net` and Supabase settings `app.settings.*` — push is not fully wired |
| 5 | README: seed data "Route A - Electronic City …" is the full data story | `seed_data.sql` is the **demo** dataset (Bangalore); a second applied dataset with **Chennai** stops exists (`extra_stops.sql`, `fix_ambattur_order.sql`, route IDs `11111111-…`) |
| 6 | Geofence sets `arrived` at "College Gate" | The trigger compares the stop name to the literal `College Gate`, but `seed_data.sql` names it `College Main Gate` — with the demo seed data the `'arrived'` running status will never be set (stop-name mismatch) |
| 7 | Agent models shown as `nemotron-3-ultra`, `mimo-v2.5`, … | Exact IDs in `opencode.json` carry `-free` suffixes and `ollama-cloud/` scope (see §2) |
| 8 | `notification_setup.sql` fires for *every* `trips.running_status` change | Correct, but note it is an `after update of running_status` trigger with a `when (old is distinct from new)` clause and non-null filter — it never fires on insert |
| 9 | Driver README: "notifications: FCM" implied on the driver side | Driver app uses only `flutter_local_notifications` (foreground notification ID 888); no Firebase dependency |

---

## 14. Setup & run order

### Backend (Supabase SQL editor, in order)

1. `schema.sql` (+ `create extension postgis` included)
2. `seed_data.sql`
3. `fix_student_role.sql`
4. `fix_rls.sql`
5. `geofence_trigger.sql`
6. `occupancy_trigger.sql`
7. `update_schema.sql`
8. `notification_setup.sql` *(optional push infra; needs `pg_net`)*
9. `ai_transport_schema.sql` *(AI slot/assignment tables + realtime)*
10. `extra_stops.sql`, `fix_ambattur_order.sql` *(live-route data fixes)*
11. `demo/seed_road_graph.py` *(optional: DB road-graph copy)*

### Apps

```bash
cd driver_app && flutter pub get && flutter run
cd student_app && flutter pub get && flutter run
```

Both folders need a `.env` (see §15) and `web/cesium/map.html` (present in
both).

### Demo validation

```powershell
pip install -r demo/requirements.txt
python demo/simulate_trip.py --list
python demo/simulate_trip.py --route "Route A" --bus 1
python demo/check_realtime.py
```

Then open the student app (or Guest Demo) and watch the pipeline live.

---

## 15. Environment variables

**`driver_app/.env` and `student_app/.env`** (both apps read the same names):

```env
Api_url=https://YOUR_PROJECT_REF.supabase.co
Anon_key=YOUR_SUPABASE_ANON_KEY
CESIUM_ION_ACCESS_TOKEN=YOUR_CESIUM_ION_ACCESS_TOKEN
```

> Without the Cesium token (or with a token ≤10 chars) both maps fall back
> to ArcGIS World Imagery.

**Root `.env`** (demo scripts only):

```env
Api_url=https://YOUR_PROJECT_REF.supabase.co
Anon_key=YOUR_SUPABASE_ANON_KEY
Service_role=YOUR_SUPABASE_SERVICE_ROLE_KEY
```

**Supabase edge secrets** (for `send-push`): `FCM_SERVICE_ACCOUNT_KEY`
(JSON service account). The function itself must get the real project ID
substituted into `FCM_API_URL`.

Never commit keys; `.env` files are untracked in this repo.

---

## 16. Known limitations

1. Push notification pipeline not fully operable: `notify_trip_status_change`
   requires `pg_net` + secrets; `send-push` still has the `YOUR_PROJECT_ID`
   placeholder; the student app registers no FCM tokens yet.
2. Geofence arrival prompts fire for **every** route stop, including CSP-
   skipped stops (driver can enter 0 / cancel); assignment-aware geofencing
   is future work.
3. Linked quirk: the `'arrived'` terminal status only triggers for a stop
   literally named `College Gate` (docs/schema mismatch noted in §13).
4. The road graph is stop-chain + skip edges, not full street topology; DB
   `road_edges.is_blocked` is respected but no UI reports live roadblocks
   (simulated in the demo/tab gameplay).
5. `driver_app/lib/ai/*` are manual copies of `student_app/lib/ai/*`
   (byte-identical today); a shared Dart package would remove the sync risk.
6. CSP enumerates up to 200 full solutions; fine for ~9 stops × few buses
   per slot, would need time caps for larger slots.
7. Realtime `select using (true)` means bus locations/occupancy are readable
   by anyone holding the anon key — acceptable for a campus scope, but worth
   hardening (e.g., signed-prepared-statement restrictions) for production.
