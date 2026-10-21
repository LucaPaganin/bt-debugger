import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../bt_labels.dart';
import '../discovery.dart';
import 'device_detail_screen.dart';

/// Discovery: chi c'è nei dintorni (Classic + BLE), separando i miei dispositivi
/// (con nickname), quelli accoppiati e gli sconosciuti.
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  bool _classic = true;
  bool _le = true;
  bool _hideWeak = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Aggiorna i "visto N s fa" anche quando non arrivano eventi.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && AppState.instance.discovered.isNotEmpty) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Discovery')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final all = app.discovered.values.where((d) => !_hideWeak || (d.rssi ?? -999) >= -80).toList()
            ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
          final mine = all.where((d) => groupOf(d, app.known) == DiscoveryGroup.mine).toList();
          final bonded = all.where((d) => groupOf(d, app.known) == DiscoveryGroup.bonded).toList();
          final unknown = all.where((d) => groupOf(d, app.known) == DiscoveryGroup.unknown).toList();
          final missing = app.known.where((k) => !app.discovered.values.any(k.matches)).toList();

          return ListView(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(children: [
                FilterChip(
                  label: const Text('Classic'),
                  selected: _classic,
                  onSelected: app.scanning ? null : (v) => setState(() => _classic = v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('BLE'),
                  selected: _le,
                  onSelected: app.scanning ? null : (v) => setState(() => _le = v),
                ),
                const Spacer(),
                app.scanning
                    ? OutlinedButton.icon(onPressed: app.stopScan, icon: const Icon(Icons.stop), label: const Text('Stop'))
                    : FilledButton.icon(
                        onPressed: (_classic || _le) ? () => app.startScan(classic: _classic, le: _le) : null,
                        icon: const Icon(Icons.radar),
                        label: const Text('Scansiona'),
                      ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    app.scanning
                        ? 'In ascolto${app.classicScanning ? ' · Classic' : ''}${app.leScanning ? ' · BLE (max ${AppState.leScanDuration.inSeconds} s)' : ''}'
                        : 'Classic trova chi è visibile (~12 s); BLE legge gli advertising per ${AppState.leScanDuration.inSeconds} s. Nessuna connessione.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ),
                const Text('Solo vicini', style: TextStyle(fontSize: 12)),
                Switch(value: _hideWeak, onChanged: (v) => setState(() => _hideWeak = v)),
              ]),
            ),
            if (app.scanning) const LinearProgressIndicator(),
            if (app.scanError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(app.scanError!, style: TextStyle(color: cs.error)),
              ),
            _header(context, 'I miei', mine.length + missing.length, Icons.star),
            if (mine.isEmpty && missing.isEmpty)
              const _Hint('Tocca un dispositivo e dagli un nickname per segnarlo come tuo.'),
            for (final d in mine) _DeviceTile(device: d),
            for (final k in missing) _MissingTile(known: k, scanned: app.discovered.isNotEmpty),
            _header(context, 'Accoppiati', bonded.length, Icons.link),
            for (final d in bonded) _DeviceTile(device: d),
            _header(context, 'Sconosciuti', unknown.length, Icons.help_outline),
            if (unknown.isEmpty)
              _Hint(app.scanning ? 'Ricerca in corso…' : 'Nessuno. Avvia una scansione.'),
            for (final d in unknown) _DeviceTile(device: d),
            const _Hint(
              'Molti dispositivi BLE cambiano MAC ogni ~15 minuti: lo stesso oggetto può comparire più volte e non è '
              'riconoscibile per indirizzo. Per questi conviene il riconoscimento per nome. I tuoi dispositivi '
              'accoppiati invece compaiono col loro indirizzo vero. Alcuni beacon possono essere filtrati da Android '
              'perché l\'app non usa la posizione.',
            ),
            const SizedBox(height: 24),
          ]);
        },
      ),
    );
  }

  Widget _header(BuildContext context, String title, int count, IconData icon) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text('$title ($count)', style: Theme.of(context).textTheme.titleSmall),
        ]),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      );
}

String _ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 3) return 'ora';
  if (s < 60) return '$s s fa';
  return '${s ~/ 60} min fa';
}

IconData _icon(DiscoveredDevice d) {
  if (d.isTracker) return Icons.location_searching;
  if (d.deviceClass == 0x0420) return Icons.directions_car;
  final major = d.cod == null ? null : d.cod! & 0x1F00;
  return switch (major) {
    0x0100 => Icons.laptop,
    0x0200 => Icons.smartphone,
    0x0400 => Icons.headphones,
    0x0500 => Icons.keyboard,
    0x0700 => Icons.watch,
    _ => d.le && !d.classic ? Icons.bluetooth_searching : Icons.bluetooth,
  };
}

Color _rssiColor(int? rssi) {
  if (rssi == null) return Colors.grey;
  if (rssi >= -60) return Colors.green;
  if (rssi >= -75) return Colors.orange;
  return Colors.red;
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});
  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final d = device;
    final k = knownFor(d, AppState.instance.known);
    final transport = [if (d.classic) 'Classic', if (d.le) 'BLE'].join('+');
    final parts = [
      d.address,
      transport,
      if (d.hint != null) d.hint! else if (d.vendor != null) d.vendor!,
      _ago(d.lastSeen),
    ];
    return ListTile(
      leading: Icon(_icon(d), color: k != null ? Theme.of(context).colorScheme.primary : null),
      title: Text(k?.nickname ?? d.name ?? '(senza nome)', style: TextStyle(fontStyle: k == null && d.name == null ? FontStyle.italic : null)),
      subtitle: Text(
        '${k != null && d.name != null && d.name != k.nickname ? '${d.name}  ·  ' : ''}${parts.join('  ·  ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text('${d.rssi ?? '?'} dBm', style: TextStyle(color: _rssiColor(d.rssi), fontWeight: FontWeight.w600)),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _DeviceSheet(device: d),
      ),
    );
  }
}

class _MissingTile extends StatelessWidget {
  const _MissingTile({required this.known, required this.scanned});
  final KnownDevice known;
  final bool scanned;

  @override
  Widget build(BuildContext context) => ListTile(
        enabled: false,
        leading: const Icon(Icons.star_border),
        title: Text(known.nickname),
        subtitle: Text(
          '${known.address ?? 'nome "${known.matchName}"'}  ·  ${scanned ? 'non visto in questa scansione' : 'non ancora cercato'}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Rimuovi',
          onPressed: () => AppState.instance.removeKnown(known),
        ),
      );
}

class _DeviceSheet extends StatelessWidget {
  const _DeviceSheet({required this.device});
  final DiscoveredDevice device;

  Future<void> _editNickname(BuildContext context, KnownDevice? current) async {
    final d = device;
    final ctrl = TextEditingController(text: current?.nickname ?? d.name ?? '');
    var byName = current?.matchName != null || (current == null && d.kind == AddrKind.rotating && d.name != null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(current == null ? 'Segna come mio' : 'Modifica nickname'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nickname')),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: byName,
              onChanged: d.name == null ? null : (v) => setLocal(() => byName = v),
              title: const Text('Riconosci dal nome'),
              subtitle: Text(
                d.name == null
                    ? 'Non disponibile: il dispositivo non pubblica un nome.'
                    : byName
                        ? 'Vale per qualunque dispositivo che si chiama "${d.name}".'
                        : 'Vale solo per il MAC ${d.address}.',
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salva')),
          ],
        ),
      ),
    );
    final name = ctrl.text.trim();
    if (ok == true && name.isNotEmpty) {
      await AppState.instance.setNickname(d, name, byName: byName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final d = device;
        final k = knownFor(d, app.known);
        final rows = <(String, String)>[
          ('Indirizzo', '${d.address} (${addrKindLabel(d.kind)})'),
          if (d.name != null) ('Nome', d.name!),
          ('Trasporto', [if (d.classic) 'Classic', if (d.le) 'BLE'].join(' + ')),
          ('RSSI', '${d.rssi ?? '?'} dBm${d.txPower != null ? '  ·  Tx ${d.txPower} dBm' : ''}'),
          ('Visto', '${d.seen} volte, ultimo ${_ago(d.lastSeen)}'),
          if (d.bonded) ('Stato', 'accoppiato con questo telefono'),
          if (d.connectable != null) ('Connettibile', d.connectable! ? 'sì' : 'no (solo annunci)'),
          if (d.cod != null) ('Class of Device', '${codHex(d.cod)}  ·  ${majorName(d.cod! & 0x1F00)}  ·  ${deviceClassName(d.deviceClass)}'),
          if (d.hint != null) ('Cos\'è (ipotesi)', d.hint!),
          for (final e in d.manufacturer.entries) ('Produttore', '${companyName(e.key)}  ·  ${e.value}'),
          for (final s in d.services)
            ('Servizio', '${serviceInfo(s).code} ${serviceInfo(s).name}${d.serviceData[s] != null ? '  ·  ${d.serviceData[s]}' : ''}'),
        ];
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k?.nickname ?? d.name ?? '(senza nome)', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 120, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(child: SelectableText(value)),
                  ]),
                ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: () => _editNickname(context, k),
                  icon: Icon(k == null ? Icons.star : Icons.edit),
                  label: Text(k == null ? 'È mio: dai un nickname' : 'Modifica nickname'),
                ),
                if (k != null)
                  OutlinedButton.icon(
                    onPressed: () => app.removeKnown(k),
                    icon: const Icon(Icons.star_border),
                    label: const Text('Non è mio'),
                  ),
                // Test e dettaglio solo sui propri dispositivi: su quelli altrui ci si limita ad ascoltare.
                if (k != null || d.bonded)
                  OutlinedButton.icon(
                    onPressed: () {
                      final nav = Navigator.of(context);
                      app.stopScan();
                      nav.pop();
                      nav.push(MaterialPageRoute(builder: (_) => DeviceDetailScreen(address: d.address)));
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Dettaglio e test'),
                  ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}
