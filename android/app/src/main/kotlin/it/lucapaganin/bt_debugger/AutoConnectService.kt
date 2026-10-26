package it.lucapaganin.bt_debugger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Foreground service sempre attivo (finché la funzione è accesa) che ascolta i trigger
 * e apre le finestre di riconnessione in [AutoConnect]:
 *  - Wi-Fi perso (esci di casa o dall'ufficio): 20 minuti, copre il tragitto fino all'auto;
 *  - telefono messo in carica: 10 minuti;
 *  - la radio apre un link verso il telefono (tentativo suo, che di solito fallisce): 3 minuti;
 *  - Bluetooth riacceso: 3 minuti.
 */
class AutoConnectService : Service() {
    companion object {
        @Volatile
        var running = false
        private const val CHANNEL = "auto_connect"
        private const val NOTIF_ID = 1002

        fun start(context: Context) {
            val i = Intent(context, AutoConnectService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AutoConnectService::class.java))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var cm: ConnectivityManager? = null
    private val wifiNetworks = mutableSetOf<Network>()

    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            main.post { wifiNetworks.add(network) }
        }

        override fun onLost(network: Network) {
            main.post {
                if (wifiNetworks.remove(network) && wifiNetworks.isEmpty()) {
                    AutoConnect.startWindow("Wi-Fi perso", AutoConnect.WINDOW_WIFI_MS)
                }
            }
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_POWER_CONNECTED ->
                    AutoConnect.startWindow("telefono in carica", AutoConnect.WINDOW_CHARGE_MS)
                BluetoothAdapter.ACTION_STATE_CHANGED ->
                    if (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_ON) {
                        AutoConnect.startWindow("Bluetooth riacceso", AutoConnect.WINDOW_RADIO_MS, firstDelayMs = 5_000)
                    }
                BluetoothDevice.ACTION_ACL_CONNECTED ->
                    if (AutoConnect.isTarget(deviceAddress(intent))) {
                        // Lascia alla radio qualche secondo: se ce la fa da sola, la finestra si chiude al primo controllo.
                        AutoConnect.startWindow("la radio si è fatta viva", AutoConnect.WINDOW_RADIO_MS, firstDelayMs = 10_000)
                    }
                BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED, BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED ->
                    if (AutoConnect.isTarget(deviceAddress(intent))) AutoConnect.onProfileChanged()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun deviceAddress(intent: Intent): String? = try {
        val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
        d?.address
    } catch (_: Throwable) {
        null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AutoConnect.init(this)
        createChannel()
        try {
            val n = build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            EventStore.emit("auto", "AUTO_SERVICE_ERROR", "Impossibile avviare la riconnessione automatica: ${e.message}")
            stopSelf()
            return
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }

        try {
            val c = getSystemService(ConnectivityManager::class.java)
            val req = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
            if (Build.VERSION.SDK_INT >= 26) c.registerNetworkCallback(req, netCallback, main) else c.registerNetworkCallback(req, netCallback)
            cm = c
        } catch (e: Exception) {
            EventStore.emit("auto", "AUTO_WIFI_ERROR", "Trigger Wi-Fi non disponibile: ${e.message}")
        }

        running = true
        EventStore.emit("auto", "AUTO_SERVICE_START", "Riconnessione automatica attiva")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        if (running) {
            try {
                unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            try {
                cm?.unregisterNetworkCallback(netCallback)
            } catch (_: Exception) {
            }
            AutoConnect.cancelWindow("riconnessione automatica spenta")
            running = false
            EventStore.emit("auto", "AUTO_SERVICE_STOP", "Riconnessione automatica spenta")
        }
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Riconnessione automatica", NotificationManager.IMPORTANCE_MIN)
            ch.description = "Notifica persistente richiesta da Android per restare attivi in background"
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun build(): Notification {
        val open = PendingIntent.getActivity(
            this, 1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Riconnessione automatica attiva")
            .setContentText("Quando esci di casa o metti in carica, il telefono chiama la radio")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}
