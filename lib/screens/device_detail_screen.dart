import 'package:flutter/material.dart';

import '../app_state.dart';
import '../bt_api.dart';
import '../bt_labels.dart';
import '../widgets/event_tile.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String address;
  const DeviceDetailScreen({super.key, required this.address});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  BtDevice? _d;
  String? _busy;
  (String, Map<String, dynamic>)? _result;
  bool _secure = true;
  String? _rfUuid;

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

  int _lastSeen = 0;
  void _onAppChange() {
    // Ricarica lo stato quando arriva un evento che riguarda questo dispositivo.
    final ev = AppState.instance.events;
    if (ev.isNotEmpty && ev.last.id != _lastSeen) {
      _lastSeen = ev.last.id;
      if (ev.last.address == widget.address) _load();
    }
  }

  Future<void> _load() async {
    final d = await BtApi.device(widget.address);
    if (!mounted) return;
    setState(() {
      _d = d;
    });
  }

  /// Preferisce un servizio RFCOMM dichiarato; null se il dispositivo non ne dichiara.
  String? _defaultRfUuid(List<String> uuids) {
    for (final s in [0x111E, 0x1108, 0x1101, 0x112F, 0x1132]) {
      if (hasService(uuids, s)) return uuids.firstWhere((u) => shortUuid(u) == s);
    }
    return uuids.isNotEmpty ? uuids.first : null;
  }


  @override
  Widget build(BuildContext context) {
    final d = _d;
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.name ?? widget.address),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: app,
              builder: (context, _) {
                final isTarget = app.targetAddress == d.address;
                final myEvents = app.events.where((e) => e.address == d.address).toList().reversed.take(60).toList();
                return ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    _section('Identità', [
                      _kv('Nome', d.realName ?? '–'),
                      _kv('Indirizzo', d.address),
                      _kv('Tipo', d.typeName),
                      _kv('Bond', d.bondState),
                      _kv('Class of Device', '${codHex(d.cod)} · ${majorName(d.major)} / ${deviceClassName(d.deviceClass)}'),
                      _kv('Servizi CoD', codServiceClasses(d.cod).join(', ').ifEmpty('–')),
                    ]),
                    _section('Stato attuale', [
                      _kv('Link ACL', d.connected == null ? 'non leggibile' : (d.connected! ? 'connesso' : 'non connesso')),
                      _kv('Cifratura', d.encrypted == null ? 'non leggibile' : (d.encrypted! ? 'attiva' : 'no')),
                      _kv('HFP (vivavoce)', '${d.hfp ?? '–'}${d.hfpAudio == true ? ' · audio SCO attivo' : ''}'),
                      _kv('A2DP (audio)', '${d.a2dp ?? '–'}${d.a2dpPlaying == true ? ' · in riproduzione' : ''}'),
                      if (d.battery != null && d.battery! >= 0) _kv('Batteria', '${d.battery}%'),
                    ]),
                    _servicesSection(d),
                    _actions(d, isTarget),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('Eventi di questo dispositivo (${myEvents.length})', style: Theme.of(context).textTheme.titleSmall),
                    ),
                    if (myEvents.isEmpty)
                      const Padding(padding: EdgeInsets.all(16), child: Text('Nessun evento registrato ancora.')),
                    for (final e in myEvents) EventTile(event: e, showDate: true),
                  ],
                );
              },
            ),
    );
  }

  Widget _servicesSection(BtDevice d) {
    final uuids = d.uuids;
    final has = (int s) => hasService(uuids, s);
    final notes = <String>[
      if (uuids.isEmpty) 'Nessun servizio in cache: esegui il ping con il dispositivo acceso.',
      if (uuids.isNotEmpty && !has(0x111E)) 'Il dispositivo non dichiara HFP Handsfree.',
      if (uuids.isNotEmpty && !has(0x110B)) 'Il dispositivo non dichiara A2DP Sink.',
      if (has(0x1108) && !has(0x111E)) 'Ha solo HSP: modulo molto vecchio.',
      if (has(0x1200)) 'Espone il Device ID: lo snoop log mostra vendor/prodotto/versione.',
    ];
    return _section('Servizi dichiarati (SDP, ${uuids.length})', [
      for (final u in uuids)
        Builder(builder: (context) {
          final s = serviceInfo(u);
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${s.code} — ${s.name}'),
            subtitle: s.note.isEmpty ? null : Text(s.note),
          );
        }),
      for (final n in notes)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text(n)),
          ]),
        ),
    ]);
  }

  Widget _actions(BtDevice d, bool isTarget) {
    final classic = d.typeName != 'LE';
    final le = d.typeName == 'LE' || d.typeName == 'DUAL' || d.typeName == 'UNKNOWN';
    final uuids = d.uuids;
    if (_rfUuid != null && !uuids.contains(_rfUuid)) _rfUuid = null;
    _rfUuid ??= _defaultRfUuid(uuids);
    return _section('Azioni e test', [
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(
          icon: Icon(isTarget ? Icons.star : Icons.star_border),
          label: Text(isTarget ? 'Monitorato' : 'Imposta come monitorato'),
          onPressed: () => AppState.instance.setTarget(isTarget ? null : d.address, isTarget ? null : d.name),
        ),
      ]),
      if (_result != null) _resultBox(),
      if (d.typeName == 'LE')
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Dispositivo solo BLE: RFCOMM e ping SDP non si applicano (sono Bluetooth Classic). Usa il test GATT.'),
        ),
      if (classic) ...[
        const SizedBox(height: 16),
        Text('1 · Ping di raggiungibilità (Classic)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Il telefono interroga i servizi del dispositivo via SDP: per farlo deve aprire il link ACL. '
          'Se il link si apre il dispositivo è raggiungibile, a prescindere dai servizi. Aggiorna anche la lista servizi.',
        ),
        const SizedBox(height: 6),
        _runButton('probe', 'Ping', Icons.network_ping, () => BtApi.probe(d.address)),
        const SizedBox(height: 16),
        Text('2 · Test canale RFCOMM (Classic)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Apre un canale verso un servizio dichiarato e chiude dopo 1,5 s. In modalità sicura serve la link key salvata: '
          'se fallisce in sicura ma riesce in non sicura, il problema è la chiave. Ha senso solo su servizi RFCOMM '
          '(HFP, HSP, SPP, PBAP, MAP), non su A2DP/AVRCP che usano L2CAP.',
        ),
        if (uuids.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Nessun servizio noto: esegui prima il ping.', style: TextStyle(fontStyle: FontStyle.italic)),
          )
        else ...[
          DropdownButton<String>(
            isExpanded: true,
            value: _rfUuid,
            items: [
              for (final u in uuids)
                DropdownMenuItem(value: u, child: Text('${serviceInfo(u).code} — ${serviceInfo(u).name}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _rfUuid = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Modalità sicura (autenticata)'),
            value: _secure,
            onChanged: (v) => setState(() => _secure = v),
          ),
          _runButton('rfcomm', 'Test RFCOMM', Icons.cable,
              _rfUuid == null ? null : () => BtApi.rfcommTest(d.address, _rfUuid!, secure: _secure)),
        ],
      ],
      if (le) ...[
        const SizedBox(height: 16),
        Text('${classic ? '3' : '1'} · Test GATT (BLE)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Connessione Bluetooth Low Energy diretta e scoperta dei servizi GATT. Molti elettrodomestici accettano '
          'una sola connessione alla volta: chiudi la loro app prima del test.',
        ),
        const SizedBox(height: 6),
        _runButton('gatt', 'Test GATT', Icons.bluetooth_searching, () => BtApi.gattTest(d.address)),
      ],
    ]);
  }

  Widget _runButton(String id, String label, IconData icon, Future<Map<String, dynamic>> Function()? run) => FilledButton.icon(
        icon: _busy == id
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon),
        label: Text(label),
        onPressed: _busy != null || run == null
            ? null
            : () async {
                setState(() => _busy = id);
                try {
                  final r = await run();
                  if (mounted) setState(() => _result = (label, r));
                } catch (e) {
                  if (mounted) setState(() => _result = (label, {'ok': false, 'verdict': 'Errore: $e'}));
                } finally {
                  if (mounted) setState(() => _busy = null);
                  _load();
                }
              },
      );

  Widget _resultBox() {
    final (label, r) = _result!;
    final ok = r['ok'] == true;
    final color = ok ? Colors.green : Colors.red;
    final services = ((r['services'] as List?) ?? const []).map((e) => '$e').toList();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(10),
        color: color.withValues(alpha: 0.08),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel, color: color, size: 18),
          const SizedBox(width: 6),
          Text('$label: ${ok ? 'OK' : 'fallito'}${r['ms'] != null ? ' · ${r['ms']} ms' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        SelectableText('${r['verdict'] ?? r['error'] ?? ''}'),
        if (r['error'] != null && r['verdict'] != null)
          SelectableText('Eccezione Android: ${r['error']}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        for (final s in services) Text('• ${serviceInfo(s).name} ($s)', style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(v)),
        ]),
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
