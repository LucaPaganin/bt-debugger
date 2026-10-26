package it.lucapaganin.bt_debugger

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.UUID

/** Interrogazioni allo stack Bluetooth esposte a Flutter via MethodChannel. */
object BtBridge {
    private lateinit var ctx: Context
    private var a2dp: BluetoothA2dp? = null
    private var headset: BluetoothHeadset? = null
    private var proxiesRequested = false

    val a2dpProxy: BluetoothA2dp? get() = a2dp
    val headsetProxy: BluetoothHeadset? get() = headset
    private val main = Handler(Looper.getMainLooper())

    fun init(context: Context) {
        ctx = context.applicationContext
    }

    val adapter: BluetoothAdapter?
        get() = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    /** I proxy dei profili danno lo stato A2DP/HFP per singolo dispositivo. */
    fun ensureProxies() {
        if (proxiesRequested) return
        val ad = adapter ?: return
        try {
            val listener = object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    when (profile) {
                        BluetoothProfile.A2DP -> a2dp = proxy as BluetoothA2dp
                        BluetoothProfile.HEADSET -> headset = proxy as BluetoothHeadset
                    }
                }

                override fun onServiceDisconnected(profile: Int) {
                    when (profile) {
                        BluetoothProfile.A2DP -> a2dp = null
                        BluetoothProfile.HEADSET -> headset = null
                    }
                }
            }
            ad.getProfileProxy(ctx, listener, BluetoothProfile.A2DP)
            ad.getProfileProxy(ctx, listener, BluetoothProfile.HEADSET)
            proxiesRequested = true
        } catch (_: SecurityException) {
        }
    }

    private inline fun <T> safe(block: () -> T): T? = try {
        block()
    } catch (_: Throwable) {
        null
    }

    fun adapterInfo(): Map<String, Any?> {
        val ad = adapter
        val pm = ctx.packageManager
        val m = linkedMapOf<String, Any?>(
            "phone" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "android" to "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "build" to Build.DISPLAY,
            "hasClassic" to pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH),
            "hasLe" to pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE),
            "available" to (ad != null),
        )
        if (ad == null) return m
        m["enabled"] = safe { ad.isEnabled }
        m["state"] = safe { BtNames.adapterState(ad.state) }
        m["name"] = safe { ad.name }
        m["scanMode"] = safe { BtNames.scanMode(ad.scanMode) }
        m["discovering"] = safe { ad.isDiscovering }
        m["a2dpState"] = safe { BtNames.connState(ad.getProfileConnectionState(BluetoothProfile.A2DP)) }
        m["hfpState"] = safe { BtNames.connState(ad.getProfileConnectionState(BluetoothProfile.HEADSET)) }
        m["le2M"] = safe { ad.isLe2MPhySupported }
        m["leCoded"] = safe { ad.isLeCodedPhySupported }
        m["leExtAdv"] = safe { ad.isLeExtendedAdvertisingSupported }
        m["lePeriodicAdv"] = safe { ad.isLePeriodicAdvertisingSupported }
        m["leMultiAdv"] = safe { ad.isMultipleAdvertisementSupported }
        m["leMaxAdvData"] = safe { ad.leMaximumAdvertisingDataLength }
        if (Build.VERSION.SDK_INT >= 33) {
            m["leAudio"] = safe { ad.isLeAudioSupported == BluetoothStatusCodes.FEATURE_SUPPORTED }
            m["leAudioBroadcast"] = safe { ad.isLeAudioBroadcastSourceSupported == BluetoothStatusCodes.FEATURE_SUPPORTED }
        }
        return m
    }

    fun bondedDevices(): List<Map<String, Any?>> {
        ensureProxies()
        val ad = adapter ?: return emptyList()
        val set = try {
            ad.bondedDevices
        } catch (_: SecurityException) {
            return emptyList()
        } ?: return emptyList()
        return set.map { describe(it) }.sortedBy { (it["name"] as? String)?.lowercase() ?: "~" }
    }

    fun device(address: String): Map<String, Any?>? {
        ensureProxies()
        val ad = adapter ?: return null
        val d = safe { ad.getRemoteDevice(address) } ?: return null
        return describe(d)
    }

    private fun describe(d: BluetoothDevice): Map<String, Any?> {
        val cls = safe { d.bluetoothClass }
        val m = linkedMapOf<String, Any?>(
            "address" to d.address,
            "name" to safe { d.name },
            "alias" to (if (Build.VERSION.SDK_INT >= 30) safe { d.alias } else null),
            "type" to safe { d.type },
            "typeName" to safe { BtNames.deviceType(d.type) },
            "bondState" to safe { BtNames.bondState(d.bondState) },
            "cod" to cls?.hashCode(),
            "major" to cls?.majorDeviceClass,
            "deviceClass" to cls?.deviceClass,
            "uuids" to (safe { d.uuids?.map { it.uuid.toString() } } ?: emptyList<String>()),
            // API nascoste: possono non funzionare, in quel caso null.
            "connected" to safe { d.javaClass.getMethod("isConnected").invoke(d) as? Boolean },
            "encrypted" to safe { d.javaClass.getMethod("isEncrypted").invoke(d) as? Boolean },
            "battery" to safe { d.javaClass.getMethod("getBatteryLevel").invoke(d) as? Int },
        )
        a2dp?.let { p ->
            m["a2dp"] = safe { BtNames.connState(p.getConnectionState(d)) }
            m["a2dpPlaying"] = safe { p.isA2dpPlaying(d) }
        }
        headset?.let { p ->
            m["hfp"] = safe { BtNames.connState(p.getConnectionState(d)) }
            m["hfpAudio"] = safe { p.isAudioConnected(d) }
        }
        return m
    }

    fun fetchUuids(address: String): Boolean {
        val ad = adapter ?: return false
        val d = safe { ad.getRemoteDevice(address) } ?: return false
        val ok = safe { d.fetchUuidsWithSdp() } ?: false
        EventStore.emit("app", "SDP_REQUEST", "Richiesta query SDP (servizi) → ${if (ok) "inviata" else "rifiutata"}", address, BtRecorder.safeName(d))
        return ok
    }

    /** Osserva gli eventi di un indirizzo durante un test, per capire in che fase si è fermato. */
    private class Watch(private val address: String) : EventStore.Listener {
        @Volatile var aclUp = false
        @Volatile var aclDownSummary: String? = null
        @Volatile var bondChange: String? = null
        @Volatile var pairing: String? = null
        @Volatile var uuidEvent = false
        @Volatile var uuids: List<String> = emptyList()

        override fun onEvent(event: Map<String, Any?>) {
            if ((event["address"] as? String)?.equals(address, ignoreCase = true) != true) return
            val summary = event["summary"] as? String ?: ""
            when (event["action"]) {
                "ACL_CONNECTED" -> aclUp = true
                "ACL_DISCONNECTED" -> aclDownSummary = summary
                "BOND_STATE_CHANGED" -> bondChange = summary
                "PAIRING_REQUEST" -> pairing = summary
                "UUID" -> {
                    uuidEvent = true
                    @Suppress("UNCHECKED_CAST")
                    val ex = event["extras"] as? Map<String, String>
                    uuids = ex?.get("uuids")?.split(',')?.filter { it.isNotBlank() } ?: emptyList()
                }
            }
        }

        fun start() = EventStore.addListener(this)
        fun stop() = EventStore.removeListener(this)
    }

    private fun isConnected(d: BluetoothDevice): Boolean =
        safe { d.javaClass.getMethod("isConnected").invoke(d) as? Boolean } ?: false

    /**
     * Ping di raggiungibilità Classic: la query SDP costringe il telefono a fare page
     * e aprire un link ACL. Se l'ACL si apre il dispositivo è raggiungibile,
     * indipendentemente dai servizi che espone.
     */
    fun probe(address: String, done: (Map<String, Any?>) -> Unit) {
        val ad = adapter
        val d = safe { ad?.getRemoteDevice(address) }
        if (ad == null || d == null) {
            done(mapOf("ok" to false, "verdict" to "Bluetooth non disponibile o indirizzo non valido"))
            return
        }
        val name = BtRecorder.safeName(d)
        val type = safe { d.type } ?: 0
        if (type == BluetoothDevice.DEVICE_TYPE_LE) {
            done(mapOf("ok" to false, "verdict" to "Dispositivo solo BLE: il ping Classic non si applica. Usa il test GATT."))
            return
        }
        val already = isConnected(d)
        val w = Watch(address)
        w.start()
        safe { ad.cancelDiscovery() }
        val t0 = System.currentTimeMillis()
        val sent = safe { d.fetchUuidsWithSdp() } ?: false
        EventStore.emit("app", "PROBE_START", "Ping SDP avviato${if (already) " (link già aperto)" else ""}", address, name)
        var finished = false
        fun finish() {
            if (finished) return
            finished = true
            w.stop()
            val ms = System.currentTimeMillis() - t0
            val reachable = w.aclUp || already
            val verdict = when {
                !sent -> "La richiesta SDP è stata rifiutata dallo stack (Bluetooth spento o permessi)."
                reachable && w.uuids.isNotEmpty() -> "Raggiungibile: link aperto e ${w.uuids.size} servizi letti via SDP."
                reachable -> "Raggiungibile (link ACL aperto) ma la lettura SDP non ha restituito servizi."
                else -> "Non raggiungibile: nessun link ACL in ${ms / 1000} s. Spento, fuori portata, non connettibile in Classic, o accetta connessioni solo dal dispositivo a cui è legato."
            }
            EventStore.emit("app", if (reachable) "PROBE_OK" else "PROBE_FAIL", "Ping: $verdict", address, name)
            done(mapOf("ok" to reachable, "ms" to ms, "verdict" to verdict, "uuids" to w.uuids, "aclUp" to w.aclUp, "already" to already))
        }
        // Finisce all'arrivo della risposta SDP (con un attimo di margine per l'evento ACL) o dopo 20 s.
        val poll = object : Runnable {
            override fun run() {
                if (finished) return
                if (w.uuidEvent) main.postDelayed({ finish() }, 700)
                else if (System.currentTimeMillis() - t0 > 20000) finish()
                else main.postDelayed(this, 250)
            }
        }
        main.postDelayed(poll, 250)
    }

    /**
     * Apre un socket RFCOMM verso un servizio del remoto: page → ACL → (autenticazione
     * con la link key se secure) → SDP del canale → RFCOMM. L'errore di Android è sempre
     * lo stesso IOException generico, quindi la fase si ricava dagli eventi osservati.
     */
    fun rfcommTest(address: String, uuid: String, secure: Boolean, done: (Map<String, Any?>) -> Unit) {
        val ad = adapter
        if (ad == null) {
            done(mapOf("ok" to false, "error" to "Bluetooth non disponibile"))
            return
        }
        Thread {
            val d = safe { ad.getRemoteDevice(address) }
            val name = d?.let { BtRecorder.safeName(it) }
            val mode = if (secure) "sicuro (autenticato+cifrato)" else "non sicuro"
            val w = Watch(address)
            w.start()
            val already = d?.let { isConnected(it) } ?: false
            val declared = (d?.let { dev -> safe { dev.uuids?.map { it.uuid.toString().lowercase() } } } ?: emptyList())
            EventStore.emit("app", "RFCOMM_TEST_START", "Test RFCOMM $mode verso servizio ${shortUuid(uuid)}", address, name)
            val t0 = System.currentTimeMillis()
            val result: Map<String, Any?> = try {
                if (d == null) throw IllegalArgumentException("indirizzo non valido")
                if (safe { d.type } == BluetoothDevice.DEVICE_TYPE_LE) {
                    throw IllegalStateException("dispositivo solo BLE: RFCOMM non esiste in Bluetooth LE")
                }
                safe { ad.cancelDiscovery() }
                val u = UUID.fromString(uuid)
                val socket = if (secure) d.createRfcommSocketToServiceRecord(u) else d.createInsecureRfcommSocketToServiceRecord(u)
                socket.use {
                    it.connect()
                    val ms = System.currentTimeMillis() - t0
                    EventStore.emit("app", "RFCOMM_TEST_OK", "Test RFCOMM riuscito in $ms ms: link, autenticazione e canale OK", address, name)
                    Thread.sleep(1500)
                    mapOf("ok" to true, "ms" to ms, "verdict" to "Riuscito: link aperto${if (secure) ", link key accettata" else ""} e canale RFCOMM stabilito.")
                }
            } catch (e: Throwable) {
                Thread.sleep(800) // lascia arrivare gli ultimi broadcast (ACL chiuso, bond)
                val ms = System.currentTimeMillis() - t0
                val msg = "${e.javaClass.simpleName}: ${e.message}"
                val linkOpened = w.aclUp || already
                val verdict = when {
                    e is IllegalStateException || e is IllegalArgumentException -> e.message ?: msg
                    w.pairing != null -> "Fase autenticazione: il dispositivo ha chiesto un nuovo pairing (${w.pairing}). La link key salvata non è stata accettata."
                    w.bondChange?.contains("→ NONE") == true -> "Fase autenticazione: il bond è stato cancellato (${w.bondChange})."
                    !linkOpened -> "Fase page: nessun link ACL. Il dispositivo non ha risposto (spento, fuori portata o non connettibile in Classic)."
                    declared.isNotEmpty() && uuid.lowercase() !in declared -> "Link aperto, ma il dispositivo non dichiara il servizio ${shortUuid(uuid)}: il canale RFCOMM non esiste."
                    else -> "Link aperto, ma il canale RFCOMM è stato rifiutato o chiuso dal dispositivo${w.aclDownSummary?.let { " ($it)" } ?: ""}. Tipico se il servizio è già occupato o accetta solo il suo client."
                }
                EventStore.emit("app", "RFCOMM_TEST_FAIL", "Test RFCOMM fallito dopo $ms ms — $verdict", address, name, mapOf("exception" to msg))
                mapOf("ok" to false, "ms" to ms, "error" to msg, "verdict" to verdict)
            } finally {
                w.stop()
            }
            main.post { done(result) }
        }.start()
    }

    private fun gattStatus(s: Int): String = when (s) {
        0 -> "SUCCESS"
        5 -> "INSUFFICIENT_AUTHENTICATION"
        8 -> "CONNECTION_TIMEOUT"
        15 -> "INSUFFICIENT_ENCRYPTION"
        19 -> "REMOTE_USER_TERMINATED"
        22 -> "LOCAL_HOST_TERMINATED"
        34 -> "LMP_RESPONSE_TIMEOUT"
        62 -> "FAILED_TO_ESTABLISH"
        133 -> "GATT_ERROR (generico: spesso dispositivo irraggiungibile o occupato)"
        147 -> "GATT_CONNECTION_TIMEOUT"
        257 -> "GATT_FAILURE"
        else -> "codice $s"
    }

    /** Test BLE: connessione GATT diretta e scoperta dei servizi. */
    fun gattTest(address: String, done: (Map<String, Any?>) -> Unit) {
        val ad = adapter
        val d = safe { ad?.getRemoteDevice(address) }
        if (ad == null || d == null) {
            done(mapOf("ok" to false, "verdict" to "Bluetooth non disponibile o indirizzo non valido"))
            return
        }
        val name = BtRecorder.safeName(d)
        val t0 = System.currentTimeMillis()
        var finished = false
        var gatt: BluetoothGatt? = null
        var connectedAt = 0L

        fun finish(ok: Boolean, verdict: String, services: List<String> = emptyList(), status: Int? = null) {
            main.post {
                if (finished) return@post
                finished = true
                safe { gatt?.disconnect() }
                safe { gatt?.close() }
                val ms = System.currentTimeMillis() - t0
                EventStore.emit("app", if (ok) "GATT_TEST_OK" else "GATT_TEST_FAIL", "Test GATT: $verdict", address, name,
                    mapOf("services" to services.joinToString(","), "status" to (status?.toString() ?: "")))
                done(mapOf("ok" to ok, "ms" to ms, "verdict" to verdict, "services" to services, "status" to status))
            }
        }

        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    connectedAt = System.currentTimeMillis()
                    EventStore.emit("app", "GATT_CONNECTED", "GATT connesso in ${connectedAt - t0} ms, scopro i servizi…", address, name)
                    if (safe { g.discoverServices() } != true) finish(true, "connesso, ma la scoperta servizi non è partita", status = status)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    val phase = if (connectedAt == 0L) "connessione" else "dopo la connessione"
                    finish(false, "disconnesso in fase $phase: ${gattStatus(status)}", status = status)
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val services = safe { g.services.map { it.uuid.toString() } } ?: emptyList()
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    finish(true, "raggiungibile, ${services.size} servizi GATT", services, status)
                } else {
                    finish(false, "connesso ma scoperta servizi fallita: ${gattStatus(status)}", services, status)
                }
            }
        }
        EventStore.emit("app", "GATT_TEST_START", "Test GATT (BLE) avviato", address, name)
        safe { ad.cancelDiscovery() }
        gatt = try {
            if (Build.VERSION.SDK_INT >= 23) d.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE) else d.connectGatt(ctx, false, cb)
        } catch (e: SecurityException) {
            finish(false, "permesso mancante: ${e.message}")
            null
        }
        if (gatt == null && !finished) finish(false, "connectGatt ha restituito null")
        main.postDelayed({
            if (!finished) finish(false, "nessuna risposta in 25 s: dispositivo spento, fuori portata, già connesso alla sua app o non accetta connessioni")
        }, 25000)
    }

    private fun shortUuid(u: String): String =
        if (u.lowercase().endsWith("-0000-1000-8000-00805f9b34fb")) "0x" + u.substring(4, 8).uppercase() else u

    fun startDiscovery(): Boolean = safe { adapter?.startDiscovery() } ?: false
    fun cancelDiscovery(): Boolean = safe { adapter?.cancelDiscovery() } ?: false

    /** Proprietà di sistema leggibili che riguardano il Bluetooth (versioni AVRCP/MAP, snoop log...). */
    fun systemProps(): List<String> {
        val out = mutableListOf<String>()
        try {
            val p = Runtime.getRuntime().exec(arrayOf("getprop"))
            p.inputStream.bufferedReader().useLines { lines ->
                lines.filter { l ->
                    val low = l.lowercase()
                    low.contains("bluetooth") || low.contains("[bt.") || low.contains(".bt.") || low.contains("a2dp") ||
                        low.contains("avrcp") || low.contains("snoop") || low.contains("hfp")
                }.forEach { out.add(it) }
            }
            p.waitFor()
        } catch (e: Exception) {
            out.add("getprop non disponibile: ${e.message}")
        }
        return out
    }

    private const val PREFS = "bt_debugger"

    fun setTarget(address: String?, name: String?) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("target_address", address)
            .putString("target_name", name)
            .apply()
    }

    fun getTarget(): Map<String, Any?> {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return mapOf("address" to p.getString("target_address", null), "name" to p.getString("target_name", null))
    }

    /** Dispositivi "miei" con nickname: JSON gestito da Flutter, qui solo persistito. */
    fun getKnownDevices(): String =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("known_devices", "[]") ?: "[]"

    fun saveKnownDevices(json: String) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("known_devices", json).apply()
    }
}
