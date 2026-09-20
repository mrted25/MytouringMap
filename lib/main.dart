import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

const String agoraAppId = "398d30b96cae43aeac064c7a0fa9add8";
const String channelName = "touring_room_1";

void main() {
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
  // MODE PILIH TITIK DI PETA
  // ==========================================================

  // null       = mode normal
  // 'kumpul'   = sedang memilih titik kumpul
  // 'destinasi'= sedang memilih destinasi
  String? _mapPickingMode;

  // ==========================================================
  // GPS
  // ==========================================================

  LatLng? _currentPosition;
  StreamSubscription<Position>? _positionStream;

  double _distanceInKm = 0.0;
  int _estimatedMinutes = 0;

  // ==========================================================
  // MODE KENDARAAN SAYA
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
  // DAFTAR ANGGOTA
  // ==========================================================

  final List<Member> _groupMembers = [
    Member(
      id: '1',
      name: 'Budi (Road Captain)',
      location: const LatLng(-6.195000, 106.832000),
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

    _checkLocationPermission();

    if (!kIsWeb) {
      _initAgoraPTT();
    } else {
      _pttStatusText =
          'Tekan & Tahan untuk Bicara';
    }
  }

  // ==========================================================
  // AGORA
  // ==========================================================

  Future<void> _initAgoraPTT() async {
    await [Permission.microphone].request();

    try {
      _engine = createAgoraRtcEngine();

      await _engine!.initialize(
        const RtcEngineContext(
          appId: agoraAppId,
          channelProfile:
              ChannelProfileType.channelProfileCommunication,
        ),
      );

      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess:
              (RtcConnection connection, int elapsed) {
            setState(() {
              _isEngineReady = true;
              _pttStatusText =
                  'Tekan & Tahan untuk Bicara';
            });
          },
        ),
      );

      await _engine!.enableAudio();

      await _engine!.muteLocalAudioStream(true);

      await _engine!.joinChannel(
        token: '',
        channelId: channelName,
        uid: 0,
        options: const ChannelMediaOptions(),
      );
    } catch (e) {
      setState(() {
        _pttStatusText =
            'Tekan & Tahan untuk Bicara';
      });
    }
  }

  Future<void> _startTransmission() async {
    if (_engine != null && _isEngineReady) {
      await _engine!.muteLocalAudioStream(false);
    }

    setState(() {
      _isTalking = true;
      _pttStatusText =
          'Transmisi Suara Aktif...';
    });
  }

  Future<void> _stopTransmission() async {
    if (_engine != null && _isEngineReady) {
      await _engine!.muteLocalAudioStream(true);
    }

    setState(() {
      _isTalking = false;
      _pttStatusText =
          'Tekan & Tahan untuk Bicara';
    });
  }

  // ==========================================================
  // GPS
  // ==========================================================

  Future<void> _checkLocationPermission() async {
    bool serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      debugPrint('GPS SERVICE MATI');
      return;
    }

    LocationPermission permission =
        await Geolocator.checkPermission();

    debugPrint(
      'Location permission: $permission',
    );

    if (permission ==
        LocationPermission.denied) {
      permission =
          await Geolocator.requestPermission();

      debugPrint(
        'Permission setelah request: $permission',
      );

      if (permission ==
          LocationPermission.denied) {
        debugPrint(
          'LOCATION PERMISSION DENIED',
        );
        return;
      }
    }

    if (permission ==
        LocationPermission.deniedForever) {
      debugPrint(
        'LOCATION PERMISSION DENIED FOREVER',
      );
      return;
    }

    await _getCurrentLocation();

    _startLocationUpdates();
  }

  Future<void> _getCurrentLocation() async {
    try {
      debugPrint('Mencari posisi GPS...');

      Position position =
          await Geolocator.getCurrentPosition(
        desiredAccuracy:
            LocationAccuracy.high,
      );

      debugPrint(
        'GPS berhasil: ${position.latitude}, ${position.longitude}',
      );

      if (mounted) {
        setState(() {
          _currentPosition = LatLng(
            position.latitude,
            position.longitude,
          );

          _calculateDistanceAndEta();
        });

        _mapController.move(
          _currentPosition!,
          15.0,
        );
      }
    } catch (e) {
      debugPrint('ERROR GPS: $e');
    }
  }

  void _startLocationUpdates() {
    const LocationSettings locationSettings =
        LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _positionStream =
        Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          _currentPosition =
              LatLng(
            position.latitude,
            position.longitude,
          );

          _calculateDistanceAndEta();
        });
      }
    });
  }

  // ==========================================================
  // HITUNG JARAK & ETA
  // ==========================================================

  void _calculateDistanceAndEta() {
    if (_currentPosition == null) {
      return;
    }

    double distanceInMeters =
        Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _destinasi.latitude,
      _destinasi.longitude,
    );

    _distanceInKm =
        distanceInMeters / 1000;

    double speedKmPerHour =
        _isMotorMode ? 45.0 : 35.0;

    _estimatedMinutes =
        ((_distanceInKm / speedKmPerHour) * 60)
            .round();
  }

  // ==========================================================
  // CENTER GPS
  // ==========================================================

  void _centerToMyLocation() {
    if (_currentPosition != null) {
      _mapController.move(
        _currentPosition!,
        15.0,
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
  // PILIH TITIK KUMPUL / DESTINASI
  // ==========================================================

  void _startPickLocation(String mode) {
    Navigator.pop(context);

    setState(() {
      _mapPickingMode = mode;
    });
  }

  void _handleMapTap(
    TapPosition tapPosition,
    LatLng point,
  ) {
    if (_mapPickingMode == null) {
      return;
    }

    if (_mapPickingMode == 'kumpul') {
      setState(() {
        _titikKumpul = point;
        _mapPickingMode = null;
      });

      _mapController.move(point, 14.0);

      _showMessage(
        'Titik kumpul berhasil dipilih',
      );
    } else if (_mapPickingMode ==
        'destinasi') {
      setState(() {
        _destinasi = point;
        _mapPickingMode = null;

        _calculateDistanceAndEta();
      });

      _mapController.move(point, 14.0);

      _showMessage(
        'Destinasi berhasil dipilih',
      );
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(message),
        duration:
            const Duration(seconds: 2),
      ),
    );
  }

  // ==========================================================
  // DIALOG ATUR RUTE
  // ==========================================================

  void _showSetRouteDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Atur Rute Touring',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // TITIK KUMPUL
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.location_on,
                    color: Colors.red,
                  ),
                  title: const Text(
                    'Titik Kumpul',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${_titikKumpul.latitude.toStringAsFixed(5)}, '
                    '${_titikKumpul.longitude.toStringAsFixed(5)}',
                  ),
                  trailing: const Icon(
                    Icons.map,
                  ),
                  onTap: () {
                    _startPickLocation(
                      'kumpul',
                    );
                  },
                ),
              ),

              const SizedBox(height: 10),

              // DESTINASI
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.flag,
                    color: Colors.green,
                  ),
                  title: const Text(
                    'Destinasi',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${_destinasi.latitude.toStringAsFixed(5)}, '
                    '${_destinasi.longitude.toStringAsFixed(5)}',
                  ),
                  trailing: const Icon(
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
                  Navigator.pop(context),
              child: const Text('Tutup'),
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
    TextEditingController
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
              title: const Text(
                'Tambah Anggota Rombongan',
              ),
              content:
                  SingleChildScrollView(
                child: Column(
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
                            Icon(Icons.person),
                      ),
                    ),

                    const SizedBox(
                      height: 18,
                    ),

                    DropdownButtonFormField<
                        String>(
                      initialValue:
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
                          value: 'Motor',
                          child: Row(
                            children: [
                              Icon(
                                Icons.two_wheeler,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Motor'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Scooter',
                          child: Row(
                            children: [
                              Icon(
                                Icons
                                    .electric_scooter,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Scooter'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Mobil',
                          child: Row(
                            children: [
                              Icon(
                                Icons
                                    .directions_car,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Mobil'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'SUV',
                          child: Row(
                            children: [
                              Icon(
                                Icons
                                    .directions_car_filled,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('SUV'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Truck',
                          child: Row(
                            children: [
                              Icon(
                                Icons
                                    .local_shipping,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Truck'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Van',
                          child: Row(
                            children: [
                              Icon(
                                Icons
                                    .airport_shuttle,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Van'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Taxi',
                          child: Row(
                            children: [
                              Icon(
                                Icons.local_taxi,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Taxi'),
                            ],
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'Sepeda',
                          child: Row(
                            children: [
                              Icon(
                                Icons.pedal_bike,
                              ),
                              SizedBox(
                                width: 10,
                              ),
                              Text('Sepeda'),
                            ],
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
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
                      Navigator.pop(context),
                  child:
                      const Text('Batal'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(
                    Icons.person_add,
                  ),
                  label:
                      const Text('Simpan'),
                  onPressed: () {
                    if (nameController
                        .text
                        .trim()
                        .isNotEmpty) {
                      setState(() {
                        _groupMembers.add(
                          Member(
                            id: DateTime.now()
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
                            status: 'Riding',
                            color:
                                Colors.green,
                            vehicleType:
                                selectedVehicle,
                          ),
                        );
                      });

                      Navigator.pop(
                          context);
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
      context: context,
      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(20),
        ),
      ),
      builder: (context) {
        return Padding(
          padding:
              const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceBetween,
                children: [
                  Text(
                    'Daftar Anggota (${_groupMembers.length + 1})',
                    style:
                        const TextStyle(
                      fontSize: 18,
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
                    onPressed: () {
                      Navigator.pop(
                          context);
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
                  child: Icon(
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
                subtitle: Text(
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
                      child: Icon(
                        _getVehicleIcon(
                          member.vehicleType,
                        ),
                        color:
                            Colors.white,
                      ),
                    ),
                    title:
                        Text(member.name),
                    subtitle: Text(
                      '${member.vehicleType} • ${member.status}',
                    ),
                    trailing:
                        const Icon(
                      Icons.check_circle,
                      color:
                          Colors.green,
                      size: 20,
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Touring Map'),
        backgroundColor:
            Colors.blueAccent,
        foregroundColor:
            Colors.white,

        actions: [
          // ATUR RUTE
          IconButton(
            icon: const Icon(
              Icons.add_location_alt,
            ),
            tooltip:
                'Atur Rute',
            onPressed:
                _showSetRouteDialog,
          ),

          // TAMBAH ANGGOTA
          IconButton(
            icon: const Icon(
              Icons.person_add,
            ),
            tooltip:
                'Tambah Anggota',
            onPressed:
                _showAddMemberDialog,
          ),

          // DAFTAR ANGGOTA
          IconButton(
            icon: Badge(
              label: Text(
                '${_groupMembers.length + 1}',
              ),
              child: const Icon(
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
            icon: Icon(
              _isMotorMode
                  ? Icons.two_wheeler
                  : Icons.directions_car,
            ),
            tooltip:
                _isMotorMode
                    ? 'Mode Motor'
                    : 'Mode Mobil',
            onPressed: () {
              setState(() {
                _isMotorMode =
                    !_isMotorMode;

                _calculateDistanceAndEta();
              });
            },
          ),

          // LAYER PETA
          PopupMenuButton<String>(
            icon:
                const Icon(Icons.layers),
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
              return _tileProviders.keys
                  .map(
                (String key) {
                  return PopupMenuItem<
                      String>(
                    value: key,
                    child: Row(
                      children: [
                        Icon(
                          key ==
                                  'Dark Mode'
                              ? Icons
                                  .dark_mode
                              : (key ==
                                      'Standard'
                                  ? Icons.map
                                  : Icons
                                      .public),
                          color:
                              Colors.blueAccent,
                          size: 20,
                        ),
                        const SizedBox(
                          width: 10,
                        ),
                        Text(key),
                      ],
                    ),
                  );
                },
              ).toList();
            },
          ),
        ],
      ),

      body: Stack(
        children: [

          // ==================================================
          // PETA
          // ==================================================

          FlutterMap(
            mapController:
                _mapController,

            options: MapOptions(
              initialCenter:
                  _titikKumpul,
              initialZoom: 13.0,

              // TAP PETA
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

              // GARIS RUTE
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [
                      _currentPosition ??
                          _titikKumpul,
                      _destinasi,
                    ],
                    strokeWidth: 4.0,
                    color:
                        _isMotorMode
                            ? Colors
                                .blueAccent
                            : Colors
                                .orangeAccent,
                  ),
                ],
              ),

              // MARKER
              MarkerLayer(
                markers: [

                  // TITIK KUMPUL
                  Marker(
                    point:
                        _titikKumpul,
                    width: 80,
                    height: 80,
                    child:
                        const Icon(
                      Icons.location_on,
                      color:
                          Colors.red,
                      size: 40,
                    ),
                  ),

                  // DESTINASI
                  Marker(
                    point:
                        _destinasi,
                    width: 80,
                    height: 80,
                    child:
                        const Icon(
                      Icons.flag,
                      color:
                          Colors.green,
                      size: 38,
                    ),
                  ),

                  // POSISI SAYA
                  if (_currentPosition !=
                      null)
                    Marker(
                      point:
                          _currentPosition!,
                      width: 50,
                      height: 50,
                      child: Icon(
                        _isMotorMode
                            ? Icons
                                .two_wheeler
                            : Icons
                                .directions_car,
                        color:
                            Colors.blueAccent,
                        size: 35,
                      ),
                    ),

                  // ANGGOTA
                  ..._groupMembers.map(
                    (member) {
                      return Marker(
                        point:
                            member.location,
                        width: 80,
                        height: 65,
                        child: Column(
                          children: [

                            // NAMA
                            Container(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
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
                                    BorderRadius
                                        .circular(
                                            4),
                                boxShadow: const [
                                  BoxShadow(
                                    blurRadius:
                                        2,
                                    color: Colors
                                        .black26,
                                  ),
                                ],
                              ),
                              child: Text(
                                member.name
                                    .split(
                                        ' ')
                                    .first,
                                style:
                                    const TextStyle(
                                  fontSize:
                                      10,
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ),

                            // ICON KENDARAAN
                            Icon(
                              _getVehicleIcon(
                                member
                                    .vehicleType,
                              ),
                              color:
                                  member.color,
                              size: 30,
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
          // INSTRUKSI PILIH TITIK
          // ==================================================

          if (_mapPickingMode != null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                color:
                    Colors.blueAccent,
                elevation: 6,
                child: Padding(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
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
                        child: Text(
                          _mapPickingMode ==
                                  'kumpul'
                              ? 'Tap peta untuk memilih TITIK KUMPUL'
                              : 'Tap peta untuk memilih DESTINASI',
                          style:
                              const TextStyle(
                            color:
                                Colors.white,
                            fontWeight:
                                FontWeight
                                    .bold,
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
                        onPressed: () {
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
          // INFO JARAK & ETA
          // ==================================================

          if (_mapPickingMode == null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                elevation: 4,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius
                          .circular(12),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .spaceAround,
                    children: [

                      Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          Text(
                            _isMotorMode
                                ? 'Rute Motor'
                                : 'Rute Mobil',
                            style:
                                const TextStyle(
                              fontSize: 12,
                              color:
                                  Colors.grey,
                              fontWeight:
                                  FontWeight
                                      .bold,
                            ),
                          ),
                          const SizedBox(
                            height: 4,
                          ),
                          Text(
                            _currentPosition !=
                                    null
                                ? '${_distanceInKm.toStringAsFixed(1)} km'
                                : 'Mencari GPS...',
                            style:
                                const TextStyle(
                              fontSize: 16,
                              fontWeight:
                                  FontWeight
                                      .bold,
                            ),
                          ),
                        ],
                      ),

                      Container(
                        height: 30,
                        width: 1,
                        color: Colors
                            .grey.shade300,
                      ),

                      Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          const Text(
                            'Est. Waktu',
                            style:
                                TextStyle(
                              fontSize: 12,
                              color:
                                  Colors.grey,
                            ),
                          ),
                          const SizedBox(
                            height: 4,
                          ),
                          Text(
                            _currentPosition !=
                                    null
                                ? '$_estimatedMinutes mnt'
                                : '--',
                            style:
                                const TextStyle(
                              fontSize: 16,
                              fontWeight:
                                  FontWeight
                                      .bold,
                              color:
                                  Colors.blueAccent,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ==================================================
          // CENTER GPS
          // ==================================================

          Positioned(
            bottom: 110,
            right: 16,
            child:
                FloatingActionButton(
              mini: true,
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
            bottom: 25,
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
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [

                Container(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration:
                      BoxDecoration(
                    color: Colors.black
                        .withOpacity(
                            0.7),
                    borderRadius:
                        BorderRadius
                            .circular(
                                12),
                  ),
                  child: Text(
                    _pttStatusText,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                      fontSize: 12,
                    ),
                    textAlign:
                        TextAlign.center,
                  ),
                ),

                const SizedBox(
                  height: 8,
                ),

                GestureDetector(
                  onTapDown: (_) =>
                      _startTransmission(),

                  onTapUp: (_) =>
                      _stopTransmission(),

                  onTapCancel: () =>
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
                              ? Colors
                                  .redAccent
                              : Colors.red,
                      shape:
                          BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _isTalking
                              ? Colors
                                  .red
                                  .withOpacity(
                                      0.6)
                              : Colors
                                  .black26,
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
                    child: Icon(
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
            bottom: 12,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration:
                  BoxDecoration(
                color: Colors.black
                    .withOpacity(0.6),
                borderRadius:
                    BorderRadius
                        .circular(6),
              ),
              child:
                  const Text(
                'created by Mr. Ted',
                style:
                    TextStyle(
                  color:
                      Colors.white,
                  fontSize: 11,
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
}
