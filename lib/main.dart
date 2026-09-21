import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

const String agoraAppId = "398d30b96cae43aeac064c7a0fa9add8";
const String channelName = "touring_room_1";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const MyApp());
}

// ============================================================
// DATA ANGGOTA
// ============================================================

class Member {
  final String id;
  final String name;
  final LatLng location;
  final String status;
  final Color color;
  final String vehicleType;

  Member({
    required this.id,
    required this.name,
    required this.location,
    required this.status,
    required this.color,
    required this.vehicleType,
  });
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
      title: 'Touring Map',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const MapScreen(),
    );
  }
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
  final MapController _mapController = MapController();

  // ==========================================================
  // TITIK KUMPUL & DESTINASI
  // ==========================================================

  LatLng _titikKumpul =
      const LatLng(-6.175392, 106.827153);

  LatLng _destinasi =
      const LatLng(-6.229728, 106.846548);

  // ==========================================================
  // MODE PILIH TITIK
  // ==========================================================

  String? _mapPickingMode;

  // ==========================================================
  // GPS
  // ==========================================================

  LatLng? _currentPosition;

  StreamSubscription<Position>? _positionStream;

  double _distanceInKm = 0.0;

  int _estimatedMinutes = 0;

  String _gpsStatus = 'Mencari GPS...';

  bool _locationReady = false;

  // ==========================================================
  // ROUTING
  // ==========================================================

  List<LatLng> _routePoints = [];

  double _routeDistanceKm = 0.0;

  int _routeDurationMinutes = 0;

  bool _isLoadingRoute = false;

  // Posisi terakhir yang digunakan untuk meminta routing.
  LatLng? _lastRoutePosition;

  // Routing ulang setiap kurang lebih 50 meter.
  static const double _rerouteDistanceMeters = 50.0;

  // ==========================================================
  // TOURING
  // ==========================================================

  bool _isTouring = false;

  DateTime? _touringStartTime;

  // ==========================================================
  // MODE KENDARAAN
  // ==========================================================

  bool _isMotorMode = true;

  // ==========================================================
  // MODE PETA
  // ==========================================================

  String _selectedTile = 'Standard';

  final Map<String, String> _tileProviders = {
    'Standard':
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',

    'Dark Mode':
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',

    'Humanitarian':
        'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
  };

  // ==========================================================
  // ANGGOTA ROMBONGAN
  // ==========================================================

  final List<Member> _groupMembers = [
    Member(
      id: '1',
      name: 'Budi (Road Captain)',
      location: const LatLng(
        -6.195000,
        106.832000,
      ),
      status: 'Riding',
      color: Colors.orange,
      vehicleType: 'Motor',
    ),
  ];

  // ==========================================================
  // AGORA PTT
  // ==========================================================

  RtcEngine? _engine;

  bool _isEngineReady = false;

  bool _isTalking = false;

  String _pttStatusText =
      'Inisialisasi Voice PTT...';

  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();

    _initializeGPS();

    if (!kIsWeb) {
      _initAgoraPTT();
    } else {
      _pttStatusText =
          'Tekan & Tahan untuk Bicara';
    }
  }

  // ==========================================================
  // GPS INITIALIZATION
  // ==========================================================

  Future<void> _initializeGPS() async {
    debugPrint('================================');
    debugPrint('MULAI INISIALISASI GPS');
    debugPrint('================================');

    if (mounted) {
      setState(() {
        _gpsStatus = 'Memeriksa GPS...';
      });
    }

    try {
      // --------------------------------------------------------
      // CEK GPS SERVICE
      // --------------------------------------------------------

      bool serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      debugPrint(
        'Location service: $serviceEnabled',
      );

      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _gpsStatus = 'GPS Tidak Aktif';
          });
        }

        _showMessage(
          'Aktifkan GPS/Lokasi di HP terlebih dahulu',
        );

        return;
      }

      // --------------------------------------------------------
      // CEK PERMISSION
      // --------------------------------------------------------

      LocationPermission permission =
          await Geolocator.checkPermission();

      debugPrint(
        'Permission awal: $permission',
      );

      // --------------------------------------------------------
      // REQUEST PERMISSION
      // --------------------------------------------------------

      if (permission ==
          LocationPermission.denied) {
        debugPrint(
          'Meminta izin lokasi...',
        );

        if (mounted) {
          setState(() {
            _gpsStatus =
                'Meminta izin GPS...';
          });
        }

        permission =
            await Geolocator.requestPermission();

        debugPrint(
          'Permission setelah request: $permission',
        );
      }

      // --------------------------------------------------------
      // DENIED
      // --------------------------------------------------------

      if (permission ==
          LocationPermission.denied) {
        if (mounted) {
          setState(() {
            _gpsStatus =
                'Izin GPS Ditolak';
          });
        }

        _showMessage(
          'Izin lokasi diperlukan untuk tracking',
        );

        return;
      }

      // --------------------------------------------------------
      // DENIED FOREVER
      // --------------------------------------------------------

      if (permission ==
          LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _gpsStatus =
                'Izin GPS Diblokir';
          });
        }

        _showMessage(
          'Izin GPS diblokir. Buka Settings aplikasi.',
        );

        return;
      }

      // --------------------------------------------------------
      // PERMISSION OK
      // --------------------------------------------------------

      debugPrint(
        'IZIN GPS OK',
      );

      if (mounted) {
        setState(() {
          _gpsStatus =
              'Mendapatkan posisi...';
        });
      }

      await _getCurrentLocation();

      if (_currentPosition != null) {
        _startLocationUpdates();
      }
    } catch (e) {
      debugPrint(
        'ERROR INITIALIZE GPS: $e',
      );

      if (!mounted) return;

      setState(() {
        _gpsStatus =
            'GPS Error';
      });

      _showMessage(
        'Gagal menginisialisasi GPS',
      );
    }
  }

  // ==========================================================
  // GET CURRENT LOCATION
  // ==========================================================

  Future<void> _getCurrentLocation() async {
    try {
      debugPrint(
        'Mencari posisi GPS...',
      );

      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy:
            LocationAccuracy.high,
        timeLimit:
            const Duration(
          seconds: 20,
        ),
      );

      debugPrint('================================');
      debugPrint('GPS BERHASIL');
      debugPrint(
        'Latitude : ${position.latitude}',
      );
      debugPrint(
        'Longitude: ${position.longitude}',
      );
      debugPrint(
        'Accuracy : ${position.accuracy}',
      );
      debugPrint('================================');

      if (!mounted) return;

      final LatLng newPosition =
          LatLng(
        position.latitude,
        position.longitude,
      );

      setState(() {
        _currentPosition =
            newPosition;

        _gpsStatus =
            'GPS Aktif';

        _locationReady = true;

        _calculateDistanceAndEta();
      });

      // Pindahkan peta ke posisi HP.
      _mapController.move(
        newPosition,
        15.0,
      );

      // Ambil rute jalan pertama.
      await _getRoadRoute();
    } catch (e) {
      debugPrint(
        'ERROR GET CURRENT LOCATION: $e',
      );

      if (!mounted) return;

      setState(() {
        _gpsStatus =
            'Gagal mendapatkan GPS';

        _locationReady = false;
      });

      _showMessage(
        'GPS belum mendapatkan posisi',
      );
    }
  }

  // ==========================================================
  // GET ROAD ROUTE
  // ==========================================================

  Future<void> _getRoadRoute() async {
    if (_currentPosition == null) {
      return;
    }

    if (_isLoadingRoute) {
      return;
    }

    if (!mounted) return;

    setState(() {
      _isLoadingRoute = true;
    });

    try {
      final LatLng start =
          _currentPosition!;

      final LatLng end =
          _destinasi;

      final Uri url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson',
      );

      debugPrint(
        '================================',
      );

      debugPrint(
        'MEMINTA RUTE OSRM',
      );

      debugPrint(
        'Start: ${start.latitude}, ${start.longitude}',
      );

      debugPrint(
        'End: ${end.latitude}, ${end.longitude}',
      );

      debugPrint(
        '================================',
      );

      final http.Response response =
          await http
              .get(url)
              .timeout(
                const Duration(
                  seconds: 15,
                ),
              );

      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}',
        );
      }

      final dynamic data =
          jsonDecode(response.body);

      if (data['code'] != 'Ok') {
        throw Exception(
          'OSRM: ${data['code']}',
        );
      }

      final List routes =
          data['routes'];

      if (routes.isEmpty) {
        throw Exception(
          'Rute tidak ditemukan',
        );
      }

      final dynamic route =
          routes[0];

      final dynamic geometry =
          route['geometry'];

      final List coordinates =
          geometry['coordinates'];

      final List<LatLng> newRoute =
          coordinates
              .map<LatLng>(
                (dynamic coordinate) {
                  return LatLng(
                    (coordinate[1] as num)
                        .toDouble(),
                    (coordinate[0] as num)
                        .toDouble(),
                  );
                },
              )
              .toList();

      final double distanceMeters =
          (route['distance'] as num)
              .toDouble();

      final double durationSeconds =
          (route['duration'] as num)
              .toDouble();

      if (!mounted) return;

      setState(() {
        _routePoints =
            newRoute;

        _routeDistanceKm =
            distanceMeters / 1000;

        _routeDurationMinutes =
            (durationSeconds / 60)
                .round();

        _distanceInKm =
            _routeDistanceKm;

        _estimatedMinutes =
            _routeDurationMinutes;

        _isLoadingRoute = false;

        _lastRoutePosition =
            start;
      });

      debugPrint(
        'RUTE BERHASIL',
      );

      debugPrint(
        'Jarak jalan: '
        '${_routeDistanceKm.toStringAsFixed(2)} km',
      );

      debugPrint(
        'Durasi: '
        '$_routeDurationMinutes menit',
      );

      debugPrint(
        'Jumlah titik rute: '
        '${_routePoints.length}',
      );
    } catch (e) {
      debugPrint(
        'ERROR ROUTING: $e',
      );

      if (!mounted) return;

      setState(() {
        _isLoadingRoute = false;
      });

      _showMessage(
        'Gagal mendapatkan rute jalan',
      );
    }
  }

  // ==========================================================
  // CEK APAKAH PERLU ROUTING ULANG
  // ==========================================================

  void _checkAndUpdateRoute(
    LatLng newPosition,
  ) {
    if (!_isTouring) {
      return;
    }

    if (_isLoadingRoute) {
      return;
    }

    if (_lastRoutePosition == null) {
      _getRoadRoute();
      return;
    }

    final double distance =
        Geolocator.distanceBetween(
      _lastRoutePosition!.latitude,
      _lastRoutePosition!.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );

    debugPrint(
      'Jarak dari routing terakhir: '
      '${distance.toStringAsFixed(1)} m',
    );

    if (distance >=
        _rerouteDistanceMeters) {
      _getRoadRoute();
    }
  }

  // ==========================================================
  // GPS REALTIME
  // ==========================================================

  void _startLocationUpdates() {
    _positionStream?.cancel();

    const LocationSettings locationSettings =
        LocationSettings(
      accuracy:
          LocationAccuracy.high,
      distanceFilter: 5,
    );

    debugPrint(
      'GPS realtime dimulai',
    );

    _positionStream =
        Geolocator.getPositionStream(
      locationSettings:
          locationSettings,
    ).listen(
      (Position position) {
        debugPrint(
          'GPS UPDATE: '
          '${position.latitude}, '
          '${position.longitude}',
        );

        if (!mounted) return;

        final LatLng newPosition =
            LatLng(
          position.latitude,
          position.longitude,
        );

        setState(() {
          _currentPosition =
              newPosition;

          _gpsStatus =
              'GPS Aktif';

          _locationReady = true;

          _calculateDistanceAndEta();
        });

        // Peta mengikuti kendaraan
        // hanya saat touring.
        if (_isTouring) {
          _mapController.move(
            newPosition,
            16.0,
          );

          _checkAndUpdateRoute(
            newPosition,
          );
        }
      },
      onError: (error) {
        debugPrint(
          'GPS STREAM ERROR: $error',
        );

        if (!mounted) return;

        setState(() {
          _gpsStatus =
              'GPS Error';

          _locationReady = false;
        });
      },
    );
  }

  // ==========================================================
  // MULAI TOURING
  // ==========================================================

  Future<void> _startTouring() async {
    if (!_locationReady ||
        _currentPosition == null) {
      _showMessage(
        'Posisi GPS belum tersedia',
      );

      return;
    }

    setState(() {
      _isTouring = true;

      _touringStartTime =
          DateTime.now();
    });

    // Ambil rute dari posisi GPS
    // saat touring dimulai.
    await _getRoadRoute();

    if (!mounted) return;

    _mapController.move(
      _currentPosition!,
      16.0,
    );

    _showMessage(
      'Touring dimulai',
    );
  }

  // ==========================================================
  // STOP TOURING
  // ==========================================================

  void _stopTouring() {
    setState(() {
      _isTouring = false;
    });

    _showMessage(
      'Touring dihentikan',
    );
  }

  // ==========================================================
  // HITUNG JARAK & ETA
  // ==========================================================

  void _calculateDistanceAndEta() {
    if (_currentPosition == null) {
      return;
    }

    // Kalau sudah ada hasil routing,
    // jangan langsung menimpa dengan
    // jarak garis lurus.
    if (_routePoints.isNotEmpty) {
      _distanceInKm =
          _routeDistanceKm;

      _estimatedMinutes =
          _routeDurationMinutes;

      return;
    }

    final double distanceInMeters =
        Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _destinasi.latitude,
      _destinasi.longitude,
    );

    _distanceInKm =
        distanceInMeters / 1000;

    final double speedKmPerHour =
        _isMotorMode
            ? 45.0
            : 35.0;

    _estimatedMinutes =
        ((_distanceInKm /
                    speedKmPerHour) *
                60)
            .round();
  }

  // ==========================================================
  // CENTER GPS
  // ==========================================================

  void _centerToMyLocation() {
    if (_currentPosition != null) {
      _mapController.move(
        _currentPosition!,
        16.0,
      );
    } else {
      _showMessage(
        'Posisi GPS belum tersedia',
      );
    }
  }

  // ==========================================================
  // ICON KENDARAAN
  // ==========================================================

  IconData _getVehicleIcon(
    String vehicleType,
  ) {
    switch (vehicleType) {
      case 'Motor':
        return Icons.two_wheeler;

      case 'Scooter':
        return Icons.electric_scooter;

      case 'Mobil':
        return Icons.directions_car;

      case 'SUV':
        return Icons.directions_car_filled;

      case 'Truck':
        return Icons.local_shipping;

      case 'Van':
        return Icons.airport_shuttle;

      case 'Taxi':
        return Icons.local_taxi;

      case 'Sepeda':
        return Icons.pedal_bike;

      default:
        return Icons.directions_car;
    }
  }

  // ==========================================================
  // PILIH TITIK
  // ==========================================================

  void _startPickLocation(
    String mode,
  ) {
    Navigator.pop(context);

    setState(() {
      _mapPickingMode = mode;
    });
  }

  // ==========================================================
  // MAP TAP
  // ==========================================================

  void _handleMapTap(
    TapPosition tapPosition,
    LatLng point,
  ) {
    if (_mapPickingMode == null) {
      return;
    }

    // --------------------------------------------------------
    // TITIK KUMPUL
    // --------------------------------------------------------

    if (_mapPickingMode ==
        'kumpul') {
      setState(() {
        _titikKumpul = point;

        _mapPickingMode = null;
      });

      _mapController.move(
        point,
        14.0,
      );

      _showMessage(
        'Titik kumpul berhasil dipilih',
      );
    }

    // --------------------------------------------------------
    // DESTINASI
    // --------------------------------------------------------

    else if (_mapPickingMode ==
        'destinasi') {
      setState(() {
        _destinasi = point;

        _mapPickingMode = null;

        // Hapus rute lama.
        _routePoints = [];

        _routeDistanceKm = 0.0;

        _routeDurationMinutes = 0;

        _calculateDistanceAndEta();
      });

      _mapController.move(
        point,
        14.0,
      );

      // Kalau GPS sudah tersedia,
      // langsung hitung rute baru.
      if (_currentPosition != null) {
        _getRoadRoute();
      }

      _showMessage(
        'Destinasi berhasil dipilih',
      );
    }
  }

  // ==========================================================
  // MESSAGE
  // ==========================================================

  void _showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content:
            Text(message),
        duration:
            const Duration(
          seconds: 2,
        ),
      ),
    );
  }

  // ==========================================================
  // ATUR RUTE
  // ==========================================================

  void _showSetRouteDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title:
              const Text(
            'Atur Rute Touring',
          ),
          content:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [

              // TITIK KUMPUL
              Card(
                child:
                    ListTile(
                  leading:
                      const Icon(
                    Icons.location_on,
                    color:
                        Colors.red,
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
                    '${_titikKumpul.latitude.toStringAsFixed(5)}, '
                    '${_titikKumpul.longitude.toStringAsFixed(5)}',
                  ),
                  trailing:
                      const Icon(
                    Icons.map,
                  ),
                  onTap: () {
                    _startPickLocation(
                      'kumpul',
                    );
                  },
                ),
              ),

              const SizedBox(
                height:
                    10,
              ),

              // DESTINASI
              Card(
                child:
                    ListTile(
                  leading:
                      const Icon(
                    Icons.flag,
                    color:
                        Colors.green,
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
                    '${_destinasi.latitude.toStringAsFixed(5)}, '
                    '${_destinasi.longitude.toStringAsFixed(5)}',
                  ),
                  trailing:
                      const Icon(
                    Icons.map,
                  ),
                  onTap: () {
                    _startPickLocation(
                      'destinasi',
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(
                context,
              ),
              child:
                  const Text(
                'Tutup',
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // TAMBAH ANGGOTA
  // ==========================================================

  void _showAddMemberDialog() {
    final TextEditingController
        nameController =
        TextEditingController();

    String selectedVehicle =
        'Motor';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder:
              (context, setDialogState) {
            return AlertDialog(
              title:
                  const Text(
                'Tambah Anggota Rombongan',
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
                          nameController,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Nama Anggota',
                        hintText:
                            'Contoh: Andi (Sweeper)',
                        prefixIcon:
                            Icon(
                          Icons.person,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height:
                          18,
                    ),

                    DropdownButtonFormField<
                        String>(
                      value:
                          selectedVehicle,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Jenis Kendaraan',
                        prefixIcon:
                            Icon(
                          Icons.directions_car,
                        ),
                        border:
                            OutlineInputBorder(),
                      ),
                      items: const [

                        DropdownMenuItem(
                          value:
                              'Motor',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.two_wheeler,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Motor',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Scooter',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.electric_scooter,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Scooter',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Mobil',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.directions_car,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Mobil',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'SUV',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons
                                    .directions_car_filled,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'SUV',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Truck',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.local_shipping,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Truck',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Van',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons
                                    .airport_shuttle,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Van',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Taxi',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.local_taxi,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Taxi',
                              ),
                            ],
                          ),
                        ),

                        DropdownMenuItem(
                          value:
                              'Sepeda',
                          child:
                              Row(
                            children: [
                              Icon(
                                Icons.pedal_bike,
                              ),
                              SizedBox(
                                width:
                                    10,
                              ),
                              Text(
                                'Sepeda',
                              ),
                            ],
                          ),
                        ),
                      ],
                      onChanged:
                          (value) {
                        if (value !=
                            null) {
                          setDialogState(() {
                            selectedVehicle =
                                value;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [

                TextButton(
                  onPressed: () =>
                      Navigator.pop(
                    context,
                  ),
                  child:
                      const Text(
                    'Batal',
                  ),
                ),

                ElevatedButton.icon(
                  icon:
                      const Icon(
                    Icons.person_add,
                  ),
                  label:
                      const Text(
                    'Simpan',
                  ),
                  onPressed: () {

                    if (nameController
                        .text
                        .trim()
                        .isNotEmpty) {

                      setState(() {
                        _groupMembers
                            .add(
                          Member(
                            id:
                                DateTime
                                    .now()
                                    .millisecondsSinceEpoch
                                    .toString(),

                            name:
                                nameController
                                    .text
                                    .trim(),

                            location:
                                LatLng(
                              (_currentPosition
                                          ?.latitude ??
                                      -6.175392) +
                                  0.002,

                              (_currentPosition
                                          ?.longitude ??
                                      106.827153) +
                                  0.002,
                            ),

                            status:
                                'Riding',

                            color:
                                Colors.green,

                            vehicleType:
                                selectedVehicle,
                          ),
                        );
                      });

                      Navigator.pop(
                        context,
                      );
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==========================================================
  // DAFTAR ANGGOTA
  // ==========================================================

  void _showMemberList() {
    showModalBottomSheet(
      context:
          context,
      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top:
              Radius.circular(
            20,
          ),
        ),
      ),
      builder:
          (context) {
        return Padding(
          padding:
              const EdgeInsets.all(
            16.0,
          ),
          child:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [

              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [

                  Text(
                    'Daftar Anggota (${_groupMembers.length + 1})',
                    style:
                        const TextStyle(
                      fontSize:
                          18,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  IconButton(
                    icon:
                        const Icon(
                      Icons.person_add,
                      color:
                          Colors.blueAccent,
                    ),
                    onPressed:
                        () {
                      Navigator.pop(
                        context,
                      );

                      _showAddMemberDialog();
                    },
                  ),
                ],
              ),

              const Divider(),

              // SAYA
              ListTile(
                leading:
                    CircleAvatar(
                  backgroundColor:
                      Colors.blueAccent,
                  child:
                      Icon(
                    _isMotorMode
                        ? Icons.two_wheeler
                        : Icons.directions_car,
                    color:
                        Colors.white,
                  ),
                ),
                title:
                    const Text(
                  'Saya (Pengemudi)',
                ),
                subtitle:
                    Text(
                  _isMotorMode
                      ? 'Motor'
                      : 'Mobil',
                ),
                trailing:
                    const Icon(
                  Icons.my_location,
                  color:
                      Colors.blueAccent,
                ),
              ),

              // ANGGOTA
              ..._groupMembers.map(
                (member) {
                  return ListTile(
                    leading:
                        CircleAvatar(
                      backgroundColor:
                          member.color,
                      child:
                          Icon(
                        _getVehicleIcon(
                          member.vehicleType,
                        ),
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
                      '${member.vehicleType} • ${member.status}',
                    ),
                    trailing:
                        const Icon(
                      Icons.check_circle,
                      color:
                          Colors.green,
                      size:
                          20,
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    _positionStream?.cancel();

    _engine?.leaveChannel();

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
        backgroundColor:
            Colors.blueAccent,
        foregroundColor:
            Colors.white,
        actions: [

          // ATUR RUTE
          IconButton(
            icon:
                const Icon(
              Icons.add_location_alt,
            ),
            tooltip:
                'Atur Rute',
            onPressed:
                _showSetRouteDialog,
          ),

          // TAMBAH ANGGOTA
          IconButton(
            icon:
                const Icon(
              Icons.person_add,
            ),
            tooltip:
                'Tambah Anggota',
            onPressed:
                _showAddMemberDialog,
          ),

          // DAFTAR ANGGOTA
          IconButton(
            icon:
                Badge(
              label:
                  Text(
                '${_groupMembers.length + 1}',
              ),
              child:
                  const Icon(
                Icons.group,
              ),
            ),
            tooltip:
                'Daftar Anggota',
            onPressed:
                _showMemberList,
          ),

          // MODE MOTOR / MOBIL
          IconButton(
            icon:
                Icon(
              _isMotorMode
                  ? Icons.two_wheeler
                  : Icons.directions_car,
            ),
            tooltip:
                _isMotorMode
                    ? 'Mode Motor'
                    : 'Mode Mobil',
            onPressed:
                () {
              setState(() {
                _isMotorMode =
                    !_isMotorMode;
              });

              _calculateDistanceAndEta();
            },
          ),

          // LAYER
          PopupMenuButton<String>(
            icon:
                const Icon(
              Icons.layers,
            ),
            tooltip:
                'Mode Peta',
            onSelected:
                (String newValue) {
              setState(() {
                _selectedTile =
                    newValue;
              });
            },
            itemBuilder:
                (BuildContext context) {
              return _tileProviders
                  .keys
                  .map(
                (String key) {
                  return PopupMenuItem<
                      String>(
                    value:
                        key,
                    child:
                        Row(
                      children: [

                        Icon(
                          key ==
                                  'Dark Mode'
                              ? Icons.dark_mode
                              : (key ==
                                      'Standard'
                                  ? Icons.map
                                  : Icons.public),
                          color:
                              Colors.blueAccent,
                          size:
                              20,
                        ),

                        const SizedBox(
                          width:
                              10,
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
      ),

      // ======================================================
      // BODY
      // ======================================================

      body:
          Stack(
        children: [

          // ==================================================
          // MAP
          // ==================================================

          FlutterMap(
            mapController:
                _mapController,
            options:
                MapOptions(
              initialCenter:
                  _titikKumpul,
              initialZoom:
                  13.0,
              onTap:
                  _handleMapTap,
            ),
            children: [

              // TILE
              TileLayer(
                urlTemplate:
                    _tileProviders[
                        _selectedTile]!,
                userAgentPackageName:
                    'com.tedapp.touringmap',
              ),

              // =================================================
              // ROAD ROUTE
              // =================================================

              PolylineLayer(
                polylines: [

                  if (_routePoints.isNotEmpty)
                    Polyline(
                      points:
                          _routePoints,
                      strokeWidth:
                          5.0,
                      color:
                          _isMotorMode
                              ? Colors.blueAccent
                              : Colors.orangeAccent,
                    ),
                ],
              ),

              // =================================================
              // MARKER
              // =================================================

              MarkerLayer(
                markers: [

                  // TITIK KUMPUL
                  Marker(
                    point:
                        _titikKumpul,
                    width:
                        80,
                    height:
                        80,
                    child:
                        const Icon(
                      Icons.location_on,
                      color:
                          Colors.red,
                      size:
                          40,
                    ),
                  ),

                  // DESTINASI
                  Marker(
                    point:
                        _destinasi,
                    width:
                        80,
                    height:
                        80,
                    child:
                        const Icon(
                      Icons.flag,
                      color:
                          Colors.green,
                      size:
                          38,
                    ),
                  ),

                  // POSISI SAYA
                  if (_currentPosition !=
                      null)
                    Marker(
                      point:
                          _currentPosition!,
                      width:
                          60,
                      height:
                          60,
                      child:
                          Container(
                        decoration:
                            BoxDecoration(
                          shape:
                              BoxShape.circle,
                          color:
                              Colors.blueAccent,
                          border:
                              Border.all(
                            color:
                                Colors.white,
                            width:
                                3,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color:
                                  Colors.black38,
                              blurRadius:
                                  5,
                            ),
                          ],
                        ),
                        child:
                            Icon(
                          _isMotorMode
                              ? Icons.two_wheeler
                              : Icons.directions_car,
                          color:
                              Colors.white,
                          size:
                              30,
                        ),
                      ),
                    ),

                  // ANGGOTA
                  ..._groupMembers.map(
                    (member) {
                      return Marker(
                        point:
                            member.location,
                        width:
                            80,
                        height:
                            65,
                        child:
                            Column(
                          children: [

                            Container(
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal:
                                    5,
                                vertical:
                                    2,
                              ),
                              decoration:
                                  BoxDecoration(
                                color:
                                    Colors.white,
                                borderRadius:
                                    BorderRadius.circular(
                                  4,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    blurRadius:
                                        2,
                                    color:
                                        Colors.black26,
                                  ),
                                ],
                              ),
                              child:
                                  Text(
                                member.name
                                    .split(
                                      ' ',
                                    )
                                    .first,
                                style:
                                    const TextStyle(
                                  fontSize:
                                      10,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ),

                            Icon(
                              _getVehicleIcon(
                                member.vehicleType,
                              ),
                              color:
                                  member.color,
                              size:
                                  30,
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
          // LOADING ROUTE
          // ==================================================

          if (_isLoadingRoute)
            Positioned(
              top:
                  100,
              right:
                  16,
              child:
                  Card(
                child:
                    Padding(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal:
                        12,
                    vertical:
                        8,
                  ),
                  child:
                      Row(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [

                      const SizedBox(
                        width:
                            16,
                        height:
                            16,
                        child:
                            CircularProgressIndicator(
                          strokeWidth:
                              2,
                        ),
                      ),

                      const SizedBox(
                        width:
                            8,
                      ),

                      const Text(
                        'Menghitung rute...',
                        style:
                            TextStyle(
                          fontSize:
                              12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================================
          // INSTRUKSI PILIH TITIK
          // ==================================================

          if (_mapPickingMode !=
              null)
            Positioned(
              top:
                  16,
              left:
                  16,
              right:
                  16,
              child:
                  Card(
                color:
                    Colors.blueAccent,
                elevation:
                    6,
                child:
                    Padding(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal:
                        16,
                    vertical:
                        12,
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
                        width:
                            10,
                      ),

                      Expanded(
                        child:
                            Text(
                          _mapPickingMode ==
                                  'kumpul'
                              ? 'Tap peta untuk memilih TITIK KUMPUL'
                              : 'Tap peta untuk memilih DESTINASI',
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
                        icon:
                            const Icon(
                          Icons.close,
                          color:
                              Colors.white,
                        ),
                        onPressed:
                            () {
                          setState(() {
                            _mapPickingMode =
                                null;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================================
          // INFO GPS / JARAK / ETA
          // ==================================================

          if (_mapPickingMode ==
              null)
            Positioned(
              top:
                  16,
              left:
                  16,
              right:
                  16,
              child:
                  Card(
                elevation:
                    4,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                    12,
                  ),
                ),
                child:
                    Padding(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal:
                        16,
                    vertical:
                        10,
                  ),
                  child:
                      Column(
                    children: [

                      // GPS STATUS
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [

                          Icon(
                            _locationReady
                                ? Icons.gps_fixed
                                : Icons.gps_not_fixed,
                            size:
                                17,
                            color:
                                _locationReady
                                    ? Colors.green
                                    : Colors.orange,
                          ),

                          const SizedBox(
                            width:
                                6,
                          ),

                          Text(
                            _gpsStatus,
                            style:
                                TextStyle(
                              fontSize:
                                  12,
                              color:
                                  _locationReady
                                      ? Colors.green
                                      : Colors.orange,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(
                        height:
                            8,
                      ),

                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceAround,
                        children: [

                          // JARAK
                          Column(
                            children: [

                              const Text(
                                'Jarak',
                                style:
                                    TextStyle(
                                  fontSize:
                                      11,
                                  color:
                                      Colors.grey,
                                ),
                              ),

                              Text(
                                _locationReady
                                    ? '${_distanceInKm.toStringAsFixed(1)} km'
                                    : '--',
                                style:
                                    const TextStyle(
                                  fontSize:
                                      16,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ],
                          ),

                          Container(
                            height:
                                30,
                            width:
                                1,
                            color:
                                Colors.grey.shade300,
                          ),

                          // ETA
                          Column(
                            children: [

                              const Text(
                                'Est. Waktu',
                                style:
                                    TextStyle(
                                  fontSize:
                                      11,
                                  color:
                                      Colors.grey,
                                ),
                              ),

                              Text(
                                _locationReady
                                    ? '$_estimatedMinutes mnt'
                                    : '--',
                                style:
                                    const TextStyle(
                                  fontSize:
                                      16,
                                  fontWeight:
                                      FontWeight.bold,
                                  color:
                                      Colors.blueAccent,
                                ),
                              ),
                            ],
                          ),

                          Container(
                            height:
                                30,
                            width:
                                1,
                            color:
                                Colors.grey.shade300,
                          ),

                          // STATUS TOURING
                          Column(
                            children: [

                              const Text(
                                'Status',
                                style:
                                    TextStyle(
                                  fontSize:
                                      11,
                                  color:
                                      Colors.grey,
                                ),
                              ),

                              Text(
                                _isTouring
                                    ? 'AKTIF'
                                    : 'SIAP',
                                style:
                                    TextStyle(
                                  fontSize:
                                      15,
                                  fontWeight:
                                      FontWeight.bold,
                                  color:
                                      _isTouring
                                          ? Colors.green
                                          : Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================================
          // TOMBOL MULAI / STOP TOURING
          // ==================================================

          Positioned(
            bottom:
                155,
            left:
                25,
            right:
                25,
            child:
                SizedBox(
              height:
                  52,
              child:
                  ElevatedButton.icon(
                onPressed:
                    _isTouring
                        ? _stopTouring
                        : _startTouring,
                icon:
                    Icon(
                  _isTouring
                      ? Icons.stop
                      : Icons.play_arrow,
                  size:
                      28,
                ),
                label:
                    Text(
                  _isTouring
                      ? 'STOP TOURING'
                      : 'MULAI TOURING',
                  style:
                      const TextStyle(
                    fontSize:
                        17,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      _isTouring
                          ? Colors.red
                          : Colors.green,
                  foregroundColor:
                      Colors.white,
                  elevation:
                      5,
                  shape:
                      RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(
                      14,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ==================================================
          // CENTER GPS
          // ==================================================

          Positioned(
            bottom:
                105,
            right:
                16,
            child:
                FloatingActionButton(
              mini:
                  true,
              backgroundColor:
                  Colors.white,
              onPressed:
                  _centerToMyLocation,
              child:
                  const Icon(
                Icons.my_location,
                color:
                    Colors.blueAccent,
              ),
            ),
          ),

          // ==================================================
          // PTT
          // ==================================================

          Positioned(
            bottom:
                25,
            left:
                MediaQuery.of(context)
                        .size
                        .width *
                    0.2,
            right:
                MediaQuery.of(context)
                        .size
                        .width *
                    0.2,
            child:
                Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [

                Container(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal:
                        12,
                    vertical:
                        4,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.black.withOpacity(
                      0.7,
                    ),
                    borderRadius:
                        BorderRadius.circular(
                      12,
                    ),
                  ),
                  child:
                      Text(
                    _pttStatusText,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                      fontSize:
                          12,
                    ),
                    textAlign:
                        TextAlign.center,
                  ),
                ),

                const SizedBox(
                  height:
                      8,
                ),

                GestureDetector(
                  onTapDown:
                      (_) =>
                          _startTransmission(),
                  onTapUp:
                      (_) =>
                          _stopTransmission(),
                  onTapCancel:
                      () =>
                          _stopTransmission(),
                  child:
                      AnimatedContainer(
                    duration:
                        const Duration(
                      milliseconds:
                          150,
                    ),
                    width:
                        _isTalking
                            ? 75
                            : 65,
                    height:
                        _isTalking
                            ? 75
                            : 65,
                    decoration:
                        BoxDecoration(
                      color:
                          _isTalking
                              ? Colors.redAccent
                              : Colors.red,
                      shape:
                          BoxShape.circle,
                      boxShadow: [

                        BoxShadow(
                          color:
                              _isTalking
                                  ? Colors.red.withOpacity(
                                      0.6,
                                    )
                                  : Colors.black26,
                          blurRadius:
                              _isTalking
                                  ? 15
                                  : 6,
                          spreadRadius:
                              _isTalking
                                  ? 4
                                  : 1,
                        ),
                      ],
                    ),
                    child:
                        Icon(
                      _isTalking
                          ? Icons.mic
                          : Icons.mic_none,
                      color:
                          Colors.white,
                      size:
                          _isTalking
                              ? 38
                              : 32,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ==================================================
          // WATERMARK
          // ==================================================

          Positioned(
            bottom:
                12,
            right:
                12,
            child:
                Container(
              padding:
                  const EdgeInsets.symmetric(
                horizontal:
                    8,
                vertical:
                    4,
              ),
              decoration:
                  BoxDecoration(
                color:
                    Colors.black.withOpacity(
                  0.6,
                ),
                borderRadius:
                    BorderRadius.circular(
                  6,
                ),
              ),
              child:
                  const Text(
                'created by Mr. Ted',
                style:
                    TextStyle(
                  color:
                      Colors.white,
                  fontSize:
                      11,
                  fontWeight:
                      FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // AGORA PTT
  // ==========================================================

  Future<void> _initAgoraPTT() async {
    await [
      Permission.microphone,
    ].request();

    try {
      _engine =
          createAgoraRtcEngine();

      await _engine!.initialize(
        const RtcEngineContext(
          appId:
              agoraAppId,
          channelProfile:
              ChannelProfileType
                  .channelProfileCommunication,
        ),
      );

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess:
              (
            RtcConnection connection,
            int elapsed,
          ) {
            if (!mounted) return;

            setState(() {
              _isEngineReady =
                  true;

              _pttStatusText =
                  'Tekan & Tahan untuk Bicara';
            });
          },
        ),
      );

      await _engine!.enableAudio();

      await _engine!
          .muteLocalAudioStream(
        true,
      );

      await _engine!.joinChannel(
        token: '',
        channelId:
            channelName,
        uid:
            0,
        options:
            const ChannelMediaOptions(),
      );
    } catch (e) {
      debugPrint(
        'Agora error: $e',
      );

      if (!mounted) return;

      setState(() {
        _pttStatusText =
            'Tekan & Tahan untuk Bicara';
      });
    }
  }

  // ==========================================================
  // START TRANSMISSION
  // ==========================================================

  Future<void>
      _startTransmission() async {
    if (_engine != null &&
        _isEngineReady) {
      await _engine!
          .muteLocalAudioStream(
        false,
      );
    }

    if (!mounted) return;

    setState(() {
      _isTalking =
          true;

      _pttStatusText =
          'Transmisi Suara Aktif...';
    });
  }

  // ==========================================================
  // STOP TRANSMISSION
  // ==========================================================

  Future<void>
      _stopTransmission() async {
    if (_engine != null &&
        _isEngineReady) {
      await _engine!
          .muteLocalAudioStream(
        true,
      );
    }

    if (!mounted) return;

    setState(() {
      _isTalking =
          false;

      _pttStatusText =
          'Tekan & Tahan untuk Bicara';
    });
  }
}
