# BT Debugger

App Flutter (solo Android) per diagnosticare connessioni **Bluetooth Classic**: pairing, link ACL, profili HFP/A2DP, servizi SDP. Nata per capire perché un'autoradio Alpine non si riconnette in automatico a un Galaxy S25.

## Cosa fa

- **Dispositivi** — info sul Bluetooth del telefono e dispositivi accoppiati: tipo, Class of Device decodificata, servizi dichiarati via SDP (HFP, A2DP, AVRCP, PBAP, MAP…), stato attuale di ACL/HFP/A2DP.
- **Dettaglio dispositivo** — rilettura SDP, *test RFCOMM* (il telefono chiama il dispositivo e apre un canale, in modalità sicura o no: distingue un problema di link key da un problema di chi avvia la riconnessione), cronologia eventi del dispositivo.
- **Monitor** — registra tutti i broadcast Bluetooth (ACL, bond con motivo, richieste di pairing con variante legacy/SSP, cambi di stato HFP/A2DP/PBAP/MAP, codec, key missing…) con tutti gli extra, anche quelli non documentati. Un foreground service continua a registrare con l'app chiusa. I *segnaposti* marcano i momenti (es. "Accendo l'auto").
- **Diagnosi** — analisi a regole della sessione a partire da un segnaposto: nessun tentativo di connessione, link chiuso subito, link senza profili, solo HFP, bond perso, ecc. Include la procedura di test e la guida all'HCI snoop log.
- **Scansione** — discovery Classic con RSSI e Class of Device.
- **Export** — log + analisi in `Download/`, condivisione o copia.

## Limiti (di Android, non dell'app)

Le app non vedono la versione LMP/Bluetooth del remoto, i codici d'errore LMP, la link key né chi ha avviato la connessione. Per questo serve l'**HCI snoop log** (istruzioni nella scheda Diagnosi). Alcune informazioni (`isConnected`, batteria, broadcast PBAP/MAP/key missing) passano da API nascoste: su certi firmware possono mancare.

## Build

Il repo contiene solo i sorgenti scritti a mano; i file Gradle, le icone e i temi li genera `flutter create`.

**Automatica**: ogni push su `main` esegue `.github/workflows/build-apk.yml`, che compila l'APK e lo pubblica in *Releases* (`build-N`).

**Locale**:

```bash
flutter create --platforms=android --org it.lucapaganin --project-name bt_debugger .
flutter pub get
flutter test
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

## Struttura

```
lib/
  bt_api.dart          canali verso Kotlin + modelli
  app_state.dart       stato condiviso (eventi, target, scansione)
  analysis.dart        analisi a regole delle sessioni
  bt_labels.dart       tabelle UUID e Class of Device
  export.dart          testo del log esportato
  screens/             dispositivi, dettaglio, monitor, diagnosi, scansione
android/app/src/main/kotlin/it/lucapaganin/bt_debugger/
  MainActivity.kt      MethodChannel/EventChannel, permessi, export
  BtBridge.kt          interrogazioni allo stack (adapter, device, SDP, RFCOMM)
  BtRecorder.kt        BroadcastReceiver → eventi leggibili
  EventStore.kt        registro eventi in memoria + file JSONL
  BtMonitorService.kt  foreground service per registrare in background
  BtNames.kt           codici numerici → nomi
```

Pattern da riusare: la logica di piattaforma sta in Kotlin dietro un `MethodChannel` (comandi) e un `EventChannel` (stream di eventi); Flutter fa solo UI e analisi. Nessun plugin di terze parti.
