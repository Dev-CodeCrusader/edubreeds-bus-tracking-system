import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'branding.dart';
import 'config.dart';
import 'screens/login_screen.dart';
import 'screens/role_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In release builds a crashed screen is normally blank. Show the error text instead,
  // so problems can be diagnosed from a screenshot.
  ErrorWidget.builder = (details) => Material(
        color: Colors.white,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Screen error (please send a screenshot):\n\n${details.exceptionAsString()}\n\n${details.stack.toString().split('\n').take(8).join('\n')}',
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ),
      );
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const DriverApp());
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: brandColor,
      builder: (context, color, _) => MaterialApp(
        title: 'EDUBREEDS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: color),
          useMaterial3: true,
        ),
        home: StreamBuilder<AuthState>(
          stream: Supabase.instance.client.auth.onAuthStateChange,
          builder: (context, _) {
            final signedIn = Supabase.instance.client.auth.currentSession != null;
            if (!signedIn && brandColor.value != defaultBrandColor) {
              WidgetsBinding.instance.addPostFrameCallback((_) => brandColor.value = defaultBrandColor);
            }
            return signedIn ? const RoleGate() : const LoginScreen();
          },
        ),
      ),
    );
  }
}
