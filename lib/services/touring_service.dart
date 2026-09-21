import 'package:cloud_firestore/cloud_firestore.dart';

class TouringService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String generateTouringCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    final now = DateTime.now().millisecondsSinceEpoch;

    String code = '';

    for (int i = 0; i < 6; i++) {
      code += chars[(now + i * 17) % chars.length];
    }

    return code;
  }

  Future<String> createTouring({
    required String name,
    required String captainId,
    required String captainName,
    required double startLat,
    required double startLng,
    required double destinationLat,
    required double destinationLng,
  }) async {
    final code = generateTouringCode();

    final touringRef = _firestore.collection('tourings').doc();

    await touringRef.set({
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

    return code;
  }
}
