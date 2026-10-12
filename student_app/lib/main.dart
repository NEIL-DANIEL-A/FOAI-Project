import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'ai_sim_screen.dart';
import 'ai/astar.dart';
import 'ai/csp.dart';
import 'ai/demand.dart';
import 'ai/road_graph.dart';
import 'ai/route_geometry.dart';

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
        cardTheme: const CardThemeData(
          color: Color(0xFF1E293B),
          elevation: 4,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkAuthState();
  }

  Future<void> _checkAuthState() async {
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;
    if (session != null) {
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Check if student profile exists
        final profile = await supabase
            .from('users')
            .select('id')
            .eq('id', user.id)
            .eq('role', 'student')
            .maybeSingle();

        if (profile == null) {
          // Create student profile if missing
          await supabase.from('users').upsert({
            'id': user.id,
            'name': user.email?.split('@').first ?? 'Student',
            'role': 'student',
          });
        }
      } else {
        await supabase.auth.signOut();
      }
    }
    if (mounted) {
      setState(() => _checking = false);
      if (session != null && supabase.auth.currentUser != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LiveMapScreen()),
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return const LoginScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter both email and password.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.session != null) {
        // Validate student profile exists in users table
        final user = response.user;
        if (user != null) {
          final profile = await Supabase.instance.client
              .from('users')
              .select('id')
              .eq('id', user.id)
              .eq('role', 'student')
              .maybeSingle();

          if (profile == null) {
            // Create student profile if it doesn't exist
            await Supabase.instance.client.from('users').upsert({
              'id': user.id,
              'name': email.split('@').first,
              'role': 'student',
            });
          }
        }

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LiveMapScreen()),
          );
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter both email and password.';
      });
      return;
    }

    if (password.length < 6) {
      setState(() {
        _errorMessage = 'Password must be at least 6 characters.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      try {
        final response = await Supabase.instance.client.auth.signUp(
          email: email,
          password: password,
        );

        final user = response.user;
        if (user == null) throw Exception('Sign up failed');

        // Create student profile in the users table
        await Supabase.instance.client.from('users').upsert({
          'id': user.id,
          'name': email.split('@').first,
          'role': 'student',
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created! You can now sign in.'),
              backgroundColor: Color(0xFF22C55E),
            ),
          );
        }
      } catch (signUpError) {
        // If auth user already exists (e.g. profile was deleted but auth
        // record remains), sign in with the same credentials and recreate profile.
        final msg = signUpError.toString();
        if (msg.contains('already') || msg.contains('registered')) {
          final response = await Supabase.instance.client.auth.signInWithPassword(
            email: email,
            password: password,
          );
          final user = response.user;
          if (user != null) {
            // Upsert student profile in case it was deleted
            await Supabase.instance.client.from('users').upsert({
              'id': user.id,
              'name': email.split('@').first,
              'role': 'student',
            });
          }
          if (response.session != null && mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const LiveMapScreen()),
            );
          }
          return;
        }
        rethrow;
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Demo login for testing
  Future<void> _demoLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // For demo purposes, just navigate to the map
    await Future.delayed(const Duration(seconds: 1));
    
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LiveMapScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo/Icon
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.directions_bus,
                      size: 48,
                      color: Color(0xFF6366F1),
                    ),
                  ),
                  const SizedBox(height: 32),
                  
                  // Title
                  const Text(
                    'College Bus Tracker',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF8FAFC),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Track your bus in real-time',
                    style: TextStyle(
                      fontSize: 16,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Email field
                  TextField(
                    controller: _emailController,
                    decoration: InputDecoration(
                      hintText: 'Email',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.email, color: Color(0xFF64748B)),
                    ),
                    style: const TextStyle(color: Color(0xFFF8FAFC)),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16),

                  // Password field
                  TextField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      hintText: 'Password',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.lock, color: Color(0xFF64748B)),
                    ),
                    style: const TextStyle(color: Color(0xFFF8FAFC)),
                    obscureText: true,
                  ),
                  const SizedBox(height: 24),

                  // Error message
                  if (_errorMessage != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Color(0xFFEF4444), fontSize: 14),
                      ),
                    ),

                  // Sign In button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _signIn,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Sign In',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Sign Up button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      onPressed: _isLoading ? null : _signUp,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF64748B)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Create Account',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF8FAFC),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Demo button
                  TextButton(
                    onPressed: _isLoading ? null : _demoLogin,
                    child: const Text(
                      'Continue as Guest (Demo)',
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}

class BusInfo {
  final String tripId;
  final String busId;
  final String slotId;
  final String busNumber;
  final String routeId;
  final String routeName;
  final int capacity;
  final int currentOccupancy;
  final String runningStatus;
  final double lat;
  final double lon;

  BusInfo({
    required this.tripId,
    this.busId = '',
    this.slotId = '',
    required this.busNumber,
    required this.routeId,
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
      busId: busId,
      slotId: slotId,
      busNumber: busNumber,
      routeId: routeId,
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
  final String id;
  final String routeId;
  final String name;
  final double lat;
  final double lon;
  final int membersCount;
  final int sequence;

  StopInfo({
    required this.id,
    required this.routeId,
    required this.name,
    required this.lat,
    required this.lon,
    this.membersCount = 0,
    this.sequence = 0,
  });
}

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _supabase = Supabase.instance.client;

  WebViewController? _webViewController;
  final Map<String, BusInfo> _buses = {};
  final Set<String> _displayedBusIds = {};
  List<StopInfo> _stops = [];
  bool _bannerDismissed = false;
  bool _mapReady = false;
  bool _isLoadingData = true;
  bool _isLocatingUser = false;
  bool _autoLocated = false;
  String? _loadingError;
  String? _trackingTripId;
  RealtimeChannel? _busPositionsSub;
  RealtimeChannel? _tripsSub;
  RealtimeChannel? _stopsSub;
  RealtimeChannel? _stopEventsSub;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    final cesiumToken = dotenv.env['CESIUM_ION_ACCESS_TOKEN'] ?? '';
    debugPrint('Cesium Ion token loaded: ${cesiumToken.isNotEmpty ? "yes (${cesiumToken.length} chars)" : "NO - token is empty!"}');

    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Register JS channel BEFORE loading so it's available the moment the page runs
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage msg) {
          debugPrint('JS channel: ${msg.message}');
          if (msg.message.contains('"type":"ready"')) {
            debugPrint('Cesium map ready');
            if (mounted) {
              setState(() {
                _mapReady = true;
                _loadingError = null;
              });
              _syncMarkersToMap();
            }
          } else if (msg.message.contains('"type":"clickBus"')) {
            try {
              final data = jsonDecode(msg.message);
              final String? tripId = data['id'];
              if (tripId != null && mounted) {
                final bus = _buses[tripId];
                if (bus != null) {
                  _showBusDetails(bus);
                }
              }
            } catch (e) {
              debugPrint('Error parsing clickBus message: $e');
            }
          }
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          debugPrint('Cesium map page started loading');
        },
        onPageFinished: (_) {
          debugPrint('Cesium map page finished loading');
          // Send init token to Cesium after the page loads.
          // The HTML page waits for the CesiumJS library to be available
          // before actually initializing, so timing is no longer an issue.
          final escapedToken = cesiumToken.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
          final initMsg = '{"type":"init","token":"$escapedToken"}';
          debugPrint('Sending init to Cesium (token present: ${cesiumToken.isNotEmpty})');
          _webViewController!.runJavaScript("handleMessage($initMsg)");

          // Timeout fallback in case Cesium never fires 'ready'
          Timer(const Duration(seconds: 20), () {
            if (mounted && !_mapReady) {
              debugPrint('Cesium init timed out - showing anyway');
              setState(() {
                _mapReady = true;
                _loadingError = null;
              });
              _syncMarkersToMap();
            }
          });
        },
        onWebResourceError: (error) {
          debugPrint('WebView error: ${error.description} (isMainFrame: ${error.isForMainFrame})');
          // Only show error overlay for main frame failures, not subresource loads
          // (CDN tiles, favicons, etc. often fail transiently without affecting the map)
          if (mounted && (error.isForMainFrame == true)) {
            setState(() {
              _mapReady = true;
              _loadingError = 'Map loading failed: ${error.description}';
            });
          }
        },
      ));

    // Apply Android-specific settings
    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidController =
          _webViewController!.platform as AndroidWebViewController;
      // Allow mixed HTTP/HTTPS content (Cesium CDN is HTTPS but some tiles may be HTTP)
      androidController.setMixedContentMode(MixedContentMode.alwaysAllow);
      // Allow file access for local assets
      androidController.setAllowFileAccess(true);
      androidController.setAllowContentAccess(true);
    }

    // Load the HTML file as a string with a https base URL.
    // This is the key fix: Android WebView blocks cross-origin fetch/XHR from
    // file:// pages. By loading the HTML content with baseUrl='https://localhost',
    // the WebView treats the page as HTTPS, so Cesium CDN requests are same-scheme
    // and go through without cross-origin blocks.
    _loadCesiumHtml();

    _loadData();
  }

  Future<void> _loadCesiumHtml() async {
    try {
      // rootBundle works without needing a BuildContext and is safe to call anywhere
      final htmlContent = await rootBundle.loadString('web/cesium/map.html');
      await _webViewController!
          .loadHtmlString(htmlContent, baseUrl: 'https://localhost');
    } catch (e) {
      debugPrint('Failed to load Cesium HTML as string: $e');
      // Fallback to direct asset load
      await _webViewController!.loadFlutterAsset('web/cesium/map.html');
    }
  }

  void _sendToMap(String json) {
    if (_webViewController == null || !_mapReady) return;
    try {
      _webViewController!.runJavaScript("handleMessage($json)");
    } catch (e) {
      debugPrint('Error sending to map: $e');
    }
  }

  String _enc(Map<String, dynamic> map) {
    final parts = <String>[];
    for (final e in map.entries) {
      final v = e.value;
      if (v is String) {
        parts.add('"${e.key}":"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"');
      } else {
        parts.add('"${e.key}":$v');
      }
    }
    return '{${parts.join(',')}}';
  }

  void _syncMarkersToMap() {
    if (!_mapReady || _webViewController == null) return;
    final currentBusIds = <String>{};

    for (final bus in _buses.values) {
      currentBusIds.add(bus.tripId);
      if (!_displayedBusIds.contains(bus.tripId)) {
        _sendToMap(_enc({
          'type': 'addBus',
          'id': bus.tripId,
          'lat': bus.lat,
          'lon': bus.lon,
          'busNumber': bus.busNumber,
          'status': bus.runningStatus,
        }));
      } else {
        _sendToMap(_enc({'type': 'updateBusPosition', 'id': bus.tripId, 'lat': bus.lat, 'lon': bus.lon}));
        _sendToMap(_enc({'type': 'updateBusStatus', 'id': bus.tripId, 'status': bus.runningStatus}));
      }
    }

    for (final removedId in _displayedBusIds.difference(currentBusIds)) {
      _sendToMap(_enc({'type': 'removeBus', 'id': removedId}));
    }
    _displayedBusIds.clear();
    _displayedBusIds.addAll(currentBusIds);

    for (int i = 0; i < _stops.length; i++) {
      _sendToMap(_enc({
        'type': 'addStop',
        'id': _stops[i].id,
        'lat': _stops[i].lat,
        'lon': _stops[i].lon,
        'name': _stops[i].name,
        'membersCount': _stops[i].membersCount,
      }));
    }

    // Auto-locate user on first sync
    if (!_autoLocated) {
      _autoLocated = true;
      _locateMe();
    }
  }

  Future<void> _upsertActiveTrip(String tripId) async {
    final trip = await _supabase
        .from('trips')
        .select(
          'id, status, bus_id, route_id, slot_id, running_status, current_occupancy, '
          'buses(bus_number, capacity), routes(name)',
        )
        .eq('id', tripId)
        .maybeSingle();

    if (trip == null) {
      _removeTripFromMap(tripId);
      return;
    }

    if (trip['status'] != 'in_progress') {
      _removeTripFromMap(tripId);
      return;
    }

    final bus = trip['buses'] as Map<String, dynamic>?;
    final route = trip['routes'] as Map<String, dynamic>?;
    if (bus == null || route == null) {
      return;
    }

    final pos = await _supabase
        .from('bus_positions')
        .select('lat, lon')
        .eq('trip_id', tripId)
        .maybeSingle();
    if (pos == null) {
      return;
    }

    _buses[tripId] = BusInfo(
      tripId: tripId,
      busId: (trip['bus_id'] as String?) ?? '',
      slotId: (trip['slot_id'] as String?) ?? '',
      busNumber: bus['bus_number'] as String,
      routeId: trip['route_id'] as String,
      routeName: route['name'] as String,
      capacity: (bus['capacity'] as num?)?.toInt() ?? 0,
      currentOccupancy: (trip['current_occupancy'] as num?)?.toInt() ?? 0,
      runningStatus: (trip['running_status'] as String?) ?? 'on_time',
      lat: (pos['lat'] as num).toDouble(),
      lon: (pos['lon'] as num).toDouble(),
    );
    _loadAssignments();
  }

  void _removeTripFromMap(String tripId) {
    _buses.remove(tripId);
    _displayedBusIds.remove(tripId);
    _sendToMap(_enc({'type': 'removeBus', 'id': tripId}));
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    
    setState(() {
      _isLoadingData = true;
      _loadingError = null;
    });

    try {
      debugPrint('Loading trips data...');
      
      // Load trips with related data
      final trips = await _supabase
          .from('trips')
          .select('id, bus_id, route_id, slot_id, running_status, current_occupancy, buses(bus_number, capacity), routes(name)')
          .eq('status', 'in_progress');

      debugPrint('Loaded ${trips.length} trips');

      // Load bus positions
      final positions = await _supabase.from('bus_positions').select('trip_id, bus_id, lat, lon');
      debugPrint('Loaded ${positions.length} positions');

      // Load stops
      final stops = await _supabase.from('stops').select('id, route_id, name, lat, lon, sequence_no').order('sequence_no');
      debugPrint('Loaded ${stops.length} stops');

      final posByTrip = {for (final p in positions) p['trip_id'] as String: p};

      _buses.clear();
      
      // Process real data first
      for (final trip in trips) {
        try {
          final bus = trip['buses'] as Map<String, dynamic>?;
          final route = trip['routes'] as Map<String, dynamic>?;
          final pos = posByTrip[trip['id'] as String];
          
          if (bus == null || route == null || pos == null) {
            debugPrint('Skipping trip ${trip['id']} - missing data');
            continue;
          }

          final tripId = trip['id'] as String;
          _buses[tripId] = BusInfo(
            tripId: tripId,
            busId: (trip['bus_id'] as String?) ?? '',
            slotId: (trip['slot_id'] as String?) ?? '',
            busNumber: bus['bus_number'] as String,
            routeId: trip['route_id'] as String,
            routeName: route['name'] as String,
            capacity: (bus['capacity'] as num?)?.toInt() ?? 0,
            currentOccupancy: (trip['current_occupancy'] as num?)?.toInt() ?? 0,
            runningStatus: (trip['running_status'] as String?) ?? 'on_time',
            lat: (pos['lat'] as num).toDouble(),
            lon: (pos['lon'] as num).toDouble(),
          );
        } catch (e) {
          debugPrint('Error processing trip ${trip['id']}: $e');
        }
      }

      // Only show real live active buses.

      _stops = stops
          .map((s) {
            try {
              return StopInfo(
                id: s['id'] as String,
                routeId: s['route_id'] as String,
                name: s['name'] as String,
                lat: (s['lat'] as num).toDouble(),
                lon: (s['lon'] as num).toDouble(),
                membersCount: 0,
                sequence: (s['sequence_no'] as num?)?.toInt() ?? 0,
              );
            } catch (e) {
              debugPrint('Error processing stop: $e');
              return null;
            }
          })
          .where((stop) => stop != null)
          .cast<StopInfo>()
          .toList();

      // If no stops, add sample stops
      if (_stops.isEmpty) {
        debugPrint('No stops found, adding sample stops for demo');
        _addSampleStops();
      }

      debugPrint('Processed ${_buses.length} buses and ${_stops.length} stops');

      _subscribeToRealtime();
      _loadAssignments();

      // Only show real active movements.

      if (mounted) {
        setState(() {
          _isLoadingData = false;
        });
        _syncMarkersToMap();
      }
    } catch (e) {
      debugPrint('Load failed: $e');
      if (mounted) {
        setState(() {
          _isLoadingData = false;
          _loadingError = 'Failed to load live data: $e';
        });
      }
    }
  }

  void _addSampleStops() {
    _stops = [
      StopInfo(id: 'demo_stop_1', routeId: 'demo_route', name: 'Electronic City', lat: 12.8456, lon: 77.6603, membersCount: 12),
      StopInfo(id: 'demo_stop_2', routeId: 'demo_route', name: 'Silk Board', lat: 12.9180, lon: 77.6220, membersCount: 8),
      StopInfo(id: 'demo_stop_3', routeId: 'demo_route', name: 'Koramangala', lat: 12.9352, lon: 77.6245, membersCount: 15),
      StopInfo(id: 'demo_stop_4', routeId: 'demo_route', name: 'Indiranagar', lat: 12.9719, lon: 77.6412, membersCount: 3),
      StopInfo(id: 'demo_stop_5', routeId: 'demo_route', name: 'Whitefield', lat: 12.9698, lon: 77.7500, membersCount: 0),
    ];
  }

  Timer? _demoTimer;
  bool _demoActive = false;
  bool _demoDialogOpen = false;
  int _demoStep = 0;
  int _demoOccupancy = 0;
  String _demoStatus = 'on_time';
  String _demoBusNumber = '';
  String _demoRouteId = '';
  String _demoRouteName = '';
  int _demoCapacity = 40;
  List<StopInfo> _demoStops = [];

  static const int _demoStepsPerLeg = 6;

  /// Full-feature demo for ANY bus in the database: pick a bus, watch it
  /// drive its real route, get student arrival alerts, enter headcounts in
  /// the driver-style pad, and see occupancy update for students.
  void _showDemoBusPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => FutureBuilder(
        future: Future.wait([
          _supabase.from('routes').select('id, name').order('name'),
          _supabase.from('buses').select('id, bus_number, route_id, capacity').order('bus_number'),
        ]),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator(color: Color(0xFF6366F1))),
            );
          }
          if (snap.hasError || !snap.hasData) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Couldn\'t load buses from the database.',
                    style: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Check internet, or preview with the sample route.',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _startSampleDemo();
                    },
                    child: const Text('Demo with sample route'),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          }
          final routes = (snap.data![0] as List).cast<Map<String, dynamic>>();
          final buses = (snap.data![1] as List).cast<Map<String, dynamic>>();
          final routeName = {for (final r in routes) r['id'] as String: r['name'] as String};
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF475569),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Demo a bus',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFF8FAFC)),
              ),
              const SizedBox(height: 4),
              const Text(
                'Pick any bus - arrivals, headcount & occupancy play out live',
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in buses)
                      ListTile(
                        leading: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            b['bus_number'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF6366F1)),
                          ),
                        ),
                        title: Text(
                          routeName[b['route_id']] ?? 'Unknown route',
                          style: const TextStyle(color: Color(0xFFF8FAFC)),
                        ),
                        subtitle: Text(
                          'Capacity ${b['capacity'] ?? '-'}',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        ),
                        trailing: const Icon(Icons.play_circle_outline, color: Color(0xFF94A3B8)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _startDemoForBus(
                            busId: b['id'] as String,
                            busNumber: b['bus_number'] as String,
                            routeId: b['route_id'] as String,
                            routeName: routeName[b['route_id']] ?? 'Demo Route',
                            capacity: (b['capacity'] as num?)?.toInt() ?? 40,
                          );
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }

  /// Fallback demo when the database can't be reached.
  void _startSampleDemo() {
    _addSampleStops();
    _beginDemoTrip(
      busNumber: 'DEMO',
      routeId: _stops.first.routeId,
      routeName: 'Sample Route',
      capacity: 40,
      stops: List.of(_stops),
    );
  }

  Future<void> _startDemoForBus({
    required String busId,
    required String busNumber,
    required String routeId,
    required String routeName,
    required int capacity,
  }) async {
    var stops = _stops.where((s) => s.routeId == routeId).toList();
    if (stops.isEmpty) {
      try {
        final data = await _supabase
            .from('stops')
            .select('id, route_id, name, lat, lon, sequence_no')
            .eq('route_id', routeId)
            .order('sequence_no');
        stops = (data as List)
            .map((s) => StopInfo(
                  id: s['id'] as String,
                  routeId: s['route_id'] as String,
                  name: s['name'] as String,
                  lat: (s['lat'] as num).toDouble(),
                  lon: (s['lon'] as num).toDouble(),
                  sequence: (s['sequence_no'] as num?)?.toInt() ?? 0,
                ))
            .toList();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Couldn\'t load stops: $e')),
          );
        }
        return;
      }
    }
    if (stops.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This route needs at least 2 stops for a demo.')),
        );
      }
      return;
    }
    // AI: run the REAL CSP for this route's slot so the demo bus serves its
    // assigned stops (skipping the rest) instead of visiting everything.
    // May narrow [stops] down to this bus's share.
    final assigned = await _prepareDemoCsp(
      busId: busId,
      busNumber: busNumber,
      routeId: routeId,
      stops: stops,
    );
    _beginDemoTrip(
      busNumber: busNumber,
      routeId: routeId,
      routeName: routeName,
      capacity: capacity,
      stops: assigned,
    );
  }

  // ---------- AI demo: CSP assignment + Google-style route overlay ----------
  // Same CspAssignmentService / AStarService the live apps and the 🧠 screen use.
  int _demoTargetIdx = 0;
  String _demoSlotLabel = '';
  String _demoServeText = '';
  String _demoSkipText = '';
  String _demoCspLine = '';
  String _demoLegLine = '';
  final Map<String, List<List<double>>> _demoGeoCache = {};

  /// Runs CSP for the picked bus's slot. Returns the stops THIS bus serves
  /// (ordered); the rest are shown as skips in the overlay card.
  Future<List<StopInfo>> _prepareDemoCsp({
    required String busId,
    required String busNumber,
    required String routeId,
    required List<StopInfo> stops,
  }) async {
    _demoSlotLabel = '';
    _demoServeText = stops.map((s) => s.name).join('→');
    _demoSkipText = '';
    _demoCspLine = 'No slot plan — serving all stops';
    try {
      // Slot containing this bus, else the route's first active slot.
      final slots = await _supabase
          .from('operating_slots')
          .select('id, label')
          .eq('route_id', routeId)
          .eq('is_active', true)
          .order('slot_time');
      if ((slots as List).isEmpty) return stops;
      var slotId = slots.first['id'] as String;
      _demoSlotLabel = slots.first['label'] as String? ?? '';
      for (final s in slots) {
        final has = await _supabase
            .from('slot_buses')
            .select('bus_id')
            .eq('slot_id', s['id'])
            .eq('bus_id', busId)
            .maybeSingle();
        if (has != null) {
          slotId = s['id'] as String;
          _demoSlotLabel = s['label'] as String? ?? '';
          break;
        }
      }
      final poolRows = await _supabase
          .from('slot_buses')
          .select('bus_id, is_available, buses(bus_number, capacity)')
          .eq('slot_id', slotId);
      // Demand: real history when it exists, else labeled sample demand.
      final since = DateTime.now().subtract(const Duration(days: 14)).toIso8601String().split('T')[0];
      final ids = stops.map((s) => s.id).toList();
      var grouped = <String, List<BoardingSample>>{};
      try {
        final rows = await _supabase
            .from('stop_boardings')
            .select('stop_id, boarding_count, recorded_at')
            .inFilter('stop_id', ids)
            .gte('recorded_at', since);
        grouped = DemandEstimationService.group(
          (rows as List).cast<Map<String, dynamic>>(),
          stopIdKey: 'stop_id',
          countKey: 'boarding_count',
          dateKey: 'recorded_at',
        );
      } catch (_) {}
      for (final s in stops) {
        grouped.putIfAbsent(s.id, () => []);
      }
      final totalSamples = grouped.values.fold(0, (a, l) => a + l.length);
      const sample = [10.0, 8.0, 15.0, 5.0, 12.0, 7.0, 9.0, 6.0, 11.0, 8.0];
      final demand = <String, double>{};
      final String demandNote;
      if (totalSamples == 0) {
        for (var i = 0; i < stops.length; i++) {
          demand[stops[i].id] = sample[i % sample.length];
        }
        demandNote = 'sample demand';
      } else {
        final est = DemandEstimationService.estimate(grouped, safetyFactor: 1.1);
        for (final s in stops) {
          demand[s.id] = est[s.id]!.expected;
        }
        demandNote = 'history ×1.1';
      }
      final cspStops = [
        for (final s in stops)
          CspStop(id: s.id, label: s.name, demand: demand[s.id]!, sequence: s.sequence),
      ];
      final cspBuses = <CspBus>[
        for (final r in (poolRows as List))
          CspBus(
            id: r['bus_id'] as String,
            label: '${(r['buses'] as Map<String, dynamic>?)?['bus_number'] ?? '?'}',
            capacity: ((r['buses'] as Map<String, dynamic>?)?['capacity'] as num?)?.toInt() ?? 40,
            available: (r['is_available'] as bool?) ?? true,
          ),
      ];
      final result = const CspAssignmentService().solve(stops: cspStops, buses: cspBuses);
      if (result.feasible && result.best != null) {
        final best = result.best!;
        final byId = {for (final s in stops) s.id: s};
        final mine = best.assignment.entries
            .where((e) => e.value == busId)
            .map((e) => e.key)
            .where((id) => byId.containsKey(id))
            .toList()
          ..sort((a, b) => byId[a]!.sequence.compareTo(byId[b]!.sequence));
        if (mine.isNotEmpty) {
          final labelOf = {for (final b in cspBuses) b.id: b.label};
          final skipByBus = <String, List<String>>{};
          for (final e in best.assignment.entries) {
            if (e.value != busId && byId.containsKey(e.key)) {
              skipByBus.putIfAbsent(labelOf[e.value] ?? '?', () => []).add(byId[e.key]!.name);
            }
          }
          final served = [for (final id in mine) byId[id]!];
          _demoServeText = served.map((s) => s.name).join('→');
          _demoSkipText =
              skipByBus.entries.map((e) => '${e.value.join(', ')} → Bus ${e.key}').join(' • ');
          _demoCspLine =
              'CSP ($demandNote): ${result.assignmentsTried} tried • ${result.backtracks} backtracks • score ${best.score.toStringAsFixed(2)}';
          if (mounted) setState(() {});
          return served;
        }
      }
    } catch (e) {
      debugPrint('Demo CSP fallback (all stops): $e');
    }
    if (mounted) setState(() {});
    return stops;
  }

  /// Next assigned stop the bus is heading to (advanced on every dialog close).
  StopInfo? _demoNextStop() {
    if (_demoStops.isEmpty) return null;
    return _demoStops[_demoTargetIdx.clamp(0, _demoStops.length - 1)];
  }

  String? _storedPrefix(RoadGraph g, String a, String b) {
    for (final e in [...g.adjacency[a] ?? [], ...g.adjacency[b] ?? []]) {
      if ((e.from == a && e.to == b) || (e.from == b && e.to == a)) {
        return e.id.split(':').first;
      }
    }
    return null;
  }

  Future<List<List<double>>> _demoGeometry(String key, List<List<double>> straight) async {
    final hit = _demoGeoCache[key];
    if (hit != null) return hit;
    final geo = await RouteGeometry.fetchRoadPath(straight);
    _demoGeoCache[key] = geo;
    return geo;
  }

  void _sendDemoPath(String id, List<List<double>> pts, String color, int width) {
    if (_webViewController == null || !_mapReady || pts.length < 2) return;
    final sb = StringBuffer('{"type":"drawPath","id":"$id","color":"$color","width":$width,"points":[');
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) sb.write(',');
      sb.write('[${pts[i][0]},${pts[i][1]}]');
    }
    sb.write(']}');
    try {
      _webViewController!.runJavaScript('handleMessage(${sb.toString()})');
    } catch (e) {
      debugPrint('Demo path draw failed: $e');
    }
  }

  /// Google-Maps-style overlay for the current leg: A* best route in blue,
  /// the next-best alternative in gray, both road-snapped. Runs the REAL
  /// AStarService on the full route road network.
  Future<void> _refreshDemoRouteOverlay() async {
    if (!_demoActive || _demoStops.length < 2) return;
    try {
      final routeStops = _stops.where((s) => s.routeId == _demoRouteId).toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      if (routeStops.length < 2) return;
      final graph = RoadGraph.fromStops([
        for (final s in routeStops)
          GraphStop(id: s.id, name: s.name, lat: s.lat, lon: s.lon, sequence: s.sequence),
      ]);
      final cur = _buses['demo-trip'];
      final next = _demoNextStop();
      if (cur == null || next == null) return;
      // Already at the final stop: nothing left to route.
      if (_demoTargetIdx >= _demoStops.length - 1 &&
          RoadGraph.haversineM(cur.lat, cur.lon, next.lat, next.lon) < 80) {
        _sendToMap(_enc({'type': 'clearPath', 'id': 'demo-best'}));
        _sendToMap(_enc({'type': 'clearPath', 'id': 'demo-alt'}));
        return;
      }
      // Temporary start node at the live demo position.
      const gpsId = 'demo-gps';
      graph.addNode(RoadNode(id: gpsId, label: 'Bus $_demoBusNumber', lat: cur.lat, lon: cur.lon));
      final byDist = List<StopInfo>.of(routeStops)
        ..sort((a, b) => RoadGraph.haversineM(cur.lat, cur.lon, a.lat, a.lon)
            .compareTo(RoadGraph.haversineM(cur.lat, cur.lon, b.lat, b.lon)));
      for (var i = 0; i < (byDist.length < 2 ? byDist.length : 2); i++) {
        final d = RoadGraph.haversineM(cur.lat, cur.lon, byDist[i].lat, byDist[i].lon);
        graph.addUndirectedEdge(
          id: 'demo-link:$i',
          a: gpsId,
          b: 'stop:${byDist[i].id}',
          cost: d / 8.0,
          distanceM: d,
        );
      }
      final legTag = _demoTargetIdx;
      final best =
          const AStarService().findPath(graph, gpsId, 'stop:${next.id}', recordTrace: false);
      if (!best.found) return;
      // Alternative: block the middle edge of the best path and re-run.
      AstarResult? alt;
      if (best.path.length >= 3) {
        final a = best.path[1];
        final b = best.path[2];
        final prefix = _storedPrefix(graph, a, b);
        if (prefix != null) {
          graph.setBlocked(prefix, true);
          final r2 =
              const AStarService().findPath(graph, gpsId, 'stop:${next.id}', recordTrace: false);
          if (r2.found && r2.path.join() != best.path.join()) alt = r2;
        }
      }
      List<List<double>> coordsOf(List<String> path) =>
          [for (final id in path) [graph.nodes[id]!.lat, graph.nodes[id]!.lon]];
      final bestGeo = await _demoGeometry('best:${next.id}:$legTag', coordsOf(best.path));
      if (!_demoActive) return;
      _sendDemoPath('demo-best', bestGeo, '#2563EB', 6);
      var altTxt = 'no alternative';
      if (alt != null) {
        final altGeo = await _demoGeometry('alt:${next.id}:$legTag', coordsOf(alt.path));
        if (!_demoActive) return;
        _sendDemoPath('demo-alt', altGeo, '#9CA3AF', 4);
        altTxt = 'alt +${((alt.cost - best.cost) * 8 / 1000).toStringAsFixed(1)} km';
      } else {
        _sendToMap(_enc({'type': 'clearPath', 'id': 'demo-alt'}));
      }
      final km = best.cost * 8 / 1000;
      final mins = best.cost / 60;
      if (mounted) {
        setState(() {
          _demoLegLine =
              'A* → ${next.name}: best ${km.toStringAsFixed(1)} km ~${mins.toStringAsFixed(0)} min '
              '(${best.nodesExpanded} nodes) • $altTxt';
        });
      }
    } catch (e) {
      debugPrint('Demo overlay failed: $e');
    }
  }

  void _beginDemoTrip({
    required String busNumber,
    required String routeId,
    required String routeName,
    required int capacity,
    List<StopInfo>? stops,
  }) {
    _demoTimer?.cancel();
    setState(() {
      _demoActive = true;
      _demoDialogOpen = false;
      _demoStep = 0;
      _demoOccupancy = 0;
      _demoStatus = 'on_time';
      _demoBusNumber = busNumber;
      _demoRouteId = routeId;
      _demoRouteName = routeName;
      _demoCapacity = capacity;
      _demoTargetIdx = 0;
      if (stops != null) _demoStops = stops;
    });
    _placeDemoBus();
    // Bring the map to the demo route even if it was looking elsewhere.
    _sendToMap(_enc({'type': 'flyToBus', 'id': 'demo-trip'}));
    _demoTimer = Timer.periodic(const Duration(seconds: 2), (_) => _demoTick());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Demo: bus $busNumber on "$routeName". Arrival + headcount coming up.'),
          backgroundColor: const Color(0xFF6366F1),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    // Opening arrival right away so the full flow shows within seconds.
    _showArrivalAlert(_demoBusNumber, _demoStops.first.name);
    _showDemoHeadcountDialog(_demoStops.first.name);
  }

  void _stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _buses.remove('demo-trip');
    if (_trackingTripId == 'demo-trip') _trackingTripId = null;
    _sendToMap(_enc({'type': 'clearPath', 'id': 'demo-best'}));
    _sendToMap(_enc({'type': 'clearPath', 'id': 'demo-alt'}));
    if (mounted) {
      setState(() {
        _demoActive = false;
        _demoDialogOpen = false;
      });
    }
    _syncMarkersToMap();
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// Position along the demo route polyline at global step [s].
  /// Steps past the end clamp to the terminus (no looping).
  List<double> _demoPosition(int s) {
    final legs = _demoStops.length - 1;
    final total = legs * _demoStepsPerLeg;
    if (s >= total) {
      final last = _demoStops.last;
      return [last.lat, last.lon];
    }
    final leg = s ~/ _demoStepsPerLeg;
    final f = (s % _demoStepsPerLeg) / _demoStepsPerLeg;
    final a = _demoStops[leg];
    final b = _demoStops[leg + 1];
    return [_lerp(a.lat, b.lat, f), _lerp(a.lon, b.lon, f)];
  }

  void _placeDemoBus() {
    final pos = _demoPosition(_demoStep);
    _buses['demo-trip'] = BusInfo(
      tripId: 'demo-trip',
      busNumber: _demoBusNumber,
      routeId: _demoRouteId,
      routeName: _demoRouteName,
      capacity: _demoCapacity,
      currentOccupancy: _demoOccupancy,
      runningStatus: _demoStatus,
      lat: pos[0],
      lon: pos[1],
    );
    if (mounted) setState(() {});
    _syncMarkersToMap();
  }

  void _demoTick() {
    if (!_demoActive || _demoDialogOpen || _demoStops.length < 2) return;
    final legs = _demoStops.length - 1;
    final total = legs * _demoStepsPerLeg;
    _demoStep = _demoStep + 1;
    if (_demoStep > total) {
      // Route complete - end the demo instead of looping.
      final busNum = _demoBusNumber;
      final stopCount = _demoStops.length;
      _stopDemo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Demo finished - bus $busNum completed all $stopCount stops.'),
            backgroundColor: const Color(0xFF22C55E),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    if (_demoStep % _demoStepsPerLeg == 0) {
      // Just arrived at a stop: flip status, alert students, ask driver.
      final stopName = _demoStops[_demoStep ~/ _demoStepsPerLeg].name;
      _demoStatus = 'arrived';
      _placeDemoBus();
      _showArrivalAlert(_demoBusNumber, stopName);
      _showDemoHeadcountDialog(stopName);
    } else {
      _demoStatus = 'on_time';
      _placeDemoBus();
    }
  }

  /// Driver-style boarding pad, simulated inside the demo.
  void _showDemoHeadcountDialog(String stopName) {
    _demoDialogOpen = true;
    final controller = TextEditingController(text: '0');
    void append(String d) {
      if (controller.text == '0') {
        controller.text = d;
      } else {
        controller.text += d;
      }
    }

    void backspace() {
      if (controller.text.length > 1) {
        controller.text = controller.text.substring(0, controller.text.length - 1);
      } else {
        controller.text = '0';
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: Text('Driver: boarding at $stopName'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'How many students boarded? (students see this live)',
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                readOnly: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 200,
                width: 240,
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: 12,
                  itemBuilder: (ctx, i) {
                    if (i < 9) {
                      final num = '${i + 1}';
                      return _demoNumpadKey(num, () {
                        append(num);
                        setDialogState(() {});
                      });
                    } else if (i == 9) {
                      return _demoNumpadKey('0', () {
                        append('0');
                        setDialogState(() {});
                      });
                    } else if (i == 10) {
                      return _demoNumpadKey('⌫', () {
                        backspace();
                        setDialogState(() {});
                      });
                    }
                    return _demoNumpadKey('C', () {
                      controller.text = '0';
                      setDialogState(() {});
                    });
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Skip'),
            ),
            ElevatedButton(
              onPressed: () {
                final count = int.tryParse(controller.text) ?? 0;
                Navigator.pop(ctx);
                _demoOccupancy = (_demoOccupancy + count).clamp(0, _demoCapacity);
                _demoStatus = 'on_time';
                _placeDemoBus();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '$count boarded - bus $_demoBusNumber now $_demoOccupancy/$_demoCapacity',
                      ),
                      backgroundColor: const Color(0xFF22C55E),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              },
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    ).then((_) {
      controller.dispose();
      _demoDialogOpen = false;
      // Bus departs the served stop: aim the next assigned stop and redraw
      // the Google-style best/alternative route overlay for the new leg.
      if (_demoActive && _demoStops.isNotEmpty) {
        _demoTargetIdx = (_demoTargetIdx + 1).clamp(0, _demoStops.length - 1);
        _refreshDemoRouteOverlay();
      }
    });
  }

  Widget _demoNumpadKey(String label, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF2C2C2C),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 20)),
    );
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _busPositionsSub?.unsubscribe();
    _tripsSub?.unsubscribe();
    _stopsSub?.unsubscribe();
    _stopEventsSub?.unsubscribe();
    _assignSub?.unsubscribe();
    super.dispose();
  }

  /// Student "bus is near" banner. Used by live stop_events and the demo.
  void _showArrivalAlert(String busNum, String stopName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.radar, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Alert: $busNum is near stop "$stopName"!',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF6366F1),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _subscribeToRealtime() {
    try {
      _busPositionsSub = _supabase
          .channel('public:bus_positions')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'bus_positions',
            callback: (payload) async {
              try {
                final rec = payload.newRecord;
                if (rec.isEmpty) return;
                final tripId = rec['trip_id'] as String?;
                if (tripId == null) return;
                var bus = _buses[tripId];
                if (bus == null) {
                  await _upsertActiveTrip(tripId);
                  bus = _buses[tripId];
                }
                if (bus == null) return;

                _buses[tripId] = bus.copyWith(
                  lat: (rec['lat'] as num).toDouble(),
                  lon: (rec['lon'] as num).toDouble(),
                );
                if (mounted) {
                  setState(() {});
                  _syncMarkersToMap();
                }
              } catch (e) {
                debugPrint('Error processing position update: $e');
              }
            },
          )
          .subscribe();

      _tripsSub = _supabase
          .channel('public:trips')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'trips',
            callback: (payload) async {
              try {
                final rec = payload.eventType == PostgresChangeEvent.delete
                    ? payload.oldRecord
                    : payload.newRecord;
                final tripId = rec['id'] as String?;
                if (tripId == null) return;

                if (payload.eventType == PostgresChangeEvent.delete ||
                    rec['status'] != 'in_progress') {
                  _removeTripFromMap(tripId);
                } else {
                  await _upsertActiveTrip(tripId);
                }

                if (mounted) {
                  setState(() {});
                  _syncMarkersToMap();
                }
              } catch (e) {
                debugPrint('Error processing trip update: $e');
              }
            },
          )
          .subscribe();

      _stopsSub = _supabase
          .channel('public:stops')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'stops',
            callback: (payload) {
              try {
                final rec = payload.newRecord;
                if (rec.isEmpty) return;
                final stopId = rec['id'] as String?;
                if (stopId == null) return;
                final idx = _stops.indexWhere((s) => s.id == stopId);
                final updatedStop = StopInfo(
                  id: stopId,
                  routeId: rec['route_id'] as String? ?? '',
                  name: rec['name'] as String,
                  lat: (rec['lat'] as num).toDouble(),
                  lon: (rec['lon'] as num).toDouble(),
                  membersCount: 0,
                  sequence: (rec['sequence_no'] as num?)?.toInt() ?? 0,
                );
                if (idx != -1) {
                  _stops[idx] = updatedStop;
                } else {
                  _stops.add(updatedStop);
                }
                if (mounted) {
                  setState(() {});
                  _syncMarkersToMap();
                }
              } catch (e) {
                debugPrint('Error processing stop update: $e');
              }
            },
          )
          .subscribe();

      _stopEventsSub = _supabase
          .channel('public:stop_events')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'stop_events',
            callback: (payload) async {
              try {
                final rec = payload.newRecord;
                final tripId = rec['trip_id'] as String?;
                final stopId = rec['stop_id'] as String?;
                if (tripId == null || stopId == null) return;
                // Track served stops so the AI assignment panel shows live progress.
                if (rec['event_type'] == 'departed') {
                  _departedByTrip.putIfAbsent(tripId, () => {}).add(stopId);
                  if (mounted) setState(() {});
                  return;
                }
                if (rec['event_type'] != 'arrived') return;

                // Look up bus
                final bus = _buses[tripId];
                final busNum = bus?.busNumber ?? 'A bus';

                // Look up stop
                String stopName = 'a nearby stop';
                final stopIdx = _stops.indexWhere((s) => s.id == stopId);
                if (stopIdx != -1) {
                  stopName = _stops[stopIdx].name;
                } else {
                  // Fallback: fetch name from database if not cached
                  final sData = await _supabase.from('stops').select('name').eq('id', stopId).maybeSingle();
                  if (sData != null) {
                    stopName = sData['name'] as String;
                  }
                }

                if (mounted) _showArrivalAlert(busNum, stopName);
              } catch (e) {
                debugPrint('Error processing stop event: $e');
              }
            },
          )
          .subscribe();

      // AI: stop assignments change when CSP (re)plans a slot.
      _assignSub = _supabase
          .channel('public:stop_assignments')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'stop_assignments',
            callback: (_) => _loadAssignments(),
          )
          .subscribe();
    } catch (e) {
      debugPrint('Error setting up realtime subscriptions: $e');
    }
  }

  /// AI assignment state: tripId -> ordered stopIds (CSP output for that
  /// trip's slot+bus), plus departed stopIds per trip for live progress.
  final Map<String, List<String>> _assignedByTrip = {};
  final Map<String, Set<String>> _departedByTrip = {};
  RealtimeChannel? _assignSub;

  /// Loads CSP stop assignments for the visible trips and matches them via
  /// (slot_id, bus_id). Trips without a plan fall back to all route stops.
  Future<void> _loadAssignments() async {
    if (_buses.isEmpty) return;
    try {
      final rows = await _supabase.from('stop_assignments').select('slot_id, stop_id, bus_id');
      final byStop = {for (final s in _stops) s.id: s};
      final next = <String, List<String>>{};
      for (final trip in _buses.values) {
        if (trip.slotId.isEmpty) continue;
        final mine = (rows as List).where((r) =>
            r['slot_id'] == trip.slotId && r['bus_id'] == trip.busId);
        final ordered = mine
            .map((r) => r['stop_id'] as String)
            .where((id) => byStop.containsKey(id))
            .toList()
          ..sort((a, b) => byStop[a]!.sequence.compareTo(byStop[b]!.sequence));
        if (ordered.isNotEmpty) next[trip.tripId] = ordered;
      }
      // Departed stops per active trip (served progress).
      for (final tripId in _buses.keys) {
        try {
          final evs = await _supabase
              .from('stop_events')
              .select('stop_id')
              .eq('trip_id', tripId)
              .eq('event_type', 'departed');
          _departedByTrip[tripId] = {
            for (final e in (evs as List)) e['stop_id'] as String
          };
        } catch (e) {
          debugPrint('AI departed load failed: $e');
        }
      }
      if (!mounted) return;
      setState(() {
        _assignedByTrip
          ..clear()
          ..addAll(next);
      });
    } catch (e) {
      debugPrint('AI assignments unavailable: $e');
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
                          if (mounted) {
                            Navigator.pop(ctx);
                            _showSubscriptionSheet();
                          }
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
          return '${full.busNumber} on "${entry.key}" is ${(full.occupancyPct * 100).round()}% full - '
              'consider ${spare.busNumber} (${(spare.occupancyPct * 100).round()}% full)';
        }
      }
    }
    return null;
  }

  Color _capColor(double pct) {
    if (pct >= 0.9) return const Color(0xFFEF4444);
    if (pct >= 0.7) return const Color(0xFFFACC15);
    return const Color(0xFF4ADE80);
  }

  Color _busColor(String status) {
    if (status == 'late') return const Color(0xFFEF4444);
    if (status == 'arrived') return const Color(0xFF22C55E);
    if (status == 'stopped') return const Color(0xFFF59E0B);
    return const Color(0xFF6366F1);
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'late':
        return 'Running Late';
      case 'arrived':
        return 'At Stop';
      case 'stopped':
        return 'Stopped';
      case 'on_time':
      default:
        return 'On Time';
    }
  }

  StopInfo? _nearestStop(BusInfo bus) {
    if (_stops.isEmpty) return null;

    StopInfo? nearest;
    var bestDistance = double.infinity;
    for (final stop in _stops) {
      final latDiff = bus.lat - stop.lat;
      final lonDiff = bus.lon - stop.lon;
      final distance = (latDiff * latDiff) + (lonDiff * lonDiff);
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = stop;
      }
    }
    return nearest;
  }

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degToRad(double deg) => deg * math.pi / 180.0;

  String _whereIsBus(BusInfo bus) {
    final nearest = _nearestStop(bus);
    if (nearest == null) return 'Live location available';

    final distanceKm = _distanceKm(bus.lat, bus.lon, nearest.lat, nearest.lon);
    if (distanceKm < 0.15) {
      return 'Near ${nearest.name}';
    }
    if (distanceKm < 1) {
      return '${(distanceKm * 1000).round()} m from ${nearest.name}';
    }
    return '${distanceKm.toStringAsFixed(1)} km from ${nearest.name}';
  }

  Future<void> _locateMe() async {
    if (_isLocatingUser) return;
    setState(() => _isLocatingUser = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Location permission denied')),
            );
          }
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission permanently denied. Please enable it in Settings.')),
          );
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _sendToMap(_enc({
        'type': 'flyToLocation',
        'lat': position.latitude,
        'lon': position.longitude,
      }));
    } catch (e) {
      debugPrint('Locate me failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to get location: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLocatingUser = false);
    }
  }

  void _startTracking(String tripId) {
    setState(() => _trackingTripId = tripId);
    _sendToMap(_enc({'type': 'flyToBus', 'id': tripId}));
    _sendToMap(_enc({'type': 'trackBus', 'id': tripId}));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tracking Bus ${_buses[tripId]?.busNumber ?? ''}'),
          backgroundColor: const Color(0xFF6366F1),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _stopTracking() {
    final prevId = _trackingTripId;
    setState(() => _trackingTripId = null);
    if (prevId != null) {
      _sendToMap(_enc({'type': 'untrackBus', 'id': prevId}));
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stopped tracking'),
          backgroundColor: Color(0xFF475569),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = _transferSuggestion();

    return Scaffold(
      body: Stack(
        children: [
          // Map WebView
          if (_webViewController != null)
            WebViewWidget(controller: _webViewController!),
          
          // Loading overlay
          if (!_mapReady || _isLoadingData)
            Container(
              color: const Color(0xFF0F172A),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      color: Color(0xFF6366F1),
                      strokeWidth: 3,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _isLoadingData ? 'Loading bus data...' : 'Loading map...',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_loadingError != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Color(0xFFEF4444),
                              size: 24,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _loadingError!,
                              style: const TextStyle(
                                color: Color(0xFFEF4444),
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _loadingError = null;
                                  _mapReady = false;
                                });
                                _initWebView();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6366F1),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Retry',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // Header with better mobile layout
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                right: 16,
                bottom: 16,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0F172A).withValues(alpha: 0.95),
                    const Color(0xFF0F172A).withValues(alpha: 0.7),
                    const Color(0xFF0F172A).withValues(alpha: 0),
                  ],
                ),
              ),
              child: Row(
                children: [
                  // Status indicator
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _mapReady && !_isLoadingData
                          ? const Color(0xFF22C55E)
                          : const Color(0xFFF59E0B),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  
                  // Title
                  const Expanded(
                    child: Text(
                      'College Bus Tracker',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFF8FAFC),
                      ),
                    ),
                  ),
                  
                  // Bus count
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_buses.length} bus${_buses.length == 1 ? '' : 'es'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // AI Algorithm Simulation button
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AiSimScreen()),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.psychology,
                        color: Color(0xFF22C55E),
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Notifications button
                  GestureDetector(
                    onTap: _showSubscriptionSheet,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.notifications_outlined,
                        color: Color(0xFF94A3B8),
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  
                  // Profile/Logout button
                  GestureDetector(
                    onTap: _showProfileMenu,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.person_outline,
                        color: Color(0xFF94A3B8),
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Locate me button (bottom-right, above bus list)
          Positioned(
            bottom: _buses.isNotEmpty ? 140 : 24,
            right: 16,
            child: GestureDetector(
              onTap: _locateMe,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF334155)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _isLocatingUser
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF6366F1),
                        ),
                      )
                    : const Icon(
                        Icons.my_location,
                        color: Color(0xFF6366F1),
                        size: 22,
                      ),
              ),
            ),
          ),

          // Empty state with Demo button (no live buses)
          if (_buses.isEmpty && _mapReady && !_isLoadingData && !_demoActive)
            Positioned.fill(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.directions_bus,
                        size: 40,
                        color: Color(0xFF6366F1),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No live buses right now',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF8FAFC),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Start a driver trip, or demo any bus: arrivals, headcount & occupancy.',
                        style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _showDemoBusPicker,
                          icon: const Icon(Icons.play_circle_outline, color: Colors.white),
                          label: const Text(
                            'Start Demo',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // AI demo overlay: CSP assignment + A* best/alt route, Google-style.
          if (_demoActive)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.psychology,
                            size: 15, color: Color(0xFF22C55E)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'AI DEMO · Bus $_demoBusNumber${_demoSlotLabel.isEmpty ? '' : ' ($_demoSlotLabel)'}',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w800),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const AiSimScreen()),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1)
                                  .withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Steps ›',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFA5B4FC))),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Serves: $_demoServeText',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFF8FAFC)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_demoSkipText.isNotEmpty)
                      Text(
                        'Skips: $_demoSkipText',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF94A3B8)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(_demoCspLine,
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFF94A3B8))),
                    if (_demoLegLine.isNotEmpty)
                      Text(_demoLegLine,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF60A5FA))),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                            width: 18,
                            height: 4,
                            decoration: BoxDecoration(
                                color: const Color(0xFF2563EB),
                                borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 4),
                        const Text('best',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFF94A3B8))),
                        const SizedBox(width: 10),
                        Container(
                            width: 18,
                            height: 4,
                            decoration: BoxDecoration(
                                color: const Color(0xFF9CA3AF),
                                borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 4),
                        const Text('alt',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFF94A3B8))),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Stop demo button
          if (_demoActive)
            Positioned(
              bottom: 150,
              left: 16,
              child: GestureDetector(
                onTap: _stopDemo,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop_circle, color: Colors.white, size: 18),
                      SizedBox(width: 6),
                      Text(
                        'Stop Demo',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Stop tracking button (shown when tracking a bus)
          if (_trackingTripId != null)
            Positioned(
              bottom: _buses.isNotEmpty ? 140 : 24,
              left: 16,
              child: GestureDetector(
                onTap: _stopTracking,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.stop_circle, color: Colors.white, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'Stop Tracking ${_buses[_trackingTripId]?.busNumber ?? ''}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Transfer suggestion banner
          if (suggestion != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 16,
              right: 16,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFF1E1B4B),
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          suggestion,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E1B4B),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _bannerDismissed = true),
                        child: const Icon(
                          Icons.close,
                          color: Color(0xFF1E1B4B),
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom bus list with improved mobile UI
          if (_buses.isNotEmpty)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 140,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.97),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  border: const Border(
                    top: BorderSide(color: Color(0xFF334155), width: 1),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                          Text(
                            'Active Buses (${_buses.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF94A3B8),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _buses.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (ctx, i) {
                          final b = _buses.values.elementAt(i);
                          final pct = b.occupancyPct;
                          final capColor = _capColor(pct);

                          return GestureDetector(
                            onTap: () {
                              _sendToMap(_enc({'type': 'flyToBus', 'id': b.tripId}));
                              _showBusDetails(b);
                            },
                            child: Container(
                              width: 160,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    const Color(0xFF1E293B),
                                    const Color(0xFF0F172A),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFF334155),
                                  width: 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _busColor(b.runningStatus).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          b.busNumber,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: _busColor(b.runningStatus),
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: _busColor(b.runningStatus),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: _busColor(b.runningStatus).withValues(alpha: 0.5),
                                              blurRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    b.routeName,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFF8FAFC),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _statusLabel(b.runningStatus),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: _busColor(b.runningStatus).withValues(alpha: 0.8),
                                    ),
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: [
                                      Icon(Icons.people_outline, size: 13, color: capColor),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${b.currentOccupancy}/${b.capacity}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: capColor,
                                        ),
                                      ),
                                      const Spacer(),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'Track',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF6366F1),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showProfileMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF475569),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.refresh, color: Color(0xFF94A3B8)),
            title: const Text('Refresh Data', style: TextStyle(color: Color(0xFFF8FAFC))),
            onTap: () {
              Navigator.pop(ctx);
              _loadData();
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Color(0xFFEF4444)),
            title: const Text('Logout', style: TextStyle(color: Color(0xFFF8FAFC))),
            onTap: () async {
              await Supabase.instance.client.auth.signOut();
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  /// Rows for the AI assignment panel: served (struck), NEXT (highlighted),
  /// upcoming stops of this trip's CSP plan.
  List<Widget> _aiStopRows(BusInfo liveBus) {
    final ordered = _assignedByTrip[liveBus.tripId] ?? [];
    final byId = {for (final s in _stops) s.id: s};
    final departed = _departedByTrip[liveBus.tripId] ?? {};
    String? nextId;
    for (final id in ordered) {
      if (!departed.contains(id)) {
        nextId = id;
        break;
      }
    }
    return [
      for (final id in ordered)
        if (byId.containsKey(id))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  departed.contains(id)
                      ? Icons.check_circle
                      : (id == nextId
                          ? Icons.navigation
                          : Icons.radio_button_unchecked),
                  size: 16,
                  color: departed.contains(id)
                      ? const Color(0xFF22C55E)
                      : (id == nextId
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF64748B)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    byId[id]!.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: departed.contains(id)
                          ? const Color(0xFF64748B)
                          : const Color(0xFFF8FAFC),
                      decoration: departed.contains(id)
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
                if (id == nextId)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'NEXT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFF59E0B),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    ];
  }

  void _showBusDetails(BusInfo bus) {
    final liveBus = _buses[bus.tripId] ?? bus;
    final nearestStopText = _whereIsBus(liveBus);
    final routeStops = _stops.where((s) => s.routeId == liveBus.routeId).toList();
    final hasAiPlan = _assignedByTrip.containsKey(liveBus.tripId);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF475569),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bus ${liveBus.busNumber}',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFF8FAFC),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              nearestStopText,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF94A3B8),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _busColor(liveBus.runningStatus).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _statusLabel(liveBus.runningStatus).toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: _busColor(liveBus.runningStatus),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildDetailRow('Route', liveBus.routeName),
                  _buildDetailRow('Live Status', _statusLabel(liveBus.runningStatus)),
                  _buildDetailRow('Bus Position', nearestStopText),
                  _buildDetailRow('Occupancy', '${liveBus.currentOccupancy}/${liveBus.capacity} (${(liveBus.occupancyPct * 100).round()}%)'),
                  if (hasAiPlan) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.psychology,
                                  size: 16, color: Color(0xFF22C55E)),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'AI: allocation optimized • live path',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF22C55E),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ..._aiStopRows(liveBus),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (_trackingTripId == liveBus.tripId) {
                          _stopTracking();
                        } else {
                          _startTracking(liveBus.tripId);
                        }
                      },
                      icon: Icon(
                        _trackingTripId == liveBus.tripId
                            ? Icons.stop_circle
                            : Icons.play_circle_outline,
                        color: Colors.white,
                      ),
                      label: Text(
                        _trackingTripId == liveBus.tripId
                            ? 'Stop Tracking'
                            : 'Track on Map',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _trackingTripId == liveBus.tripId
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  if (routeStops.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'All Stops',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF8FAFC),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...List.generate(routeStops.length, (i) {
                      final stop = routeStops[i];
                      final isNearBus = liveBus.lat != 0 &&
                          _distanceKm(liveBus.lat, liveBus.lon, stop.lat, stop.lon) < 0.3;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: isNearBus
                                        ? const Color(0xFF22C55E)
                                        : const Color(0xFF475569),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isNearBus
                                          ? const Color(0xFF22C55E)
                                          : const Color(0xFF94A3B8),
                                      width: 2,
                                    ),
                                  ),
                                ),
                                if (i < routeStops.length - 1)
                                  Container(
                                    width: 2,
                                    height: 24,
                                    color: const Color(0xFF475569),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isNearBus
                                      ? const Color(0xFF22C55E).withValues(alpha: 0.1)
                                      : const Color(0xFF0F172A),
                                  borderRadius: BorderRadius.circular(8),
                                  border: isNearBus
                                      ? Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.3))
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        stop.name,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: isNearBus ? FontWeight.w600 : FontWeight.w400,
                                          color: isNearBus
                                              ? const Color(0xFF22C55E)
                                              : const Color(0xFFF8FAFC),
                                        ),
                                      ),
                                    ),
                                    if (stop.membersCount > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${stop.membersCount}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF6366F1),
                                          ),
                                        ),
                                      ),
                                    if (isNearBus) ...[
                                      const SizedBox(width: 8),
                                      const Icon(
                                        Icons.directions_bus,
                                        size: 16,
                                        color: Color(0xFF22C55E),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF94A3B8),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFFF8FAFC),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
