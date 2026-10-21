import 'bt_api.dart';

enum Severity { ok, info, warn, error }

class Finding {
  final Severity severity;
  final String title;
  final String detail;
  const Finding(this.severity, this.title, this.detail);

  @override
  String toString() => '[${severity.name}] $title — $detail';
}

/// Un intervallo in cui il link ACL col dispositivo è stato aperto.
class AclSession {
  final DateTime start;
  DateTime? end;
  String? endSummary;
  final Set<String> profilesUp = {};
  AclSession(this.start);

  Duration? get duration => end?.difference(start);
}

class SessionAnalysis {
  final List<Finding> findings;
  final List<AclSession> aclSessions;
  final List<BtEvent> targetEvents;
  const SessionAnalysis(this.findings, this.aclSessions, this.targetEvents);
}

/// Segnaposti da cui far partire l'analisi: note dell'utente e avvii del monitor.
List<BtEvent> sessionMarkers(List<BtEvent> events) =>
    events.where((e) => e.cat == 'note' || e.action == 'MONITOR_START').toList();

/// Analisi a regole degli eventi di una sessione per il dispositivo [target].
SessionAnalysis analyzeSession(List<BtEvent> all, String target, {DateTime? since}) {
  final events = all.where((e) => since == null || !e.ts.isBefore(since)).toList();
  final t = target.toUpperCase();
  final mine = events.where((e) => (e.address ?? '').toUpperCase() == t).toList();
  final findings = <Finding>[];

  if (events.isEmpty) {
    return const SessionAnalysis(
      [Finding(Severity.info, 'Nessun evento', 'Avvia il monitor, accendi l\'autoradio e torna qui.')],
      [],
      [],
    );
  }

  // --- Bluetooth del telefono spento durante la sessione
  final adapterOff = events.where((e) => e.action == 'STATE_CHANGED' && e.summary.contains('→ OFF'));
  if (adapterOff.isNotEmpty) {
    findings.add(Finding(Severity.info, 'Bluetooth del telefono spento',
        'Il Bluetooth del telefono è stato spento ${adapterOff.length} volte nella sessione: durante quei momenti la radio non può riconnettersi.'));
  }

  // --- Link key / bond
  final bondLost = mine.where((e) => e.cat == 'bond' && e.summary.contains('→ NONE')).toList();
  for (final e in bondLost) {
    final authFail = e.summary.contains('AUTH_FAILED') || e.summary.contains('AUTH_REJECTED') || e.summary.contains('AUTH_TIMEOUT');
    findings.add(Finding(
      Severity.error,
      'Bond perso',
      '${e.summary}. ${authFail ? 'Il telefono ha cancellato l\'accoppiamento perché la link key non è stata accettata: la radio probabilmente ha perso o rigenerato la sua chiave.' : 'L\'accoppiamento è stato rimosso.'}',
    ));
  }
  if (mine.any((e) => e.action == 'KEY_MISSING')) {
    findings.add(const Finding(Severity.error, 'Link key mancante sul remoto',
        'Lo stack segnala che l\'autoradio non ha più la chiave di questo telefono: la radio "dimentica" il pairing pur mostrandolo in lista.'));
  }
  final pairing = mine.where((e) => e.cat == 'pairing').toList();
  if (pairing.isNotEmpty) {
    final legacy = pairing.any((e) => e.summary.contains('legacy'));
    findings.add(Finding(
      Severity.warn,
      'Richiesto un nuovo pairing',
      'La radio ha chiesto di riaccoppiarsi (${pairing.last.summary}). Se il dispositivo era già accoppiato, vuol dire che la chiave salvata non è stata usata o accettata.'
          '${legacy ? ' La radio usa il pairing legacy con PIN: modulo Bluetooth ≤ 2.0 o SSP disattivato.' : ''}',
    ));
  }

  // --- Sessioni ACL e profili
  final sessions = <AclSession>[];
  AclSession? cur;
  int hfpFails = 0, a2dpFails = 0;
  String? lastHfp, lastA2dp;
  for (final e in mine) {
    if (e.action == 'ACL_CONNECTED') {
      cur = AclSession(e.ts);
      sessions.add(cur);
    } else if (e.action == 'ACL_DISCONNECTED') {
      if (cur != null) {
        cur.end = e.ts;
        cur.endSummary = e.summary;
      }
      cur = null;
    } else if (e.cat == 'hfp' && e.action == 'CONNECTION_STATE_CHANGED') {
      if (e.summary.endsWith('→ CONNECTED')) cur?.profilesUp.add('HFP');
      if (lastHfp == 'CONNECTING' && e.summary.endsWith('→ DISCONNECTED')) hfpFails++;
      lastHfp = e.summary.split('→ ').last;
    } else if (e.cat == 'a2dp' && e.action == 'CONNECTION_STATE_CHANGED') {
      if (e.summary.endsWith('→ CONNECTED')) cur?.profilesUp.add('A2DP');
      if (lastA2dp == 'CONNECTING' && e.summary.endsWith('→ DISCONNECTED')) a2dpFails++;
      lastA2dp = e.summary.split('→ ').last;
    }
  }

  if (sessions.isEmpty) {
    findings.add(const Finding(
      Severity.error,
      'Nessun tentativo di connessione',
      'In questa sessione il link ACL con il dispositivo non si è mai aperto. La radio non ha "chiamato" il telefono (o la chiamata non è arrivata). '
          'Cause tipiche: la radio prova a riconnettersi solo all\'ultimo dispositivo usato (o a un altro della lista), rinuncia troppo presto all\'accensione, '
          'oppure il telefono non era connettibile. Verifica col snoop log se la radio invia "Create Connection"/page.',
    ));
  } else {
    final quick = sessions.where((s) => s.duration != null && s.duration! < const Duration(seconds: 5) && s.profilesUp.isEmpty).toList();
    if (quick.isNotEmpty) {
      findings.add(Finding(
        Severity.error,
        'Link aperto e chiuso subito',
        '${quick.length} volte il link ACL si è chiuso in meno di 5 s senza attivare profili. È la firma di un fallimento in autenticazione/cifratura o nella negoziazione iniziale. '
            'Ultimo motivo: ${quick.last.endSummary ?? '?'}',
      ));
    }
    final bare = sessions.where((s) => s.profilesUp.isEmpty && (s.duration == null || s.duration! >= const Duration(seconds: 5))).toList();
    if (bare.isNotEmpty) {
      findings.add(Finding(
        Severity.warn,
        'Link aperto senza profili',
        '${bare.length} volte il link ACL è rimasto su ma né HFP né A2DP si sono connessi. La radio apre il collegamento ma nessuno dei due avvia i profili: '
            'spesso la radio aspetta che sia il telefono a farlo, o la query SDP fallisce.',
      ));
    }
    final full = sessions.where((s) => s.profilesUp.containsAll({'HFP', 'A2DP'})).toList();
    final hfpOnly = sessions.where((s) => s.profilesUp.contains('HFP') && !s.profilesUp.contains('A2DP')).toList();
    final a2dpOnly = sessions.where((s) => s.profilesUp.contains('A2DP') && !s.profilesUp.contains('HFP')).toList();
    if (full.isNotEmpty) {
      findings.add(Finding(Severity.ok, 'Connessione completa riuscita',
          '${full.length} volte si sono connessi sia HFP che A2DP. Se questo è successo all\'accensione senza intervento, la riconnessione automatica ha funzionato.'));
    }
    if (hfpOnly.isNotEmpty) {
      findings.add(Finding(Severity.warn, 'Solo vivavoce (HFP), niente audio',
          '${hfpOnly.length} volte si è connesso HFP ma non A2DP. Prova AVRCP 1.4/1.3 nelle opzioni sviluppatore e disattiva i codec avanzati.'));
    }
    if (a2dpOnly.isNotEmpty) {
      findings.add(Finding(Severity.info, 'Solo audio (A2DP), niente vivavoce',
          '${a2dpOnly.length} volte si è connesso A2DP ma non HFP.'));
    }
  }
  if (hfpFails > 0) {
    findings.add(Finding(Severity.warn, 'Tentativi HFP falliti', '$hfpFails volte HFP è passato da CONNECTING a DISCONNECTED.'));
  }
  if (a2dpFails > 0) {
    findings.add(Finding(Severity.warn, 'Tentativi A2DP falliti', '$a2dpFails volte A2DP è passato da CONNECTING a DISCONNECTED.'));
  }

  // --- Test RFCOMM fatti dall'app
  final rfOk = mine.where((e) => e.action == 'RFCOMM_TEST_OK').length;
  final rfKo = mine.where((e) => e.action == 'RFCOMM_TEST_FAIL').toList();
  if (rfOk > 0) {
    findings.add(Finding(Severity.ok, 'Test RFCOMM riusciti: $rfOk',
        'Quando è il telefono a chiamare, il link si apre e (in modalità sicura) la link key viene accettata.'));
  }
  if (rfKo.isNotEmpty) {
    findings.add(Finding(Severity.warn, 'Test RFCOMM falliti: ${rfKo.length}', rfKo.last.summary));
  }

  return SessionAnalysis(findings, sessions, mine);
}
