
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

class TouringService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Random _random = Random.secure();

  static const String _chars =
      'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  String generateTouringCode() {
    return List.generate(
      6,
      (_) => _chars[_random.nextInt(_chars.length)],
    ).join();
  }

  Future<Map<String, String>> createTouring({
    required String name,
    required String captainId,
    required String captainName,
    required double startLat,
    required double startLng,
    required double destinationLat,
    required double destinationLng,
  }) async {
    final tourings = _firestore.collection('tourings');

    // Coba beberapa kali jika kode sudah digunakan.
    for (int attempt = 0; attempt < 10; attempt++) {
      final code = generateTouringCode();

      final result = await _firestore.runTransaction<
          Map<String, String>>((transaction) async {
        final existing = await tourings
            .where('code', isEqualTo: code)
            .limit(1)
            .get();

        if (existing.docs.isNotEmpty) {
          return <String, String>{};
        }

        final touringRef = tourings.doc();

        transaction.set(touringRef, {
          'name': name,
          'code': code,
          'captainId': captainId,
          'captainName': captainName,
          'startLat': startLat,
          'startLng': startLng,
          'destinationLat': destinationLat,
          'destinationLng': destinationLng,
          'status': 'waiting',
          'createdAt': FieldValue.serverTimestamp(),
        });

        return {
          'touringId': touringRef.id,
          'code': code,
        };
      });

      if (result.isNotEmpty) {
        return result;
      }
    }

    throw Exception(
      'Gagal membuat kode touring unik. Silakan coba lagi.',
    );
  }

  Future<void> updateTouringRoute({
    required String touringId,
    required List<GeoPoint> routePoints,
    required double startLat,
    required double startLng,
    required double destinationLat,
    required double destinationLng,
    required double distanceKm,
    required double durationMinutes,
  }) async {
    await _firestore
        .collection('tourings')
        .doc(touringId)
        .update({
      'startLat': startLat,
      'startLng': startLng,
      'destinationLat': destinationLat,
      'destinationLng': destinationLng,
      'routePoints': routePoints,
      'routeDistanceKm': distanceKm,
      'routeDurationMinutes': durationMinutes,
      'routeUpdatedAt': FieldValue.serverTimestamp(),
    });
  }
}
