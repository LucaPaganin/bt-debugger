package it.lucapaganin.bt_debugger

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var eventListener: EventStore.Listener? = null
    private var recorderAcquired = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventStore.init(this)
        BtBridge.init(this)
        AutoConnect.init(this)
        if (!recorderAcquired) {
            BtRecorder.acquire(this)
            recorderAcquired = true
        }

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "bt_debugger/methods").setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: SecurityException) {
                result.error("PERMISSION", "Permesso Bluetooth mancante: ${e.message}", null)
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }

        EventChannel(messenger, "bt_debugger/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l = EventStore.Listener { ev -> events.success(ev) }
                eventListener = l
                EventStore.addListener(l)
            }

            override fun onCancel(arguments: Any?) {
                eventListener?.let { EventStore.removeListener(it) }
                eventListener = null
            }
        })
    }

    override fun onDestroy() {
        BleScanner.stop()
        eventListener?.let { EventStore.removeListener(it) }
        eventListener = null
        if (recorderAcquired) {
            BtRecorder.release()
            recorderAcquired = false
        }
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestBtPermissions(result)
            "checkPermissions" -> result.success(permissionStatus())
            "getAdapterInfo" -> result.success(BtBridge.adapterInfo())
            "getBondedDevices" -> result.success(BtBridge.bondedDevices())
            "getDevice" -> result.success(BtBridge.device(call.argument<String>("address")!!))
            "fetchUuids" -> result.success(BtBridge.fetchUuids(call.argument<String>("address")!!))
            "rfcommTest" -> BtBridge.rfcommTest(
                call.argument<String>("address")!!,
                call.argument<String>("uuid")!!,
                call.argument<Boolean>("secure") ?: true,
            ) { result.success(it) }
            "probe" -> BtBridge.probe(call.argument<String>("address")!!) { result.success(it) }
            "gattTest" -> BtBridge.gattTest(call.argument<String>("address")!!) { result.success(it) }
            "startDiscovery" -> result.success(BtBridge.startDiscovery())
            "cancelDiscovery" -> result.success(BtBridge.cancelDiscovery())
            "startLeScan" -> result.success(BleScanner.start())
            "stopLeScan" -> result.success(BleScanner.stop())
            "isLeScanning" -> result.success(BleScanner.running)
            "getKnownDevices" -> result.success(BtBridge.getKnownDevices())
            "saveKnownDevices" -> {
                BtBridge.saveKnownDevices(call.argument<String>("json") ?: "[]")
                result.success(true)
            }
            "startMonitor" -> {
                BtMonitorService.start(this)
                result.success(true)
            }
            "stopMonitor" -> {
                BtMonitorService.stop(this)
                result.success(true)
            }
            "isMonitorRunning" -> result.success(BtMonitorService.running)
            "getAutoConnect" -> result.success(AutoConnect.status())
            "setAutoConnect" -> {
                val on = call.argument<Boolean>("enabled") ?: false
                AutoConnect.setEnabled(on)
                if (on) AutoConnectService.start(this) else AutoConnectService.stop(this)
                result.success(AutoConnect.status())
            }
            "autoConnectNow" -> {
                AutoConnect.startWindow("prova manuale", AutoConnect.WINDOW_MANUAL_MS, manual = true)
                result.success(true)
            }
            "getEvents" -> result.success(EventStore.all())
            "clearEvents" -> {
                EventStore.clear()
                result.success(true)
            }
            "addNote" -> {
                EventStore.emit("note", "NOTE", call.argument<String>("text") ?: "")
                result.success(true)
            }
            "setTarget" -> {
                BtBridge.setTarget(call.argument<String>("address"), call.argument<String>("name"))
                result.success(true)
            }
            "getTarget" -> result.success(BtBridge.getTarget())
            "getSystemProps" -> result.success(BtBridge.systemProps())
            "openSettings" -> result.success(openSettings(call.argument<String>("kind") ?: "bluetooth"))
            "saveToDownloads" -> result.success(
                saveToDownloads(call.argument<String>("fileName")!!, call.argument<String>("content")!!),
            )
            "shareText" -> {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "BT Debugger log")
                    putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                }
                startActivity(Intent.createChooser(send, "Condividi log"))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun neededPermissions(): List<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            list.add(Manifest.permission.BLUETOOTH_CONNECT)
            list.add(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            list.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= 33) list.add(Manifest.permission.POST_NOTIFICATIONS)
        return list
    }

    private fun permissionStatus(): Map<String, Boolean> =
        neededPermissions().associate {
            it.substringAfterLast('.') to (checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED)
        }

    private fun requestBtPermissions(result: MethodChannel.Result) {
        val missing = neededPermissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(permissionStatus())
            return
        }
        pendingPermissionResult?.success(permissionStatus())
        pendingPermissionResult = result
        requestPermissions(missing.toTypedArray(), 42)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 42) {
            BtBridge.ensureProxies()
            pendingPermissionResult?.success(permissionStatus())
            pendingPermissionResult = null
        }
    }

    private fun openSettings(kind: String): Boolean {
        val intent = when (kind) {
            "developer" -> Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            "app" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            else -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Salva il log in Download/ (MediaStore, nessun permesso necessario da Android 10). */
    private fun saveToDownloads(fileName: String, content: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore non disponibile")
            contentResolver.openOutputStream(uri)?.use { it.write(content.toByteArray()) }
            return "Download/$fileName"
        }
        val dir = getExternalFilesDir(null) ?: filesDir
        val f = File(dir, fileName)
        f.writeText(content)
        return f.absolutePath
    }
}
