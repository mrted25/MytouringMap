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

import 'firebase_options.dart';
import 'services/touring_service.dart';

const String agoraAppId =
    "398d30b96cae43aeac064c7a0fa9add8";

const String channelName =
    "touring_room_1";

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

// ============================================================
// APP
// ============================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      // Nama aplikasi
      title: 'Mytouring',

      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.green,
      ),

      home: const MapScreen(),
    );
  }
}

// ============================================================
// MEMBER MODEL
// ============================================================

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

// ============================================================
// MAP SCREEN
// ============================================================

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // ==========================================================
  // MAP
  // ==========================================================

  final MapController _mapController = MapController();

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

  bool _mapPickingMode = false;

  String _pickingTarget = '';

  List<LatLng> _routePoints = [];

  double _routeDistanceKm = 0;

  double _routeDurationMinutes = 0;

  bool _isLoadingRoute = false;

  // ==========================================================
  // GPS
  // ==========================================================

  Position? _currentPosition;

  StreamSubscription<Position>? _positionStream;

  bool _locationReady = false;

  bool _gpsActive = false;

  String _gpsStatus = 'GPS belum aktif';

  double _distanceInKm = 0;

  int _estimatedMinutes = 0;

  // Arah kendaraan.
  double _heading = 0;

  // Posisi GPS sebelumnya.
  LatLng? _previousGpsLocation;

  // Waktu GPS sebelumnya.
  DateTime? _previousGpsTime;

  // ==========================================================
  // TOURING
  // ==========================================================

  bool _isTouring = false;

  DateTime? _touringStartTime;

  bool _isMotorMode = false;

  // ==========================================================
  // FIREBASE TOURING
  // ==========================================================

  String? _activeTouringId;

  String? _activeTouringCode;

  String? _activeTouringName;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _membersSubscription;

  Timer? _firestoreLocationTimer;

  // ==========================================================
  // MEMBERS
  // ==========================================================

  final List<Member> _groupMembers = [];

  // ==========================================================
  // AGORA PTT
  // ==========================================================

  RtcEngine? _engine;

  bool _agoraInitialized = false;

  bool _agoraJoined = false;

  bool _microphoneEnabled = false;

  bool _isTalking = false;

  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();

    _initializeGPS();

    if (!kIsWeb) {
      _initAgoraPTT();
    }
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
            _gpsActive = false;
            _gpsStatus = 'GPS tidak aktif';
          });
        }

        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission =
            await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission ==
              LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _gpsActive = false;
            _gpsStatus = 'Izin GPS ditolak';
          });
        }

        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _handleNewPosition(position);

      _positionStream =
          Geolocator.getPositionStream(
        locationSettings:
            const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(_handleNewPosition);

      if (mounted) {
        setState(() {
          _gpsActive = true;
          _gpsStatus = 'GPS aktif';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gpsActive = false;
          _gpsStatus = 'GPS error';
        });
      }
    }
  }

  // ==========================================================
  // HANDLE GPS
  // ==========================================================

  void _handleNewPosition(Position position) {
    final newLocation = LatLng(
      position.latitude,
      position.longitude,
    );

    double newHeading = _heading;

    // ========================================================
    // HITUNG ARAH PERJALANAN
    // ========================================================

    if (_previousGpsLocation != null) {
      final distance =
          Geolocator.distanceBetween(
        _previousGpsLocation!.latitude,
        _previousGpsLocation!.longitude,
        newLocation.latitude,
        newLocation.longitude,
      );

      // Jangan ubah arah jika pergerakan terlalu kecil.
      if (distance >= 2.0) {
        newHeading = _calculateBearing(
          _previousGpsLocation!,
          newLocation,
        );
      }
    }

    _previousGpsLocation = newLocation;

    _previousGpsTime = DateTime.now();

    if (!mounted) {
      _currentPosition = position;
      _heading = newHeading;

      return;
    }

    setState(() {
      _currentPosition = position;

      _heading = newHeading;

      _locationReady = true;

      _gpsActive = true;

      _gpsStatus = 'GPS aktif';
    });

    _updateDistanceAndEta();

    _scheduleOwnMemberUpdate(
      newLocation,
      newHeading,
    );
  }

  // ==========================================================
  // BEARING
  // ==========================================================

  double _calculateBearing(
    LatLng from,
    LatLng to,
  ) {
    final lat1 =
        from.latitude * math.pi / 180;

    final lat2 =
        to.latitude * math.pi / 180;

    final dLon =
        (to.longitude - from.longitude) *
            math.pi /
            180;

    final y =
        math.sin(dLon) * math.cos(lat2);

    final x =
        math.cos(lat1) * math.sin(lat2) -
            math.sin(lat1) *
                math.cos(lat2) *
                math.cos(dLon);

    var bearing =
        math.atan2(y, x) *
            180 /
            math.pi;

    bearing =
        (bearing + 360) % 360;

    return bearing;
  }

  // ==========================================================
  // DISTANCE + ETA
  // ==========================================================

  void _updateDistanceAndEta() {
    if (_currentPosition == null) {
      return;
    }

    final current = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );

    final distanceMeters =
        Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      _destinasi.latitude,
      _destinasi.longitude,
    );

    final distanceKm =
        distanceMeters / 1000;

    final speedKmH =
        _isMotorMode ? 45.0 : 35.0;

    final estimatedMinutes =
        ((distanceKm / speedKmH) * 60)
            .round();

    if (!mounted) return;

    setState(() {
      _distanceInKm = distanceKm;

      _estimatedMinutes =
          estimatedMinutes;
    });
  }

  // ==========================================================
  // CENTER LOCATION
  // ==========================================================

  void _centerMyLocation() {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Lokasi GPS belum tersedia',
          ),
        ),
      );

      return;
    }

    final point = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );

    try {
      _mapController.move(
        point,
        17,
      );
    } catch (_) {}
  }

  // ==========================================================
  // OSRM ROUTE
  // ==========================================================

  Future<void> _getRoute() async {
    if (!mounted) return;

    setState(() {
      _isLoadingRoute = true;
    });

    try {
      final start =
          '${_titikKumpul.longitude},'
          '${_titikKumpul.latitude}';

      final end =
          '${_destinasi.longitude},'
          '${_destinasi.latitude}';

      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$start;$end'
        '?overview=full&geometries=geojson',
      );

      final response =
          await http.get(url);

      if (response.statusCode != 200) {
        throw Exception(
          'OSRM HTTP ${response.statusCode}',
        );
      }

      final data =
          jsonDecode(response.body);

      final routes =
          data['routes'];

      if (routes == null ||
          routes.isEmpty) {
        throw Exception(
          'Route tidak ditemukan',
        );
      }

      final route = routes[0];

      final geometry =
          route['geometry']['coordinates']
              as List;

      final points =
          geometry.map<LatLng>(
        (coordinate) {
          return LatLng(
            (coordinate[1] as num)
                .toDouble(),
            (coordinate[0] as num)
                .toDouble(),
          );
        },
      ).toList();

      final distanceMeters =
          (route['distance'] as num)
              .toDouble();

      final durationSeconds =
          (route['duration'] as num)
              .toDouble();

      if (!mounted) return;

      setState(() {
        _routePoints = points;

        _routeDistanceKm =
            distanceMeters / 1000;

        _routeDurationMinutes =
            durationSeconds / 60;

        _isLoadingRoute = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoadingRoute = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Gagal mengambil rute: $e',
          ),
        ),
      );
    }
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
              const Text('Atur Rute Touring'),

          content: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(
                  Icons.location_on,
                  color: Colors.green,
                ),
                title:
                    const Text(
                  'Titik Kumpul',
                ),
                subtitle:
                    Text(
                  '${_titikKumpul.latitude.toStringAsFixed(6)}, '
                  '${_titikKumpul.longitude.toStringAsFixed(6)}',
                ),
                onTap: () {
                  Navigator.pop(context);

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
                      content: Text(
                        'Tap lokasi titik kumpul di map',
                      ),
                    ),
                  );
                },
              ),

              ListTile(
                leading:
                    const Icon(
                  Icons.flag,
                  color: Colors.red,
                ),
                title:
                    const Text(
                  'Tujuan',
                ),
                subtitle:
                    Text(
                  '${_destinasi.latitude.toStringAsFixed(6)}, '
                  '${_destinasi.longitude.toStringAsFixed(6)}',
                ),
                onTap: () {
                  Navigator.pop(context);

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
                      content: Text(
                        'Tap lokasi tujuan di map',
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(
                height: 8,
              ),

              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(context);

                  await _getRoute();
                },
                icon:
                    const Icon(
                  Icons.alt_route,
                ),
                label:
                    const Text(
                  'Hitung Rute',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================
  // MAP PICKING
  // ==========================================================

  void _handleMapTap(
    TapPosition tapPosition,
    LatLng point,
  ) {
    if (!_mapPickingMode) {
      return;
    }

    if (_pickingTarget == 'start') {
      setState(() {
        _titikKumpul =
            point;

        _mapPickingMode =
            false;

        _pickingTarget =
            '';
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Titik kumpul berhasil dipilih',
          ),
        ),
      );
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

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Tujuan berhasil dipilih',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // CREATE TOURING
  // ==========================================================

  Future<void> _showCreateTouringDialog() async {
    final nameController =
        TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool saving = false;

        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              title:
                  const Text(
                'Create Touring',
              ),

              content:
                  TextField(
                controller:
                    nameController,
                textCapitalization:
                    TextCapitalization.words,
                decoration:
                    const InputDecoration(
                  labelText:
                      'Nama Touring',
                  hintText:
                      'Contoh: Touring Bogor',
                  prefixIcon:
                      Icon(Icons.groups),
                ),
              ),

              actions: [
                TextButton(
                  onPressed:
                      saving
                          ? null
                          : () {
                              Navigator.pop(
                                dialogContext,
                              );
                            },
                  child:
                      const Text(
                    'Batal',
                  ),
                ),

                FilledButton(
                  onPressed:
                      saving
                          ? null
                          : () async {
                              final name =
                                  nameController
                                      .text
                                      .trim();

                              if (name.isEmpty) {
                                ScaffoldMessenger
                                    .of(
                                  context,
                                ).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text(
                                      'Masukkan nama touring',
                                    ),
                                  ),
                                );

                                return;
                              }

                              final user =
                                  FirebaseAuth
                                      .instance
                                      .currentUser;

                              if (user ==
                                  null) {
                                return;
                              }

                              setDialogState(
                                () {
                                  saving =
                                      true;
                                },
                              );

                              try {
                                final service =
                                    TouringService();

                                final code =
                                    await service
                                        .createTouring(
                                  name:
                                      name,
                                  captainId:
                                      user.uid,
                                  captainName:
                                      'Road Captain',
                                  startLat:
                                      _titikKumpul
                                          .latitude,
                                  startLng:
                                      _titikKumpul
                                          .longitude,
                                  destinationLat:
                                      _destinasi
                                          .latitude,
                                  destinationLng:
                                      _destinasi
                                          .longitude,
                                );

                                final result =
                                    await FirebaseFirestore
                                        .instance
                                        .collection(
                                          'tourings',
                                        )
                                        .where(
                                          'code',
                                          isEqualTo:
                                              code,
                                        )
                                        .limit(
                                          1,
                                        )
                                        .get();

                                if (result
                                    .docs
                                    .isEmpty) {
                                  throw Exception(
                                    'Data touring tidak ditemukan',
                                  );
                                }

                                final touringDoc =
                                    result
                                        .docs
                                        .first;

                                await _joinFirestoreTouring(
                                  touringId:
                                      touringDoc
                                          .id,
                                  touringCode:
                                      code,
                                  touringName:
                                      name,
                                  memberName:
                                      'Road Captain',
                                );

                                if (!mounted) {
                                  return;
                                }

                                Navigator.pop(
                                  dialogContext,
                                );

                                await _showTouringCreatedDialog(
                                  code,
                                  name,
                                );
                              } catch (e) {
                                if (!mounted) {
                                  return;
                                }

                                setDialogState(
                                  () {
                                    saving =
                                        false;
                                  },
                                );

                                ScaffoldMessenger
                                    .of(
                                  context,
                                ).showSnackBar(
                                  SnackBar(
                                    content:
                                        Text(
                                      'Gagal membuat touring: $e',
                                    ),
                                  ),
                                );
                              }
                            },

                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'BUAT',
                        ),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
  }

  // ==========================================================
  // TOURING CREATED
  // ==========================================================

  Future<void> _showTouringCreatedDialog(
    String code,
    String name,
  ) async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Touring Berhasil Dibuat',
          ),

          content: Column(
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
                'Bagikan kode ini kepada member:',
              ),

              const SizedBox(
                height: 10,
              ),

              Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      Colors.green
                          .withOpacity(
                    0.15,
                  ),
                  borderRadius:
                      BorderRadius
                          .circular(
                    12,
                  ),
                  border:
                      Border.all(
                    color:
                        Colors.green,
                  ),
                ),
                child:
                    Text(
                  code,
                  style:
                      const TextStyle(
                    fontSize: 30,
                    fontWeight:
                        FontWeight.bold,
                    letterSpacing: 5,
                  ),
                ),
              ),
            ],
          ),

          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(
                    text: code,
                  ),
                );

                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Kode touring disalin',
                    ),
                  ),
                );
              },
              child:
                  const Text(
                'SALIN KODE',
              ),
            ),

            FilledButton(
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
        _isMotorMode
            ? 'motor'
            : 'mobil';

    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool joining = false;

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
                child: Column(
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
                            'Contoh: AB12CD',
                        prefixIcon:
                            Icon(
                          Icons.key,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    TextField(
                      controller:
                          nameController,
                      textCapitalization:
                          TextCapitalization
                              .words,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Nama Anda',
                        hintText:
                            'Contoh: Ted',
                        prefixIcon:
                            Icon(
                          Icons.person,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    DropdownButtonFormField<
                        String>(
                      value:
                          selectedVehicle,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Kendaraan',
                        prefixIcon:
                            Icon(
                          Icons
                              .directions_car,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value:
                              'motor',
                          child:
                              Text(
                            'Motor',
                          ),
                        ),
                        DropdownMenuItem(
                          value:
                              'mobil',
                          child:
                              Text(
                            'Mobil',
                          ),
                        ),
                      ],
                      onChanged:
                          joining
                              ? null
                              : (value) {
                                  if (value ==
                                      null) {
                                    return;
                                  }

                                  setDialogState(
                                    () {
                                      selectedVehicle =
                                          value;
                                    },
                                  );
                                },
                    ),
                  ],
                ),
              ),

              actions: [
                TextButton(
                  onPressed:
                      joining
                          ? null
                          : () {
                              Navigator.pop(
                                dialogContext,
                              );
                            },
                  child:
                      const Text(
                    'BATAL',
                  ),
                ),

                FilledButton(
                  onPressed:
                      joining
                          ? null
                          : () async {
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
                                      'Kode dan nama wajib diisi',
                                    ),
                                  ),
                                );

                                return;
                              }

                              setDialogState(
                                () {
                                  joining =
                                      true;
                                },
                              );

                              try {
                                final query =
                                    await FirebaseFirestore
                                        .instance
                                        .collection(
                                          'tourings',
                                        )
                                        .where(
                                          'code',
                                          isEqualTo:
                                              code,
                                        )
                                        .limit(
                                          1,
                                        )
                                        .get();

                                if (query
                                    .docs
                                    .isEmpty) {
                                  throw Exception(
                                    'Kode touring tidak ditemukan',
                                  );
                                }

                                final doc =
                                    query
                                        .docs
                                        .first;

                                final data =
                                    doc.data();

                                await _joinFirestoreTouring(
                                  touringId:
                                      doc.id,
                                  touringCode:
                                      code,
                                  touringName:
                                      data['name']
                                              ?.toString() ??
                                          'Touring',
                                  memberName:
                                      name,
                                  vehicleType:
                                      selectedVehicle,
                                );

                                if (!mounted) {
                                  return;
                                }

                                Navigator.pop(
                                  dialogContext,
                                );

                                ScaffoldMessenger
                                    .of(
                                  context,
                                ).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text(
                                      'Berhasil join touring',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) {
                                  return;
                                }

                                setDialogState(
                                  () {
                                    joining =
                                        false;
                                  },
                                );

                                ScaffoldMessenger
                                    .of(
                                  context,
                                ).showSnackBar(
                                  SnackBar(
                                    content:
                                        Text(
                                      'Gagal join touring: $e',
                                    ),
                                  ),
                                );
                              }
                            },

                  child: joining
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'JOIN',
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

  // ==========================================================
  // JOIN FIRESTORE
  // ==========================================================

  Future<void> _joinFirestoreTouring({
    required String touringId,
    required String touringCode,
    required String touringName,
    required String memberName,
    String? vehicleType,
  }) async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw Exception(
        'User Firebase belum tersedia',
      );
    }

    await _membersSubscription
        ?.cancel();

    _membersSubscription =
        null;

    final selectedVehicle =
        vehicleType ??
            (_isMotorMode
                ? 'motor'
                : 'mobil');

    await FirebaseFirestore
        .instance
        .collection('tourings')
        .doc(touringId)
        .collection('members')
        .doc(user.uid)
        .set(
      {
        'id': user.uid,
        'name': memberName,
        'vehicleType':
            selectedVehicle,
        'status': 'Riding',
        'lat':
            _currentPosition
                    ?.latitude ??
                _titikKumpul
                    .latitude,
        'lng':
            _currentPosition
                    ?.longitude ??
                _titikKumpul
                    .longitude,
        'heading':
            _heading,
        'updatedAt':
            FieldValue
                .serverTimestamp(),
      },
      SetOptions(
        merge: true,
      ),
    );

    if (!mounted) return;

    setState(() {
      _activeTouringId =
          touringId;

      _activeTouringCode =
          touringCode;

      _activeTouringName =
          touringName;

      _isMotorMode =
          selectedVehicle ==
              'motor';
    });

    _listenToMembers(
      touringId,
    );

    _getRoute();
  }

  // ==========================================================
  // MEMBER REALTIME
  // ==========================================================

  void _listenToMembers(
    String touringId,
  ) {
    _membersSubscription
        ?.cancel();

    _membersSubscription =
        FirebaseFirestore
            .instance
            .collection('tourings')
            .doc(touringId)
            .collection('members')
            .snapshots()
            .listen(
      (snapshot) {
        final user =
            FirebaseAuth
                .instance
                .currentUser;

        final members =
            <Member>[];

        for (final doc
            in snapshot.docs) {
          final data =
              doc.data();

          final lat =
              (data['lat']
                      as num?)
                  ?.toDouble();

          final lng =
              (data['lng']
                      as num?)
                  ?.toDouble();

          if (lat == null ||
              lng == null) {
            continue;
          }

          final vehicle =
              data['vehicleType']
                      ?.toString() ??
                  'mobil';

          final name =
              data['name']
                      ?.toString() ??
                  'Member';

          final heading =
              (data['heading']
                      as num?)
                  ?.toDouble() ??
              0;

          final color =
              _memberColor(
            doc.id,
          );

          members.add(
            Member(
              id: doc.id,
              name: name,
              location:
                  LatLng(
                lat,
                lng,
              ),
              status:
                  data['status']
                          ?.toString() ??
                      'Riding',
              color: color,
              vehicleType:
                  vehicle,
              heading:
                  heading,
            ),
          );
        }

        if (!mounted) return;

        setState(() {
          _groupMembers
              .clear();

          for (final member
              in members) {
            if (member.id !=
                user?.uid) {
              _groupMembers
                  .add(member);
            }
          }
        });
      },
    );
  }

  // ==========================================================
  // MEMBER COLOR
  // ==========================================================

  Color _memberColor(
    String id,
  ) {
    final colors = [
      Colors.orange,
      Colors.blue,
      Colors.purple,
      Colors.red,
      Colors.cyan,
      Colors.yellow,
      Colors.pink,
    ];

    final index =
        id.codeUnits.fold(
              0,
              (
                previous,
                element,
              ) =>
                  previous +
                  element,
            ) %
            colors.length;

    return colors[index];
  }

  // ==========================================================
  // OWN MEMBER UPDATE
  // ==========================================================

  void _scheduleOwnMemberUpdate(
    LatLng location,
    double heading,
  ) {
    if (_activeTouringId ==
        null) {
      return;
    }

    if (_firestoreLocationTimer !=
        null) {
      return;
    }

    _firestoreLocationTimer =
        Timer(
      const Duration(
        seconds: 2,
      ),
      () async {
        _firestoreLocationTimer =
            null;

        await _updateOwnMember(
          location,
          heading,
        );
      },
    );
  }

  Future<void> _updateOwnMember(
    LatLng location,
    double heading,
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

    try {
      await FirebaseFirestore
          .instance
          .collection('tourings')
          .doc(touringId)
          .collection('members')
          .doc(user.uid)
          .set(
        {
          'lat':
              location.latitude,
          'lng':
              location.longitude,
          'heading':
              heading,
          'updatedAt':
              FieldValue
                  .serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );
    } catch (_) {}
  }

  // ==========================================================
  // START TOURING
  // ==========================================================

  Future<void> _startTouring() async {
    if (!_locationReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Tunggu GPS aktif terlebih dahulu',
          ),
        ),
      );

      return;
    }

    if (_activeTouringId ==
        null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Buat atau Join Touring terlebih dahulu',
          ),
        ),
      );

      return;
    }

    await _getRoute();

    if (!mounted) return;

    setState(() {
      _isTouring = true;

      _touringStartTime =
          DateTime.now();
    });

    _centerMyLocation();
  }

  // ==========================================================
  // STOP TOURING
  // ==========================================================

  Future<void> _stopTouring() async {
    if (mounted) {
      setState(() {
        _isTouring = false;

        _touringStartTime =
            null;
      });
    }

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
      await FirebaseFirestore
          .instance
          .collection('tourings')
          .doc(touringId)
          .collection('members')
          .doc(user.uid)
          .set(
        {
          'status':
              'Stopped',
          'updatedAt':
              FieldValue
                  .serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );
    } catch (_) {}
  }

  // ==========================================================
  // VEHICLE
  // ==========================================================

  void _toggleVehicle() {
    setState(() {
      _isMotorMode =
          !_isMotorMode;
    });

    _updateDistanceAndEta();

    _updateVehicleTypeInFirestore();
  }

  Future<void>
      _updateVehicleTypeInFirestore() async {
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
      await FirebaseFirestore
          .instance
          .collection('tourings')
          .doc(touringId)
          .collection('members')
          .doc(user.uid)
          .set(
        {
          'vehicleType':
              _isMotorMode
                  ? 'motor'
                  : 'mobil',
          'updatedAt':
              FieldValue
                  .serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );
    } catch (_) {}
  }

  // ==========================================================
  // MEMBER LIST
  // ==========================================================

  void _showMemberList() {
    showModalBottomSheet(
      context: context,
      backgroundColor:
          const Color(0xFF161616),
      builder: (context) {
        final user =
            FirebaseAuth
                .instance
                .currentUser;

        return SafeArea(
          child: SizedBox(
            height: 450,
            child: Column(
              children: [
                const SizedBox(
                  height: 12,
                ),

                Container(
                  width: 40,
                  height: 4,
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.grey,
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

                const Text(
                  'Member Touring',
                  style:
                      TextStyle(
                    fontSize: 20,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                if (_activeTouringName !=
                    null)
                  Padding(
                    padding:
                        const EdgeInsets
                            .only(
                      top: 4,
                    ),
                    child: Text(
                      _activeTouringName!,
                      style:
                          const TextStyle(
                        color:
                            Colors.grey,
                      ),
                    ),
                  ),

                const Divider(),

                Expanded(
                  child:
                      ListView(
                    children: [
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
                            const Text(
                          'Saya',
                        ),
                        subtitle:
                            Text(
                          _isMotorMode
                              ? 'Motor • Road Captain / Member'
                              : 'Mobil • Road Captain / Member',
                        ),
                        trailing:
                            const Icon(
                          Icons.circle,
                          color:
                              Colors.green,
                          size: 12,
                        ),
                      ),

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
                                  Icon(
                                member.vehicleType ==
                                        'motor'
                                    ? Icons
                                        .two_wheeler
                                    : Icons
                                        .directions_car,
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
                              '${member.vehicleType == 'motor' ? 'Motor' : 'Mobil'} • ${member.status}',
                            ),
                            trailing:
                                const Icon(
                              Icons.circle,
                              color:
                                  Colors.green,
                              size: 12,
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
  // AGORA PTT
  // ==========================================================

  Future<void> _initAgoraPTT() async {
    if (kIsWeb) {
      return;
    }

    try {
      final micPermission =
          await Permission
              .microphone
              .request();

      if (!micPermission
          .isGranted) {
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
          appId: agoraAppId,
        ),
      );

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess:
              (
            connection,
            elapsed,
          ) {
            if (!mounted) {
              return;
            }

            setState(() {
              _agoraJoined =
                  true;
            });
          },

          onUserJoined:
              (
            connection,
            remoteUid,
            elapsed,
          ) {},

          onUserOffline:
              (
            connection,
            remoteUid,
            reason,
          ) {},

          onError:
              (
            err,
            msg,
          ) {
            if (!mounted) {
              return;
            }

            setState(() {
              _agoraJoined =
                  false;
            });
          },
        ),
      );

      await engine.enableAudio();

      await engine.setClientRole(
        role: ClientRoleType
            .clientRoleBroadcaster,
      );

      await engine
          .setEnableSpeakerphone(
        true,
      );

      await engine
          .muteLocalAudioStream(
        true,
      );

      await engine.joinChannel(
        token: '',
        channelId:
            channelName,
        uid: 0,
        options:
            const ChannelMediaOptions(),
      );

      if (!mounted) {
        await engine.release();

        return;
      }

      setState(() {
        _engine =
            engine;

        _agoraInitialized =
            true;

        _microphoneEnabled =
            true;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _agoraInitialized =
            false;

        _agoraJoined =
            false;

        _microphoneEnabled =
            false;
      });
    }
  }

  // ==========================================================
  // PTT START
  // ==========================================================

  Future<void> _startPTT() async {
    if (_engine == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone belum siap',
          ),
        ),
      );

      return;
    }

    try {
      await _engine!
          .muteLocalAudioStream(
        false,
      );

      if (!mounted) return;

      setState(() {
        _isTalking = true;
      });
    } catch (_) {}
  }

  // ==========================================================
  // PTT STOP
  // ==========================================================

  Future<void> _stopPTT() async {
    if (_engine == null) {
      return;
    }

    try {
      await _engine!
          .muteLocalAudioStream(
        true,
      );
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _isTalking = false;
    });
  }

  // ==========================================================
  // VEHICLE MARKER
  // ==========================================================

  Widget _vehicleMarker({
    required String vehicleType,
    required double heading,
    required Color color,
    required String name,
  }) {
    final asset =
        vehicleType == 'motor'
            ? 'assets/metic.png'
            : 'assets/xtrail.png';

    return Column(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        Transform.rotate(
          angle:
              heading *
                  math.pi /
                  180,

          alignment:
              Alignment.center,

          child: Image.asset(
            asset,

            width: 58,

            height: 58,

            fit:
                BoxFit.contain,

            errorBuilder:
                (
              context,
              error,
              stackTrace,
            ) {
              return Icon(
                vehicleType ==
                        'motor'
                    ? Icons
                        .two_wheeler
                    : Icons
                        .directions_car,

                size: 48,

                color: color,
              );
            },
          ),
        ),

        Container(
          margin:
              const EdgeInsets
                  .only(
            top: 2,
          ),

          padding:
              const EdgeInsets
                  .symmetric(
            horizontal: 7,
            vertical: 3,
          ),

          decoration:
              BoxDecoration(
            color: Colors.black
                .withOpacity(
              0.75,
            ),

            borderRadius:
                BorderRadius
                    .circular(
              7,
            ),
          ),

          child: Text(
            name,

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
        ),
      ],
    );
  }

  // ==========================================================
  // MAP MARKERS
  // ==========================================================

  List<Marker> _buildMarkers() {
    final markers =
        <Marker>[];

    // ========================================================
    // TITIK KUMPUL
    // ========================================================

    markers.add(
      Marker(
        point:
            _titikKumpul,

        width: 45,

        height: 45,

        child:
            const Icon(
          Icons.location_on,
          color:
              Colors.green,
          size: 42,
        ),
      ),
    );

    // ========================================================
    // DESTINATION
    // ========================================================

    markers.add(
      Marker(
        point:
            _destinasi,

        width: 45,

        height: 45,

        child:
            const Icon(
          Icons.flag,
          color:
              Colors.red,
          size: 42,
        ),
      ),
    );

    // ========================================================
    // OWN POSITION
    // ========================================================

    if (_currentPosition !=
        null) {
      final ownLocation =
          LatLng(
        _currentPosition!
            .latitude,
        _currentPosition!
            .longitude,
      );

      markers.add(
        Marker(
          point:
              ownLocation,

          width: 90,

          height: 100,

          child:
              _vehicleMarker(
            vehicleType:
                _isMotorMode
                    ? 'motor'
                    : 'mobil',

            heading:
                _heading,

            color:
                Colors.green,

            name:
                'Saya',
          ),
        ),
      );
    }

    // ========================================================
    // OTHER MEMBERS
    // ========================================================

    for (final member
        in _groupMembers) {
      markers.add(
        Marker(
          point:
              member.location,

          width: 90,

          height: 100,

          child:
              _vehicleMarker(
            vehicleType:
                member.vehicleType,

            heading:
                member.heading,

            color:
                member.color,

            name:
                member.name,
          ),
        ),
      );
    }

    return markers;
  }

  // ==========================================================
  // APP BAR
  // ==========================================================

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor:
          const Color(
        0xFF0B0F12,
      ),

      foregroundColor:
          Colors.white,

      elevation: 0,

      title:
          const Text(
        'Mytouring',

        maxLines: 1,

        overflow:
            TextOverflow
                .ellipsis,
      ),

      actions: [
        // ====================================================
        // CREATE
        // ====================================================

        IconButton(
          tooltip:
              'Create Touring',

          icon:
              const Icon(
            Icons
                .add_circle_outline,
          ),

          onPressed:
              _showCreateTouringDialog,
        ),

        // ====================================================
        // ROUTE
        // ====================================================

        IconButton(
          tooltip:
              'Atur Rute',

          icon:
              const Icon(
            Icons.alt_route,
          ),

          onPressed:
              _showSetRouteDialog,
        ),

        // ====================================================
        // JOIN
        // ====================================================

        IconButton(
          tooltip:
              'Join Touring',

          icon:
              const Icon(
            Icons.login,
          ),

          onPressed:
              _showJoinTouringDialog,
        ),

        // ====================================================
        // MEMBERS
        // ====================================================

        Stack(
          alignment:
              Alignment.center,

          children: [
            IconButton(
              tooltip:
                  'Member',

              icon:
                  const Icon(
                Icons.groups,
              ),

              onPressed:
                  _showMemberList,
            ),

            if (_groupMembers
                .isNotEmpty)
              Positioned(
                right: 5,
                top: 7,

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
                        BoxShape
                            .circle,
                  ),

                  child:
                      Text(
                    '${_groupMembers.length}',

                    style:
                        const TextStyle(
                      fontSize:
                          9,

                      fontWeight:
                          FontWeight
                              .bold,
                    ),
                  ),
                ),
              ),
          ],
        ),

        // ====================================================
        // VEHICLE
        // ====================================================

        IconButton(
          tooltip:
              _isMotorMode
                  ? 'Mode Motor'
                  : 'Mode Mobil',

          icon:
              Icon(
            _isMotorMode
                ? Icons
                    .two_wheeler
                : Icons
                    .directions_car,
          ),

          onPressed:
              _toggleVehicle,
        ),

        // ====================================================
        // MAP TILE
        // ====================================================

        PopupMenuButton<
            String>(
          tooltip:
              'Map Style',

          icon:
              const Icon(
            Icons.layers,
          ),

          onSelected:
              (value) {
            setState(() {
              _selectedTile =
                  value;
            });
          },

          itemBuilder:
              (context) {
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
                      Row(
                    children: [
                      Icon(
                        key ==
                                'Standard'
                            ? Icons
                                .map
                            : key ==
                                    'Dark Mode'
                                ? Icons
                                    .dark_mode
                                : Icons
                                    .public,
                      ),

                      const SizedBox(
                        width: 10,
                      ),

                      Text(
                        key,
                      ),
                    ],
                  ),
                );
              },
            ).toList();
          },
        ),
      ],
    );
  }

  // ==========================================================
  // STATUS CARD
  // ==========================================================

  Widget _buildStatusCard() {
    return Container(
      margin:
          const EdgeInsets
              .fromLTRB(
        16,
        16,
        16,
        0,
      ),

      padding:
          const EdgeInsets
              .all(
        16,
      ),

      decoration:
          BoxDecoration(
        color: Colors.black
            .withOpacity(
          0.78,
        ),

        borderRadius:
            BorderRadius
                .circular(
          20,
        ),

        border:
            Border.all(
          color: Colors.white
              .withOpacity(
            0.08,
          ),
        ),
      ),

      child:
          Column(
        children: [
          Row(
            children: [
              Expanded(
                child:
                    Row(
                  children: [
                    Icon(
                      Icons
                          .gps_fixed,

                      color:
                          _gpsActive
                              ? Colors
                                  .green
                              : Colors
                                  .red,
                    ),

                    const SizedBox(
                      width: 8,
                    ),

                    Text(
                      _gpsStatus,

                      style:
                          TextStyle(
                        color:
                            _gpsActive
                                ? Colors
                                    .green
                                : Colors
                                    .red,

                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                  ],
                ),
              ),

              Row(
                children: [
                  Icon(
                    Icons.mic,

                    color:
                        _microphoneEnabled
                            ? Colors
                                .green
                            : Colors
                                .red,
                  ),

                  const SizedBox(
                    width: 6,
                  ),

                  Text(
                    _microphoneEnabled
                        ? 'Microphone Aktif'
                        : 'Microphone Tidak Aktif',

                    style:
                        TextStyle(
                      color:
                          _microphoneEnabled
                              ? Colors
                                  .green
                              : Colors
                                  .red,

                      fontWeight:
                          FontWeight
                              .bold,
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(
            height: 14,
          ),

          Row(
            children: [
              const Icon(
                Icons
                    .directions_car,

                color:
                    Colors.white,
              ),

              const SizedBox(
                width: 8,
              ),

              Text(
                '${_distanceInKm.toStringAsFixed(1)} km',

                style:
                    const TextStyle(
                  fontSize: 17,
                ),
              ),

              const SizedBox(
                width: 25,
              ),

              const Icon(
                Icons
                    .access_time,

                color:
                    Colors.white,
              ),

              const SizedBox(
                width: 8,
              ),

              Text(
                '$_estimatedMinutes min',

                style:
                    const TextStyle(
                  fontSize: 17,
                ),
              ),
            ],
          ),

          if (_activeTouringCode !=
              null) ...[
            const SizedBox(
              height: 12,
            ),

            Row(
              children: [
                const Icon(
                  Icons.key,

                  color:
                      Colors.amber,

                  size: 20,
                ),

                const SizedBox(
                  width: 7,
                ),

                Text(
                  'Kode: $_activeTouringCode',

                  style:
                      const TextStyle(
                    color:
                        Colors.amber,

                    fontWeight:
                        FontWeight
                            .bold,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ==========================================================
  // GPS BUTTON
  // ==========================================================

  Widget _buildGpsButton() {
    return FloatingActionButton(
      heroTag:
          'gpsButton',

      backgroundColor:
          Colors.black
              .withOpacity(
        0.92,
      ),

      foregroundColor:
          Colors.white,

      onPressed:
          _centerMyLocation,

      child:
          const Icon(
        Icons.gps_fixed,

        size: 32,
      ),
    );
  }

  // ==========================================================
  // WATERMARK
  // ==========================================================

  Widget _buildWatermark() {
    return Container(
      padding:
          const EdgeInsets
              .symmetric(
        horizontal: 12,
        vertical: 8,
      ),

      decoration:
          BoxDecoration(
        color: Colors.black
            .withOpacity(
          0.72,
        ),

        borderRadius:
            BorderRadius
                .circular(
          9,
        ),
      ),

      child:
          const Text(
        'Created by Mr. Ted',

        style:
            TextStyle(
          color:
              Colors.white,

          fontSize:
              14,
        ),
      ),
    );
  }

  // ==========================================================
  // PTT BUTTON
  // ==========================================================

  Widget _buildPTTButton() {
    return GestureDetector(
      onLongPressStart:
          (_) {
        _startPTT();
      },

      onLongPressEnd:
          (_) {
        _stopPTT();
      },

      onLongPressCancel:
          () {
        _stopPTT();
      },

      child:
          AnimatedContainer(
        duration:
            const Duration(
          milliseconds: 150,
        ),

        width: 230,

        height: 120,

        decoration:
            BoxDecoration(
          color: _isTalking
              ? Colors.red.shade700
              : const Color(
                  0xFF101512,
                ),

          borderRadius:
              BorderRadius
                  .circular(
            20,
          ),

          border:
              Border.all(
            color: _isTalking
                ? Colors
                    .redAccent
                : Colors.green
                    .withOpacity(
                  0.35,
                ),

            width: 2,
          ),

          boxShadow: [
            BoxShadow(
              color: _isTalking
                  ? Colors.red
                      .withOpacity(
                      0.35,
                    )
                  : Colors.black
                      .withOpacity(
                      0.35,
                    ),

              blurRadius:
                  15,
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
                  : Icons.mic_none,

              color:
                  _isTalking
                      ? Colors.white
                      : Colors
                          .greenAccent,

              size: 38,
            ),

            const SizedBox(
              height: 5,
            ),

            Text(
              _isTalking
                  ? 'Transmisi Suara Aktif...'
                  : 'PTT',

              style:
                  const TextStyle(
                color:
                    Colors.white,

                fontWeight:
                    FontWeight.bold,

                fontSize:
                    17,
              ),

              textAlign:
                  TextAlign.center,
            ),

            if (!_isTalking)
              const Text(
                'Tekan & Tahan untuk Bicara',

                style:
                    TextStyle(
                  color:
                      Colors.grey,

                  fontSize:
                      11,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // START TOURING BUTTON
  // ==========================================================

  Widget _buildTouringButton() {
    return Expanded(
      child:
          SizedBox(
        height: 120,

        child:
            ElevatedButton(
          onPressed:
              _isTouring
                  ? _stopTouring
                  : _startTouring,

          style:
              ElevatedButton.styleFrom(
            backgroundColor:
                _isTouring
                    ? Colors.red
                    : Colors.green,

            foregroundColor:
                Colors.white,

            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius
                      .circular(
                20,
              ),
            ),
          ),

          child:
              Column(
            mainAxisAlignment:
                MainAxisAlignment
                    .center,

            children: [
              Icon(
                _isTouring
                    ? Icons.stop
                    : Icons.play_arrow,

                size: 32,
              ),

              const SizedBox(
                height: 5,
              ),

              Text(
                _isTouring
                    ? 'STOP TOURING'
                    : 'START TOURING',

                style:
                    const TextStyle(
                  fontSize: 18,

                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // BOTTOM CONTROLS
  // ==========================================================

  Widget _buildBottomControls() {
    return SafeArea(
      top: false,

      child:
          Padding(
        padding:
            const EdgeInsets
                .fromLTRB(
          16,
          8,
          16,
          12,
        ),

        child:
            Row(
          crossAxisAlignment:
              CrossAxisAlignment
                  .stretch,

          children: [
            _buildPTTButton(),

            const SizedBox(
              width: 14,
            ),

            _buildTouringButton(),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // ROUTE INFO
  // ==========================================================

  Widget _buildRouteInfo() {
    if (_routePoints.isEmpty) {
      return const SizedBox
          .shrink();
    }

    return Positioned(
      top: 150,

      left: 20,

      right: 20,

      child:
          Container(
        padding:
            const EdgeInsets
                .symmetric(
          horizontal: 14,
          vertical: 9,
        ),

        decoration:
            BoxDecoration(
          color: Colors.black
              .withOpacity(
            0.72,
          ),

          borderRadius:
              BorderRadius
                  .circular(
            12,
          ),
        ),

        child:
            Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,

          children: [
            const Icon(
              Icons.route,

              color:
                  Colors.blueAccent,

              size: 20,
            ),

            const SizedBox(
              width: 7,
            ),

            Text(
              '${_routeDistanceKm.toStringAsFixed(1)} km',

              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            const SizedBox(
              width: 18,
            ),

            const Icon(
              Icons.timer,

              color:
                  Colors.orange,

              size: 20,
            ),

            const SizedBox(
              width: 7,
            ),

            Text(
              '${_routeDurationMinutes.round()} min',
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // MAP
  // ==========================================================

  Widget _buildMap() {
    return FlutterMap(
      mapController:
          _mapController,

      options:
          MapOptions(
        initialCenter:
            _titikKumpul,

        initialZoom:
            14.5,

        onTap:
            _handleMapTap,
      ),

      children: [
        TileLayer(
          urlTemplate:
              _tileProviders[
                  _selectedTile]!,

          userAgentPackageName:
              'com.tedapp.touringmap',
        ),

        // ====================================================
        // ROUTE
        // ====================================================

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
                    _isMotorMode
                        ? Colors.blue
                        : Colors.orange,
              ),
            ],
          ),

        // ====================================================
        // MARKERS
        // ====================================================

        MarkerLayer(
          markers:
              _buildMarkers(),
        ),
      ],
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          Colors.black,

      appBar:
          _buildAppBar(),

      body:
          Stack(
        children: [
          // ==================================================
          // MAP FULL
          // ==================================================

          Positioned.fill(
            child:
                _buildMap(),
          ),

          // ==================================================
          // STATUS CARD
          // ==================================================

          Positioned(
            top: 0,

            left: 0,

            right: 0,

            child:
                _buildStatusCard(),
          ),

          // ==================================================
          // ROUTE INFO
          // ==================================================

          _buildRouteInfo(),

          // ==================================================
          // MAP PICKING
          // ==================================================

          if (_mapPickingMode)
            Positioned(
              top: 115,

              left: 20,

              right: 20,

              child:
                  Container(
                padding:
                    const EdgeInsets
                        .all(
                  12,
                ),

                decoration:
                    BoxDecoration(
                  color: Colors.green
                      .withOpacity(
                    0.9,
                  ),

                  borderRadius:
                      BorderRadius
                          .circular(
                    12,
                  ),
                ),

                child:
                    Row(
                  children: [
                    const Icon(
                      Icons.touch_app,

                      color:
                          Colors.white,
                    ),

                    const SizedBox(
                      width: 10,
                    ),

                    Expanded(
                      child:
                          Text(
                        _pickingTarget ==
                                'start'
                            ? 'Tap map untuk memilih titik kumpul'
                            : 'Tap map untuk memilih tujuan',

                        style:
                            const TextStyle(
                          color:
                              Colors.white,

                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),

                    IconButton(
                      onPressed:
                          () {
                        setState(
                          () {
                            _mapPickingMode =
                                false;

                            _pickingTarget =
                                '';
                          },
                        );
                      },

                      icon:
                          const Icon(
                        Icons.close,

                        color:
                            Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ==================================================
          // GPS CENTER BUTTON
          // ==================================================
          //
          // Posisi dibuat lebih tinggi supaya tidak menabrak
          // watermark dan tombol START TOURING.
          //

          Positioned(
            right: 18,

            bottom: 220,

            child:
                _buildGpsButton(),
          ),

          // ==================================================
          // WATERMARK
          // ==================================================

          Positioned(
            right: 18,

            bottom: 145,

            child:
                _buildWatermark(),
          ),

          // ==================================================
          // BOTTOM PTT + START TOURING
          // ==================================================

          Positioned(
            left: 0,

            right: 0,

            bottom: 0,

            child:
                _buildBottomControls(),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    _positionStream?.cancel();

    _membersSubscription
        ?.cancel();

    _firestoreLocationTimer
        ?.cancel();

    _releaseAgora();

    super.dispose();
  }

  Future<void>
      _releaseAgora() async {
    try {
      await _engine
          ?.leaveChannel();

      await _engine
          ?.release();
    } catch (_) {}
  }
}
