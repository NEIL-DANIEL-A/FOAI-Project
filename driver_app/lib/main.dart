import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
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
  final _busNumberController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _isLoading = false;

  final _supabase = Supabase.instance.client;

  Future<void> _enterAsDriver() async {
    final name = _nameController.text.trim();
    final busNumber = _busNumberController.text.trim();

    if (name.isEmpty || busNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your name and bus number.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      // 1. Sign in anonymously — no email, no OTP needed
      final response = await _supabase.auth.signInAnonymously();
      final user = response.user;
      if (user == null) throw Exception('Anonymous sign-in failed');

      // 2. Validate bus number exists
      final busResponse = await _supabase
          .from('buses')
          .select('id')
          .eq('bus_number', busNumber)
          .maybeSingle();

      if (busResponse == null) {
        await _supabase.auth.signOut();
        throw Exception('Bus "$busNumber" not found — ask admin to add it first.');
      }

      final busId = busResponse['id'] as String;

      // 3. Insert driver profile
      await _supabase.from('users').insert({
        'id': user.id,
        'name': name,
        'phone': _phoneController.text.trim().isEmpty
            ? null
            : _phoneController.text.trim(),
        'role': 'driver',
      });

      // 4. Assign driver to bus
      await _supabase.from('driver_bus_assignments').insert({
        'driver_id': user.id,
        'bus_id': busId,
      });

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const TripDashboardScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _busNumberController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Sign Up')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Full Name'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _busNumberController,
                decoration: const InputDecoration(
                  labelText: 'Bus Number (e.g. 4)',
                  hintText: 'Must match system record',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone Number (Optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _isLoading ? null : _enterAsDriver,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text(
                        'Enter as Driver',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
  
  String? _activeTripId;
  bool _isTracking = false;
  StreamSubscription<Position>? _positionSubscription;
  RealtimeChannel? _arrivalChannel;
  final Set<String> _handledArrivalIds = {};

  @override
  void initState() {
    super.initState();
    _loadDriverDetails();
  }

  Future<void> _loadDriverDetails() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

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
          // Resume tracking if trip was in_progress
          _startLocationUpdates();
          _subscribeToArrivals();
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
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

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
    await flutterLocalNotificationsPlugin.cancel(888);
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
    await flutterLocalNotificationsPlugin.show(
      888,
      'Bus tracking active',
      'Your location is being shared for this trip.',
      details,
    );
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

  Future<void> _startTrip() async {
    if (_busId == null || _routeId == null) return;

    setState(() => _isLoading = true);
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // 1. Create a trip record
      final response = await _supabase.from('trips').insert({
        'bus_id': _busId,
        'driver_id': user.id,
        'route_id': _routeId,
        'trip_date': DateTime.now().toIso8601String().split('T')[0],
        'status': 'in_progress',
        'started_at': DateTime.now().toIso8601String(),
      }).select('id').single();

      final tripId = response['id'] as String;

      setState(() {
        _activeTripId = tripId;
        _isTracking = true;
      });

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

      setState(() {
        _activeTripId = null;
        _isTracking = false;
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
    super.dispose();
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
                mainAxisAlignment: MainAxisAlignment.center,
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
                            'Driver: ${user?.email ?? "Unknown"}',
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
                  const SizedBox(height: 48),
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
