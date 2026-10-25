import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart' as rx;
import 'package:provider/provider.dart';

import 'package:pdf_fit/core/ads/ad_service.dart';
import 'package:pdf_fit/core/entitlements/billing_service.dart';
import 'package:pdf_fit/core/entitlements/entitlement_service.dart';
import 'package:pdf_fit/core/files/file_service.dart';
import 'package:pdf_fit/core/state/app_state.dart';
import 'package:pdf_fit/ui/screens/home_screen.dart';
import 'package:pdf_fit/ui/screens/history_screen.dart';
import 'package:pdf_fit/ui/screens/presets_screen.dart';
import 'package:pdf_fit/ui/screens/settings_screen.dart';
import 'package:pdf_fit/ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // PDFium must be initialised before any document is opened. pdfrx handles the
  // platform-specific loading (native asset on Android) and process-wide gate.
  await rx.pdfrxInitialize();

  final entitlements = EntitlementService();
  final billing = BillingService(entitlements);
  final ads = AdService(entitlements);
  final appState = AppState(entitlements: entitlements, billing: billing, ads: ads);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: entitlements),
        ChangeNotifierProvider.value(value: appState),
        Provider.value(value: billing),
        Provider.value(value: ads),
        Provider.value(value: FileService.instance),
      ],
      child: const PdfFitApp(),
    ),
  );

  // Load persisted state after the first frame so the UI can paint immediately;
  // screens show a lightweight placeholder until this completes.
  await appState.initialize();

  // Clear the preview cache from previous sessions.
  await FileService.instance.clearPreviews();
}

class PdfFitApp extends StatelessWidget {
  const PdfFitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Fit',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}

/// Bottom-navigation shell. All four destinations are fully implemented.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _screens = [
    HomeScreen(),
    HistoryScreen(),
    PresetsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _index != 0) setState(() => _index = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _index, children: _screens),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            HapticFeedback.selectionClick();
            setState(() => _index = i);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'History',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Presets',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
