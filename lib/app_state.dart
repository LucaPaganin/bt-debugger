import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bt_api.dart';
import 'discovery.dart';

/// Stato condiviso dell'app: log eventi, dispositivo monitorato, discovery.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final List<BtEvent> events = [];
  /// Discovery: dispositivi visti (per indirizzo) e dispositivi "miei" con nickname.
  final Map<String, DiscoveredDevice> discovered = {};
  List<KnownDevice> known = [];
  bool classicScanning = false;
  bool leScanning = false;
  String? scanError;
  Timer? _leTimer;

  /// Durata della scansione BLE: oltre consuma batteria e Android limita i riavvii.
  static const leScanDuration = Duration(seconds: 60);

  bool get scanning => classicScanning || leScanning;
  bool monitorRunning = false;
  AutoStatus auto = const AutoStatus();
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
    await refreshAuto();
    // Se la funzione è accesa ma Android ha fermato il servizio, lo riavvia.
    if (auto.enabled && !auto.serviceRunning) {
      try {
        auto = await BtApi.setAutoConnect(true);
      } catch (_) {}
    }
    try {
      known = decodeKnown(await BtApi.getKnownDevices());
    } catch (_) {}
    _sub ??= BtApi.events().listen(_onEvent);
    notifyListeners();
  }

  /// Al rientro in primo piano: eventi registrati in background, permessi cambiati nelle impostazioni.
  Future<void> resume() async {
    try {
      permissions = await BtApi.checkPermissions();
      monitorRunning = await BtApi.isMonitorRunning();
    } catch (_) {}
    await refreshAuto();
    await reloadEvents();
  }

  Future<void> refreshAuto() async {
    try {
      auto = await BtApi.getAutoConnect();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleAuto() async {
    auto = await BtApi.setAutoConnect(!auto.enabled);
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refreshAuto();
  }

  Future<void> autoConnectNow() async {
    await BtApi.autoConnectNow();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await refreshAuto();
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
      switch (e.action) {
        case 'DISCOVERY_STARTED':
          classicScanning = true;
        case 'DISCOVERY_FINISHED':
          classicScanning = false;
        case 'LE_SCAN_STARTED':
          leScanning = true;
        case 'LE_SCAN_STOPPED':
          leScanning = false;
        case 'LE_SCAN_FAILED':
          leScanning = false;
          scanError = e.summary;
        case 'FOUND' || 'LE_FOUND':
          final a = e.address;
          if (a != null) discovered.putIfAbsent(a, () => DiscoveredDevice(a, e.ts)).update(e);
      }
      notifyListeners();
      return;
    }
    if (!e.persist) return;
    if (events.isNotEmpty && events.last.id >= e.id) return;
    events.add(e);
    if (e.action == 'MONITOR_START') monitorRunning = true;
    if (e.action == 'MONITOR_STOP' || e.action == 'MONITOR_ERROR') monitorRunning = false;
    if (e.cat == 'auto') refreshAuto();
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

  /// Avvia la discovery: Classic (inquiry ~12 s) e/o BLE (advertising, [leScanDuration]).
  Future<void> startScan({bool classic = true, bool le = true}) async {
    discovered.clear();
    scanError = null;
    if (classic) classicScanning = await BtApi.startDiscovery();
    if (le) {
      leScanning = await BtApi.startLeScan();
      _leTimer?.cancel();
      if (leScanning) _leTimer = Timer(leScanDuration, () => BtApi.stopLeScan());
    }
    if (!scanning) scanError ??= 'Scansione non avviata: Bluetooth spento o permessi mancanti.';
    notifyListeners();
  }

  Future<void> stopScan() async {
    _leTimer?.cancel();
    await BtApi.cancelDiscovery();
    await BtApi.stopLeScan();
    classicScanning = false;
    leScanning = false;
    notifyListeners();
  }

  Future<void> _saveKnown() async {
    notifyListeners();
    await BtApi.saveKnownDevices(encodeKnown(known));
  }

  /// Assegna o cambia il nickname; [byName] riconosce il dispositivo dal nome invece che dal MAC.
  Future<void> setNickname(DiscoveredDevice d, String nickname, {bool byName = false}) async {
    final old = knownFor(d, known);
    known = [
      for (final k in known)
        if (!identical(k, old)) k,
      KnownDevice(
        nickname: nickname,
        address: byName ? null : d.address,
        matchName: byName ? d.name : null,
      ),
    ];
    await _saveKnown();
  }

  Future<void> removeKnown(KnownDevice k) async {
    known = [for (final x in known) if (!identical(x, k)) x];
    await _saveKnown();
  }
}
