import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'ai/astar.dart';
import 'ai/csp.dart';
import 'ai/demand.dart';
import 'ai/road_graph.dart';

class StopInfo {
  final String id;
  final String name;
  final double lat;
  final double lon;
  final int membersCount;
  final int sequence;
  StopInfo({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    this.membersCount = 0,
    this.sequence = 0,
  });
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load configuration from local project environment
  await dotenv.load(fileName: ".env");
  
  final supabaseUrl = dotenv.env['Api_url'] ?? '';
  final supabaseAnonKey = dotenv.env['Anon_key'] ?? '';
  
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabaseAnonKey,
  );

  // Initialize local notifications (used for foreground service)
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  await flutterLocalNotificationsPlugin.initialize(initSettings);
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'College Bus Driver',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1E1E1E),
          border: OutlineInputBorder(),
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
    _validateSession();
  }

  Future<void> _validateSession() async {
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;
    if (session != null) {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final profile = await supabase
            .from('users')
            .select('id')
            .eq('id', user.id)
            .maybeSingle();
        if (profile == null) {
          await supabase.auth.signOut();
        }
      } else {
        await supabase.auth.signOut();
      }
    }
    if (mounted) {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      return const TripDashboardScreen();
    }
    return const AuthScreen();
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _busNumberController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _isLoading = false;
  bool _isSignUp = true;
  String? _errorMessage;

  final _supabase = Supabase.instance.client;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _busNumberController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Please enter email and password.');
      return;
    }

    if (_isSignUp) {
      final name = _nameController.text.trim();
      final busNumber = _busNumberController.text.trim();

      if (name.isEmpty || busNumber.isEmpty) {
        setState(() => _errorMessage = 'Please fill in all required fields.');
        return;
      }
      if (password.length < 6) {
        setState(() => _errorMessage = 'Password must be at least 6 characters.');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_isSignUp) {
        await _signUp();
      } else {
        await _signIn();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();
    final busNumber = _busNumberController.text.trim();

    try {
      final response = await _supabase.auth.signUp(
        email: email,
        password: password,
      );

      final user = response.user;
      if (user == null) throw Exception('Sign up failed');

      // If Supabase has email confirmation enabled, session will be null
      if (response.session == null) {
        if (mounted) {
          setState(() {
            _errorMessage = null;
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Check your email for a confirmation link, then sign in.'),
              backgroundColor: Color(0xFF22C55E),
              duration: Duration(seconds: 5),
            ),
          );
          // Switch to sign-in mode
          setState(() => _isSignUp = false);
        }
        return;
      }

      // Session exists (email confirmation disabled) - complete setup
      await _completeDriverSetup(user.id, name, busNumber);
    } catch (e) {
      // If auth user already exists but profile was deleted, recover by
      // signing in and recreating the profile + bus assignment.
      final msg = e.toString();
      if (msg.contains('already') || msg.contains('registered')) {
        final signInResp = await _supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );
        final user = signInResp.user;
        if (user == null) throw Exception('Sign up failed. Email already in use but sign-in also failed. Try signing in instead.');
        await _completeDriverSetup(user.id, name, busNumber);
        return;
      }
      rethrow;
    }
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    final response = await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );

    final user = response.user;
    if (user == null) throw Exception('Sign in failed');

    // Fetch existing driver profile
    final profile = await _supabase
        .from('users')
        .select('name')
        .eq('id', user.id)
        .maybeSingle();

    if (profile == null) {
      await _supabase.auth.signOut();
      throw Exception('No driver profile found. Please sign up again with the same email.');
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TripDashboardScreen()),
      );
    }
  }

  Future<void> _completeDriverSetup(String userId, String name, String busNumber) async {
    // 1. Validate bus number exists
    final busResponse = await _supabase
        .from('buses')
        .select('id')
        .eq('bus_number', busNumber)
        .maybeSingle();

    if (busResponse == null) {
      await _supabase.auth.signOut();
      throw Exception('Bus "$busNumber" not found. Ask admin to add it first.');
    }

    final busId = busResponse['id'] as String;

    // 2. Insert driver profile
    await _supabase.from('users').upsert({
      'id': userId,
      'name': name,
      'phone': _phoneController.text.trim().isEmpty
          ? null
          : _phoneController.text.trim(),
      'role': 'driver',
    });

    // 3. Assign driver to bus
    await _supabase.from('driver_bus_assignments').upsert({
      'driver_id': userId,
      'bus_id': busId,
    });

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TripDashboardScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isSignUp ? 'Driver Sign Up' : 'Driver Sign In')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isSignUp) ...[
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Full Name *'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email *'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password *'),
                obscureText: true,
              ),
              if (_isSignUp) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _busNumberController,
                  decoration: const InputDecoration(
                    labelText: 'Bus Number *',
                    hintText: 'e.g. 1, 2, 3...',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(labelText: 'Phone (Optional)'),
                  keyboardType: TextInputType.phone,
                ),
              ],
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

              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Text(
                        _isSignUp ? 'Create Account & Enter' : 'Sign In',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isLoading
                    ? null
                    : () => setState(() {
                          _isSignUp = !_isSignUp;
                          _errorMessage = null;
                        }),
                child: Text(
                  _isSignUp
                      ? 'Already have an account? Sign In'
                      : "Don't have an account? Sign Up",
                  style: const TextStyle(color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TripDashboardScreen extends StatefulWidget {
  const TripDashboardScreen({super.key});

  @override
  State<TripDashboardScreen> createState() => _TripDashboardScreenState();
}

class _TripDashboardScreenState extends State<TripDashboardScreen> {
  final _supabase = Supabase.instance.client;
  
  bool _isLoading = true;
  String? _busId;
  String? _busNumber;
  String? _routeId;
  String? _driverName;
  
  String? _activeTripId;
  bool _isTracking = false;
  StreamSubscription<Position>? _positionSubscription;
  RealtimeChannel? _arrivalChannel;
  final Set<String> _handledArrivalIds = {};

  WebViewController? _webViewController;
  bool _mapReady = false;
  bool _busMarkerAddedToMap = false;
  List<StopInfo> _stops = [];
  Position? _lastPosition;

  // ---- AI: CSP slot planning + A* pathfinding state ----
  List<Map<String, dynamic>> _slots = [];
  String? _selectedSlotId;
  bool _planning = false;
  String? _cspStats;
  List<StopInfo> _myAssignedStops = [];
  String? _nextStopId;
  List<List<double>> _tripPathPoints = [];
  String? _astarInfo;
  DateTime? _lastPathCompute;
  RealtimeChannel? _assignChannel;
  RealtimeChannel? _slotBusChannel;

  @override
  void initState() {
    super.initState();
    _loadDriverDetails();
  }

  Future<void> _loadDriverDetails() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // 0. Fetch driver profile from users table
      final userProfile = await _supabase
          .from('users')
          .select('name')
          .eq('id', user.id)
          .maybeSingle();

      if (userProfile != null) {
        _driverName = userProfile['name'] as String;
      }

      // 1. Fetch assigned bus for current driver
      final assignment = await _supabase
          .from('driver_bus_assignments')
          .select('bus_id, buses(bus_number, route_id)')
          .eq('driver_id', user.id)
          .maybeSingle();

      if (assignment != null) {
        final bus = assignment['buses'] as Map<String, dynamic>;
        setState(() {
          _busId = assignment['bus_id'] as String;
          _busNumber = bus['bus_number'] as String;
          _routeId = bus['route_id'] as String;
        });

        // AI: load Admin-defined operating slots (CSP candidate pools).
        _loadSlots();

        // 2. Fetch if there is already an active (in_progress) trip for this driver
        final activeTrip = await _supabase
            .from('trips')
            .select('id')
            .eq('driver_id', user.id)
            .eq('status', 'in_progress')
            .maybeSingle();

        if (activeTrip != null) {
          final String tripId = activeTrip['id'] as String;
          setState(() {
            _activeTripId = tripId;
            _isTracking = true;
          });
          _initWebView();
          _loadRouteStops();
          // Resume tracking if trip was in_progress
          _startLocationUpdates();
          _subscribeToArrivals();
        } else {
          // No active trip - still init map to show driver location
          _initWebView();
          if (_routeId != null) _loadRouteStops();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading driver profile: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _startLocationUpdates() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are turned off on this device.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied.');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission is permanently denied for this app.');
    }

    // Request notification permission on Android 13+
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    // Show foreground notification (keeps the service alive when backgrounded)
    await _showForegroundNotification();

    // Subscribe to GPS position stream
    _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position position) async {
      if (!_isTracking || _activeTripId == null) return;

      if (mounted) {
        setState(() {
          _lastPosition = position;
        });
      }
      // AI: first fix draws the A* path; later fixes only replan on deviation.
      if (_tripPathPoints.isEmpty && _nextStopId != null) {
        _computePathToNext();
      } else {
        _maybeReplanPath(position);
      }
      if (_mapReady && _webViewController != null) {
        if (!_busMarkerAddedToMap && _busNumber != null) {
          _sendToMap(_enc({
            'type': 'addBus',
            'id': _activeTripId!,
            'lat': position.latitude,
            'lon': position.longitude,
            'busNumber': _busNumber!,
            'status': 'on_time',
          }));
          _busMarkerAddedToMap = true;
          _sendToMap(_enc({'type': 'flyToBus', 'id': _activeTripId!}));
        } else {
          _sendToMap(_enc({
            'type': 'updateBusPosition',
            'id': _activeTripId!,
            'lat': position.latitude,
            'lon': position.longitude,
          }));
        }
      }

      try {
        await _supabase.from('location_pings').insert({
          'trip_id': _activeTripId,
          'lat': position.latitude,
          'lon': position.longitude,
          'speed': position.speed,
        });

        await _supabase.from('bus_positions').upsert({
          'trip_id': _activeTripId,
          'bus_id': _busId,
          'lat': position.latitude,
          'lon': position.longitude,
          'updated_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint('Failed to sync location coordinates: $e');
      }
    });
  }

  Future<void> _stopLocationUpdates() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    // Guarded: plugin.cancel() can throw a PlatformException
    // (Gson "Missing type parameter" from its corrupt scheduled-cache on
    // some Android builds). A notification-plugin crash must never break
    // end-trip, so it is swallowed here as non-fatal.
    try {
      await flutterLocalNotificationsPlugin.cancel(888);
    } catch (e) {
      debugPrint('Notification cancel failed (non-fatal): $e');
    }
  }

  Future<void> _showForegroundNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'bus_tracking',
      'Bus Location Tracking',
      channelDescription: 'Keeps GPS active while your trip is in progress',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      showWhen: false,
    );
    const details = NotificationDetails(android: androidDetails);
    // Same guard as above: the sticky notification is nice-to-have;
    // trip tracking must start even if the plugin misbehaves.
    try {
      await flutterLocalNotificationsPlugin.show(
        888,
        'Bus tracking active',
        'Your location is being shared for this trip.',
        details,
      );
    } catch (e) {
      debugPrint('Foreground notification failed (non-fatal): $e');
    }
  }

  void _subscribeToArrivals() {
    _arrivalChannel?.unsubscribe();
    if (_activeTripId == null) return;

    _arrivalChannel = _supabase
        .channel('arrivals:$_activeTripId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'stop_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'trip_id',
            value: _activeTripId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (row['event_type'] != 'arrived') return;
            final eventId = row['id'] as String;
            if (_handledArrivalIds.contains(eventId)) return;
            _handledArrivalIds.add(eventId);

            final stopId = row['stop_id'] as String;
            _fetchStopNameAndShowDialog(stopId);
          },
        )
        .subscribe();
  }

  Future<void> _fetchStopNameAndShowDialog(String stopId) async {
    try {
      final stop = await _supabase
          .from('stops')
          .select('name')
          .eq('id', stopId)
          .maybeSingle();
      final stopName = stop?['name'] ?? 'Unknown Stop';
      if (mounted) _showHeadcountDialog(stopId, stopName);
    } catch (e) {
      debugPrint('Failed to fetch stop name: $e');
    }
  }

  void _showHeadcountDialog(String stopId, String stopName) {
    final controller = TextEditingController(text: '0');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: Text('Boarding at $stopName'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('How many students boarded?'),
                  const SizedBox(height: 16),
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
                  // Number pad grid
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
                          final num = i + 1;
                          return _numpadKey('$num', () {
                            _appendDigit(controller, '$num');
                            setDialogState(() {});
                          });
                        } else if (i == 9) {
                          return _numpadKey('0', () {
                            _appendDigit(controller, '0');
                            setDialogState(() {});
                          });
                        } else if (i == 10) {
                          return _numpadKey('⌫', () {
                            _backspace(controller);
                            setDialogState(() {});
                          });
                        } else {
                          return _numpadKey('C', () {
                            controller.text = '0';
                            setDialogState(() {});
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final count = int.tryParse(controller.text) ?? 0;
                    Navigator.pop(ctx);
                    await _submitBoarding(stopId, count);
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => controller.dispose());
  }

  Widget _numpadKey(String label, VoidCallback onTap) {
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

  void _appendDigit(TextEditingController c, String d) {
    if (c.text == '0') {
      c.text = d;
    } else {
      c.text += d;
    }
  }

  void _backspace(TextEditingController c) {
    if (c.text.length > 1) {
      c.text = c.text.substring(0, c.text.length - 1);
    } else {
      c.text = '0';
    }
  }

  Future<void> _submitBoarding(String stopId, int count) async {
    if (_activeTripId == null) return;
    try {
      await _supabase.from('stop_boardings').insert({
        'trip_id': _activeTripId,
        'stop_id': stopId,
        'boarding_count': count,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count student${count == 1 ? '' : 's'} boarded at stop')),
        );
      }
      // AI: served one assigned stop -> advance to the next, replan A* path.
      _advanceAfterBoarding(stopId);
    } catch (e) {
      debugPrint('Failed to submit boarding: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to record boarding: $e')),
        );
      }
    }
  }

  void _unsubscribeFromArrivals() {
    _arrivalChannel?.unsubscribe();
    _arrivalChannel = null;
    _handledArrivalIds.clear();
  }

  void _initWebView() {
    final cesiumToken = dotenv.env['CESIUM_ION_ACCESS_TOKEN'] ?? '';
    _busMarkerAddedToMap = false;
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage msg) {
          if (msg.message.contains('"type":"ready"')) {
            setState(() {
              _mapReady = true;
            });
            _syncRouteAndLocationToMap();
          }
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          final escapedToken = cesiumToken.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
          final initMsg = '{"type":"init","token":"$escapedToken"}';
          _webViewController!.runJavaScript("handleMessage($initMsg)");
        },
      ));

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidController = _webViewController!.platform as AndroidWebViewController;
      androidController.setMixedContentMode(MixedContentMode.alwaysAllow);
      androidController.setAllowFileAccess(true);
      androidController.setAllowContentAccess(true);
    }

    _loadCesiumHtml();
  }

  Future<void> _loadCesiumHtml() async {
    try {
      final htmlContent = await rootBundle.loadString('web/cesium/map.html');
      await _webViewController!.loadHtmlString(htmlContent, baseUrl: 'https://localhost');
    } catch (e) {
      debugPrint('Failed to load Cesium HTML: $e');
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

  Future<void> _loadRouteStops() async {
    if (_routeId == null) return;
    try {
      final data = await _supabase
          .from('stops')
          .select('id, name, lat, lon, sequence_no')
          .eq('route_id', _routeId!)
          .order('sequence_no');

      setState(() {
        _stops = (data as List).map((s) => StopInfo(
          id: s['id'] as String,
          name: s['name'] as String,
          lat: (s['lat'] as num).toDouble(),
          lon: (s['lon'] as num).toDouble(),
          membersCount: 0,
          sequence: (s['sequence_no'] as num?)?.toInt() ?? 0,
        )).toList();
      });
      
      _syncRouteAndLocationToMap();
    } catch (e) {
      debugPrint('Failed to load stops: $e');
    }
  }

  void _syncRouteAndLocationToMap() {
    if (!_mapReady || _webViewController == null) return;
    
    for (final stop in _stops) {
      _sendToMap(_enc({
        'type': 'addStop',
        'id': stop.id,
        'lat': stop.lat,
        'lon': stop.lon,
        'name': stop.name,
        'membersCount': stop.membersCount,
      }));
    }

    if (_stops.isNotEmpty && _lastPosition == null && !_isTracking) {
      _sendToMap(_enc({'type': 'flyToStops'}));
    }

    if (_lastPosition != null && _busNumber != null && _activeTripId != null) {
      _sendToMap(_enc({
        'type': 'addBus',
        'id': _activeTripId!,
        'lat': _lastPosition!.latitude,
        'lon': _lastPosition!.longitude,
        'busNumber': _busNumber!,
        'status': 'on_time',
      }));
      _busMarkerAddedToMap = true;
      _sendToMap(_enc({
        'type': 'flyToBus',
        'id': _activeTripId!,
      }));
    } else if (!_isTracking) {
      // No active trip - auto-locate driver
      _locateMe();
    }
  }

  // ================= AI: CSP + A* =================
  // Same service classes the simulation replays (student_app/lib/ai/).

  Future<void> _loadSlots() async {
    if (_routeId == null) return;
    try {
      final data = await _supabase
          .from('operating_slots')
          .select('id, label, slot_time')
          .eq('route_id', _routeId!)
          .eq('is_active', true)
          .order('slot_time');
      if (!mounted) return;
      setState(() {
        _slots = (data as List).cast<Map<String, dynamic>>();
        if (_selectedSlotId == null && _slots.isNotEmpty) {
          _selectedSlotId = _slots.first['id'] as String;
        }
      });
      if (_selectedSlotId != null) {
        _loadMyAssignment();
        _subscribeSlotChannels();
      }
    } catch (e) {
      debugPrint('AI slots unavailable (tables missing?): $e');
    }
  }

  /// Runs demand estimation + CSP + Backtracking for the selected slot and
  /// stores the stop->bus assignment. Triggered by the driver pre-trip, or
  /// automatically when slot availability changes (event-driven, never on
  /// GPS updates).
  Future<void> _runAiPlan({bool silent = false}) async {
    if (_selectedSlotId == null || _routeId == null || _busId == null) return;
    if (_stops.isEmpty) await _loadRouteStops();
    if (_stops.isEmpty) return;
    setState(() => _planning = true);
    try {
      // 1. Candidate pool: Admin-scheduled buses for this slot.
      final poolRows = await _supabase
          .from('slot_buses')
          .select('bus_id, is_available, buses(bus_number, capacity)')
          .eq('slot_id', _selectedSlotId!);

      // 2. Demand estimation from ACTUAL historical boardings (last 14 days).
      final since = DateTime.now().subtract(const Duration(days: 14));
      final sinceStr = since.toIso8601String().split('T')[0];
      final ids = _stops.map((s) => s.id).toList();
      final boardRows = await _supabase
          .from('stop_boardings')
          .select('stop_id, boarding_count, recorded_at')
          .inFilter('stop_id', ids)
          .gte('recorded_at', sinceStr);
      final grouped = DemandEstimationService.group(
        (boardRows as List).cast<Map<String, dynamic>>(),
        stopIdKey: 'stop_id',
        countKey: 'boarding_count',
        dateKey: 'recorded_at',
      );
      for (final s in _stops) {
        grouped.putIfAbsent(s.id, () => []);
      }
      final estimates = DemandEstimationService.estimate(grouped, safetyFactor: 1.1);

      // 3. CSP + Backtracking (same CspAssignmentService as the simulation).
      final cspStops = _stops
          .map((s) => CspStop(
                id: s.id,
                label: s.name,
                demand: estimates[s.id]!.expected,
                sequence: s.sequence,
              ))
          .toList();
      final cspBuses = (poolRows as List).map((r) {
        final b = r['buses'] as Map<String, dynamic>?;
        return CspBus(
          id: r['bus_id'] as String,
          label: '${b?['bus_number'] ?? '?'}',
          capacity: (b?['capacity'] as num?)?.toInt() ?? 30,
          available: (r['is_available'] as bool?) ?? true,
        );
      }).toList();
      final result = const CspAssignmentService().solve(stops: cspStops, buses: cspBuses);

      if (!result.feasible || result.best == null) {
        if (mounted && !silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('AI plan infeasible: demand exceeds available capacity.')),
          );
        }
        setState(() => _cspStats = 'CSP infeasible (tried ${result.assignmentsTried}, backtracks ${result.backtracks})');
        return;
      }

      // 4. Store the assignment (replaces any previous plan for this slot).
      await _supabase.from('stop_assignments').delete().eq('slot_id', _selectedSlotId!);
      await _supabase.from('stop_assignments').insert(
        result.best!.assignment.entries
            .map((e) => {'slot_id': _selectedSlotId!, 'stop_id': e.key, 'bus_id': e.value})
            .toList(),
      );

      final totalExpected = cspStops.fold(0.0, (a, s) => a + s.demand);
      setState(() {
        _cspStats =
            'CSP: ${cspStops.length} stops -> ${result.best!.busesUsed} bus(es), '
            'expected ${totalExpected.toStringAsFixed(0)} riders '
            '(tried ${result.assignmentsTried}, backtracks ${result.backtracks}, '
            'score ${result.best!.score.toStringAsFixed(2)})';
      });
      await _loadMyAssignment();
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI plan ready. ${_myAssignedStops.map((s) => s.name).join(' -> ')}')),
        );
      }
    } catch (e) {
      debugPrint('AI plan failed: $e');
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI plan failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  /// Loads MY bus's assigned stops for the selected slot (ordered by route
  /// direction). Falls back to all route stops when no AI plan exists.
  Future<void> _loadMyAssignment() async {
    if (_selectedSlotId == null || _busId == null) return;
    try {
      final rows = await _supabase
          .from('stop_assignments')
          .select('stop_id, bus_id')
          .eq('slot_id', _selectedSlotId!)
          .eq('bus_id', _busId!);
      final myIds = <String>{for (final r in (rows as List)) r['stop_id'] as String};
      setState(() {
        if (myIds.isEmpty) {
          _myAssignedStops = List.of(_stops);
        } else {
          _myAssignedStops = _stops.where((s) => myIds.contains(s.id)).toList();
        }
        if (_nextStopId == null ||
            !_myAssignedStops.any((s) => s.id == _nextStopId)) {
          _nextStopId = _myAssignedStops.isEmpty ? null : _myAssignedStops.first.id;
        }
      });
    } catch (e) {
      debugPrint('AI assignment load failed: $e');
    }
  }

  /// Event channels: assignment changes (pre-trip reallocation) and bus
  /// availability changes (auto re-plan). Never fires on GPS updates.
  void _subscribeSlotChannels() {
    _assignChannel?.unsubscribe();
    _slotBusChannel?.unsubscribe();
    if (_selectedSlotId == null) return;
    final slotId = _selectedSlotId!;
    _assignChannel = _supabase
        .channel('slot-assign:$slotId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'stop_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'slot_id',
            value: slotId,
          ),
          callback: (_) async {
            if (_isTracking) return; // live trips are never silently changed
            await _loadMyAssignment();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trip assignment updated.')),
              );
            }
          },
        )
        .subscribe();
    _slotBusChannel = _supabase
        .channel('slot-buses:$slotId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'slot_buses',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'slot_id',
            value: slotId,
          ),
          callback: (_) async {
            if (_isTracking || _selectedSlotId == null) return;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Slot bus changed - re-planning stops...')),
              );
            }
            await _runAiPlan(silent: true);
          },
        )
        .subscribe();
  }

  void _unsubscribeSlotChannels() {
    _assignChannel?.unsubscribe();
    _assignChannel = null;
    _slotBusChannel?.unsubscribe();
    _slotBusChannel = null;
  }

  /// A* from the current GPS fix to the next assigned stop, over the road
  /// graph built from route stops. Recomputed only on: trip start, next-stop
  /// change, or significant deviation — never every GPS frame.
  Future<void> _computePathToNext({bool force = false}) async {
    if (_nextStopId == null || _lastPosition == null || _stops.isEmpty) return;
    if (!force &&
        _lastPathCompute != null &&
        DateTime.now().difference(_lastPathCompute!).inSeconds < 15) {
      return;
    }
    try {
      final graph = RoadGraph.fromStops(
        _stops.map((s) => GraphStop(id: s.id, name: s.name, lat: s.lat, lon: s.lon, sequence: s.sequence)).toList(),
      );
      // Temporary start node at the live GPS fix, linked to the 2 nearest stops.
      const gpsId = 'gps:live';
      final plat = _lastPosition!.latitude;
      final plon = _lastPosition!.longitude;
      graph.addNode(RoadNode(id: gpsId, label: 'Current location', lat: plat, lon: plon));
      final byDist = _stops.toList()
        ..sort((a, b) => RoadGraph.haversineM(plat, plon, a.lat, a.lon)
            .compareTo(RoadGraph.haversineM(plat, plon, b.lat, b.lon)));
      for (var i = 0; i < (byDist.length < 2 ? byDist.length : 2); i++) {
        final s = byDist[i];
        final dM = RoadGraph.haversineM(plat, plon, s.lat, s.lon);
        graph.addUndirectedEdge(
          id: 'gps-link:$i',
          a: gpsId,
          b: 'stop:${s.id}',
          cost: dM / 8.0,
          distanceM: dM,
        );
      }
      final res = const AStarService()
          .findPath(graph, gpsId, 'stop:$_nextStopId', recordTrace: false);
      _lastPathCompute = DateTime.now();
      if (!res.found) {
        setState(() => _astarInfo = 'A*: no road path to next stop');
        return;
      }
      final pts = <List<double>>[];
      final labels = <String>[];
      for (final id in res.path) {
        final n = graph.nodes[id]!;
        pts.add([n.lat, n.lon]);
        if (id != gpsId) labels.add(n.label);
      }
      final next = _stops.firstWhere((s) => s.id == _nextStopId);
      setState(() {
        _tripPathPoints = pts;
        final km = res.cost * 8.0 / 1000.0;
        final mins = res.cost / 60.0;
        _astarInfo =
            'A* to ${next.name}: ${km.toStringAsFixed(1)} km, ~${mins.toStringAsFixed(0)} min '
            '(${res.nodesExpanded} nodes explored)';
      });
      _drawTripPath();
    } catch (e) {
      debugPrint('A* path failed: $e');
    }
  }

  void _drawTripPath() {
    if (_tripPathPoints.length < 2) return;
    _sendToMap(
        '{"type":"drawPath","id":"trip-path","points":[${_tripPathPoints.map((p) => '[${p[0]},${p[1]}]').join(',')}]}');
  }

  /// Deviation guard called from the GPS stream: replan only when the bus
  /// has actually left the planned corridor (>150 m) — throttled inside
  /// [_computePathToNext].
  void _maybeReplanPath(Position position) {
    if (!_isTracking || _tripPathPoints.length < 2) return;
    var best = double.infinity;
    for (var i = 0; i < _tripPathPoints.length - 1; i++) {
      final d = _distToSegmentM(
        position.latitude,
        position.longitude,
        _tripPathPoints[i][0],
        _tripPathPoints[i][1],
        _tripPathPoints[i + 1][0],
        _tripPathPoints[i + 1][1],
      );
      if (d < best) best = d;
    }
    if (best > 150) {
      debugPrint('A*: deviation ${best.toStringAsFixed(0)} m - replanning');
      _computePathToNext(force: true);
    }
  }

  double _distToSegmentM(double plat, double plon, double alat, double alon, double blat, double blon) {
    // Equirectangular projection is plenty accurate at these scales.
    const r = 6371000.0;
    const k = 3.141592653589793 / 180.0;
    final mx = (alon + blon) / 2 * k;
    double x(double lon) => lon * k * r * math.cos(mx);
    double y(double lat) => lat * k * r;
    final px = x(plon), py = y(plat);
    final ax = x(alon), ay = y(alat);
    final bx = x(blon), by = y(blat);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  /// After a boarding is recorded, advance to the next ASSIGNED stop
  /// (skipped stops are simply never visited) and recompute the A* path.
  void _advanceAfterBoarding(String stopId) {
    if (_myAssignedStops.isEmpty) return;
    final idx = _myAssignedStops.indexWhere((s) => s.id == stopId);
    final nextIdx = idx == -1 ? 0 : idx + 1;
    setState(() {
      if (nextIdx < _myAssignedStops.length) {
        _nextStopId = _myAssignedStops[nextIdx].id;
      } else {
        _nextStopId = null; // terminus reached
        _tripPathPoints = [];
        _astarInfo = 'Terminus reached - all assigned stops served';
      }
    });
    if (_nextStopId != null) _computePathToNext(force: true);
  }

  String _nextStopName() {
    for (final s in _myAssignedStops) {
      if (s.id == _nextStopId) return s.name;
    }
    return _nextStopId == null ? 'terminus reached' : '…';
  }

  Future<void> _startTrip() async {
    if (_busId == null || _routeId == null) return;

    setState(() => _isLoading = true);
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // 1. Create a trip record (linked to its operating slot for AI assignments)
      final response = await _supabase.from('trips').insert({
        'bus_id': _busId,
        'driver_id': user.id,
        'route_id': _routeId,
        'slot_id': _selectedSlotId,
        'trip_date': DateTime.now().toIso8601String().split('T')[0],
        'status': 'in_progress',
        'started_at': DateTime.now().toIso8601String(),
      }).select('id').single();

      final tripId = response['id'] as String;

      setState(() {
        _activeTripId = tripId;
        _isTracking = true;
        _lastPosition = null;
      });

      _initWebView();
      _loadRouteStops();

      // AI: reload this trip's assignment, watch for pre-trip updates.
      await _loadMyAssignment();
      _subscribeSlotChannels();

      // 2. Activate background geolocation stream
      await _startLocationUpdates();

      // 3. Subscribe to arrival events for headcount prompts
      _subscribeToArrivals();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip started successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start trip: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _endTrip() async {
    if (_activeTripId == null) return;

    setState(() => _isLoading = true);
    try {
      // 1. Update trip record
      await _supabase.from('trips').update({
        'status': 'completed',
        'ended_at': DateTime.now().toIso8601String(),
      }).eq('id', _activeTripId!);

      // 2. Stop location updates
      await _stopLocationUpdates();

      // 3. Unsubscribe from arrival events
      _unsubscribeFromArrivals();
      _unsubscribeSlotChannels();

      setState(() {
        _activeTripId = null;
        _isTracking = false;
        _mapReady = false;
        _busMarkerAddedToMap = false;
        _webViewController = null;
        _stops.clear();
        _lastPosition = null;
        _myAssignedStops = [];
        _nextStopId = null;
        _tripPathPoints = [];
        _astarInfo = null;
        _cspStats = null;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip completed and stopped tracking.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to end trip: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _arrivalChannel?.unsubscribe();
    _unsubscribeSlotChannels();
    super.dispose();
  }

  Future<void> _locateMe() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _sendToMap(_enc({
        'type': 'flyToLocation',
        'lat': position.latitude,
        'lon': position.longitude,
      }));
    } catch (e) {
      debugPrint('Driver locate me failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _supabase.auth.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _isTracking ? null : () async {
              await _supabase.auth.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                );
              }
            },
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    color: const Color(0xFF1E1E1E),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Driver: ${_driverName ?? "Unknown"}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Assigned Bus: ${_busNumber ?? "No Bus Assigned"}',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: Colors.deepPurpleAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ---- AI planning panel (CSP slot plan + A* path) ----
                  Card(
                    color: const Color(0xFF1E1E1E),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.psychology,
                                  size: 18, color: Color(0xFF22C55E)),
                              const SizedBox(width: 6),
                              const Text('AI Slot Plan',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              if (!_isTracking && _slots.isNotEmpty)
                                DropdownButton<String>(
                                  value: _selectedSlotId,
                                  dropdownColor: const Color(0xFF1E1E1E),
                                  items: _slots
                                      .map((s) => DropdownMenuItem<String>(
                                            value: s['id'] as String,
                                            child: Text('${s['label']}',
                                                style: const TextStyle(fontSize: 13)),
                                          ))
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() => _selectedSlotId = v);
                                    _loadMyAssignment();
                                    _subscribeSlotChannels();
                                  },
                                ),
                            ],
                          ),
                          if (!_isTracking) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: (_planning ||
                                        _selectedSlotId == null ||
                                        _stops.isEmpty)
                                    ? null
                                    : () => _runAiPlan(),
                                icon: _planning
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.auto_awesome, size: 16),
                                label: Text(_planning ? 'Planning...' : 'AI Plan Stops (CSP)'),
                              ),
                            ),
                          ],
                          if (_cspStats != null) ...[
                            const SizedBox(height: 4),
                            Text(_cspStats!,
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF94A3B8))),
                          ],
                          if (_myAssignedStops.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              _isTracking
                                  ? 'Next: ${_nextStopName()}'
                                  : 'Your stops: ${_myAssignedStops.map((s) => s.name).join(' → ')}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF22C55E),
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                          if (_astarInfo != null && _isTracking) ...[
                            const SizedBox(height: 2),
                            Text(_astarInfo!,
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF94A3B8))),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        children: [
                          if (_webViewController != null)
                            WebViewWidget(controller: _webViewController!)
                          else
                            const Center(child: CircularProgressIndicator()),
                          Positioned(
                            bottom: 16,
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
                                child: const Icon(
                                  Icons.my_location,
                                  color: Color(0xFF6366F1),
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!_isTracking) ...[
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('START TRIP'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _busId != null ? _startTrip : null,
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.radar, color: Colors.red),
                          SizedBox(width: 8),
                          Text(
                            'TRIP IN PROGRESS (TRACKING LIVE)',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.stop),
                      label: const Text('END TRIP'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _endTrip,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
