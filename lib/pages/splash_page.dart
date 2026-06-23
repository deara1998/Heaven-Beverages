import 'package:flutter/material.dart';
import 'package:heaven_beverages/pages/dashboard_page.dart';
import 'package:heaven_beverages/pages/login_page.dart';
import 'package:heaven_beverages/services/session_manager.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  final _sessionManager = SessionManager();
  String _statusText = 'Loading...';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _sessionManager.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (mounted) {
      setState(() => _statusText = 'Refreshing session...');
    }

    final minimumSplash = Future.delayed(const Duration(milliseconds: 1800));
    final loginFuture = _sessionManager.refreshSessionSilently();

    final result = await loginFuture;
    await minimumSplash;

    if (!mounted) return;

    switch (result.status) {
      case SilentLoginStatus.success:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardPage(session: result.session!),
          ),
        );
      case SilentLoginStatus.noCredentials:
      case SilentLoginStatus.failed:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF1B5E20);
    const primaryLight = Color(0xFF2E7D32);

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [primary, primaryLight, Color(0xFF43A047)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.local_drink_rounded,
                  size: 72,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Heaven Beverages',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Field Attendance & Tracking',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
              ),
              const Spacer(),
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _statusText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}
