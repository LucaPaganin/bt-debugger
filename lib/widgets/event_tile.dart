import 'package:flutter/material.dart';

import '../bt_api.dart';

String fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 100)}';

String fmtDate(DateTime t) =>
    '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} ${fmtTime(t)}';

IconData catIcon(String cat) => switch (cat) {
      'adapter' => Icons.bluetooth,
      'acl' => Icons.link,
      'bond' => Icons.key,
      'pairing' => Icons.handshake_outlined,
      'security' => Icons.lock_outline,
      'sdp' => Icons.list_alt,
      'a2dp' => Icons.music_note,
      'hfp' => Icons.call,
      'pbap' => Icons.contacts_outlined,
      'map' => Icons.sms_outlined,
      'device' => Icons.devices_other,
      'note' => Icons.flag,
      'app' => Icons.build_circle_outlined,
      _ => Icons.circle_outlined,
    };

Color catColor(String cat, ColorScheme cs) => switch (cat) {
      'acl' => Colors.blue,
      'bond' || 'security' => Colors.deepOrange,
      'pairing' => Colors.orange,
      'a2dp' => Colors.purple,
      'hfp' => Colors.teal,
      'sdp' => Colors.indigo,
      'note' => Colors.amber.shade800,
      'app' => cs.outline,
      _ => cs.onSurfaceVariant,
    };

class EventTile extends StatelessWidget {
  final BtEvent event;
  final bool showDate;
  const EventTile({super.key, required this.event, this.showDate = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = catColor(event.cat, cs);
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(52, 0, 12, 8),
      leading: Icon(catIcon(event.cat), color: color, size: 22),
      title: Text(event.summary, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        '${showDate ? fmtDate(event.ts) : fmtTime(event.ts)}  ·  ${event.cat.toUpperCase()}${event.who.isNotEmpty ? '  ·  ${event.who}' : ''}',
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText('action: ${event.action}', style: mono),
        if (event.address != null) SelectableText('address: ${event.address}', style: mono),
        for (final e in event.extras.entries) SelectableText('${e.key}: ${e.value}', style: mono),
      ],
    );
  }
}
