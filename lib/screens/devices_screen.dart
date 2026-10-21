import 'package:flutter/material.dart';

import '../app_state.dart';
import '../bt_api.dart';
import '../bt_labels.dart';
import 'device_detail_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Map<String, dynamic> _adapter = {};
  List<BtDevice> _devices = [];
  String? _error;
  bool _loading = true;

  bool _hadPermissions = false;

  @override
  void initState() {
    super.initState();
    _load();
    AppState.instance.addListener(_onAppChange);
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppChange);
    super.dispose();
  }

  void _onAppChange() {
    // Appena l'utente concede i permessi, ricarica la lista.
    final ok = AppState.instance.permissionsOk;
    if (ok && !_hadPermissions) _load();
    _hadPermissions = ok;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final a = await BtApi.adapterInfo();
      final d = await BtApi.bondedDevices();
      if (!mounted) return;
      setState(() {
        _adapter = a;
        _devices = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispositivi'),
        actions: [
          IconButton(icon: const Icon(Icons.settings_bluetooth), tooltip: 'Impostazioni Bluetooth', onPressed: () => BtApi.openSettings('bluetooth')),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (!app.permissionsOk) _permissionBanner(app),
              if (_error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))),
              _adapterCard(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Accoppiati (${_devices.length})', style: Theme.of(context).textTheme.titleSmall),
              ),
              if (_loading && _devices.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
              for (final d in _devices) _deviceTile(d, app),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permissionBanner(AppState app) => Card(
        margin: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.warning_amber),
          title: const Text('Permessi mancanti'),
          subtitle: Text(app.permissions.entries.where((e) => !e.value).map((e) => e.key).join(', ')),
          trailing: TextButton(
            onPressed: () async {
              await app.refreshPermissions();
              if (!app.permissionsOk) await BtApi.openSettings('app');
              _load();
            },
            child: const Text('Concedi'),
          ),
        ),
      );

  Widget _adapterCard() {
    final a = _adapter;
    String yn(dynamic v) => v == null ? '–' : (v == true ? 'sì' : 'no');
    final rows = <(String, String)>[
      ('Telefono', '${a['phone'] ?? '–'}'),
      ('Android', '${a['android'] ?? '–'}'),
      ('Nome BT', '${a['name'] ?? '–'}'),
      ('Stato', '${a['state'] ?? '–'}  ·  scan ${a['scanMode'] ?? '–'}'),
      ('Profili attivi', 'HFP ${a['hfpState'] ?? '–'}  ·  A2DP ${a['a2dpState'] ?? '–'}'),
      ('LE 2M / Coded PHY', '${yn(a['le2M'])} / ${yn(a['leCoded'])}  (indicano BT ≥ 5.0)'),
      ('LE Audio', yn(a['leAudio'])),
    ];
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(a['enabled'] == true ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
              const SizedBox(width: 8),
              Text('Questo telefono', style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 120, child: Text(r.$1, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
                  Expanded(child: Text(r.$2)),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(BtDevice d, AppState app) {
    final isTarget = app.targetAddress == d.address;
    final chips = <Widget>[
      if (d.hfp == 'CONNECTED') _chip('HFP', Colors.teal),
      if (d.a2dp == 'CONNECTED') _chip('A2DP', Colors.purple),
      if (d.connected == true && d.hfp != 'CONNECTED' && d.a2dp != 'CONNECTED') _chip('ACL', Colors.blue),
    ];
    return ListTile(
      leading: Icon(d.deviceClass == 0x0420 ? Icons.directions_car : Icons.bluetooth, color: isTarget ? Colors.amber.shade800 : null),
      title: Row(children: [
        Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis)),
        if (isTarget) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.star, size: 16, color: Colors.amber)),
      ]),
      subtitle: Text('${d.address}  ·  ${d.typeName}  ·  ${deviceClassName(d.deviceClass)}'),
      trailing: Wrap(spacing: 4, children: chips),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeviceDetailScreen(address: d.address)));
        _load();
      },
    );
  }

  Widget _chip(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
        child: Text(label, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}
