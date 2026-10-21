import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../bt_api.dart';
import '../export.dart';
import '../widgets/event_tile.dart';

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  bool _onlyTarget = false;
  bool _hideApp = false;

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _menu(String v) async {
    final app = AppState.instance;
    switch (v) {
      case 'save':
        final text = await buildExport();
        final path = await BtApi.saveToDownloads(exportFileName(), text);
        _snack('Salvato in $path');
      case 'share':
        var text = await buildExport();
        if (text.length > 400000) text = '${text.substring(0, 400000)}\n…(troncato, usa "Salva in Download")';
        await BtApi.shareText(text);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: await buildExport()));
        _snack('Log copiato negli appunti');
      case 'clear':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Cancellare il log?'),
            content: const Text('Tutti gli eventi registrati verranno eliminati.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annulla')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancella')),
            ],
          ),
        );
        if (ok == true) await app.clearEvents();
      case 'battery':
        await BtApi.openSettings('battery');
    }
  }

  Future<void> _addNote() async {
    final ctrl = TextEditingController(text: 'Accendo l\'auto');
    final text = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Aggiungi segnaposto'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Cosa sta succedendo?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Aggiungi')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) await BtApi.addNote(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor'),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', child: Text('Salva in Download')),
              PopupMenuItem(value: 'share', child: Text('Condividi')),
              PopupMenuItem(value: 'copy', child: Text('Copia negli appunti')),
              PopupMenuItem(value: 'battery', child: Text('Ottimizzazione batteria')),
              PopupMenuItem(value: 'clear', child: Text('Cancella log')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNote,
        icon: const Icon(Icons.flag),
        label: const Text('Segnaposto'),
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          var list = app.events.reversed.toList();
          if (_onlyTarget && app.targetAddress != null) {
            list = list.where((e) => e.address == app.targetAddress || e.cat == 'note' || e.cat == 'adapter' || e.action.startsWith('MONITOR')).toList();
          }
          if (_hideApp) list = list.where((e) => e.cat != 'app').toList();
          return Column(
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                color: app.monitorRunning ? Colors.green.withValues(alpha: 0.12) : null,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(app.monitorRunning ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: app.monitorRunning ? Colors.green : null),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(app.monitorRunning ? 'Monitor in background attivo' : 'Monitor in background spento',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      Switch(value: app.monitorRunning, onChanged: (_) => app.toggleMonitor()),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      app.monitorRunning
                          ? 'Gli eventi vengono registrati anche con l\'app chiusa. Accendi l\'autoradio, poi guarda la scheda Diagnosi.'
                          : 'Con l\'app aperta gli eventi si registrano comunque. Attiva il monitor prima di salire in macchina per registrare anche a schermo spento.',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Monitorato: ${app.targetName ?? 'nessuno (scegline uno in Dispositivi)'}',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ]),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  FilterChip(
                    label: const Text('Solo monitorato'),
                    selected: _onlyTarget,
                    onSelected: app.targetAddress == null ? null : (v) => setState(() => _onlyTarget = v),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(label: const Text('Nascondi eventi app'), selected: _hideApp, onSelected: (v) => setState(() => _hideApp = v)),
                  const SizedBox(width: 8),
                  Text('${list.length} eventi'),
                ]),
              ),
              const Divider(height: 16),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('Nessun evento ancora.'))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: list.length,
                        itemBuilder: (_, i) => EventTile(key: ValueKey(list[i].id), event: list[i], showDate: true),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
