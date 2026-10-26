package it.lucapaganin.bt_debugger

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.lang.reflect.InvocationTargetException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Riconnessione avviata dal telefono. Con l'Alpine la connessione riesce quando la
 * avvia il telefono (la link key viene rifiutata ma il pairing Just Works si rifà da
 * solo), mentre fallisce quando la avvia la radio. Qui, dentro una "finestra" aperta
 * da un trigger (Wi-Fi perso, carica, radio che si fa viva, prova manuale), il
 * telefono chiama la radio ogni [RETRY_MS] finché HFP o A2DP risultano connessi.
 *
 * Strategie, in ordine:
 *  1. connect() dei profili HFP/A2DP, cioè quello che fanno le Impostazioni. È un'API
 *     di sistema: su Android recenti può essere negata, e allora non la si riprova.
 *  2. Socket RFCOMM sicuro verso il servizio vivavoce (0x111E): costringe il telefono a
 *     fare page, aprire il link e autenticarsi (rifacendo il pairing se serve). Poi si
 *     chiude subito e si lascia alla radio o allo stack il collegamento dei profili.
 */
object AutoConnect {
    private const val PREFS = "bt_debugger"
    private const val KEY_ENABLED = "auto_enabled"
    private val HFP_UUID: UUID = UUID.fromString("0000111e-0000-1000-8000-00805f9b34fb")

    const val RETRY_MS = 30_000L
    const val WINDOW_WIFI_MS = 20 * 60_000L
    const val WINDOW_CHARGE_MS = 10 * 60_000L
    const val WINDOW_RADIO_MS = 3 * 60_000L
    const val WINDOW_MANUAL_MS = 5 * 60_000L
    private const val SOCKET_TIMEOUT_MS = 25_000L
    private const val PROFILE_CHECK_MS = 12_000L

    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private val timeFmt = SimpleDateFormat("HH:mm", Locale.ITALY)

    @Volatile var windowUntil = 0L
        private set
    @Volatile var windowReason: String? = null
        private set
    @Volatile var lastResult: String? = null
        private set
    @Volatile var attempts = 0
        private set

    @Volatile private var attempting = false
    @Volatile private var socket: BluetoothSocket? = null
    private var recorderHeld = false
    private var linkOkNoProfiles = 0
    /** null = non ancora provato, true = funziona, false = negato da Android. */
    private var systemConnectAllowed: Boolean? = null

    fun init(context: Context) {
        ctx = context.applicationContext
        BtBridge.init(ctx)
        BtBridge.ensureProxies()
        EventStore.init(ctx)
    }

    private fun prefs() = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(): Boolean = prefs().getBoolean(KEY_ENABLED, false)

    fun setEnabled(on: Boolean) {
        prefs().edit().putBoolean(KEY_ENABLED, on).apply()
    }

    private fun targetAddress(): String? = prefs().getString("target_address", null)

    private fun targetDevice(): BluetoothDevice? {
        val addr = targetAddress() ?: return null
        return try {
            BtBridge.adapter?.getRemoteDevice(addr)
        } catch (_: Throwable) {
            null
        }
    }

    fun isTarget(address: String?): Boolean =
        address != null && address.equals(targetAddress(), ignoreCase = true)

    fun windowActive(): Boolean = windowUntil > System.currentTimeMillis()

    fun status(): Map<String, Any?> = mapOf(
        "enabled" to isEnabled(),
        "serviceRunning" to AutoConnectService.running,
        "windowUntil" to windowUntil.takeIf { it > System.currentTimeMillis() },
        "windowReason" to windowReason,
        "attempts" to attempts,
        "lastResult" to lastResult,
        "target" to targetAddress(),
        "systemConnect" to systemConnectAllowed,
    )

    // ---------------------------------------------------------------- stato profili

    private fun state(profile: BluetoothProfile?, d: BluetoothDevice): Int =
        try {
            profile?.getConnectionState(d) ?: BluetoothProfile.STATE_DISCONNECTED
        } catch (_: Throwable) {
            BluetoothProfile.STATE_DISCONNECTED
        }

    fun isProfileConnected(d: BluetoothDevice): Boolean {
        BtBridge.ensureProxies()
        return state(BtBridge.headsetProxy, d) == BluetoothProfile.STATE_CONNECTED ||
            state(BtBridge.a2dpProxy, d) == BluetoothProfile.STATE_CONNECTED
    }

    private fun isProfileConnecting(d: BluetoothDevice): Boolean =
        state(BtBridge.headsetProxy, d) == BluetoothProfile.STATE_CONNECTING ||
            state(BtBridge.a2dpProxy, d) == BluetoothProfile.STATE_CONNECTING

    private fun profilesText(d: BluetoothDevice): String {
        val hfp = BtNames.connState(state(BtBridge.headsetProxy, d))
        val a2dp = BtNames.connState(state(BtBridge.a2dpProxy, d))
        return "HFP $hfp, A2DP $a2dp"
    }

    // ---------------------------------------------------------------- finestra

    /**
     * Apre (o prolunga) la finestra di tentativi. [firstDelayMs] lascia tempo alla radio
     * di finire il suo tentativo prima di intervenire.
     */
    fun startWindow(reason: String, durationMs: Long, firstDelayMs: Long = 0, manual: Boolean = false) {
        main.post {
            val d = targetDevice()
            if (d == null) {
                if (manual) log("AUTO_NO_TARGET", "Riconnessione automatica: nessun dispositivo monitorato. Sceglilo in Dispositivi.")
                return@post
            }
            val name = BtRecorder.safeName(d)
            if (isProfileConnected(d)) {
                if (manual) log("AUTO_ALREADY", "Riconnessione: già connessa (${profilesText(d)})", d.address, name)
                return@post
            }
            val now = System.currentTimeMillis()
            val until = now + durationMs
            val active = windowUntil > now
            if (active) {
                if (until > windowUntil) {
                    windowUntil = until
                    windowReason = reason
                    log("AUTO_WINDOW_EXTEND", "Riconnessione: $reason → finestra prolungata fino alle ${timeFmt.format(Date(until))}", d.address, name)
                }
                return@post
            }
            windowUntil = until
            windowReason = reason
            attempts = 0
            linkOkNoProfiles = 0
            if (!recorderHeld) {
                BtRecorder.acquire(ctx)
                recorderHeld = true
            }
            log(
                "AUTO_WINDOW_START",
                "Riconnessione: $reason → il telefono chiama la radio ogni ${RETRY_MS / 1000} s fino alle ${timeFmt.format(Date(until))}",
                d.address, name,
            )
            main.removeCallbacks(tick)
            main.postDelayed(tick, firstDelayMs)
        }
    }

    /** Chiamata dal servizio quando un profilo del target cambia stato: verifica subito. */
    fun onProfileChanged() {
        if (!windowActive()) return
        main.removeCallbacks(tick)
        main.post(checkOnly)
    }

    fun cancelWindow(reason: String) {
        main.post {
            if (windowUntil == 0L) return@post
            endWindow(reason, ok = false)
        }
    }

    private fun endWindow(result: String, ok: Boolean) {
        windowUntil = 0L
        main.removeCallbacks(tick)
        main.removeCallbacks(checkOnly)
        lastResult = result
        val d = targetDevice()
        log(if (ok) "AUTO_OK" else "AUTO_STOP", "Riconnessione: $result", d?.address, d?.let { BtRecorder.safeName(it) })
        if (recorderHeld) {
            BtRecorder.release()
            recorderHeld = false
        }
    }

    /** Controllo di successo senza tentativo (dopo un cambio di profilo). */
    private val checkOnly = Runnable {
        val d = targetDevice()
        if (d != null && isProfileConnected(d)) {
            endWindow("connessa dopo $attempts tentativi (${profilesText(d)})", ok = true)
        } else if (windowActive()) {
            main.postDelayed(tick, RETRY_MS)
        }
    }

    private val tick: Runnable = object : Runnable {
        override fun run() {
            if (windowUntil == 0L) return
            val d = targetDevice()
            if (d == null) {
                endWindow("nessun dispositivo monitorato", ok = false)
                return
            }
            if (isProfileConnected(d)) {
                endWindow("connessa dopo $attempts tentativi (${profilesText(d)})", ok = true)
                return
            }
            if (System.currentTimeMillis() >= windowUntil) {
                endWindow("finestra scaduta dopo $attempts tentativi senza connessione", ok = false)
                return
            }
            if (!attempting && !isProfileConnecting(d)) attempt(d)
            main.postDelayed(this, RETRY_MS)
        }
    }

    // ---------------------------------------------------------------- tentativi

    private fun attempt(d: BluetoothDevice) {
        attempts += 1
        val n = attempts
        if (systemConnectAllowed != false) {
            val (ok, detail) = trySystemConnect(d)
            if (ok) {
                systemConnectAllowed = true
                lastResult = "tentativo $n: connessione chiesta allo stack"
                log("AUTO_ATTEMPT", "Tentativo $n: connect() HFP/A2DP accettato dallo stack ($detail)", d.address, BtRecorder.safeName(d))
                return
            }
            if (systemConnectAllowed == false) {
                log("AUTO_SYSTEM_DENIED", "connect() dei profili negato da Android ($detail): da qui in poi uso il socket RFCOMM", d.address, BtRecorder.safeName(d))
            } else {
                log("AUTO_SYSTEM_FAIL", "Tentativo $n: connect() dei profili non riuscito ($detail), provo il socket RFCOMM", d.address, BtRecorder.safeName(d))
            }
        }
        rfcommKick(d, n)
    }

    /** connect() dei proxy di profilo via reflection. Ritorna (accettato, dettaglio). */
    private fun trySystemConnect(d: BluetoothDevice): Pair<Boolean, String> {
        BtBridge.ensureProxies()
        val parts = mutableListOf<String>()
        var anyOk = false
        var denied = 0
        var tried = 0

        fun call(label: String, proxy: Any?, cls: Class<*>) {
            if (proxy == null) {
                parts += "$label: proxy non pronto"
                return
            }
            tried += 1
            try {
                val r = cls.getMethod("connect", BluetoothDevice::class.java).invoke(proxy, d)
                if (r == true) anyOk = true
                parts += "$label: $r"
            } catch (e: InvocationTargetException) {
                val c = e.targetException
                if (c is SecurityException) denied += 1
                parts += "$label: ${c?.javaClass?.simpleName}"
            } catch (_: NoSuchMethodException) {
                denied += 1
                parts += "$label: API nascosta non accessibile"
            } catch (e: Throwable) {
                parts += "$label: ${e.javaClass.simpleName}"
            }
        }

        call("HFP", BtBridge.headsetProxy, BluetoothHeadset::class.java)
        call("A2DP", BtBridge.a2dpProxy, BluetoothA2dp::class.java)
        if (!anyOk && tried > 0 && denied == tried) systemConnectAllowed = false
        return anyOk to parts.joinToString(", ")
    }

    /**
     * Apre e chiude un socket RFCOMM sicuro verso il vivavoce della radio: page, link ACL,
     * autenticazione (o nuovo pairing). È lo stesso percorso di quando ti colleghi tu dal telefono.
     */
    private fun rfcommKick(d: BluetoothDevice, n: Int) {
        attempting = true
        val addr = d.address
        val name = BtRecorder.safeName(d)
        val watchdog = Runnable {
            if (attempting) try {
                socket?.close()
            } catch (_: Throwable) {
            }
        }
        main.postDelayed(watchdog, SOCKET_TIMEOUT_MS)
        Thread {
            val t0 = System.currentTimeMillis()
            var linkOk = false
            val outcome = try {
                try {
                    BtBridge.adapter?.cancelDiscovery()
                } catch (_: Throwable) {
                }
                val s = d.createRfcommSocketToServiceRecord(HFP_UUID)
                socket = s
                s.use {
                    it.connect()
                    linkOk = true
                    Thread.sleep(300)
                }
                "link aperto e autenticato in ${System.currentTimeMillis() - t0} ms; canale chiuso, ora i profili li collega la radio o lo stack"
            } catch (e: Throwable) {
                "nessun link dopo ${System.currentTimeMillis() - t0} ms (${e.javaClass.simpleName}: ${e.message}): radio spenta, fuori portata o autenticazione rifiutata"
            } finally {
                socket = null
            }
            main.post {
                main.removeCallbacks(watchdog)
                attempting = false
                lastResult = "tentativo $n: $outcome"
                log(if (linkOk) "AUTO_LINK_OK" else "AUTO_LINK_FAIL", "Tentativo $n (RFCOMM): $outcome", addr, name)
                if (linkOk) main.postDelayed({ checkProfilesAfterLink(n) }, PROFILE_CHECK_MS)
            }
        }.start()
    }

    private fun checkProfilesAfterLink(n: Int) {
        if (windowUntil == 0L) return
        val d = targetDevice() ?: return
        if (isProfileConnected(d)) {
            endWindow("connessa al tentativo $n (${profilesText(d)})", ok = true)
            return
        }
        linkOkNoProfiles += 1
        log(
            "AUTO_NO_PROFILES",
            "Tentativo $n: link autenticato ma dopo ${PROFILE_CHECK_MS / 1000} s nessun profilo collegato (${profilesText(d)})",
            d.address, BtRecorder.safeName(d),
        )
        if (linkOkNoProfiles >= 2) {
            endWindow(
                "mi fermo: il link si apre ma né la radio né lo stack collegano HFP/A2DP. Da app normale non si può chiedere il collegamento dei profili",
                ok = false,
            )
        }
    }

    private fun log(action: String, summary: String, address: String? = null, name: String? = null) {
        EventStore.emit("auto", action, summary, address, name)
    }
}
