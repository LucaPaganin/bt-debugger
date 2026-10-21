import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bt_api.dart';

/// Stato condiviso dell'app: log eventi, dispositivo monitorato, scansione.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final List<BtEvent> events = [];
  final Map<String, BtEvent> scanResults = {};
  bool scanning = false;
  bool monitorRunning = false;
  String? targetAddress;
  String? targetName;
  Map<String, bool> permissions = {};
  StreamSubscription<BtEvent>? _sub;

  bool get permissionsOk => permissions.isNotEmpty && permissions.values.every((v) => v);

  Future<void> start() async {
    try {
      permissions = await BtApi.requestPermissions();
    } catch (_) {}
    await reloadEvents();
    final t = await BtApi.getTarget();
    targetAddress = t.address;
    targetName = t.name;
    monitorRunning = await BtApi.isMonitorRunning();
    _sub ??= BtApi.events().listen(_onEvent);
    notifyListeners();
  }

  /// Al rientro in primo piano: eventi registrati in background, permessi cambiati nelle impostazioni.
  Future<void> resume() async {
    try {
      permissions = await BtApi.checkPermissions();
      monitorRunning = await BtApi.isMonitorRunning();
    } catch (_) {}
    await reloadEvents();
  }

  Future<void> refreshPermissions() async {
    permissions = await BtApi.requestPermissions();
    notifyListeners();
  }

  Future<void> reloadEvents() async {
    final list = await BtApi.getEvents();
    events
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void _onEvent(BtEvent e) {
    if (e.cat == 'scan') {
      if (e.action == 'DISCOVERY_STARTED') scanning = true;
      if (e.action == 'DISCOVERY_FINISHED') scanning = false;
      if (e.action == 'FOUND' && e.address != null) scanResults[e.address!] = e;
      notifyListeners();
      return;
    }
    if (!e.persist) return;
    if (events.isNotEmpty && events.last.id >= e.id) return;
    events.add(e);
    if (e.action == 'MONITOR_START') monitorRunning = true;
    if (e.action == 'MONITOR_STOP' || e.action == 'MONITOR_ERROR') monitorRunning = false;
    notifyListeners();
  }

  Future<void> setTarget(String? address, String? name) async {
    targetAddress = address;
    targetName = name;
    await BtApi.setTarget(address, name);
    notifyListeners();
  }

  Future<void> toggleMonitor() async {
    if (monitorRunning) {
      await BtApi.stopMonitor();
    } else {
      await BtApi.startMonitor();
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    monitorRunning = await BtApi.isMonitorRunning();
    notifyListeners();
  }

  Future<void> clearEvents() async {
    await BtApi.clearEvents();
    events.clear();
    notifyListeners();
  }

  Future<void> startScan() async {
    scanResults.clear();
    scanning = await BtApi.startDiscovery();
    notifyListeners();
  }

  Future<void> stopScan() async {
    await BtApi.cancelDiscovery();
    scanning = false;
    notifyListeners();
  }
}
