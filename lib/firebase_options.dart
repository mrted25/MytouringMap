import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'ISI_DENGAN_current_key_DARI_google-services.json',
      appId: 'ISI_DENGAN_mobilesdk_app_id_DARI_google-services.json',
      messagingSenderId: '1040431925286',
      projectId: 'touring-map-app-f31f8',
      storageBucket: 'touring-map-app-f31f8.firebasestorage.app',
    );
  }
}
