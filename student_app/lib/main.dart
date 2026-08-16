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

  StopInfo({
    required this.id,
    required this.routeId,
    required this.name,
    required this.lat,
    required this.lon,
    this.membersCount = 0,
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
          'id, status, bus_id, route_id, running_status, current_occupancy, '
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
      busNumber: bus['bus_number'] as String,
      routeId: trip['route_id'] as String,
      routeName: route['name'] as String,
      capacity: (bus['capacity'] as num?)?.toInt() ?? 0,
      currentOccupancy: (trip['current_occupancy'] as num?)?.toInt() ?? 0,
      runningStatus: (trip['running_status'] as String?) ?? 'on_time',
      lat: (pos['lat'] as num).toDouble(),
      lon: (pos['lon'] as num).toDouble(),
    );
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
          .select('id, bus_id, route_id, running_status, current_occupancy, buses(bus_number, capacity), routes(name)')
          .eq('status', 'in_progress');

      debugPrint('Loaded ${trips.length} trips');

      // Load bus positions
      final positions = await _supabase.from('bus_positions').select('trip_id, bus_id, lat, lon');
      debugPrint('Loaded ${positions.length} positions');

      // Load stops
      final stops = await _supabase.from('stops').select('id, route_id, name, lat, lon').order('sequence_no');
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

  void _addSampleBusData() {}

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
  
  void _startDemoMovement() {}

  @override
  void dispose() {
    _demoTimer?.cancel();
    _busPositionsSub?.unsubscribe();
    _tripsSub?.unsubscribe();
    _stopsSub?.unsubscribe();
    _stopEventsSub?.unsubscribe();
    super.dispose();
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
                if (rec['event_type'] != 'arrived') return;
                final tripId = rec['trip_id'] as String?;
                final stopId = rec['stop_id'] as String?;
                if (tripId == null || stopId == null) return;

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

                if (mounted) {
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
              } catch (e) {
                debugPrint('Error processing stop event: $e');
              }
            },
          )
          .subscribe();
    } catch (e) {
      debugPrint('Error setting up realtime subscriptions: $e');
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

  void _showBusDetails(BusInfo bus) {
    final liveBus = _buses[bus.tripId] ?? bus;
    final nearestStopText = _whereIsBus(liveBus);
    final routeStops = _stops.where((s) => s.routeId == liveBus.routeId).toList();

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
