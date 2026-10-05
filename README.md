# College Bus Transit & Real-Time Tracking System (FOAI Project) 🚍🎓

An end-to-end college bus tracking, passenger telemetry, and transit intelligence platform consisting of two dedicated Flutter mobile applications backed by **Supabase (PostgreSQL + PostGIS + Realtime + Edge Functions)** and **CesiumJS 3D**.

---

## 🏛 System Architecture

```mermaid
flowchart TB
    subgraph Drivers["Driver Mobile Ecosystem"]
        DA["Driver App (Flutter)"]
        D_GPS["Foreground GPS Service\n(geolocator)"]
        D_MAP["Cesium 3D Globe View"]
        D_MODAL["Headcount Entry Modal"]
    end

    subgraph Backend["Supabase Backend (PostgreSQL + PostGIS)"]
        AUTH["Supabase Auth\n(Drivers & Students)"]
        DB_TRIPS["trips & bus_positions"]
        DB_BOARDING["stop_boardings & occupancy"]
        POSTGIS["PostGIS Geofence Trigger\nST_DWithin(bus, stop)"]
        DB_EVENTS["stop_events (arrived / departed)"]
        REALTIME["Supabase Realtime\n(WebSocket Replication)"]
        EDGE["Edge Function\n(send-push / FCM)"]
    end

    subgraph Students["Student Mobile Ecosystem"]
        SA["Student App (Flutter)"]
        S_MAP["Cesium 3D Satellite Map"]
        S_REC["Load-Balancing Recommender"]
        S_SUB["Route Subscriptions"]
        S_RADAR["Proximity Radar Alerts"]
    end

    %% Driver connections
    DA -->|Logs in & assigns bus| AUTH
    D_GPS -->|Uploads pings & current pos| DB_TRIPS
    D_MODAL -->|Logs headcounts| DB_BOARDING
    POSTGIS -->|Fires on pos update| DB_EVENTS
    DB_EVENTS -.->|Realtime trigger| D_MODAL

    %% Student connections
    SA -->|Auth / Guest session| AUTH
    REALTIME -.->|Live positions, status & occupancy| SA
    REALTIME -.->|Arrival alerts| S_RADAR
    SA -->|Manages subscriptions| S_SUB
    DB_EVENTS -->|Status change triggers push| EDGE
    EDGE -->|FCM Notifications| SA
```

---

## 📱 Sub-Applications

| Application | Directory | Target Users | Key Capabilities |
|---|---|---|---|
| **Driver App** | [`driver_app/`](file:///c:/Users/neil-/Projects/FOAI-Project/driver_app) | Bus Drivers | Background GPS broadcast, ongoing foreground notification, route stop visualization, automated PostGIS geofence arrival detection, and boarding headcount numpad. |
| **Student App** | [`student_app/`](file:///c:/Users/neil-/Projects/FOAI-Project/student_app) | Students & Staff | Realtime 3D Cesium satellite map, zero-polling bus tracking, live occupancy percentages, smart load-balancing transfer suggestions, route timeline, and arrival alerts. |

---

## 🗃 Backend Database & SQL Modules

All schema definitions, PostGIS spatial queries, and triggers are located in the repository root:

- **[`schema.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/schema.sql)**: Core data schema including PostGIS extension setup, `users`, `routes`, `stops`, `buses`, `driver_bus_assignments`, `trips`, `stop_boardings`, `location_pings`, `bus_positions`, `stop_events`, and Row Level Security (RLS) policies.
- **[`geofence_trigger.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/geofence_trigger.sql)**: PL/pgSQL function `handle_bus_position_update()` attached to `bus_positions`. Executes `ST_DWithin` geodetic distance checks in meters against route stops, automatically inserting `arrived`/`departed` events into `stop_events` and computing delay metrics (`on_time`, `late`, `arrived`).
- **[`occupancy_trigger.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/occupancy_trigger.sql)**: Automatically increments `trips.current_occupancy` whenever drivers submit new entries into `stop_boardings`.
- **[`notification_setup.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/notification_setup.sql)**: Push notification infrastructure defining `user_devices` (FCM tokens), `route_subscriptions`, and a trigger that invokes the `send-push` Edge Function when bus status changes.
- **[`seed_data.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/seed_data.sql)**: Sample routes, stops, and buses for Bangalore transit corridors (Route A - Electronic City, Route B - Whitefield, Route C - Koramangala).
- **[`update_schema.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/update_schema.sql)**: Enables Supabase Realtime publication for `bus_positions`, `trips`, `stop_events`, and `stops`.
- **[`fix_rls.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/fix_rls.sql)** & **[`fix_student_role.sql`](file:///c:/Users/neil-/Projects/FOAI-Project/fix_student_role.sql)**: Patches for driver bus assignment upserts and student role validation.

---

## ⚡ Edge Functions

- **[`supabase/functions/send-push/`](file:///c:/Users/neil-/Projects/FOAI-Project/supabase/functions/send-push)**: Deno TypeScript edge function that exchanges service account credentials for Google OAuth2 tokens and dispatches Firebase Cloud Messaging (FCM) push notifications to subscribed students.

---

## 🛠 Quick Start Guide

### 1. Backend Setup (Supabase)
1. Create a Supabase project at [supabase.com](https://supabase.com).
2. In the Supabase SQL Editor, execute the following SQL scripts in order:
   - `schema.sql`
   - `geofence_trigger.sql`
   - `occupancy_trigger.sql`
   - `notification_setup.sql`
   - `update_schema.sql`
   - `fix_rls.sql`
   - `fix_student_role.sql`
   - `seed_data.sql`
3. Retrieve your **Project URL** and **Anon Public Key** from Project Settings > API.

### 2. Configure Environment Variables
Create a `.env` file inside both `driver_app/` and `student_app/`:

```env
Api_url=https://YOUR_SUPABASE_PROJECT_ID.supabase.co
Anon_key=YOUR_SUPABASE_ANON_KEY
CESIUM_ION_ACCESS_TOKEN=YOUR_OPTIONAL_CESIUM_ION_ACCESS_TOKEN
```

### 3. Running the Driver App
```bash
cd driver_app
flutter pub get
flutter run
```
*Read full documentation at [`driver_app/README.md`](file:///c:/Users/neil-/Projects/FOAI-Project/driver_app/README.md).*

### 4. Running the Student App
```bash
cd student_app
flutter pub get
flutter run
```
*Read full documentation at [`student_app/README.md`](file:///c:/Users/neil-/Projects/FOAI-Project/student_app/README.md).*
