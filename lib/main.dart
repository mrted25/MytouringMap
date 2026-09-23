import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'services/touring_service.dart';

const String agoraAppId = '398d30b96cae43aeac064c7a0fa9add8';
const String channelName = 'touring_room_1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Touring Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const MapScreen(),
    );
  }
}

class Member {
  final String id;
  final String name;
  final LatLng location;
  final String status;
  final Color color;
  final String vehicleType;
  final double heading;

  Member({
    required this.id,
    required this.name,
    required this.location,
    required this.status,
    required this.color,
    required this.vehicleType,
    required this.heading,
  });
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ==========================================================
  // LOCAL SESSION
  // ==========================================================

  static const String _prefTouringId = 'active_touring_id';
  static const String _prefTouringCode = 'active_touring_code';
  static const String _prefTouringName = 'active_touring_name';
  static const String _prefIsCaptain = 'active_touring_is_captain';
  static const String _prefMyName = 'active_touring_my_name';
  static const String _prefVehicleType = 'active_touring_vehicle_type';
  static const String _prefIsTouring = 'active_touring_is_touring';

  bool _isRestoringSession = false;

  // ==========================================================
  // ROUTE
  // ==========================================================

  LatLng _titikKumpul = const LatLng(
    -6.175392,
    106.827153,
  );

  LatLng _destinasi = const LatLng(
    -6.229728,
    106.846548,
  );

  List<LatLng> _routePoints = [];

  double _routeDistanceKm = 0;
  double _routeDurationMinutes = 0;

  bool _isLoadingRoute = false;

  Position? _lastRoutePosition;

  final double _rerouteDistanceMeters = 50;

  bool _mapPickingMode = false;
  String _pickingTarget = '';

  // ==========================================================
  // GPS
  // ==========================================================

  Position? _currentPosition;

  StreamSubscription<Position>? _positionStream;

  double _distanceInKm = 0;
  int _estimatedMinutes = 0;

  String _gpsStatus = 'GPS belum aktif';
  bool _locationReady = false;

  double _heading = 0;

  // ==========================================================
  // TOURING
  // ==========================================================

  bool _isTouring = false;

  DateTime? _touringStartTime;

  String? _activeTouringId;
  String? _activeTouringCode;
  String? _activeTouringName;

  bool _isCaptain = false;

  String _myName = 'Road Captain';
  String _myVehicleType = 'Motor';

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _membersSubscription;

  DateTime? _lastMemberUpload;

  // ==========================================================
  // MEMBERS
  // ==========================================================

  final List<Member> _groupMembers = [];

  // ==========================================================
  // VEHICLE
  // ==========================================================

  bool _isMotorMode = true;

  // ==========================================================
  // MAP TILE
  // ==========================================================

  final Map<String, String> _tileProviders = {
    'Standard':
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'Dark Mode':
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
    'Humanitarian':
        'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
  };

  String _selectedTile = 'Standard';

  // ==========================================================
  // AGORA PTT
  // ==========================================================

  RtcEngine? _engine;

  bool _isPttInitialized = false;
  bool _isTalking = false;
  bool _microphoneEnabled = false;

  // ==========================================================
  // INIT
  // ==========================================================

  @override
void initState() {
  super.initState();

  _initializeGPS();

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!kIsWeb) {
      await _initAgoraPTT();
    }

    await _restoreTouringSession();
  });
}

  // ==========================================================
  // SAVE LOCAL TOURING SESSION
  // ==========================================================

  Future<void> _saveTouringSession() async {
    if (_activeTouringId == null) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(
        _prefTouringId,
        _activeTouringId!,
      );

      await prefs.setString(
        _prefTouringCode,
        _activeTouringCode ?? '',
      );

      await prefs.setString(
        _prefTouringName,
        _activeTouringName ?? '',
      );

      await prefs.setBool(
        _prefIsCaptain,
        _isCaptain,
      );

      await prefs.setString(
        _prefMyName,
        _myName,
      );

      await prefs.setString(
        _prefVehicleType,
        _myVehicleType,
      );

      await prefs.setBool(
        _prefIsTouring,
        _isTouring,
      );
    } catch (e) {
      debugPrint(
        'Save touring session error: $e',
      );
    }
  }

  // ==========================================================
  // CLEAR LOCAL TOURING SESSION
  // ==========================================================

  Future<void> _clearTouringSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.remove(_prefTouringId);
      await prefs.remove(_prefTouringCode);
      await prefs.remove(_prefTouringName);
      await prefs.remove(_prefIsCaptain);
      await prefs.remove(_prefMyName);
      await prefs.remove(_prefVehicleType);
      await prefs.remove(_prefIsTouring);
    } catch (e) {
      debugPrint(
        'Clear touring session error: $e',
      );
    }
  }

  // ==========================================================
  // RESTORE TOURING SESSION
  // ==========================================================

  Future<void> _restoreTouringSession() async {
    if (_isRestoringSession || !mounted) {
      return;
    }

    _isRestoringSession = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      final touringId =
          prefs.getString(_prefTouringId);

      if (touringId == null ||
          touringId.isEmpty) {
        return;
      }

      final touringDoc = await _firestore
          .collection('tourings')
          .doc(touringId)
          .get();

      // Touring sudah tidak ada.
      if (!touringDoc.exists) {
        await _clearTouringSession();
        return;
      }

      final data = touringDoc.data();

      if (data == null) {
        await _clearTouringSession();
        return;
      }

      final rootStatus =
          data['status']?.toString() ?? 'waiting';

      // Kalau touring sudah selesai,
      // hapus sesi lokal supaya tidak muncul lagi.
      if (rootStatus == 'finished') {
        await _clearTouringSession();
        return;
      }

      final savedCode =
          prefs.getString(_prefTouringCode) ??
              data['code']?.toString() ??
              '';

      final savedName =
          prefs.getString(_prefTouringName) ??
              data['name']?.toString() ??
              'Touring';

      final savedIsCaptain =
          prefs.getBool(_prefIsCaptain) ??
              false;

      final savedMyName =
          prefs.getString(_prefMyName) ??
              (savedIsCaptain
                  ? 'Road Captain'
                  : 'Member');

      final savedVehicle =
          prefs.getString(_prefVehicleType) ??
              'Motor';

      final savedIsTouring =
          prefs.getBool(_prefIsTouring) ??
              false;

      final startLat =
          (data['startLat'] as num?)?.toDouble();

      final startLng =
          (data['startLng'] as num?)?.toDouble();

      final destinationLat =
          (data['destinationLat'] as num?)
              ?.toDouble();

      final destinationLng =
          (data['destinationLng'] as num?)
              ?.toDouble();

      if (!mounted) return;

      final shouldContinue =
          await _showResumeTouringDialog(
        touringName: savedName,
        touringCode: savedCode,
        isCaptain: savedIsCaptain,
        isTouring: savedIsTouring,
      );

      if (!shouldContinue) {
        // Tandai diri sebagai keluar dari sesi.
        setState(() {
          _activeTouringId = touringId;
          _activeTouringCode = savedCode;
          _activeTouringName = savedName;
          _isCaptain = savedIsCaptain;
          _myName = savedMyName;
          _myVehicleType = savedVehicle;

          _isMotorMode =
              savedVehicle.toLowerCase() == 'motor' ||
              savedVehicle.toLowerCase() == 'scooter';
        });

        await _saveMyMember(
          status: 'Left',
        );

        await _clearTouringSession();

        if (mounted) {
          setState(() {
            _activeTouringId = null;
            _activeTouringCode = null;
            _activeTouringName = null;
            _isCaptain = false;
            _isTouring = false;
            _groupMembers.clear();
          });
        }

        return;
      }

      setState(() {
        _activeTouringId = touringId;
        _activeTouringCode = savedCode;
        _activeTouringName = savedName;
        _isCaptain = savedIsCaptain;
        _myName = savedMyName;
        _myVehicleType = savedVehicle;
        _isTouring = savedIsTouring;

        _isMotorMode =
            savedVehicle.toLowerCase() == 'motor' ||
            savedVehicle.toLowerCase() == 'scooter';

        if (startLat != null &&
            startLng != null) {
          _titikKumpul = LatLng(
            startLat,
            startLng,
          );
        }

        if (destinationLat != null &&
            destinationLng != null) {
          _destinasi = LatLng(
            destinationLat,
            destinationLng,
          );
        }
      });

      _subscribeToTouringMembers(
        touringId,
      );

      await _saveMyMember(
        status: _isTouring
            ? 'Riding'
            : 'Joined',
      );

      if (_currentPosition != null) {
        await _getRoadRoute(
          fromCurrentLocation: _isTouring,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isTouring
                  ? 'Touring sebelumnya dilanjutkan.'
                  : 'Touring sebelumnya ditemukan.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'Restore touring session error: $e',
      );
    } finally {
      _isRestoringSession = false;
    }
  }

  // ==========================================================
  // RESUME DIALOG
  // ==========================================================

  Future<bool> _showResumeTouringDialog({
    required String touringName,
    required String touringCode,
    required bool isCaptain,
    required bool isTouring,
  }) async {
    if (!mounted) {
      return false;
    }

    final result =
        await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              const Icon(
                Icons.restore,
                color: Colors.blue,
              ),
              const SizedBox(
                width: 10,
              ),
              const Expanded(
                child: Text(
                  'Touring Sebelumnya Ditemukan',
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                touringName.isEmpty
                    ? 'Touring'
                    : touringName,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 12,
              ),
              Row(
                children: [
                  const Icon(
                    Icons.confirmation_number,
                    size: 18,
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Text(
                    'Kode: $touringCode',
                  ),
                ],
              ),
              const SizedBox(
                height: 8,
              ),
              Row(
                children: [
                  Icon(
                    isCaptain
                        ? Icons
                            .admin_panel_settings
                        : Icons.person,
                    size: 18,
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Text(
                    isCaptain
                        ? 'Road Captain'
                        : 'Anggota',
                  ),
                ],
              ),
              const SizedBox(
                height: 8,
              ),
              Row(
                children: [
                  const Icon(
                    Icons.directions_car,
                    size: 18,
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Text(
                    isTouring
                        ? 'Status: Sedang Touring'
                        : 'Status: Belum dimulai',
                  ),
                ],
              ),
              const SizedBox(
                height: 18,
              ),
              const Text(
                'Data touring masih tersimpan di perangkat ini.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  false,
                );
              },
              child: const Text(
                'Keluar dari Sesi',
              ),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(
                  context,
                  true,
                );
              },
              icon: const Icon(
                Icons.play_arrow,
              ),
              label: const Text(
                'Lanjutkan Touring',
              ),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  // ==========================================================
  // GPS
  // ==========================================================

  Future<void> _initializeGPS() async {
    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _gpsStatus = 'GPS mati';
          });
        }

        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission ==
          LocationPermission.denied) {
        permission =
            await Geolocator.requestPermission();
      }

      if (permission ==
              LocationPermission.denied ||
          permission ==
              LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _gpsStatus =
                'Izin GPS ditolak';
          });
        }

        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy:
            LocationAccuracy.high,
      );

      _handlePosition(position);

      _positionStream =
          Geolocator.getPositionStream(
        locationSettings:
            const LocationSettings(
          accuracy:
              LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        _handlePosition,
      );

      if (mounted) {
        setState(() {
          _gpsStatus =
              'GPS aktif';
          _locationReady = true;
        });
      }
    } catch (e) {
      debugPrint(
        'GPS error: $e',
      );

      if (mounted) {
        setState(() {
          _gpsStatus =
              'GPS error';
        });
      }
    }
  }

  void _handlePosition(
    Position position,
  ) {
    if (!mounted) return;

    if (position.heading >= 0 &&
        position.speed > 1.0) {
      _heading =
          position.heading;
    }

    setState(() {
      _currentPosition =
          position;

      _distanceInKm =
          Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            _destinasi.latitude,
            _destinasi.longitude,
          ) /
          1000;

      _estimatedMinutes =
          (_distanceInKm / 40 * 60)
              .round();

      _gpsStatus =
          'GPS aktif';

      _locationReady =
          true;
    });

    if (_activeTouringId !=
        null) {
      _updateMyMemberLocation(
        position,
      );
    }

    if (_isTouring) {
      if (_lastRoutePosition ==
          null) {
        _getRoadRoute();
      } else {
        final distance =
            Geolocator.distanceBetween(
          _lastRoutePosition!
              .latitude,
          _lastRoutePosition!
              .longitude,
          position.latitude,
          position.longitude,
        );

        if (distance >=
            _rerouteDistanceMeters) {
          _getRoadRoute();
        }
      }
    }
  }

  // ==========================================================
  // CENTER LOCATION
  // ==========================================================

  void _centerMyLocation() {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Lokasi GPS belum tersedia.',
          ),
        ),
      );

      return;
    }

    _mapController.move(
      LatLng(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      ),
      16,
    );
  }

  // ==========================================================
  // OSRM ROUTE
  // ==========================================================

  Future<void> _getRoadRoute({
  bool fromCurrentLocation = true,
}) async {
  if (_isLoadingRoute) return;

  LatLng start;

  if (fromCurrentLocation) {
    if (_currentPosition == null) {
      return;
    }

    start = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
  } else {
    start = _titikKumpul;
  }

  if (mounted) {
    setState(() {
      _isLoadingRoute = true;
    });
  }

  try {
    final url =
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${_destinasi.longitude},${_destinasi.latitude}'
        '?overview=full'
        '&geometries=geojson'
        '&alternatives=3';

    final response = await http.get(
      Uri.parse(url),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'OSRM HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body);

    final routes = data['routes'] as List?;

    if (routes == null || routes.isEmpty) {
      throw Exception(
        'Rute tidak ditemukan',
      );
    }

    final options = <RouteOption>[];

    for (
      int i = 0;
      i < routes.length && i < 3;
      i++
    ) {
      final route =
          routes[i] as Map<String, dynamic>;

      final geometry =
          route['geometry']
              as Map<String, dynamic>;

      final coordinates =
          geometry['coordinates'] as List;

      final points =
          coordinates.map<LatLng>((item) {
        return LatLng(
          (item[1] as num).toDouble(),
          (item[0] as num).toDouble(),
        );
      }).toList();

      final distanceMeters =
          (route['distance'] as num)
              .toDouble();

      final durationSeconds =
          (route['duration'] as num)
              .toDouble();

      String label;

      if (i == 0) {
        label = 'Rute tercepat';
      } else {
        label = 'Alternatif $i';
      }

      options.add(
        RouteOption(
          label: label,
          points: points,
          distanceKm:
              distanceMeters / 1000,
          durationMinutes:
              durationSeconds / 60,
        ),
      );
    }

    if (options.isEmpty) {
      throw Exception(
        'Tidak ada pilihan rute.',
      );
    }

    if (fromCurrentLocation) {
      _lastRoutePosition =
          _currentPosition;
    }

    // Pertahankan pilihan rute sebelumnya
    // apabila masih tersedia.
    int selectedIndex =
        _selectedRouteIndex;

    if (selectedIndex >=
        options.length) {
      selectedIndex = 0;
    }

    final selected =
        options[selectedIndex];

    if (mounted) {
      setState(() {
        _routeOptions = options;

        _selectedRouteIndex =
            selectedIndex;

        _routePoints =
            selected.points;

        _routeDistanceKm =
            selected.distanceKm;

        _routeDurationMinutes =
            selected.durationMinutes;

        _isLoadingRoute = false;
      });
    }
  } catch (e) {
    debugPrint(
      'Route error: $e',
    );

    if (mounted) {
      setState(() {
        _isLoadingRoute = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Gagal mencari rute: $e',
          ),
        ),
      );
    }
  }
}

  // ==========================================================
  // START TOURING
  // ==========================================================

  Future<void> _startTouring() async {
    if (_activeTouringId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Buat atau join touring terlebih dahulu.',
          ),
        ),
      );

      return;
    }

    if (_currentPosition == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Lokasi GPS belum tersedia.',
          ),
        ),
      );

      return;
    }

    setState(() {
      _isTouring = true;
      _touringStartTime =
          DateTime.now();
    });

    // Captain mengubah status group menjadi active.
    if (_isCaptain &&
        _activeTouringId != null) {
      try {
        await _firestore
            .collection('tourings')
            .doc(_activeTouringId)
            .set(
          {
            'status': 'active',
            'startedAt':
                FieldValue
                    .serverTimestamp(),
          },
          SetOptions(
            merge: true,
          ),
        );
      } catch (e) {
        debugPrint(
          'Update touring active error: $e',
        );
      }
    }

    await _getRoadRoute(
      fromCurrentLocation: true,
    );

    await _saveMyMember(
      status: 'Riding',
    );

    await _saveTouringSession();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Touring dimulai',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // STOP TOURING
  // ==========================================================

  Future<void> _stopTouring() async {
    setState(() {
      _isTouring = false;
    });

    await _saveMyMember(
      status: 'Stopped',
    );

    await _saveTouringSession();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Touring dihentikan sementara',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // FINISH TOURING
  // ==========================================================

  Future<void> _finishTouring() async {
    final touringId =
        _activeTouringId;

    if (touringId == null) {
      return;
    }

    final confirmed =
        await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Selesaikan Touring?',
          ),
          content: const Text(
            'Touring akan ditandai sebagai selesai. '
            'Setelah selesai, sesi ini tidak akan ditawarkan lagi '
            'saat aplikasi dibuka.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  false,
                );
              },
              child:
                  const Text('Batal'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(
                  context,
                  true,
                );
              },
              icon: const Icon(
                Icons.flag,
              ),
              label:
                  const Text(
                'Selesaikan',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      setState(() {
        _isTouring = false;
      });

      await _saveMyMember(
        status: 'Finished',
      );

      if (_isCaptain) {
        await _firestore
            .collection('tourings')
            .doc(touringId)
            .set(
          {
            'status': 'finished',
            'finishedAt':
                FieldValue
                    .serverTimestamp(),
          },
          SetOptions(
            merge: true,
          ),
        );
      }

      await _clearTouringSession();

      await _membersSubscription
          ?.cancel();

      if (mounted) {
        setState(() {
          _activeTouringId =
              null;
          _activeTouringCode =
              null;
          _activeTouringName =
              null;
          _isCaptain = false;
          _isTouring = false;
          _groupMembers.clear();
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          const SnackBar(
            content: Text(
              'Touring telah diselesaikan.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'Finish touring error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text(
              'Gagal menyelesaikan touring: $e',
            ),
          ),
        );
      }
    }
  }

  // ==========================================================
  // LEAVE TOURING - MEMBER
  // ==========================================================

  Future<void> _leaveTouring() async {
    final touringId =
        _activeTouringId;

    if (touringId == null) {
      return;
    }

    final confirmed =
        await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Keluar dari Touring?',
          ),
          content: const Text(
            'Anda akan keluar dari sesi touring di perangkat ini. '
            'Touring tetap berjalan untuk anggota lainnya.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  false,
                );
              },
              child:
                  const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  true,
                );
              },
              child:
                  const Text('Keluar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      await _saveMyMember(
        status: 'Left',
      );

      await _clearTouringSession();

      await _membersSubscription
          ?.cancel();

      if (mounted) {
        setState(() {
          _activeTouringId =
              null;
          _activeTouringCode =
              null;
          _activeTouringName =
              null;
          _isCaptain = false;
          _isTouring = false;
          _groupMembers.clear();
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          const SnackBar(
            content: Text(
              'Anda telah keluar dari touring.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'Leave touring error: $e',
      );
    }
  }

  // ==========================================================
  // NOMINATIM SEARCH
  // ==========================================================

  Future<List<Map<String, dynamic>>> _searchPlaces(
    String query,
  ) async {
    final trimmed =
        query.trim();

    if (trimmed.isEmpty) {
      return [];
    }

    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/search',
      {
        'q': trimmed,
        'format': 'jsonv2',
        'limit': '8',
        'countrycodes': 'id',
        'addressdetails': '1',
        'accept-language': 'id',
      },
    );

    final response =
        await http.get(
      uri,
      headers: const {
        'User-Agent':
            'TouringMap/1.0 (Flutter OpenStreetMap Nominatim client)',
        'Accept':
            'application/json',
      },
    );

    if (response.statusCode !=
        200) {
      throw Exception(
        'Pencarian tempat gagal '
        '(HTTP ${response.statusCode})',
      );
    }

    final decoded =
        jsonDecode(
      response.body,
    );

    if (decoded is! List) {
      return [];
    }

    return decoded
        .whereType<Map>()
        .map<Map<String, dynamic>>(
          (item) =>
              Map<String, dynamic>.from(
            item,
          ),
        )
        .toList();
  }

  // ==========================================================
  // SEARCH PLACE DIALOG
  // ==========================================================

  Future<void> _showPlaceSearchDialog(
    String target,
  ) async {
    final controller =
        TextEditingController();

    List<Map<String, dynamic>>
        results = [];

    bool isSearching = false;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            Future<void> doSearch() async {
              final query =
                  controller.text.trim();

              if (query.isEmpty) {
                return;
              }

              setDialogState(() {
                isSearching = true;
                results = [];
              });

              try {
                final searchResults =
                    await _searchPlaces(
                  query,
                );

                if (context.mounted) {
                  setDialogState(() {
                    results =
                        searchResults;
                    isSearching =
                        false;
                  });
                }
              } catch (e) {
                if (context.mounted) {
                  setDialogState(() {
                    isSearching =
                        false;
                  });

                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Gagal mencari tempat: $e',
                      ),
                    ),
                  );
                }
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    target == 'start'
                        ? Icons.location_on
                        : Icons.flag,
                    color:
                        target == 'start'
                            ? Colors.green
                            : Colors.red,
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: Text(
                      target == 'start'
                          ? 'Cari Titik Kumpul'
                          : 'Cari Destinasi',
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width:
                    double.maxFinite,
                height: 420,
                child: Column(
                  children: [
                    TextField(
                      controller:
                          controller,
                      autofocus: true,
                      textInputAction:
                          TextInputAction.search,
                      onSubmitted: (_) {
                        doSearch();
                      },
                      decoration:
                          InputDecoration(
                        hintText:
                            'Contoh: Indomaret Cibinong',
                        prefixIcon:
                            const Icon(
                          Icons.search,
                        ),
                        suffixIcon:
                            IconButton(
                          onPressed:
                              isSearching
                                  ? null
                                  : doSearch,
                          icon:
                              const Icon(
                            Icons.search,
                          ),
                        ),
                        border:
                            const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(
                      height: 12,
                    ),
                    if (isSearching)
                      const Padding(
                        padding:
                            EdgeInsets.all(
                          20,
                        ),
                        child:
                            CircularProgressIndicator(),
                      )
                    else if (results.isEmpty)
                      const Expanded(
                        child: Center(
                          child: Text(
                            'Ketik nama tempat lalu tekan cari.',
                            textAlign:
                                TextAlign.center,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child:
                            ListView.separated(
                          itemCount:
                              results.length,
                          separatorBuilder:
                              (
                            context,
                            index,
                          ) =>
                                  const Divider(
                            height: 1,
                          ),
                          itemBuilder:
                              (
                            context,
                            index,
                          ) {
                            final result =
                                results[index];

                            final displayName =
                                result[
                                        'display_name']
                                    ?.toString() ??
                                'Tempat tanpa nama';

                            final lat =
                                double.tryParse(
                              result[
                                      'lat']
                                  ?.toString() ??
                                  '',
                            );

                            final lon =
                                double.tryParse(
                              result[
                                      'lon']
                                  ?.toString() ??
                                  '',
                            );

                            return ListTile(
                              leading:
                                  Icon(
                                target ==
                                        'start'
                                    ? Icons
                                        .location_on
                                    : Icons.flag,
                                color:
                                    target ==
                                            'start'
                                        ? Colors
                                            .green
                                        : Colors
                                            .red,
                              ),
                              title:
                                  Text(
                                displayName,
                                maxLines:
                                    3,
                                overflow:
                                    TextOverflow
                                        .ellipsis,
                              ),
                              onTap:
                                  lat == null ||
                                          lon ==
                                              null
                                      ? null
                                      : () {
                                          final point =
                                              LatLng(
                                            lat,
                                            lon,
                                          );

                                          if (target ==
                                              'start') {
                                            setState(
                                              () {
                                                _titikKumpul =
                                                    point;
                                              },
                                            );
                                          } else {
                                            setState(
                                              () {
                                                _destinasi =
                                                    point;
                                              },
                                            );
                                          }

                                          Navigator.pop(
                                            context,
                                          );

                                          _getRoadRoute(
                                            fromCurrentLocation:
                                                _isTouring,
                                          );

                                          _mapController
                                              .move(
                                            point,
                                            16,
                                          );
                                        },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      context,
                    );
                  },
                  child:
                      const Text('Tutup'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }

  // ==========================================================
  // SET ROUTE
  // ==========================================================

  Future<void> _showSetRouteDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Atur Rute',
          ),
          content:
              SingleChildScrollView(
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                ListTile(
                  leading:
                      const Icon(
                    Icons.location_on,
                    color:
                        Colors.green,
                  ),
                  title:
                      const Text(
                    'Titik Kumpul',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  subtitle:
                      Text(
                    '${_titikKumpul.latitude.toStringAsFixed(6)}, '
                    '${_titikKumpul.longitude.toStringAsFixed(6)}',
                  ),
                  trailing:
                      IconButton(
                    tooltip:
                        'Cari tempat',
                    icon:
                        const Icon(
                      Icons.search,
                    ),
                    onPressed:
                        () {
                      Navigator.pop(
                        context,
                      );

                      _showPlaceSearchDialog(
                        'start',
                      );
                    },
                  ),
                  onTap: () {
                    Navigator.pop(
                      context,
                    );

                    setState(() {
                      _mapPickingMode =
                          true;
                      _pickingTarget =
                          'start';
                    });

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(
                      const SnackBar(
                        content:
                            Text(
                          'Tap map untuk memilih titik kumpul.',
                        ),
                      ),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading:
                      const Icon(
                    Icons.flag,
                    color:
                        Colors.red,
                  ),
                  title:
                      const Text(
                    'Destinasi',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  subtitle:
                      Text(
                    '${_destinasi.latitude.toStringAsFixed(6)}, '
                    '${_destinasi.longitude.toStringAsFixed(6)}',
                  ),
                  trailing:
                      IconButton(
                    tooltip:
                        'Cari tempat',
                    icon:
                        const Icon(
                      Icons.search,
                    ),
                    onPressed:
                        () {
                      Navigator.pop(
                        context,
                      );

                      _showPlaceSearchDialog(
                        'destination',
                      );
                    },
                  ),
                  onTap: () {
                    Navigator.pop(
                      context,
                    );

                    setState(() {
                      _mapPickingMode =
                          true;
                      _pickingTarget =
                          'destination';
                    });

                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(
                      const SnackBar(
                        content:
                            Text(
                          'Tap map untuk memilih destinasi.',
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(
                  height: 12,
                ),
                SizedBox(
                  width:
                      double.infinity,
                  child:
                      ElevatedButton
                          .icon(
                    onPressed: () {
                      Navigator.pop(
                        context,
                      );

                      if (_currentPosition !=
                          null) {
                        setState(() {
                          _titikKumpul =
                              LatLng(
                            _currentPosition!
                                .latitude,
                            _currentPosition!
                                .longitude,
                          );
                        });

                        _getRoadRoute(
                          fromCurrentLocation:
                              _isTouring,
                        );
                      } else {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(
                          const SnackBar(
                            content:
                                Text(
                              'Lokasi GPS belum tersedia.',
                            ),
                          ),
                        );
                      }
                    },
                    icon:
                        const Icon(
                      Icons.my_location,
                    ),
                    label:
                        const Text(
                      'Gunakan Lokasi Saya sebagai Titik Kumpul',
                    ),
                  ),
                ),
                const SizedBox(
                  height: 8,
                ),
                const Text(
                  'Tip: tekan ikon 🔍 untuk mencari tempat berdasarkan nama.',
                  textAlign:
                      TextAlign.center,
                  style:
                      TextStyle(
                    fontSize: 12,
                    color:
                        Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // MAP TAP
  // ==========================================================

  void _handleMapTap(
    TapPosition tapPosition,
    LatLng point,
  ) {
    if (!_mapPickingMode) {
      return;
    }

    if (_pickingTarget ==
        'start') {
      setState(() {
        _titikKumpul =
            point;
        _mapPickingMode =
            false;
        _pickingTarget =
            '';
      });
    } else if (_pickingTarget ==
        'destination') {
      setState(() {
        _destinasi =
            point;
        _mapPickingMode =
            false;
        _pickingTarget =
            '';
      });
    }

    _getRoadRoute(
      fromCurrentLocation:
          _isTouring,
    );
  }

  // ==========================================================
  // CREATE TOURING
  // ==========================================================

  Future<void> _showCreateTouringDialog() async {
    final nameController =
        TextEditingController();

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Buat Touring',
          ),
          content:
              TextField(
            controller:
                nameController,
            decoration:
                const InputDecoration(
              labelText:
                  'Nama Touring',
              hintText:
                  'Contoh: Touring Bogor',
              border:
                  OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                );
              },
              child:
                  const Text(
                'Batal',
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                final name =
                    nameController
                        .text
                        .trim();

                if (name.isEmpty) {
                  return;
                }

                Navigator.pop(
                  context,
                );

                await _createTouring(
                  name,
                );
              },
              child:
                  const Text(
                'Buat',
              ),
            ),
          ],
        );
      },
    );

    nameController.dispose();
  }

  Future<void> _createTouring(
    String name,
  ) async {
    try {
      final user =
          FirebaseAuth.instance
              .currentUser;

      if (user == null) {
        throw Exception(
          'Firebase user belum tersedia.',
        );
      }

      final service =
          TouringService();

      final code =
          await service.createTouring(
        name: name,
        captainId:
            user.uid,
        captainName:
            'Road Captain',
        startLat:
            _titikKumpul.latitude,
        startLng:
            _titikKumpul.longitude,
        destinationLat:
            _destinasi.latitude,
        destinationLng:
            _destinasi.longitude,
      );

      final query =
          await _firestore
              .collection(
                'tourings',
              )
              .where(
                'code',
                isEqualTo: code,
              )
              .limit(1)
              .get();

      if (query.docs.isEmpty) {
        throw Exception(
          'Dokumen touring tidak ditemukan.',
        );
      }

      final touringDoc =
          query.docs.first;

      setState(() {
        _activeTouringId =
            touringDoc.id;

        _activeTouringCode =
            code;

        _activeTouringName =
            name;

        _isCaptain = true;

        _myName =
            'Road Captain';

        _myVehicleType =
            _isMotorMode
                ? 'Motor'
                : 'SUV';
      });

      // SIMPAN SESI LOKAL
      await _saveTouringSession();

      await _saveMyMember(
        status: 'Joined',
      );

      _subscribeToTouringMembers(
        touringDoc.id,
      );

      await _showTouringCreatedDialog(
        name,
        code,
      );
    } catch (e) {
      debugPrint(
        'Create touring error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text(
              'Gagal membuat touring: $e',
            ),
          ),
        );
      }
    }
  }

  // ==========================================================
  // TOURING CODE DIALOG
  // ==========================================================

  Future<void> _showTouringCreatedDialog(
    String name,
    String code,
  ) async {
    await showDialog(
      context: context,
      barrierDismissible:
          false,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Touring Berhasil Dibuat',
          ),
          content:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              Text(
                name,
                style:
                    const TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              const SizedBox(
                height: 20,
              ),
              const Text(
                'Kode Touring',
              ),
              const SizedBox(
                height: 8,
              ),
              SelectableText(
                code,
                style:
                    const TextStyle(
                  fontSize: 32,
                  fontWeight:
                      FontWeight.bold,
                  letterSpacing:
                      5,
                ),
              ),
              const SizedBox(
                height: 15,
              ),
              const Text(
                'Bagikan kode ini kepada anggota touring.',
                textAlign:
                    TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed:
                  () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: code,
                  ),
                );

                if (context
                    .mounted) {
                  ScaffoldMessenger
                      .of(
                    context,
                  ).showSnackBar(
                    const SnackBar(
                      content:
                          Text(
                        'Kode berhasil disalin.',
                      ),
                    ),
                  );
                }
              },
              icon:
                  const Icon(
                Icons.copy,
              ),
              label:
                  const Text(
                'Copy',
              ),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(
                  context,
                );
              },
              child:
                  const Text(
                'OK',
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // JOIN TOURING
  // ==========================================================

  Future<void> _showJoinTouringDialog() async {
    final codeController =
        TextEditingController();

    final nameController =
        TextEditingController();

    String selectedVehicle =
        'Motor';

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              title:
                  const Text(
                'Join Touring',
              ),
              content:
                  SingleChildScrollView(
                child:
                    Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    TextField(
                      controller:
                          codeController,
                      textCapitalization:
                          TextCapitalization
                              .characters,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Kode Touring',
                        hintText:
                            'Contoh: A7K9P2',
                        border:
                            OutlineInputBorder(),
                        prefixIcon:
                            Icon(
                          Icons
                              .confirmation_number,
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 15,
                    ),
                    TextField(
                      controller:
                          nameController,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Nama Anggota',
                        hintText:
                            'Masukkan nama',
                        border:
                            OutlineInputBorder(),
                        prefixIcon:
                            Icon(
                          Icons.person,
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 15,
                    ),
                    DropdownButtonFormField<
                        String>(
                      value:
                          selectedVehicle,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Jenis Kendaraan',
                        border:
                            OutlineInputBorder(),
                      ),
                      items:
                          const [
                        DropdownMenuItem(
                          value:
                              'Motor',
                          child:
                              Text(
                            'Motor',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Scooter',
                          child:
                              Text(
                            'Scooter',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Mobil',
                          child:
                              Text(
                            'Mobil',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'SUV',
                          child:
                              Text(
                            'SUV',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Truck',
                          child:
                              Text(
                            'Truck',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Van',
                          child:
                              Text(
                            'Van',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Taxi',
                          child:
                              Text(
                            'Taxi',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'Sepeda',
                          child:
                              Text(
                            'Sepeda',
                          ),
                        ),
                      ],
                      onChanged:
                          (value) {
                        if (value !=
                            null) {
                          setDialogState(
                            () {
                              selectedVehicle =
                                  value;
                            },
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      () {
                    Navigator.pop(
                      context,
                    );
                  },
                  child:
                      const Text(
                    'Batal',
                  ),
                ),
                ElevatedButton.icon(
                  onPressed:
                      () async {
                    final code =
                        codeController
                            .text
                            .trim()
                            .toUpperCase();

                    final name =
                        nameController
                            .text
                            .trim();

                    if (code.isEmpty ||
                        name.isEmpty) {
                      ScaffoldMessenger
                          .of(
                        context,
                      ).showSnackBar(
                        const SnackBar(
                          content:
                              Text(
                            'Kode dan nama harus diisi.',
                          ),
                        ),
                      );

                      return;
                    }

                    Navigator.pop(
                      context,
                    );

                    await _joinTouring(
                      code: code,
                      name: name,
                      vehicleType:
                          selectedVehicle,
                    );
                  },
                  icon:
                      const Icon(
                    Icons.login,
                  ),
                  label:
                      const Text(
                    'Join',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    codeController.dispose();
    nameController.dispose();
  }

  Future<void> _joinTouring({
    required String code,
    required String name,
    required String vehicleType,
  }) async {
    try {
      final user =
          FirebaseAuth.instance
              .currentUser;

      if (user == null) {
        throw Exception(
          'Firebase user belum tersedia.',
        );
      }

      final query =
          await _firestore
              .collection(
                'tourings',
              )
              .where(
                'code',
                isEqualTo: code,
              )
              .limit(1)
              .get();

      if (query.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            const SnackBar(
              content: Text(
                'Kode touring tidak ditemukan.',
              ),
            ),
          );
        }

        return;
      }

      final touringDoc =
          query.docs.first;

      final data =
          touringDoc.data();

      // Jangan join touring yang sudah selesai.
      if (data['status']
              ?.toString() ==
          'finished') {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            const SnackBar(
              content: Text(
                'Touring ini sudah selesai.',
              ),
            ),
          );
        }

        return;
      }

      final startLat =
          (data['startLat']
                  as num?)
              ?.toDouble();

      final startLng =
          (data['startLng']
                  as num?)
              ?.toDouble();

      final destinationLat =
          (data[
                      'destinationLat']
                  as num?)
              ?.toDouble();

      final destinationLng =
          (data[
                      'destinationLng']
                  as num?)
              ?.toDouble();

      setState(() {
        _activeTouringId =
            touringDoc.id;

        _activeTouringCode =
            data['code']
                ?.toString();

        _activeTouringName =
            data['name']
                ?.toString();

        _isCaptain =
            false;

        _myName =
            name;

        _myVehicleType =
            vehicleType;

        _isMotorMode =
            vehicleType ==
                    'Motor' ||
                vehicleType ==
                    'Scooter';

        if (startLat !=
                null &&
            startLng !=
                null) {
          _titikKumpul =
              LatLng(
            startLat,
            startLng,
          );
        }

        if (destinationLat !=
                null &&
            destinationLng !=
                null) {
          _destinasi =
              LatLng(
            destinationLat,
            destinationLng,
          );
        }
      });

      // SIMPAN SESI LOKAL
      await _saveTouringSession();

      await _saveMyMember(
        status: 'Joined',
      );

      _subscribeToTouringMembers(
        touringDoc.id,
      );

      if (_currentPosition !=
          null) {
        await _getRoadRoute(
          fromCurrentLocation:
              _isTouring,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content:
                Text(
              'Berhasil join ${data['name'] ?? 'Touring'}',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'Join touring error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(
            content: Text(
              'Gagal join touring: $e',
            ),
          ),
        );
      }
    }
  }

  // ==========================================================
  // SAVE MEMBER
  // ==========================================================

  Future<void> _saveMyMember({
    String? status,
  }) async {
    final touringId =
        _activeTouringId;

    final user =
        FirebaseAuth.instance
            .currentUser;

    if (touringId == null ||
        user == null) {
      return;
    }

    try {
      final position =
          _currentPosition;

      await _firestore
          .collection(
            'tourings',
          )
          .doc(
            touringId,
          )
          .collection(
            'members',
          )
          .doc(
            user.uid,
          )
          .set(
        {
          'userId':
              user.uid,
          'name':
              _myName,
          'lat':
              position?.latitude,
          'lng':
              position?.longitude,
          'heading':
              _heading,
          'vehicleType':
              _myVehicleType,
          'status':
              status ??
                  (_isTouring
                      ? 'Riding'
                      : 'Joined'),
          'updatedAt':
              FieldValue
                  .serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );
    } catch (e) {
      debugPrint(
        'Save member error: $e',
      );
    }
  }

  // ==========================================================
  // UPDATE MEMBER LOCATION
  // ==========================================================

  Future<void> _updateMyMemberLocation(
    Position position,
  ) async {
    final touringId =
        _activeTouringId;

    final user =
        FirebaseAuth.instance
            .currentUser;

    if (touringId == null ||
        user == null) {
      return;
    }

    final now =
        DateTime.now();

    if (_lastMemberUpload !=
            null &&
        now.difference(
              _lastMemberUpload!,
            ) <
            const Duration(
              seconds: 2,
            )) {
      return;
    }

    _lastMemberUpload =
        now;

    try {
      await _firestore
          .collection(
            'tourings',
          )
          .doc(
            touringId,
          )
          .collection(
            'members',
          )
          .doc(
            user.uid,
          )
          .set(
        {
          'userId':
              user.uid,
          'name':
              _myName,
          'lat':
              position.latitude,
          'lng':
              position.longitude,
          'heading':
              _heading,
          'vehicleType':
              _myVehicleType,
          'status':
              _isTouring
                  ? 'Riding'
                  : 'Joined',
          'updatedAt':
              FieldValue
                  .serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );
    } catch (e) {
      debugPrint(
        'Update member location error: $e',
      );
    }
  }

  // ==========================================================
  // MEMBER LISTENER
  // ==========================================================

  void _subscribeToTouringMembers(
    String touringId,
  ) {
    _membersSubscription?.cancel();

    _membersSubscription =
        _firestore
            .collection(
              'tourings',
            )
            .doc(
              touringId,
            )
            .collection(
              'members',
            )
            .snapshots()
            .listen(
      (snapshot) {
        final user =
            FirebaseAuth.instance
                .currentUser;

        final members =
            <Member>[];

        for (final doc
            in snapshot.docs) {
          final data =
              doc.data();

          if (user != null &&
              doc.id ==
                  user.uid) {
            continue;
          }

          final lat =
              data['lat'];

          final lng =
              data['lng'];

          if (lat is! num ||
              lng is! num) {
            continue;
          }

          final heading =
              (data['heading']
                          as num?)
                      ?.toDouble() ??
                  0;

          final name =
              data['name']
                      ?.toString() ??
                  'Member';

          final status =
              data['status']
                      ?.toString() ??
                  'Joined';

          final vehicleType =
              data['vehicleType']
                      ?.toString() ??
                  'Motor';

          members.add(
            Member(
              id:
                  doc.id,
              name:
                  name,
              location:
                  LatLng(
                lat.toDouble(),
                lng.toDouble(),
              ),
              status:
                  status,
              color:
                  _memberColor(
                doc.id,
              ),
              vehicleType:
                  vehicleType,
              heading:
                  heading,
            ),
          );
        }

        if (mounted) {
          setState(() {
            _groupMembers
              ..clear()
              ..addAll(
                members,
              );
          });
        }
      },
      onError: (error) {
        debugPrint(
          'Member listener error: $error',
        );
      },
    );
  }

  // ==========================================================
  // MEMBER COLOR
  // ==========================================================

  Color _memberColor(
    String id,
  ) {
    const colors = [
      Colors.blue,
      Colors.orange,
      Colors.purple,
      Colors.cyan,
      Colors.pink,
      Colors.amber,
      Colors.teal,
      Colors.indigo,
    ];

    final value =
        id.codeUnits.fold<int>(
      0,
      (
        previous,
        element,
      ) =>
          previous +
          element,
    );

    return colors[
        value %
            colors.length];
  }

  // ==========================================================
  // VEHICLE ASSET
  // ==========================================================

  String _vehicleAsset(
    String vehicleType,
  ) {
    final type =
        vehicleType.toLowerCase();

    if (type ==
            'motor' ||
        type ==
            'scooter') {
      return 'assets/metic.png';
    }

    return 'assets/xtrail.png';
  }

  // ==========================================================
  // MEMBER LIST
  // ==========================================================

  void _showMemberList() {
    showModalBottomSheet(
      context: context,
      backgroundColor:
          Colors.grey[900],
      isScrollControlled:
          true,
      builder: (context) {
        final ownCount =
            _activeTouringId !=
                    null
                ? 1
                : 0;

        final total =
            _groupMembers
                    .length +
                ownCount;

        return SafeArea(
          child:
              SizedBox(
            height:
                MediaQuery.of(
                      context,
                    )
                        .size
                        .height *
                    0.65,
            child:
                Column(
              children: [
                const SizedBox(
                  height: 10,
                ),
                Container(
                  width: 45,
                  height: 5,
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.grey[600],
                    borderRadius:
                        BorderRadius
                            .circular(
                      10,
                    ),
                  ),
                ),
                const SizedBox(
                  height: 15,
                ),
                Padding(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal:
                        20,
                  ),
                  child:
                      Row(
                    children: [
                      const Icon(
                        Icons.groups,
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      Text(
                        'Anggota Touring ($total)',
                        style:
                            const TextStyle(
                          fontSize:
                              20,
                          fontWeight:
                              FontWeight
                                  .bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),

                if (_activeTouringId ==
                    null)
                  Expanded(
                    child:
                        Center(
                      child:
                          Column(
                        mainAxisSize:
                            MainAxisSize
                                .min,
                        children: [
                          Icon(
                            Icons
                                .groups_outlined,
                            size: 70,
                            color: Colors
                                .grey[600],
                          ),
                          const SizedBox(
                            height: 15,
                          ),
                          const Text(
                            'Belum Join Touring',
                          ),
                          const SizedBox(
                            height: 10,
                          ),
                          ElevatedButton
                              .icon(
                            onPressed:
                                () {
                              Navigator.pop(
                                context,
                              );

                              _showJoinTouringDialog();
                            },
                            icon:
                                const Icon(
                              Icons.login,
                            ),
                            label:
                                const Text(
                              'Join Touring',
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child:
                        ListView(
                      children: [
                        // ==================================================
                        // CONTROL TOURING
                        // ==================================================

                        Padding(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal:
                                16,
                            vertical:
                                8,
                          ),
                          child:
                              _isCaptain
                                  ? SizedBox(
                                      width:
                                          double.infinity,
                                      child:
                                          OutlinedButton.icon(
                                        style:
                                            OutlinedButton.styleFrom(
                                          foregroundColor:
                                              Colors.redAccent,
                                          side:
                                              const BorderSide(
                                            color:
                                                Colors.redAccent,
                                          ),
                                        ),
                                        onPressed:
                                            _finishTouring,
                                        icon:
                                            const Icon(
                                          Icons.flag,
                                        ),
                                        label:
                                            const Text(
                                          'Selesaikan Touring',
                                        ),
                                      ),
                                    )
                                  : SizedBox(
                                      width:
                                          double.infinity,
                                      child:
                                          OutlinedButton.icon(
                                        style:
                                            OutlinedButton.styleFrom(
                                          foregroundColor:
                                              Colors.orangeAccent,
                                          side:
                                              const BorderSide(
                                            color:
                                                Colors.orangeAccent,
                                          ),
                                        ),
                                        onPressed:
                                            _leaveTouring,
                                        icon:
                                            const Icon(
                                          Icons.logout,
                                        ),
                                        label:
                                            const Text(
                                          'Keluar dari Touring',
                                        ),
                                      ),
                                    ),
                        ),

                        const Divider(),

                        // ==================================================
                        // SAYA
                        // ==================================================

                        ListTile(
                          leading:
                              const CircleAvatar(
                            backgroundColor:
                                Colors.green,
                            child:
                                Icon(
                              Icons.person,
                              color:
                                  Colors.white,
                            ),
                          ),
                          title:
                              Text(
                            '$_myName (Saya)',
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                          subtitle:
                              Text(
                            '${_myVehicleType} • '
                            '${_isTouring ? 'Riding' : 'Joined'}',
                          ),
                          trailing:
                              _isCaptain
                                  ? const Chip(
                                      label:
                                          Text(
                                        'CAPTAIN',
                                      ),
                                    )
                                  : null,
                        ),

                        const Divider(),

                        // ==================================================
                        // MEMBER LAIN
                        // ==================================================

                        if (_groupMembers
                            .isEmpty)
                          const Padding(
                            padding:
                                EdgeInsets
                                    .all(
                              30,
                            ),
                            child:
                                Center(
                              child:
                                  Text(
                                'Belum ada anggota lain.',
                              ),
                            ),
                          )
                        else
                          ..._groupMembers
                              .map(
                            (
                              member,
                            ) {
                              return ListTile(
                                leading:
                                    CircleAvatar(
                                  backgroundColor:
                                      member.color,
                                  child:
                                      const Icon(
                                    Icons.person,
                                    color:
                                        Colors.white,
                                  ),
                                ),
                                title:
                                    Text(
                                  member.name,
                                ),
                                subtitle:
                                    Text(
                                  '${member.vehicleType} • '
                                  '${member.status}',
                                ),
                                trailing:
                                    Transform.rotate(
                                  angle:
                                      member.heading *
                                          math.pi /
                                          180,
                                  alignment:
                                      Alignment.center,
                                  child:
                                      Image.asset(
                                    _vehicleAsset(
                                      member.vehicleType,
                                    ),
                                    width:
                                        40,
                                    height:
                                        40,
                                    fit:
                                        BoxFit.contain,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================================
  // AGORA
  // ==========================================================

  Future<void> _initAgoraPTT() async {
    try {
      if (kIsWeb) return;

      final micStatus =
          await Permission.microphone
              .request();

      if (!micStatus.isGranted) {
        debugPrint(
          'Microphone permission denied.',
        );

        if (mounted) {
          setState(() {
            _microphoneEnabled =
                false;
          });
        }

        return;
      }

      final engine =
          createAgoraRtcEngine();

      await engine.initialize(
        const RtcEngineContext(
          appId:
              agoraAppId,
        ),
      );

      await engine.enableAudio();

      await engine
          .muteLocalAudioStream(
        true,
      );

      await engine
          .setChannelProfile(
        ChannelProfileType
            .channelProfileCommunication,
      );

      await engine.setClientRole(
        role: ClientRoleType
            .clientRoleBroadcaster,
      );

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess:
              (
            connection,
            elapsed,
          ) {
            debugPrint(
              'Agora joined: '
              '${connection.channelId}',
            );
          },
          onError:
              (
            err,
            msg,
          ) {
            debugPrint(
              'Agora error: '
              '$err $msg',
            );
          },
        ),
      );

      _engine =
          engine;

      await engine.joinChannel(
        token: '',
        channelId:
            channelName,
        uid: 0,
        options:
            const ChannelMediaOptions(),
      );

      if (mounted) {
        setState(() {
          _isPttInitialized =
              true;
          _microphoneEnabled =
              true;
        });
      }
    } catch (e) {
      debugPrint(
        'Agora init error: $e',
      );

      if (mounted) {
        setState(() {
          _isPttInitialized =
              false;
          _microphoneEnabled =
              false;
        });
      }
    }
  }

  // ==========================================================
  // PTT START
  // ==========================================================

  Future<void> _startTalking() async {
    if (!_isPttInitialized ||
        _engine == null) {
      return;
    }

    try {
      await _engine!
          .muteLocalAudioStream(
        false,
      );

      if (mounted) {
        setState(() {
          _isTalking =
              true;
        });
      }
    } catch (e) {
      debugPrint(
        'PTT start error: $e',
      );
    }
  }

  // ==========================================================
  // PTT STOP
  // ==========================================================

  Future<void> _stopTalking() async {
    if (!_isPttInitialized ||
        _engine == null) {
      return;
    }

    try {
      await _engine!
          .muteLocalAudioStream(
        true,
      );

      if (mounted) {
        setState(() {
          _isTalking =
              false;
        });
      }
    } catch (e) {
      debugPrint(
        'PTT stop error: $e',
      );
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    _positionStream?.cancel();

    _membersSubscription
        ?.cancel();

    _engine
        ?.leaveChannel();

    _engine?.release();

    super.dispose();
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar:
          AppBar(
        title:
            const Text(
          'Touring Map',
        ),
        actions: [
          // ==================================================
          // CREATE TOURING
          // ==================================================

          IconButton(
            icon:
                const Icon(
              Icons
                  .add_circle_outline,
            ),
            tooltip:
                'Buat Touring',
            onPressed:
                _showCreateTouringDialog,
          ),

          // ==================================================
          // ROUTE
          // ==================================================

          IconButton(
            icon:
                const Icon(
              Icons.route,
            ),
            tooltip:
                'Atur Rute',
            onPressed:
                _showSetRouteDialog,
          ),

          // ==================================================
          // JOIN
          // ==================================================

          IconButton(
            icon:
                const Icon(
              Icons.login,
            ),
            tooltip:
                'Join Touring',
            onPressed:
                _showJoinTouringDialog,
          ),

          // ==================================================
          // MEMBERS
          // ==================================================

          Stack(
            alignment:
                Alignment.center,
            children: [
              IconButton(
                icon:
                    const Icon(
                  Icons.groups,
                ),
                tooltip:
                    'Anggota',
                onPressed:
                    _showMemberList,
              ),
              if (_activeTouringId !=
                  null)
                Positioned(
                  right: 4,
                  top: 5,
                  child:
                      Container(
                    padding:
                        const EdgeInsets
                            .all(
                      4,
                    ),
                    decoration:
                        const BoxDecoration(
                      color:
                          Colors.red,
                      shape:
                          BoxShape.circle,
                    ),
                    child:
                        Text(
                      '${_groupMembers.length + 1}',
                      style:
                          const TextStyle(
                        fontSize:
                            9,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // ==================================================
          // VEHICLE
          // ==================================================

          IconButton(
            icon:
                Icon(
              _isMotorMode
                  ? Icons
                      .two_wheeler
                  : Icons
                      .directions_car,
            ),
            tooltip:
                'Ganti Kendaraan',
            onPressed:
                () async {
              setState(() {
                _isMotorMode =
                    !_isMotorMode;

                _myVehicleType =
                    _isMotorMode
                        ? 'Motor'
                        : 'SUV';
              });

              if (_activeTouringId !=
                  null) {
                await _saveMyMember();
                await _saveTouringSession();
              }
            },
          ),

          // ==================================================
          // MAP STYLE
          // ==================================================

          PopupMenuButton<String>(
            icon:
                const Icon(
              Icons.layers,
            ),
            tooltip:
                'Map Style',
            onSelected:
                (
              String key,
            ) {
              setState(() {
                _selectedTile =
                    key;
              });
            },
            itemBuilder:
                (
              BuildContext context,
            ) {
              return _tileProviders
                  .keys
                  .map(
                (
                  String key,
                ) {
                  return PopupMenuItem<
                      String>(
                    value:
                        key,
                    child:
                        Text(
                      key,
                    ),
                  );
                },
              ).toList();
            },
          ),
        ],
      ),

      // ======================================================
      // BODY
      // ======================================================

      body:
          Stack(
        children: [
          FlutterMap(
            mapController:
                _mapController,
            options:
                MapOptions(
              initialCenter:
                  _currentPosition !=
                          null
                      ? LatLng(
                          _currentPosition!
                              .latitude,
                          _currentPosition!
                              .longitude,
                        )
                      : _titikKumpul,
              initialZoom:
                  14,
              onTap:
                  _handleMapTap,
            ),
            children: [
              // ==================================================
              // MAP TILE
              // ==================================================

              TileLayer(
                urlTemplate:
                    _tileProviders[
                        _selectedTile]!,
                userAgentPackageName:
                    'com.tedapp.touringmap',
                maxZoom:
                    19,
              ),

              // ==================================================
              // ROUTE LINE
              // ==================================================

              if (_routePoints
                  .isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points:
                          _routePoints,
                      strokeWidth:
                          5,
                      color:
                          Colors.blue,
                    ),
                  ],
                ),

              // ==================================================
              // MARKERS
              // ==================================================

              MarkerLayer(
                markers: [
                  // ============================================
                  // MARKER SAYA
                  // ============================================

                  if (_currentPosition != null)
  Marker(
    point: LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    ),
    width: 80,
    height: 90,
    // Menjaga marker tetap konsisten terhadap peta
    rotate: true, 
    child: Transform.rotate(
      // Memutar motor SEKALIGUS label namanya agar nama selalu berada di ekor motor
      angle: (_heading - 45) * math.pi / 180,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Gambar Motor
          Image.asset(
            _isMotorMode
                ? 'assets/metic.png'
                : 'assets/xtrail.png',
            width: 50,
            height: 50,
            fit: BoxFit.contain,
          ),
          
          // 2. Label Nama di bagian belakang (pantat) motor
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'Saya',
              style: TextStyle(
                fontSize: 10,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    ),
  ),

                  // ============================================
                  // START
                  // ============================================

                  Marker(
                    point:
                        _titikKumpul,
                    width:
                        55,
                    height:
                        65,
                    child:
                        const Column(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_on,
                          color:
                              Colors.green,
                          size:
                              40,
                        ),
                        Text(
                          'Start',
                          style:
                              TextStyle(
                            fontSize:
                                10,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ============================================
                  // FINISH
                  // ============================================

                  Marker(
                    point:
                        _destinasi,
                    width:
                        55,
                    height:
                        65,
                    child:
                        const Column(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.flag,
                          color:
                              Colors.red,
                          size:
                              40,
                        ),
                        Text(
                          'Finish',
                          style:
                              TextStyle(
                            fontSize:
                                10,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ============================================
                  // MEMBER TOURING
                  // ============================================

                  ..._groupMembers.map(
                    (
                      member,
                    ) {
                      return Marker(
                        point:
                            member.location,
                        width:
                            90,
                        height:
                            100,
                        child:
                            Column(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Transform.rotate(
                              angle:
                                  member.heading *
                                      math.pi /
                                      180,
                              alignment:
                                  Alignment.center,
                              child:
                                  Image.asset(
                                _vehicleAsset(
                                  member.vehicleType,
                                ),
                                width:
                                    55,
                                height:
                                    55,
                                fit:
                                    BoxFit.contain,
                              ),
                            ),
                            Container(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                horizontal:
                                    6,
                                vertical:
                                    3,
                              ),
                              decoration:
                                  BoxDecoration(
                                color: member
                                    .color
                                    .withOpacity(
                                  0.9,
                                ),
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  5,
                                ),
                              ),
                              child:
                                  Text(
                                member.name,
                                style:
                                    const TextStyle(
                                  fontSize:
                                      10,
                                  color:
                                      Colors.white,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          // ==================================================
          // CENTER LOCATION
          // ==================================================

          Positioned(
            right:
                15,
            bottom:
                175,
            child:
                FloatingActionButton.small(
              heroTag:
                  'center_location',
              backgroundColor:
                  Colors.black87,
              foregroundColor:
                  Colors.white,
              onPressed:
                  _centerMyLocation,
              child:
                  const Icon(
                Icons.my_location,
              ),
            ),
          ),

          // ==================================================
          // TOP STATUS
          // ==================================================

          Positioned(
            left:
                10,
            right:
                10,
            top:
                10,
            child:
                Card(
              color:
                  Colors.black
                      .withOpacity(
                0.78,
              ),
              child:
                  Padding(
                padding:
                    const EdgeInsets.all(
                  12,
                ),
                child:
                    Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _locationReady
                              ? Icons
                                  .gps_fixed
                              : Icons
                                  .gps_off,
                          color:
                              _locationReady
                                  ? Colors
                                      .green
                                  : Colors
                                      .red,
                          size:
                              18,
                        ),
                        const SizedBox(
                          width:
                              7,
                        ),
                        Text(
                          _gpsStatus,
                          style:
                              const TextStyle(
                            fontSize:
                                12,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          _microphoneEnabled
                              ? Icons.mic
                              : Icons
                                  .mic_off,
                          size:
                              18,
                          color:
                              _microphoneEnabled
                                  ? Colors
                                      .green
                                  : Colors
                                      .red,
                        ),
                        const SizedBox(
                          width:
                              5,
                        ),
                        Text(
                          _microphoneEnabled
                              ? 'Microphone Aktif'
                              : 'Microphone Tidak Aktif',
                          style:
                              TextStyle(
                            fontSize:
                                12,
                            color:
                                _microphoneEnabled
                                    ? Colors
                                        .green
                                    : Colors
                                        .red,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(
                      height:
                          8,
                    ),

                    Row(
                      children: [
                        const Icon(
                          Icons
                              .directions_car,
                          size:
                              18,
                        ),
                        const SizedBox(
                          width:
                              7,
                        ),
                        Text(
                          _routeDistanceKm >
                                  0
                              ? '${_routeDistanceKm.toStringAsFixed(1)} km'
                              : '${_distanceInKm.toStringAsFixed(1)} km',
                        ),
                        const SizedBox(
                          width:
                              15,
                        ),
                        const Icon(
                          Icons
                              .access_time,
                          size:
                              18,
                        ),
                        const SizedBox(
                          width:
                              5,
                        ),
                        Text(
                          _routeDurationMinutes >
                                  0
                              ? '${_routeDurationMinutes.round()} min'
                              : '$_estimatedMinutes min',
                        ),
                        const Spacer(),
                        if (_isLoadingRoute)
                          const SizedBox(
                            width:
                                18,
                            height:
                                18,
                            child:
                                CircularProgressIndicator(
                              strokeWidth:
                                  2,
                            ),
                          ),
                      ],
                    ),

                    if (_activeTouringId !=
                        null) ...[
                      const SizedBox(
                        height:
                            9,
                      ),
                      Container(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal:
                              10,
                          vertical:
                              7,
                        ),
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.blue
                                  .withOpacity(
                            0.25,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            8,
                          ),
                          border:
                              Border.all(
                            color:
                                Colors.blue,
                          ),
                        ),
                        child:
                            Row(
                          children: [
                            const Icon(
                              Icons.groups,
                              size:
                                  18,
                              color:
                                  Colors.blue,
                            ),
                            const SizedBox(
                              width:
                                  8,
                            ),
                            Expanded(
                              child:
                                  Text(
                                _activeTouringName ??
                                    'Touring',
                                style:
                                    const TextStyle(
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ),
                            Text(
                              _activeTouringCode ??
                                  '',
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                                letterSpacing:
                                    2,
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
          ),

          // ==================================================
          // MAP PICKING BANNER
          // ==================================================

          if (_mapPickingMode)
            Positioned(
              left:
                  20,
              right:
                  20,
              bottom:
                  155,
              child:
                  Card(
                color:
                    Colors.orange
                        .withOpacity(
                  0.95,
                ),
                child:
                    Padding(
                  padding:
                      const EdgeInsets.all(
                    10,
                  ),
                  child:
                      Row(
                    children: [
                      const Icon(
                        Icons.touch_app,
                        color:
                            Colors.black,
                      ),
                      const SizedBox(
                        width:
                            8,
                      ),
                      Expanded(
                        child:
                            Text(
                          _pickingTarget ==
                                  'start'
                              ? 'Tap map untuk memilih titik kumpul'
                              : 'Tap map untuk memilih destinasi',
                          style:
                              const TextStyle(
                            color:
                                Colors.black,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed:
                            () {
                          setState(() {
                            _mapPickingMode =
                                false;
                            _pickingTarget =
                                '';
                          });
                        },
                        icon:
                            const Icon(
                          Icons.close,
                          color:
                              Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================================
          // PTT ACTIVE
          // ==================================================

          if (_isTalking)
            Positioned(
              left:
                  20,
              bottom:
                  150,
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal:
                      12,
                  vertical:
                      7,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      Colors.red,
                  borderRadius:
                      BorderRadius
                          .circular(
                    20,
                  ),
                ),
                child:
                    const Row(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mic,
                      color:
                          Colors.white,
                      size:
                          18,
                    ),
                    SizedBox(
                      width:
                          6,
                    ),
                    Text(
                      'Transmisi Suara Aktif...',
                      style:
                          TextStyle(
                        color:
                            Colors.white,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ==================================================
          // WATERMARK
          // ==================================================

          Positioned(
            right:
                10,
            bottom:
                92,
            child:
                Container(
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal:
                    8,
                vertical:
                    4,
              ),
              decoration:
                  BoxDecoration(
                color:
                    Colors.black
                        .withOpacity(
                  0.65,
                ),
                borderRadius:
                    BorderRadius
                        .circular(
                  5,
                ),
              ),
              child:
                  const Text(
                'Created by Mr. Ted',
                style:
                    TextStyle(
                  fontSize:
                      11,
                  color:
                      Colors.white,
                ),
              ),
            ),
          ),

          // ==================================================
          // BOTTOM CONTROL
          // ==================================================

          Positioned(
            left:
                20,
            right:
                20,
            bottom:
                20,
            child:
                Row(
              children: [
                // ==================================================
                // PTT BUTTON
                // ==================================================

                GestureDetector(
                  onLongPressStart:
                      (_) {
                    _startTalking();
                  },
                  onLongPressEnd:
                      (_) {
                    _stopTalking();
                  },
                  onLongPressCancel:
                      () {
                    _stopTalking();
                  },
                  child:
                      Container(
                    width:
                        115,
                    height:
                        60,
                    decoration:
                        BoxDecoration(
                      color:
                          _isTalking
                              ? Colors
                                  .red
                              : Colors
                                  .black87,
                      borderRadius:
                          BorderRadius
                              .circular(
                        12,
                      ),
                      border:
                          Border.all(
                        color:
                            _isTalking
                                ? Colors
                                    .redAccent
                                : Colors
                                    .grey,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors
                              .black
                              .withOpacity(
                            0.3,
                          ),
                          blurRadius:
                              8,
                        ),
                      ],
                    ),
                    child:
                        Column(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .center,
                      children: [
                        Icon(
                          _isTalking
                              ? Icons.mic
                              : Icons
                                  .mic_none,
                          color:
                              _isTalking
                                  ? Colors
                                      .white
                                  : Colors
                                      .greenAccent,
                          size:
                              22,
                        ),
                        const SizedBox(
                          height:
                              2,
                        ),
                        Text(
                          _isTalking
                              ? 'BICARA'
                              : 'PTT',
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                            fontSize:
                                11,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(
                  width:
                      12,
                ),

                // ==================================================
                // START / STOP
                // ==================================================

                Expanded(
                  child:
                      ElevatedButton
                          .icon(
                    style:
                        ElevatedButton
                            .styleFrom(
                      backgroundColor:
                          _isTouring
                              ? Colors
                                  .red
                              : Colors
                                  .green,
                      foregroundColor:
                          Colors.white,
                      minimumSize:
                          const Size(
                        0,
                        60,
                      ),
                      shape:
                          RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                      ),
                    ),
                    onPressed:
                        _isTouring
                            ? _stopTouring
                            : _startTouring,
                    icon:
                        Icon(
                      _isTouring
                          ? Icons.stop
                          : Icons
                              .play_arrow,
                    ),
                    label:
                        Text(
                      _isTouring
                          ? 'STOP TOURING'
                          : 'START TOURING',
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
