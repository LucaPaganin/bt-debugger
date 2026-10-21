package it.lucapaganin.bt_debugger

import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.Build
import android.os.SystemClock

/**
 * Scansione BLE passiva: legge gli advertising dei dispositivi vicini (nome, RSSI,
 * produttore, servizi) senza connettersi. I risultati passano da [EventStore] come
 * eventi "scan" non persistiti, con al più un aggiornamento al secondo per indirizzo.
 */
object BleScanner {
    private var callback: ScanCallback? = null
    private val lastEmit = HashMap<String, Long>()

    val running: Boolean get() = callback != null

    fun start(): Boolean {
        if (callback != null) return true
        val scanner = try {
            BtBridge.adapter?.bluetoothLeScanner
        } catch (_: Throwable) {
            null
        } ?: return false
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = report(result)

            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { report(it) }

            override fun onScanFailed(errorCode: Int) {
                callback = null
                EventStore.emit("scan", "LE_SCAN_FAILED", "Scansione BLE fallita: ${failName(errorCode)}", persist = false)
            }
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        return try {
            synchronized(lastEmit) { lastEmit.clear() }
            scanner.startScan(null, settings, cb)
            callback = cb
            EventStore.emit("scan", "LE_SCAN_STARTED", "Scansione BLE avviata", persist = false)
            true
        } catch (e: Throwable) {
            EventStore.emit("scan", "LE_SCAN_FAILED", "Scansione BLE non avviata: ${e.message}", persist = false)
            false
        }
    }

    fun stop(): Boolean {
        val cb = callback ?: return true
        callback = null
        try {
            BtBridge.adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Throwable) {
        }
        EventStore.emit("scan", "LE_SCAN_STOPPED", "Scansione BLE fermata", persist = false)
        return true
    }

    private fun report(r: ScanResult) {
        val d = r.device ?: return
        val address = d.address ?: return
        val now = SystemClock.elapsedRealtime()
        synchronized(lastEmit) {
            val last = lastEmit[address]
            if (last != null && now - last < 1000) return
            lastEmit[address] = now
        }
        val rec = r.scanRecord
        val ex = linkedMapOf<String, String>()
        ex["rssi"] = r.rssi.toString()
        ex["transport"] = "le"
        if (Build.VERSION.SDK_INT >= 26) {
            ex["connectable"] = r.isConnectable.toString()
            if (r.txPower != ScanResult.TX_POWER_NOT_PRESENT) ex["txPower"] = r.txPower.toString()
        }
        addressType(d)?.let { ex["addrType"] = it.toString() }
        BtRecorder.safeType(d)?.let { ex["type"] = it.toString() }
        try {
            ex["bond"] = d.bondState.toString()
        } catch (_: Throwable) {
        }
        if (rec != null) {
            rec.deviceName?.let { ex["advName"] = it }
            val mfr = rec.manufacturerSpecificData
            if (mfr != null && mfr.size() > 0) {
                ex["mfr"] = (0 until mfr.size()).joinToString(",") { i ->
                    "%04X:%s".format(mfr.keyAt(i), hex(mfr.valueAt(i)))
                }
            }
            rec.serviceUuids?.let { list ->
                if (list.isNotEmpty()) ex["svc"] = list.joinToString(",") { it.uuid.toString() }
            }
            rec.serviceData?.let { map ->
                if (map.isNotEmpty()) ex["svcData"] = map.entries.joinToString(",") { (k, v) -> "${k.uuid}:${hex(v)}" }
            }
        }
        val name = rec?.deviceName ?: BtRecorder.safeName(d)
        EventStore.emit("scan", "LE_FOUND", "BLE ${name ?: address}", address, name, ex, persist = false)
    }

    /** 0 = pubblico, 1 = random (API 35+, letta per riflessione per non dipendere dal compileSdk). */
    private fun addressType(d: BluetoothDevice): Int? = try {
        if (Build.VERSION.SDK_INT >= 35) d.javaClass.getMethod("getAddressType").invoke(d) as? Int else null
    } catch (_: Throwable) {
        null
    }

    private fun hex(b: ByteArray?): String {
        if (b == null) return ""
        val n = minOf(b.size, 24)
        val sb = StringBuilder(n * 2)
        for (i in 0 until n) sb.append("%02X".format(b[i]))
        return sb.toString()
    }

    private fun failName(code: Int): String = when (code) {
        1 -> "già in corso"
        2 -> "registrazione dell'app fallita (troppe scansioni ravvicinate? Android ne consente 5 ogni 30 s)"
        3 -> "errore interno"
        4 -> "funzione non supportata"
        5 -> "risorse hardware esaurite"
        6 -> "scansioni troppo frequenti"
        else -> "codice $code"
    }
}
