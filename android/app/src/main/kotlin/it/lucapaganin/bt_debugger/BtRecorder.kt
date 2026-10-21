package it.lucapaganin.bt_debugger

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.ParcelUuid
import android.os.Parcelable

/**
 * Ascolta tutti i broadcast Bluetooth utili alla diagnosi e li scrive in [EventStore].
 * Registrato con reference counting: lo tengono vivo sia l'Activity aperta sia il
 * foreground service del monitor.
 */
object BtRecorder {
    private var refCount = 0
    private var appContext: Context? = null

    // Azioni nascoste (non nell'SDK pubblico): se lo stack le invia, le registriamo.
    private const val A2DP_CODEC_CHANGED = "android.bluetooth.a2dp.profile.action.CODEC_CONFIG_CHANGED"
    private const val A2DP_ACTIVE_DEVICE = "android.bluetooth.a2dp.profile.action.ACTIVE_DEVICE_CHANGED"
    private const val HFP_ACTIVE_DEVICE = "android.bluetooth.headset.profile.action.ACTIVE_DEVICE_CHANGED"
    private const val PBAP_STATE = "android.bluetooth.pbap.profile.action.CONNECTION_STATE_CHANGED"
    private const val MAP_STATE = "android.bluetooth.map.profile.action.CONNECTION_STATE_CHANGED"
    private const val KEY_MISSING = "android.bluetooth.device.action.KEY_MISSING"
    private const val ENCRYPTION_CHANGE = "android.bluetooth.device.action.ENCRYPTION_CHANGE"
    private const val ACCESS_REQUEST = "android.bluetooth.device.action.CONNECTION_ACCESS_REQUEST"
    private const val ACCESS_REPLY = "android.bluetooth.device.action.CONNECTION_ACCESS_REPLY"
    private const val ACCESS_CANCEL = "android.bluetooth.device.action.CONNECTION_ACCESS_CANCEL"
    private const val SDP_RECORD = "android.bluetooth.device.action.SDP_RECORD"
    private const val BATTERY_LEVEL = "android.bluetooth.device.action.BATTERY_LEVEL_CHANGED"
    private const val EXTRA_REASON = "android.bluetooth.device.extra.REASON"
    private const val EXTRA_TRANSPORT = "android.bluetooth.device.extra.TRANSPORT"
    // Extra proprietari Samsung (One UI): motivo HCI della disconnessione e funzioni HFP del remoto.
    private const val SEC_DISC_REASON = "com.samsung.bluetooth.device.extra.DISCONNECTION_REASON"
    private const val SEC_HF_FEATURES = "com.samsung.bt.hfp.intent.extra.HF_SUPPORTED_FEATURE"
    private const val HFP_DISC_REASON = "android.bluetooth.headset.extra.DISCONNECTED_REASON"
    private const val A2DP_DISC_REASON = "android.bluetooth.a2dp.extra.DISCONNECTED_REASON"

    private val actions = listOf(
        BluetoothAdapter.ACTION_STATE_CHANGED,
        BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED,
        BluetoothAdapter.ACTION_SCAN_MODE_CHANGED,
        BluetoothAdapter.ACTION_DISCOVERY_STARTED,
        BluetoothAdapter.ACTION_DISCOVERY_FINISHED,
        BluetoothDevice.ACTION_ACL_CONNECTED,
        BluetoothDevice.ACTION_ACL_DISCONNECTED,
        BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED,
        BluetoothDevice.ACTION_BOND_STATE_CHANGED,
        BluetoothDevice.ACTION_PAIRING_REQUEST,
        BluetoothDevice.ACTION_UUID,
        BluetoothDevice.ACTION_NAME_CHANGED,
        BluetoothDevice.ACTION_CLASS_CHANGED,
        BluetoothDevice.ACTION_FOUND,
        "android.bluetooth.device.action.ALIAS_CHANGED",
        BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED,
        BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED,
        BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED,
        BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED,
        A2DP_CODEC_CHANGED, A2DP_ACTIVE_DEVICE, HFP_ACTIVE_DEVICE,
        PBAP_STATE, MAP_STATE, KEY_MISSING, ENCRYPTION_CHANGE,
        ACCESS_REQUEST, ACCESS_REPLY, ACCESS_CANCEL, SDP_RECORD, BATTERY_LEVEL,
    )

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            try {
                handle(intent)
            } catch (e: Exception) {
                EventStore.emit("app", "RECORDER_ERROR", "Errore nel decodificare ${intent.action}: ${e.message}")
            }
        }
    }

    @Synchronized
    fun acquire(context: Context) {
        refCount += 1
        if (refCount > 1) return
        val ctx = context.applicationContext
        appContext = ctx
        val filter = IntentFilter()
        actions.forEach { filter.addAction(it) }
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            ctx.registerReceiver(receiver, filter)
        }
    }

    @Synchronized
    fun release() {
        if (refCount == 0) return
        refCount -= 1
        if (refCount > 0) return
        try {
            appContext?.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        appContext = null
    }

    private fun handle(intent: Intent) {
        val action = intent.action ?: return
        val device = deviceFrom(intent)
        val address = device?.address
        val name = device?.let { safeName(it) }
        val extras = dumpExtras(intent.extras)
        val short = action.substringAfterLast('.')

        fun int(key: String, def: Int = Int.MIN_VALUE) = intent.getIntExtra(key, def)
        fun has(key: String) = intent.hasExtra(key)

        when (action) {
            BluetoothAdapter.ACTION_STATE_CHANGED -> EventStore.emit(
                "adapter", short,
                "Bluetooth del telefono: ${BtNames.adapterState(int(BluetoothAdapter.EXTRA_PREVIOUS_STATE))} → ${BtNames.adapterState(int(BluetoothAdapter.EXTRA_STATE))}",
                extras = extras,
            )
            BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED -> EventStore.emit(
                "adapter", short,
                "Stato connessione adapter: ${BtNames.connState(int(BluetoothAdapter.EXTRA_PREVIOUS_CONNECTION_STATE))} → ${BtNames.connState(int(BluetoothAdapter.EXTRA_CONNECTION_STATE))}",
                address, name, extras,
            )
            BluetoothAdapter.ACTION_SCAN_MODE_CHANGED -> EventStore.emit(
                "adapter", short,
                "Modalità scan telefono: ${BtNames.scanMode(int(BluetoothAdapter.EXTRA_SCAN_MODE))}",
                extras = extras,
            )
            BluetoothAdapter.ACTION_DISCOVERY_STARTED -> EventStore.emit("scan", short, "Scansione avviata", persist = false)
            BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> EventStore.emit("scan", short, "Scansione terminata", persist = false)

            BluetoothDevice.ACTION_FOUND -> {
                val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE)
                val cls = parcelable(intent, BluetoothDevice.EXTRA_CLASS, BluetoothClass::class.java)
                val ex = extras.toMutableMap()
                if (rssi != Short.MIN_VALUE) ex["rssi"] = rssi.toString()
                if (cls != null) {
                    ex["cod"] = cls.hashCode().toString()
                    ex["major"] = cls.majorDeviceClass.toString()
                    ex["deviceClass"] = cls.deviceClass.toString()
                }
                ex["type"] = device?.let { safeType(it) }?.toString() ?: ""
                ex["bond"] = device?.bondState?.toString() ?: ""
                EventStore.emit("scan", short, "Trovato ${name ?: address}", address, name, ex, persist = false)
            }

            BluetoothDevice.ACTION_ACL_CONNECTED -> {
                val tr = if (has(EXTRA_TRANSPORT)) " via ${BtNames.transport(int(EXTRA_TRANSPORT))}" else ""
                EventStore.emit("acl", short, "Link ACL STABILITO$tr", address, name, extras)
            }
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                val tr = if (has(EXTRA_TRANSPORT)) " via ${BtNames.transport(int(EXTRA_TRANSPORT))}" else ""
                val reason = when {
                    has(SEC_DISC_REASON) -> {
                        val r = int(SEC_DISC_REASON)
                        " — motivo HCI 0x%02X %s".format(r, BtNames.hciError(r) ?: "")
                    }
                    has(EXTRA_REASON) -> {
                        val r = int(EXTRA_REASON)
                        val hci = BtNames.hciError(r)
                        " — reason=$r" + (if (hci != null) " (se codice HCI: $hci)" else "")
                    }
                    else -> ""
                }
                EventStore.emit("acl", short, "Link ACL CHIUSO$tr$reason", address, name, extras)
            }
            BluetoothDevice.ACTION_ACL_DISCONNECT_REQUESTED -> EventStore.emit(
                "acl", short, "Richiesta di disconnessione ACL", address, name, extras,
            )

            BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                val prev = BtNames.bondState(int(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE))
                val now = BtNames.bondState(int(BluetoothDevice.EXTRA_BOND_STATE))
                val reason = if (has(EXTRA_REASON)) " — motivo: ${BtNames.unbondReason(int(EXTRA_REASON))}" else ""
                EventStore.emit("bond", short, "Bond: $prev → $now$reason", address, name, extras)
            }
            BluetoothDevice.ACTION_PAIRING_REQUEST -> {
                val v = int(BluetoothDevice.EXTRA_PAIRING_VARIANT)
                val key = if (has(BluetoothDevice.EXTRA_PAIRING_KEY)) " — chiave ${int(BluetoothDevice.EXTRA_PAIRING_KEY)}" else ""
                EventStore.emit("pairing", short, "Richiesta di pairing: ${BtNames.pairingVariant(v)}$key", address, name, extras)
            }
            BluetoothDevice.ACTION_UUID -> {
                val arr = parcelableArray(intent, BluetoothDevice.EXTRA_UUID)
                val uuids = arr?.mapNotNull { (it as? ParcelUuid)?.uuid?.toString() } ?: emptyList()
                val ex = extras.toMutableMap()
                ex["uuids"] = uuids.joinToString(",")
                EventStore.emit(
                    "sdp", short,
                    if (uuids.isEmpty()) "Risposta SDP: nessun servizio (remoto non raggiungibile o cache vuota)"
                    else "Risposta SDP: ${uuids.size} servizi",
                    address, name, ex,
                )
            }
            BluetoothDevice.ACTION_NAME_CHANGED -> EventStore.emit("device", short, "Nome remoto: ${intent.getStringExtra(BluetoothDevice.EXTRA_NAME)}", address, name, extras)
            BluetoothDevice.ACTION_CLASS_CHANGED -> EventStore.emit("device", short, "Class of Device aggiornata", address, name, extras)

            BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED -> {
                val why = if (has(A2DP_DISC_REASON) && int(A2DP_DISC_REASON) != 0) " (motivo ${int(A2DP_DISC_REASON)})" else ""
                EventStore.emit(
                    "a2dp", short,
                    "A2DP (audio): ${BtNames.connState(int(BluetoothA2dp.EXTRA_PREVIOUS_STATE))} → ${BtNames.connState(int(BluetoothA2dp.EXTRA_STATE))}$why",
                    address, name, extras,
                )
            }
            BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED -> EventStore.emit(
                "a2dp", short, "A2DP streaming: ${BtNames.a2dpPlaying(int(BluetoothA2dp.EXTRA_STATE))}", address, name, extras,
            )
            BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED -> {
                val why = if (has(HFP_DISC_REASON) && int(HFP_DISC_REASON) != 0) " (motivo ${int(HFP_DISC_REASON)})" else ""
                val feat = if (has(SEC_HF_FEATURES)) " · " + BtNames.hfFeatures(int(SEC_HF_FEATURES)) else ""
                EventStore.emit(
                    "hfp", short,
                    "HFP (vivavoce): ${BtNames.connState(int(BluetoothHeadset.EXTRA_PREVIOUS_STATE))} → ${BtNames.connState(int(BluetoothHeadset.EXTRA_STATE))}$why$feat",
                    address, name, extras,
                )
            }
            BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED -> EventStore.emit(
                "hfp", short, "HFP audio (SCO): ${BtNames.headsetAudio(int(BluetoothHeadset.EXTRA_STATE))}", address, name, extras,
            )
            A2DP_CODEC_CHANGED -> EventStore.emit("a2dp", short, "Codec A2DP cambiato", address, name, extras)
            A2DP_ACTIVE_DEVICE -> EventStore.emit("a2dp", short, "Dispositivo audio attivo: ${name ?: address ?: "nessuno"}", address, name, extras)
            HFP_ACTIVE_DEVICE -> EventStore.emit("hfp", short, "Dispositivo vivavoce attivo: ${name ?: address ?: "nessuno"}", address, name, extras)
            PBAP_STATE -> EventStore.emit(
                "pbap", short,
                "PBAP (rubrica): ${BtNames.connState(int("android.bluetooth.profile.extra.PREVIOUS_STATE"))} → ${BtNames.connState(int("android.bluetooth.profile.extra.STATE"))}",
                address, name, extras,
            )
            MAP_STATE -> EventStore.emit(
                "map", short,
                "MAP (messaggi): ${BtNames.connState(int("android.bluetooth.profile.extra.PREVIOUS_STATE"))} → ${BtNames.connState(int("android.bluetooth.profile.extra.STATE"))}",
                address, name, extras,
            )
            KEY_MISSING -> EventStore.emit("security", short, "Il remoto non ha più la link key (KEY MISSING)", address, name, extras)
            ENCRYPTION_CHANGE -> {
                val on = intent.getBooleanExtra("android.bluetooth.device.extra.ENCRYPTION_ENABLED", false)
                val size = int("android.bluetooth.device.extra.KEY_SIZE")
                val alg = when (int("android.bluetooth.device.extra.EXTRA_ENCRYPTION_ALGORITHM")) {
                    1 -> "E0 (legacy, senza Secure Connections)"
                    2 -> "AES-CCM (Secure Connections)"
                    else -> "algoritmo ?"
                }
                EventStore.emit(
                    "security", short,
                    if (on) "Cifratura ATTIVA: chiave ${size} byte, $alg" else "Cifratura DISATTIVATA",
                    address, name, extras,
                )
            }
            ACCESS_REQUEST, ACCESS_REPLY, ACCESS_CANCEL -> EventStore.emit(
                "security", short, "Richiesta accesso profilo (rubrica/messaggi/SIM): $short", address, name, extras,
            )
            SDP_RECORD -> EventStore.emit("sdp", short, "Record SDP ricevuto", address, name, extras)
            BATTERY_LEVEL -> EventStore.emit("device", short, "Livello batteria remoto: ${int("android.bluetooth.device.extra.BATTERY_LEVEL")}", address, name, extras)
            else -> EventStore.emit("other", short, action, address, name, extras)
        }
    }

    fun safeName(d: BluetoothDevice): String? = try {
        if (Build.VERSION.SDK_INT >= 30) d.alias ?: d.name else d.name
    } catch (_: SecurityException) {
        null
    }

    fun safeType(d: BluetoothDevice): Int? = try {
        d.type
    } catch (_: SecurityException) {
        null
    }

    private fun deviceFrom(intent: Intent): BluetoothDevice? =
        parcelable(intent, BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)

    @Suppress("DEPRECATION")
    private fun <T : Parcelable> parcelable(intent: Intent, key: String, cls: Class<T>): T? = try {
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(key, cls)
        else intent.getParcelableExtra(key)
    } catch (_: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun parcelableArray(intent: Intent, key: String): Array<out Parcelable>? = try {
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayExtra(key, Parcelable::class.java)
        else intent.getParcelableArrayExtra(key)
    } catch (_: Exception) {
        null
    }

    /** Dump grezzo di tutti gli extra: così vediamo anche quelli nascosti non documentati. */
    @Suppress("DEPRECATION")
    private fun dumpExtras(b: Bundle?): Map<String, String> {
        if (b == null) return emptyMap()
        val out = linkedMapOf<String, String>()
        val keys = try {
            b.keySet().toList()
        } catch (_: Exception) {
            return mapOf("_error" to "extras non leggibili")
        }
        for (k in keys) {
            if (k == BluetoothDevice.EXTRA_DEVICE) continue
            out[k.removePrefix("android.bluetooth.")] = try {
                when (val v = b.get(k)) {
                    null -> "null"
                    is BluetoothDevice -> v.address
                    is Array<*> -> v.joinToString(",") { it.toString() }
                    is IntArray -> v.joinToString(",")
                    is ByteArray -> v.joinToString(" ") { "%02X".format(it) }
                    else -> v.toString()
                }
            } catch (e: Exception) {
                "<${e.javaClass.simpleName}>"
            }
        }
        return out
    }
}
