package it.lucapaganin.bt_debugger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Riavvia la riconnessione automatica dopo un riavvio del telefono o un aggiornamento dell'app. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                AutoConnect.init(context)
                if (!AutoConnect.isEnabled()) return
                try {
                    AutoConnectService.start(context)
                } catch (e: Exception) {
                    EventStore.emit("auto", "AUTO_SERVICE_ERROR", "Riavvio automatico non riuscito: ${e.message}")
                }
            }
        }
    }
}
