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

  /// 'telefono' se i profili erano già in CONNECTING (o c'era un test dell'app) prima del link, altrimenti 'radio'.
  final String initiator;
  DateTime? end;
  String? endSummary;
  DateTime? encryptedAt;
  int repairings = 0;
  final Set<String> profilesUp = {};
  AclSession(this.start, {this.initiator = 'radio'});

  Duration? get duration => end?.difference(start);
}

class SessionAnalysis {
  final List<Finding> findings;
  final List<AclSession> aclSessions;
  final List<BtEvent> targetEvents;
  const SessionAnalysis(this.findings, this.aclSessions, this.targetEvents);
}

/// Stato di un profilo dagli extra (0 disconnesso, 1 connecting, 2 connesso, 3 disconnecting), con ripiego sul testo.
int? profileState(BtEvent e) => int.tryParse(e.extras['profile.extra.STATE'] ?? '') ?? _stateFromText(e.summary, after: true);
int? profilePrev(BtEvent e) => int.tryParse(e.extras['profile.extra.PREVIOUS_STATE'] ?? '') ?? _stateFromText(e.summary, after: false);

int? _stateFromText(String s, {required bool after}) {
  final m = RegExp(r'(DISCONNECTED|CONNECTING|CONNECTED|DISCONNECTING) → (DISCONNECTED|CONNECTING|CONNECTED|DISCONNECTING)').firstMatch(s);
  if (m == null) return null;
  return const {'DISCONNECTED': 0, 'CONNECTING': 1, 'CONNECTED': 2, 'DISCONNECTING': 3}[m.group(after ? 2 : 1)];
}

/// Bond che riparte da capo pur essendo già accoppiato.
bool isRepairing(BtEvent e) =>
    (e.extras['device.extra.PREVIOUS_BOND_STATE'] == '12' && e.extras['device.extra.BOND_STATE'] == '11') ||
    e.summary.contains('BONDED → BONDING');

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
  final pairing = mine.where((e) => e.cat == 'pairing').toList();
  final legacy = pairing.any((e) => e.summary.contains('legacy'));

  // --- Sessioni ACL, chi le avvia, cifratura, profili
  final sessions = <AclSession>[];
  AclSession? cur;
  DateTime? phoneInitAt;
  int hfpFails = 0, a2dpFails = 0, repairTotal = 0;
  String? lastHfpFail, lastA2dpFail, hfFeatures;
  for (final e in mine) {
    final isProfile = (e.cat == 'hfp' || e.cat == 'a2dp') && e.action == 'CONNECTION_STATE_CHANGED';
    if (e.action.endsWith('_TEST_START') || e.action == 'PROBE_START') {
      if (cur == null) phoneInitAt = e.ts;
    } else if (isProfile && profilePrev(e) == 0 && profileState(e) == 1 && cur == null) {
      // Il telefono mette i profili in CONNECTING prima che esista il link: sta chiamando lui.
      phoneInitAt = e.ts;
    }

    if (e.action == 'ACL_CONNECTED') {
      final byPhone = phoneInitAt != null && e.ts.difference(phoneInitAt).inSeconds <= 10;
      cur = AclSession(e.ts, initiator: byPhone ? 'telefono' : 'radio');
      sessions.add(cur);
      phoneInitAt = null;
    } else if (e.action == 'ACL_DISCONNECTED') {
      if (cur != null) {
        cur.end = e.ts;
        cur.endSummary = e.summary;
      }
      cur = null;
    } else if (e.cat == 'security' && e.action == 'ENCRYPTION_CHANGE') {
      final on = e.extras['device.extra.ENCRYPTION_ENABLED'] == 'true' || e.summary.startsWith('Cifratura ATTIVA');
      if (on && cur != null) cur.encryptedAt ??= e.ts;
    } else if (e.cat == 'bond' && isRepairing(e)) {
      repairTotal++;
      if (cur != null) cur.repairings++;
    } else if (isProfile) {
      final name = e.cat == 'hfp' ? 'HFP' : 'A2DP';
      final st = profileState(e), prev = profilePrev(e);
      if (st == 2) cur?.profilesUp.add(name);
      if (prev == 1 && st == 0) {
        if (name == 'HFP') {
          hfpFails++;
          lastHfpFail = e.summary;
        } else {
          a2dpFails++;
          lastA2dpFail = e.summary;
        }
      }
      final i = e.summary.indexOf('funzioni HF');
      if (i >= 0) hfFeatures = e.summary.substring(i);
    }
  }

  if (repairTotal > 0) {
    final withRepair = sessions.where((s) => s.repairings > 0).length;
    findings.add(Finding(
      Severity.error,
      'Nuovo pairing a ogni connessione',
      'Il dispositivo era già accoppiato, ma $repairTotal volte il bond è ripartito da capo (BONDED → BONDING)'
          '${sessions.isEmpty ? '' : ', in $withRepair connessioni su ${sessions.length}'}. La chiave salvata non viene riusata: '
          'uno dei due lati (di solito la radio) non la conserva o non la accetta. È il sintomo "si dimentica il pairing", '
          'e da solo basta a far fallire la riconnessione automatica.'
          '${pairing.isEmpty ? '' : ' Tipo di pairing: ${pairing.last.summary.replaceFirst('Richiesta di pairing: ', '')}.'}'
          '${legacy ? ' La radio usa il pairing legacy con PIN: modulo Bluetooth ≤ 2.0 o SSP disattivato.' : ''}',
    ));
  } else if (pairing.isNotEmpty) {
    findings.add(Finding(Severity.info, 'Pairing eseguito', pairing.last.summary));
  }
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
        'Lo stack segnala che il dispositivo non ha più la chiave di questo telefono: "dimentica" il pairing pur mostrandolo in lista.'));
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
    final byRadio = sessions.where((s) => s.initiator == 'radio').length;
    if (byRadio == 0) {
      findings.add(Finding(
        Severity.error,
        'La radio non ha mai avviato la connessione',
        'Tutte le ${sessions.length} connessioni le ha avviate il telefono (profili in CONNECTING prima che esistesse il link). '
            'Nella sessione la radio non ha mai chiamato il telefono da sola: la riconnessione automatica all\'accensione non è partita.',
      ));
    } else {
      findings.add(Finding(Severity.info, 'Connessioni avviate dalla radio: $byRadio su ${sessions.length}',
          'La radio prova a chiamare il telefono: la riconnessione automatica parte, resta da vedere se va a buon fine.'));
    }

    final slow = sessions.where((s) => s.encryptedAt != null && s.encryptedAt!.difference(s.start) > const Duration(seconds: 5)).toList();
    if (slow.isNotEmpty) {
      final worst = slow.map((s) => s.encryptedAt!.difference(s.start).inMilliseconds).reduce((a, b) => a > b ? a : b);
      findings.add(Finding(
        Severity.warn,
        'Autenticazione lenta',
        '${slow.length} volte sono passati più di 5 s tra apertura del link e cifratura (massimo ${(worst / 1000).toStringAsFixed(1)} s). '
            'Con un dispositivo sano ci vuole meno di un secondo: lo scambio della chiave si trascina o va in timeout.',
      ));
    }

    // Link breve senza profili: innocuo se subito dopo arriva una connessione riuscita.
    bool benign(AclSession s) {
      if (s.repairings > 0 || s.end == null) return false;
      return sessions.any((o) =>
          o.start.isAfter(s.start) && o.start.difference(s.end!) <= const Duration(seconds: 10) && o.profilesUp.isNotEmpty);
    }

    final quick = sessions.where((s) => s.duration != null && s.duration! < const Duration(seconds: 5) && s.profilesUp.isEmpty).toList();
    final quickBad = quick.where((s) => !benign(s)).toList();
    if (quickBad.isNotEmpty) {
      findings.add(Finding(
        Severity.error,
        'Link aperto e chiuso subito',
        '${quickBad.length} volte il link si è chiuso in meno di 5 s senza attivare profili, e nessuna connessione riuscita è seguita. '
            'Ultimo: ${quickBad.last.endSummary ?? '?'}',
      ));
    }
    if (quick.length > quickBad.length) {
      findings.add(Finding(Severity.info, 'Rimbalzo iniziale innocuo',
          '${quick.length - quickBad.length} volte un link breve è stato seguito subito da una connessione riuscita (tipico quando i due lati si chiamano insieme).'));
    }
    final bare = sessions.where((s) => s.profilesUp.isEmpty && (s.duration == null || s.duration! >= const Duration(seconds: 5))).toList();
    if (bare.isNotEmpty) {
      findings.add(Finding(
        Severity.warn,
        'Link aperto senza profili',
        '${bare.length} volte il link è rimasto su almeno 5 s ma né HFP né A2DP si sono connessi.'
            '${bare.any((s) => s.repairings > 0) ? ' In queste connessioni c\'è stato un nuovo pairing: i profili cadono subito dopo.' : ''}',
      ));
    }
    final full = sessions.where((s) => s.profilesUp.containsAll({'HFP', 'A2DP'})).toList();
    final hfpOnly = sessions.where((s) => s.profilesUp.contains('HFP') && !s.profilesUp.contains('A2DP')).toList();
    final a2dpOnly = sessions.where((s) => s.profilesUp.contains('A2DP') && !s.profilesUp.contains('HFP')).toList();
    if (full.isNotEmpty) {
      final auto = full.where((s) => s.initiator == 'radio').length;
      findings.add(Finding(Severity.ok, 'Connessione completa riuscita',
          '${full.length} volte si sono connessi sia HFP che A2DP'
              '${auto > 0 ? ' ($auto avviate dal dispositivo: la riconnessione automatica funziona)' : ' (sempre su richiesta del telefono)'}.'));
    }
    if (hfpOnly.isNotEmpty) {
      findings.add(Finding(Severity.warn, 'Solo vivavoce (HFP), niente audio',
          '${hfpOnly.length} volte si è connesso HFP ma non A2DP. Prova AVRCP 1.3 nelle opzioni sviluppatore e disattiva i codec avanzati.'));
    }
    if (a2dpOnly.isNotEmpty) {
      findings.add(Finding(Severity.info, 'Solo audio (A2DP), niente vivavoce',
          '${a2dpOnly.length} volte si è connesso A2DP ma non HFP.'));
    }
  }
  if (hfpFails > 0) {
    findings.add(Finding(Severity.warn, 'Tentativi HFP falliti: $hfpFails', 'Ultimo: $lastHfpFail'));
  }
  if (a2dpFails > 0) {
    findings.add(Finding(Severity.warn, 'Tentativi A2DP falliti: $a2dpFails', 'Ultimo: $lastA2dpFail'));
  }
  if (hfFeatures != null) {
    findings.add(Finding(Severity.info, 'Funzioni vivavoce dichiarate', hfFeatures));
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

  final probeKo = mine.where((e) => e.action == 'PROBE_FAIL').toList();
  if (probeKo.isNotEmpty) {
    findings.add(Finding(Severity.warn, 'Ping non riuscito: ${probeKo.length}', probeKo.last.summary));
  }

  return SessionAnalysis(findings, sessions, mine);
}
