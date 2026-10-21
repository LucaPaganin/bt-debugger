import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/devices_screen.dart';
import 'screens/diagnosis_screen.dart';
import 'screens/monitor_screen.dart';
import 'screens/discovery_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BtDebuggerApp());
}

class BtDebuggerApp extends StatelessWidget {
  const BtDebuggerApp({super.key, this.startNative = true});

  /// Disattivabile nei test, dove i canali nativi non esistono.
  final bool startNative;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1565C0);
    return MaterialApp(
      title: 'BT Debugger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(startNative: startNative),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.startNative = true});
  final bool startNative;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.startNative) AppState.instance.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al rientro ricarica dal file: il monitor può aver registrato eventi con l'app in background.
    if (state == AppLifecycleState.resumed && widget.startNative) AppState.instance.resume();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [DevicesScreen(), MonitorScreen(), DiagnosisScreen(), DiscoveryScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.devices), label: 'Dispositivi'),
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Monitor'),
          NavigationDestination(icon: Icon(Icons.medical_services_outlined), label: 'Diagnosi'),
          NavigationDestination(icon: Icon(Icons.radar), label: 'Discovery'),
        ],
      ),
    );
  }
}
