import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heaven_beverages/pages/splash_page.dart';
import 'package:heaven_beverages/services/background_tracking_service.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await BackgroundTrackingService.initialize();
    await BackgroundTrackingService.resumeIfPunchedIn();
  }
  runApp(const HeavenBeveragesApp());
}

class HeavenBeveragesApp extends StatelessWidget {
  const HeavenBeveragesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heaven Beverages',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const SplashPage(),
    );
  }
}
