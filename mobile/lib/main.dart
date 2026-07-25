import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'api/sync_service.dart';
import 'screens/login_screen.dart';
import 'screens/games_hub_screen.dart';

void main() {
  runApp(const GameHubApp());
}

class GameHubApp extends StatefulWidget {
  const GameHubApp({super.key});

  @override
  State<GameHubApp> createState() => _GameHubAppState();
}

class _GameHubAppState extends State<GameHubApp> {
  late final SyncService _syncService;

  @override
  void initState() {
    super.initState();
    _syncService = SyncService(ApiClient());
    _syncService.start();
  }

  @override
  void dispose() {
    _syncService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GameHub',
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ThemeMode.system,
      home: const _StartupGate(),
    );
  }
}

// Mirrors BRAND.md exactly - see that file before changing any of these
// hex values, and update it if you do. Explicit color schemes (rather
// than ColorScheme.fromSeed's auto-derived dark variant) are what keep
// the app's dark mode actually matching the web app's dark mode instead
// of just being "in the same family."

const _brandLight = Color(0xFF4F46E5);
const _brandDark = Color(0xFF818CF8);

/// Material 3's ColorScheme has no built-in "success" role - this adds
/// one so screens can reach `context.successColor` instead of hardcoding
/// Colors.green, keeping the exact brand hex from BRAND.md instead of
/// Flutter's default green.
class BrandColors extends ThemeExtension<BrandColors> {
  final Color success;

  const BrandColors({required this.success});

  @override
  BrandColors copyWith({Color? success}) => BrandColors(success: success ?? this.success);

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    return BrandColors(success: Color.lerp(success, other.success, t)!);
  }
}

extension BrandColorsContext on BuildContext {
  Color get successColor => Theme.of(this).extension<BrandColors>()!.success;
}

final ThemeData _lightTheme = _buildTheme(
  brightness: Brightness.light,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _brandLight,
    brightness: Brightness.light,
    primary: _brandLight,
    surface: const Color(0xFFFFFFFF),
    onSurface: const Color(0xFF0F172A),
    error: const Color(0xFFDC2626),
  ),
  scaffoldBackground: const Color(0xFFF1F5F9),
  panelBorder: const Color(0xFFE2E8F0),
  success: const Color(0xFF16A34A),
);

final ThemeData _darkTheme = _buildTheme(
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _brandDark,
    brightness: Brightness.dark,
    primary: _brandDark,
    surface: const Color(0xFF1A2436),
    onSurface: const Color(0xFFF1F5F9),
    error: const Color(0xFFF87171),
  ),
  scaffoldBackground: const Color(0xFF0B1220),
  panelBorder: const Color(0xFF2D3B52),
  success: const Color(0xFF4ADE80),
);

ThemeData _buildTheme({
  required Brightness brightness,
  required ColorScheme colorScheme,
  required Color scaffoldBackground,
  required Color panelBorder,
  required Color success,
}) {
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBackground,
    extensions: [BrandColors(success: success)],
    cardTheme: CardThemeData(
      color: colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: panelBorder),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colorScheme.onSurface,
        side: BorderSide(color: panelBorder),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: panelBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: panelBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
    ),
  );
}

/// Decides the first screen: if a session is cached locally (from a
/// previous login), go straight to the hub - even offline, since there's
/// no way to re-verify a session cookie without a network round trip, and
/// the whole point of offline mode is not blocking on connectivity.
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool? _hasSession;

  @override
  void initState() {
    super.initState();
    ApiClient().hasLocalSession().then((has) {
      if (mounted) setState(() => _hasSession = has);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasSession == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _hasSession! ? const GamesHubScreen() : const LoginScreen();
  }
}
