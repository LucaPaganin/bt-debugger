package it.lucapaganin.bt_debugger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Foreground service che tiene registrati i receiver Bluetooth anche con l'app
 * chiusa: si avvia prima di salire in macchina e registra cosa succede
 * all'accensione dell'autoradio.
 */
class BtMonitorService : Service() {
    companion object {
        @Volatile
        var running = false
        private const val CHANNEL = "bt_monitor"
        private const val NOTIF_ID = 1001

        fun start(context: Context) {
            val i = Intent(context, BtMonitorService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BtMonitorService::class.java))
        }
    }

    private var count = 0
    private val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.ITALY)
    private val listener = EventStore.Listener { ev ->
        if (ev["persist"] == true && ev["cat"] != "app") {
            count += 1
            val ts = (ev["ts"] as? Long) ?: System.currentTimeMillis()
            notify("$count eventi · ultimo ${timeFmt.format(Date(ts))}", ev["summary"] as? String ?: "")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        EventStore.init(this)
        BtBridge.init(this)
        createChannel()
        try {
            val n = build("Monitor Bluetooth attivo", "In ascolto degli eventi Bluetooth…")
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            EventStore.emit("app", "MONITOR_ERROR", "Impossibile avviare il monitor: ${e.message}")
            stopSelf()
            return
        }
        BtRecorder.acquire(this)
        EventStore.addListener(listener)
        running = true
        EventStore.emit("app", "MONITOR_START", "Monitor in background avviato")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        if (running) {
            EventStore.removeListener(listener)
            BtRecorder.release()
            running = false
            EventStore.emit("app", "MONITOR_STOP", "Monitor in background fermato")
        }
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Monitor Bluetooth", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Notifica persistente mentre il monitor registra gli eventi"
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun build(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }

    private fun notify(title: String, text: String) {
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, build(title, text))
        } catch (_: Exception) {
        }
    }
}
