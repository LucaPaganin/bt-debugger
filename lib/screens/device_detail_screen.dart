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
  bool _testing = false;
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
      if (d != null && _rfUuid == null) _rfUuid = _defaultRfUuid(d.uuids);
    });
  }

  String _defaultRfUuid(List<String> uuids) {
    for (final s in [0x111E, 0x1108, 0x1101]) {
      if (hasService(uuids, s)) return uuidFromShort(s);
    }
    return uuids.isNotEmpty ? uuids.first : uuidFromShort(0x111E);
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

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
      if (uuids.isEmpty) 'Nessun servizio in cache: premi "Rileggi servizi (SDP)" con l\'autoradio accesa.',
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
    final rfOptions = {...d.uuids, if (_rfUuid != null) _rfUuid!}.toList();
    return _section('Azioni', [
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(
          icon: Icon(isTarget ? Icons.star : Icons.star_border),
          label: Text(isTarget ? 'Monitorato' : 'Imposta come monitorato'),
          onPressed: () => AppState.instance.setTarget(isTarget ? null : d.address, isTarget ? null : d.name),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.manage_search),
          label: const Text('Rileggi servizi (SDP)'),
          onPressed: () async {
            final ok = await BtApi.fetchUuids(d.address);
            _snack(ok ? 'Query SDP inviata: il risultato arriva nel log (fino a ~10 s)' : 'Query SDP rifiutata');
          },
        ),
      ]),
      const SizedBox(height: 16),
      Text('Test connessione RFCOMM', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      const Text(
        'Il telefono chiama la radio e apre un canale verso un suo servizio, poi chiude dopo 1,5 s. '
        'In modalità sicura serve la link key salvata: se fallisce qui ma riesce in non sicura, il problema è la chiave. '
        'Va fatto con l\'autoradio accesa e il telefono non già connesso.',
      ),
      DropdownButton<String>(
        isExpanded: true,
        value: _rfUuid,
        items: [
          for (final u in rfOptions)
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
      FilledButton.icon(
        icon: _testing
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.cable),
        label: const Text('Esegui test'),
        onPressed: _testing || _rfUuid == null
            ? null
            : () async {
                setState(() => _testing = true);
                try {
                  final r = await BtApi.rfcommTest(d.address, _rfUuid!, secure: _secure);
                  _snack(r['ok'] == true ? 'Riuscito in ${r['ms']} ms' : 'Fallito: ${r['error']}');
                } catch (e) {
                  _snack('Errore: $e');
                } finally {
                  if (mounted) setState(() => _testing = false);
                  _load();
                }
              },
      ),
    ]);
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
