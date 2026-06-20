import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heaven_beverages/pages/dashboard_page.dart';
import 'package:heaven_beverages/pages/login_page.dart';
import 'package:heaven_beverages/services/background_tracking_service.dart';
import 'package:heaven_beverages/services/session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await BackgroundTrackingService.initialize();
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
      home: const AppStartPage(),
    );
  }
}

class AppStartPage extends StatefulWidget {
  const AppStartPage({super.key});

  @override
  State<AppStartPage> createState() => _AppStartPageState();
}

class _AppStartPageState extends State<AppStartPage> {
  final _sessionStorage = SessionStorage();

  @override
  void initState() {
    super.initState();
    _resolveStartDestination();
  }

  Future<void> _resolveStartDestination() async {
    final session = await _sessionStorage.loadUserSession();
    if (!mounted) return;

    if (session != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DashboardPage(session: session),
        ),
      );
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
