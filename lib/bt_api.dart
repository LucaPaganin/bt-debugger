import 'package:flutter/services.dart';

/// Evento registrato dal lato nativo (broadcast Bluetooth o azione dell'app).
class BtEvent {
  final int id;
  final DateTime ts;
  final String cat;
  final String action;
  final String summary;
  final String? address;
  final String? name;
  final Map<String, String> extras;
  final bool persist;

  BtEvent({
    required this.id,
    required this.ts,
    required this.cat,
    required this.action,
    required this.summary,
    this.address,
    this.name,
    this.extras = const {},
    this.persist = true,
  });

  factory BtEvent.fromMap(Map<dynamic, dynamic> m) {
    final ex = <String, String>{};
    final raw = m['extras'];
    if (raw is Map) {
      raw.forEach((k, v) => ex['$k'] = '$v');
    }
    return BtEvent(
      id: (m['id'] as num?)?.toInt() ?? 0,
      ts: DateTime.fromMillisecondsSinceEpoch((m['ts'] as num?)?.toInt() ?? 0),
      cat: m['cat'] as String? ?? 'other',
      action: m['action'] as String? ?? '',
      summary: m['summary'] as String? ?? '',
      address: m['address'] as String?,
      name: m['name'] as String?,
      extras: ex,
      persist: m['persist'] != false,
    );
  }

  String get who => name ?? address ?? '';
}

/// Dispositivo (accoppiato o trovato) con lo stato letto dallo stack Android.
class BtDevice {
  final Map<String, dynamic> raw;
  BtDevice(Map<dynamic, dynamic> m) : raw = m.map((k, v) => MapEntry('$k', v));

  String get address => raw['address'] as String? ?? '';
  String get name => (raw['alias'] as String?) ?? (raw['name'] as String?) ?? address;
  String? get realName => raw['name'] as String?;
  String get typeName => raw['typeName'] as String? ?? '?';
  String get bondState => raw['bondState'] as String? ?? '?';
  int? get cod => (raw['cod'] as num?)?.toInt();
  int? get major => (raw['major'] as num?)?.toInt();
  int? get deviceClass => (raw['deviceClass'] as num?)?.toInt();
  List<String> get uuids => ((raw['uuids'] as List?) ?? const []).map((e) => '$e').toList();
  bool? get connected => raw['connected'] as bool?;
  bool? get encrypted => raw['encrypted'] as bool?;
  int? get battery => (raw['battery'] as num?)?.toInt();
  String? get a2dp => raw['a2dp'] as String?;
  bool? get a2dpPlaying => raw['a2dpPlaying'] as bool?;
  String? get hfp => raw['hfp'] as String?;
  bool? get hfpAudio => raw['hfpAudio'] as bool?;
}

/// Wrapper dei canali verso il codice Kotlin.
class BtApi {
  static const _m = MethodChannel('bt_debugger/methods');
  static const _e = EventChannel('bt_debugger/events');

  static Stream<BtEvent> events() =>
      _e.receiveBroadcastStream().map((e) => BtEvent.fromMap(e as Map));

  static Future<Map<String, bool>> requestPermissions() async {
    final r = await _m.invokeMethod<Map>('requestPermissions');
    return (r ?? {}).map((k, v) => MapEntry('$k', v == true));
  }

  static Future<Map<String, bool>> checkPermissions() async {
    final r = await _m.invokeMethod<Map>('checkPermissions');
    return (r ?? {}).map((k, v) => MapEntry('$k', v == true));
  }

  static Future<Map<String, dynamic>> adapterInfo() async {
    final r = await _m.invokeMethod<Map>('getAdapterInfo');
    return (r ?? {}).map((k, v) => MapEntry('$k', v));
  }

  static Future<List<BtDevice>> bondedDevices() async {
    final r = await _m.invokeMethod<List>('getBondedDevices');
    return (r ?? []).map((e) => BtDevice(e as Map)).toList();
  }

  static Future<BtDevice?> device(String address) async {
    final r = await _m.invokeMethod<Map>('getDevice', {'address': address});
    return r == null ? null : BtDevice(r);
  }

  static Future<bool> fetchUuids(String address) async =>
      await _m.invokeMethod<bool>('fetchUuids', {'address': address}) ?? false;

  static Future<Map<String, dynamic>> rfcommTest(String address, String uuid, {bool secure = true}) async {
    final r = await _m.invokeMethod<Map>('rfcommTest', {'address': address, 'uuid': uuid, 'secure': secure});
    return (r ?? {}).map((k, v) => MapEntry('$k', v));
  }

  static Future<Map<String, dynamic>> probe(String address) async {
    final r = await _m.invokeMethod<Map>('probe', {'address': address});
    return (r ?? {}).map((k, v) => MapEntry('$k', v));
  }

  static Future<Map<String, dynamic>> gattTest(String address) async {
    final r = await _m.invokeMethod<Map>('gattTest', {'address': address});
    return (r ?? {}).map((k, v) => MapEntry('$k', v));
  }

  static Future<bool> startDiscovery() async => await _m.invokeMethod<bool>('startDiscovery') ?? false;
  static Future<bool> cancelDiscovery() async => await _m.invokeMethod<bool>('cancelDiscovery') ?? false;

  static Future<void> startMonitor() => _m.invokeMethod('startMonitor');
  static Future<void> stopMonitor() => _m.invokeMethod('stopMonitor');
  static Future<bool> isMonitorRunning() async => await _m.invokeMethod<bool>('isMonitorRunning') ?? false;

  static Future<List<BtEvent>> getEvents() async {
    final r = await _m.invokeMethod<List>('getEvents');
    return (r ?? []).map((e) => BtEvent.fromMap(e as Map)).toList();
  }

  static Future<void> clearEvents() => _m.invokeMethod('clearEvents');
  static Future<void> addNote(String text) => _m.invokeMethod('addNote', {'text': text});

  static Future<void> setTarget(String? address, String? name) =>
      _m.invokeMethod('setTarget', {'address': address, 'name': name});

  static Future<({String? address, String? name})> getTarget() async {
    final r = await _m.invokeMethod<Map>('getTarget') ?? {};
    return (address: r['address'] as String?, name: r['name'] as String?);
  }

  static Future<List<String>> systemProps() async {
    final r = await _m.invokeMethod<List>('getSystemProps');
    return (r ?? []).map((e) => '$e').toList();
  }

  static Future<bool> openSettings(String kind) async =>
      await _m.invokeMethod<bool>('openSettings', {'kind': kind}) ?? false;

  static Future<String> saveToDownloads(String fileName, String content) async =>
      await _m.invokeMethod<String>('saveToDownloads', {'fileName': fileName, 'content': content}) ?? '';

  static Future<void> shareText(String text, {String subject = 'BT Debugger log'}) =>
      _m.invokeMethod('shareText', {'text': text, 'subject': subject});
}
