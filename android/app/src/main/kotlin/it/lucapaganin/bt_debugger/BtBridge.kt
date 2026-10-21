package it.lucapaganin.bt_debugger

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
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

    /**
     * Apre un socket RFCOMM verso un servizio del remoto. Forza: page → ACL →
     * autenticazione con la link key salvata (se secure) → canale RFCOMM.
     * Se la link key non è più valida qui si vede il fallimento.
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
            EventStore.emit("app", "RFCOMM_TEST_START", "Test RFCOMM $mode verso servizio ${shortUuid(uuid)}", address, name)
            val t0 = System.currentTimeMillis()
            val result: Map<String, Any?> = try {
                if (d == null) throw IllegalArgumentException("indirizzo non valido")
                safe { ad.cancelDiscovery() }
                val u = UUID.fromString(uuid)
                val socket = if (secure) d.createRfcommSocketToServiceRecord(u) else d.createInsecureRfcommSocketToServiceRecord(u)
                socket.use {
                    it.connect()
                    val ms = System.currentTimeMillis() - t0
                    EventStore.emit("app", "RFCOMM_TEST_OK", "Test RFCOMM riuscito in $ms ms: il link si apre e l'autenticazione passa", address, name)
                    Thread.sleep(1500)
                    mapOf("ok" to true, "ms" to ms)
                }
            } catch (e: Throwable) {
                val ms = System.currentTimeMillis() - t0
                val msg = "${e.javaClass.simpleName}: ${e.message}"
                EventStore.emit("app", "RFCOMM_TEST_FAIL", "Test RFCOMM fallito dopo $ms ms — $msg", address, name)
                mapOf("ok" to false, "ms" to ms, "error" to msg)
            }
            main.post { done(result) }
        }.start()
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
}
