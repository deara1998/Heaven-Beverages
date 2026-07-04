import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heaven_beverages/pages/splash_page.dart';
import 'package:heaven_beverages/theme/app_theme.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[FlutterError] ${details.exceptionAsString()}');
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('[PlatformError] $error');
        debugPrint('$stack');
        return true;
      };

      runApp(const HeavenBeveragesApp());
    },
    (error, stack) {
      debugPrint('[Uncaught] $error');
      debugPrint('$stack');
    },
  );
}

class HeavenBeveragesApp extends StatelessWidget {
  const HeavenBeveragesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heaven Beverages',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const SplashPage(),
    );
  }
}
