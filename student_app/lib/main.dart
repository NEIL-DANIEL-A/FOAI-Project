import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint('dotenv load failed: $e');
  }

  final supabaseUrl = dotenv.env['Api_url'] ?? '';
  final supabaseAnonKey = dotenv.env['Anon_key'] ?? '';

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }

  try {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  } catch (e) {
    debugPrint('Supabase initialization failed: $e');
  }

  runApp(const StudentApp());
}

class StudentApp extends StatelessWidget {
  const StudentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'College Bus Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F172A),
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const LiveMapScreen(),
    );
  }
}

// ── Data models ──────────────────────────────────────────────────────────────

class BusInfo {
  final String tripId;
  final String busNumber;
  final String routeName;
  final int capacity;
  final int currentOccupancy;
  final String runningStatus;
  final double lat;
  final double lon;

  BusInfo({
    required this.tripId,
    required this.busNumber,
    required this.routeName,
    required this.capacity,
    required this.currentOccupancy,
    required this.runningStatus,
    required this.lat,
    required this.lon,
  });

  double get occupancyPct => capacity > 0 ? currentOccupancy / capacity : 0;

  BusInfo copyWith({double? lat, double? lon, int? currentOccupancy, String? runningStatus}) {
    return BusInfo(
      tripId: tripId,
      busNumber: busNumber,
      routeName: routeName,
      capacity: capacity,
      currentOccupancy: currentOccupancy ?? this.currentOccupancy,
      runningStatus: runningStatus ?? this.runningStatus,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
    );
  }
}

class StopInfo {
  final String name;
  final double lat;
  final double lon;

  StopInfo({required this.name, required this.lat, required this.lon});
}

// ── Live Map Screen ──────────────────────────────────────────────────────────

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();

  final Map<String, BusInfo> _buses = {};
  List<StopInfo> _stops = [];
  bool _isLoading = true;
  bool _bannerDismissed = false;
  RealtimeChannel? _busPositionsSub;
  RealtimeChannel? _tripsSub;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _busPositionsSub?.unsubscribe();
    _tripsSub?.unsubscribe();
    super.dispose();
  }

  // ── Initial data load ────────────────────────────────────────────────────

  Future<void> _loadData() async {
    try {
      // Active trips with bus + route info
      final trips = await _supabase
          .from('trips')
          .select('id, bus_id, route_id, running_status, current_occupancy, buses(bus_number, capacity), routes(name)')
          .eq('status', 'in_progress');

      // Current positions
      final positions = await _supabase.from('bus_positions').select('trip_id, bus_id, lat, lon');

      // Stops
      final stops = await _supabase.from('stops').select('name, lat, lon').order('sequence_no');

      final posByTrip = {for (final p in positions) p['trip_id'] as String: p};

      for (final trip in trips) {
        final bus = trip['buses'] as Map<String, dynamic>;
        final route = trip['routes'] as Map<String, dynamic>;
        final pos = posByTrip[trip['id'] as String];
        if (pos == null) continue;

        final tripId = trip['id'] as String;
        _buses[tripId] = BusInfo(
          tripId: tripId,
          busNumber: bus['bus_number'] as String,
          routeName: route['name'] as String,
          capacity: (bus['capacity'] as num?)?.toInt() ?? 0,
          currentOccupancy: (trip['current_occupancy'] as num?)?.toInt() ?? 0,
          runningStatus: (trip['running_status'] as String?) ?? 'on_time',
          lat: (pos['lat'] as num).toDouble(),
          lon: (pos['lon'] as num).toDouble(),
        );
      }

      _stops = stops
          .map((s) => StopInfo(
                name: s['name'] as String,
                lat: (s['lat'] as num).toDouble(),
                lon: (s['lon'] as num).toDouble(),
              ))
          .toList();

      _subscribeToRealtime();
      _setupFCM();
    } catch (e) {
      debugPrint('Load failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Supabase Realtime (native channel API) ───────────────────────────────

  void _subscribeToRealtime() {
    _busPositionsSub = _supabase
        .channel('public:bus_positions')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bus_positions',
          callback: (payload) {
            final rec = payload.newRecord;
            if (rec.isEmpty) return;
            final tripId = rec['trip_id'] as String?;
            if (tripId == null) return;
            final bus = _buses[tripId];
            if (bus == null) return;

            _buses[tripId] = bus.copyWith(
              lat: (rec['lat'] as num).toDouble(),
              lon: (rec['lon'] as num).toDouble(),
            );
            if (mounted) setState(() {});
          },
        )
        .subscribe();

    _tripsSub = _supabase
        .channel('public:trips')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'trips',
          callback: (payload) {
            final rec = payload.newRecord;
            final tripId = rec['id'] as String?;
            if (tripId == null) return;
            final bus = _buses[tripId];
            if (bus == null) return;

            _buses[tripId] = bus.copyWith(
              currentOccupancy: (rec['current_occupancy'] as num?)?.toInt(),
              runningStatus: rec['running_status'] as String?,
            );
            if (mounted) setState(() {});
          },
        )
        .subscribe();
  }

  // ── FCM setup ────────────────────────────────────────────────────────────

  Future<void> _setupFCM() async {
    try {
      final messaging = FirebaseMessaging.instance;

      // Request permission (iOS + Android 13+)
      await messaging.requestPermission(alert: true, badge: true, sound: true);

    // Get token
    final token = await messaging.getToken();
    if (token != null) await _registerDevice(token);

    // Refresh on token rotation
    messaging.onTokenRefresh.listen(_registerDevice);

    // Foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification == null) return;
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${notification.title ?? ''} ${notification.body ?? ''}'.trim()),
        backgroundColor: const Color(0xFF1E293B),
        behavior: SnackBarBehavior.floating,
      ));
    });

    // Tap on notification when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      // Could navigate to specific route — for now just opens the app
    });
    } catch (e) {
      debugPrint('FCM setup failed (likely Firebase not initialized): $e');
    }
  }

  Future<void> _registerDevice(String token) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      await _supabase.from('user_devices').upsert({
        if (userId != null) 'user_id': userId,
        'fcm_token': token,
      }, onConflict: 'fcm_token');
    } catch (e) {
      debugPrint('Failed to register device: $e');
    }
  }

  Future<void> _toggleRouteSubscription(String routeId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final existing = await _supabase
          .from('route_subscriptions')
          .select('id')
          .eq('user_id', userId)
          .eq('route_id', routeId)
          .maybeSingle();

      if (existing != null) {
        await _supabase.from('route_subscriptions').delete().eq('id', existing['id'] as String);
      } else {
        await _supabase.from('route_subscriptions').insert({
          'user_id': userId,
          'route_id': routeId,
        });
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Subscription toggle failed: $e');
    }
  }

  Future<List<String>> _getSubscribedRouteIds() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return [];
    try {
      final subs = await _supabase
          .from('route_subscriptions')
          .select('route_id')
          .eq('user_id', userId);
      return subs.map((s) => s['route_id'] as String).toList();
    } catch (e) {
      return [];
    }
  }

  void _showSubscriptionSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => FutureBuilder<List<String>>(
        future: _getSubscribedRouteIds(),
        builder: (ctx, snap) {
          final subscribed = snap.data ?? [];
          return FutureBuilder(
            future: _supabase.from('routes').select('id, name').order('name'),
            builder: (ctx, routeSnap) {
              final routes = (routeSnap.data as List?)?.cast<Map<String, dynamic>>() ?? [];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF475569), borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),
                  const Text('Subscribe to Routes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF8FAFC))),
                  const SizedBox(height: 4),
                  const Text('Get notified about bus arrivals & delays', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                  const SizedBox(height: 12),
                  if (routes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No routes available', style: TextStyle(color: Color(0xFF94A3B8))),
                    )
                  else
                    ...routes.map((r) {
                      final isSub = subscribed.contains(r['id'] as String);
                      return ListTile(
                        title: Text(r['name'] as String, style: const TextStyle(color: Color(0xFFF8FAFC))),
                        trailing: Icon(
                          isSub ? Icons.notifications_active : Icons.notifications_off_outlined,
                          color: isSub ? const Color(0xFF6366F1) : const Color(0xFF64748B),
                        ),
                        onTap: () => _toggleRouteSubscription(r['id'] as String).then((_) {
                          Navigator.pop(ctx);
                          _showSubscriptionSheet();
                        }),
                      );
                    }),
                  const SizedBox(height: 20),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ── Transfer suggestions ──────────────────────────────────────────────────

  String? _transferSuggestion() {
    if (_bannerDismissed) return null;

    final byRoute = <String, List<BusInfo>>{};
    for (final b in _buses.values) {
      byRoute.putIfAbsent(b.routeName, () => []).add(b);
    }

    for (final entry in byRoute.entries) {
      if (entry.value.length < 2) continue;
      final overFull = entry.value.where((b) => b.capacity > 0 && b.occupancyPct >= 0.9).toList();
      final underUsed = entry.value.where((b) => b.capacity > 0 && b.occupancyPct <= 0.5).toList();

      for (final full in overFull) {
        for (final spare in underUsed) {
          if (full.tripId == spare.tripId) continue;
          return '${full.busNumber} on "${entry.key}" is ${(full.occupancyPct * 100).round()}% full — '
              'consider ${spare.busNumber} (${(spare.occupancyPct * 100).round()}% full)';
        }
      }
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Color _capColor(double pct) {
    if (pct >= 0.9) return const Color(0xFFEF4444);
    if (pct >= 0.7) return const Color(0xFFFACC15);
    return const Color(0xFF4ADE80);
  }

  IconData _busIcon(String status) {
    if (status == 'late') return Icons.directions_bus_filled;
    if (status == 'arrived') return Icons.check_circle;
    return Icons.directions_bus_filled;
  }

  Color _busColor(String status) {
    if (status == 'late') return const Color(0xFFEF4444);
    if (status == 'arrived') return const Color(0xFF22C55E);
    return const Color(0xFF6366F1);
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = _transferSuggestion();

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF6366F1)))
          : Stack(
              children: [
                // Map
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(12.9716, 77.5946),
                    initialZoom: 13,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c'],
                    ),
                    // Stop markers
                    MarkerLayer(
                      markers: _stops
                          .map((s) => Marker(
                                point: LatLng(s.lat, s.lon),
                                width: 10,
                                height: 10,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF475569),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF94A3B8), width: 1.5),
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                    // Bus markers
                    MarkerLayer(
                      markers: _buses.values
                          .map((b) => Marker(
                                point: LatLng(b.lat, b.lon),
                                width: 40,
                                height: 40,
                                child: GestureDetector(
                                  onTap: () => _showBusSheet(b),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _busColor(b.runningStatus),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2.5),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _busColor(b.runningStatus).withValues(alpha: 0.5),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        b.busNumber.replaceAll(RegExp(r'\D'), '').padLeft(2, '0').substring(0, 2),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  ],
                ),

                // Top bar
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 20,
                      right: 20,
                      bottom: 12,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xFF0F172A),
                          const Color(0xFF0F172A).withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF22C55E),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'College Bus Tracker',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFFF8FAFC)),
                        ),
                        const Spacer(),
                        Text(
                          '${_buses.length} bus${_buses.length == 1 ? '' : 'es'} active',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: _showSubscriptionSheet,
                          child: const Icon(Icons.notifications_outlined, color: Color(0xFF94A3B8), size: 22),
                        ),
                      ],
                    ),
                  ),
                ),

                // Transfer banner
                if (suggestion != null)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 56,
                    left: 12,
                    right: 12,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Color(0xFF1E1B4B), size: 22),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                suggestion,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1E1B4B),
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => setState(() => _bannerDismissed = true),
                              child: const Icon(Icons.close, color: Color(0xFF1E1B4B), size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Bottom bus list
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 80,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.95),
                      border: const Border(top: BorderSide(color: Color(0xFF1E293B))),
                    ),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      itemCount: _buses.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, i) {
                        final b = _buses.values.elementAt(i);
                        final pct = b.occupancyPct;
                        final capColor = _capColor(pct);

                        return GestureDetector(
                          onTap: () {
                            _mapController.move(LatLng(b.lat, b.lon), 16);
                          },
                          child: Container(
                            width: 110,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF334155)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  b.busNumber,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFF8FAFC)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  b.routeName,
                                  style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${b.currentOccupancy}/${b.capacity}',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: capColor),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Bus detail bottom sheet ───────────────────────────────────────────────

  void _showBusSheet(BusInfo bus) {
    final pct = bus.occupancyPct;
    final barColor = _capColor(pct);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF475569), borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _busColor(bus.runningStatus).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(_busIcon(bus.runningStatus), color: _busColor(bus.runningStatus), size: 24),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bus.busNumber, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFF8FAFC))),
                    Text(bus.routeName, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            _detailRow('Status', _statusLabel(bus.runningStatus)),
            const SizedBox(height: 8),
            _detailRow('Occupancy', '${bus.currentOccupancy} / ${bus.capacity}'),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct.clamp(0, 1).toDouble(),
                backgroundColor: const Color(0xFF334155),
                valueColor: AlwaysStoppedAnimation(barColor),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8))),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFF8FAFC))),
      ],
    );
  }

  String _statusLabel(String status) {
    if (status == 'late') return '🔴 Late';
    if (status == 'arrived') return '🟢 Arrived';
    return '🟢 On Time';
  }
}
