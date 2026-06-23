import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heaven_beverages/models/user_session.dart';
import 'package:heaven_beverages/pages/dashboard_page.dart';
import 'package:heaven_beverages/services/api_client.dart';
import 'package:heaven_beverages/services/auth_service.dart';
import 'package:heaven_beverages/services/session_manager.dart';
import 'package:heaven_beverages/services/session_storage.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _mobileController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  final _sessionManager = SessionManager();
  final _sessionStorage = SessionStorage();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _loadDeviceId();
  }

  Future<void> _loadDeviceId() async {
    final deviceId = await _sessionStorage.loadOrCreateDeviceId();
    if (mounted) setState(() => _deviceId = deviceId);
  }

  @override
  void dispose() {
    _mobileController.dispose();
    _passwordController.dispose();
    _authService.dispose();
    _sessionManager.dispose();
    super.dispose();
  }

  String get _deviceIdentifier {
    return _deviceId ?? 'flutter-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _openDashboard(UserSession session, LoginResult result) async {
    await _sessionManager.saveLoginCredentials(
      mobileNo: _mobileController.text.trim(),
      password: _passwordController.text,
      session: session,
      loginResponseRaw: result.raw,
    );
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => DashboardPage(session: session),
      ),
      (_) => false,
    );
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final result = await _authService.login(
        mobileNo: _mobileController.text.trim(),
        password: _passwordController.text,
        deviceId: _deviceIdentifier,
        lang: 'en',
      );

      if (!mounted) return;

      if (result.isSuccess) {
        try {
          final session = UserSession.fromLogin(
            result,
            mobileNo: _mobileController.text.trim(),
          );
          await _openDashboard(session, result);
        } on UserSessionException catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.message),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message ?? result.raw),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } catch (error) {
      if (!mounted) return;

      final message = _connectionErrorMessage(error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _connectionErrorMessage(Object error) {
    if (error is ApiTimeoutException) {
      return error.message;
    }
    if (error is ApiNetworkException) {
      return error.message;
    }
    final errorText = error.toString();
    if (errorText.contains('TimeoutException') || errorText.contains('timed out')) {
      return 'Server took too long to respond. Please try again.';
    }
    if (kIsWeb && errorText.contains('Failed to fetch')) {
      return 'Browser blocked the API (CORS). For web testing, run '
          '".\\scripts\\run_web.ps1" instead of "flutter run", or use '
          'Windows/Android.';
    }
    return 'Unable to connect. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.local_drink_rounded,
                      size: 72,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Heaven Beverages',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to your account',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 40),
                    TextFormField(
                      controller: _mobileController,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      decoration: const InputDecoration(
                        labelText: 'Mobile Number',
                        hintText: 'Enter your mobile number',
                        prefixIcon: Icon(Icons.phone_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your mobile number';
                        }
                        final mobileRegex = RegExp(r'^[0-9]{10,15}$');
                        if (!mobileRegex.hasMatch(value.trim())) {
                          return 'Please enter a valid mobile number';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _handleLogin(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        hintText: 'Enter your password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your password';
                        }

                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign In'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
