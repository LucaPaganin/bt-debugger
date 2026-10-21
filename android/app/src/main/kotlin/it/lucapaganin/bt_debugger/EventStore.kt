package it.lucapaganin.bt_debugger

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * Registro eventi condiviso tra Activity e foreground service (stesso processo).
 * Tiene in memoria gli ultimi MAX eventi e li persiste in un file JSONL, così
 * ciò che succede con l'app chiusa (monitor in background) resta consultabile.
 */
object EventStore {
    private const val MAX = 5000

    fun interface Listener {
        fun onEvent(event: Map<String, Any?>)
    }

    private val events = ArrayDeque<Map<String, Any?>>()
    private val listeners = CopyOnWriteArrayList<Listener>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var file: File? = null
    private var seq = 0L
    private var initialized = false

    @Synchronized
    fun init(context: Context) {
        if (initialized) return
        val f = File(context.applicationContext.filesDir, "events.jsonl")
        file = f
        if (f.exists()) {
            try {
                val lines = f.readLines()
                for (line in lines.takeLast(MAX)) {
                    if (line.isBlank()) continue
                    try {
                        val ev = fromJson(JSONObject(line))
                        events.addLast(ev)
                        val id = (ev["id"] as? Number)?.toLong() ?: 0L
                        if (id > seq) seq = id
                    } catch (_: Exception) {
                    }
                }
                // Compatta il file se è cresciuto troppo.
                if (lines.size > MAX * 2) rewriteFile()
            } catch (_: Exception) {
            }
        }
        initialized = true
    }

    fun emit(
        category: String,
        action: String,
        summary: String,
        address: String? = null,
        name: String? = null,
        extras: Map<String, String> = emptyMap(),
        persist: Boolean = true,
    ) {
        val ev: Map<String, Any?>
        synchronized(this) {
            seq += 1
            ev = mapOf(
                "id" to seq,
                "ts" to System.currentTimeMillis(),
                "cat" to category,
                "action" to action,
                "summary" to summary,
                "address" to address,
                "name" to name,
                "extras" to extras,
                "persist" to persist,
            )
            if (persist) {
                events.addLast(ev)
                while (events.size > MAX) events.removeFirst()
                val line = toJson(ev).toString()
                val f = file
                if (f != null) io.execute {
                    try {
                        f.appendText(line + "\n")
                    } catch (_: Exception) {
                    }
                }
            }
        }
        mainHandler.post {
            for (l in listeners) {
                try {
                    l.onEvent(ev)
                } catch (_: Exception) {
                }
            }
        }
    }

    @Synchronized
    fun all(): List<Map<String, Any?>> = events.toList()

    @Synchronized
    fun clear() {
        events.clear()
        val f = file ?: return
        io.execute {
            try {
                f.writeText("")
            } catch (_: Exception) {
            }
        }
    }

    fun addListener(l: Listener) {
        listeners.add(l)
    }

    fun removeListener(l: Listener) {
        listeners.remove(l)
    }

    private fun rewriteFile() {
        val f = file ?: return
        val snapshot = events.toList()
        io.execute {
            try {
                f.writeText(snapshot.joinToString("") { toJson(it).toString() + "\n" })
            } catch (_: Exception) {
            }
        }
    }

    private fun toJson(ev: Map<String, Any?>): JSONObject {
        val o = JSONObject()
        for ((k, v) in ev) {
            if (k == "extras") {
                val ex = JSONObject()
                @Suppress("UNCHECKED_CAST")
                (v as? Map<String, String>)?.forEach { (ek, evv) -> ex.put(ek, evv) }
                o.put(k, ex)
            } else {
                o.put(k, v ?: JSONObject.NULL)
            }
        }
        return o
    }

    private fun fromJson(o: JSONObject): Map<String, Any?> {
        val extras = mutableMapOf<String, String>()
        val ex = o.optJSONObject("extras")
        if (ex != null) {
            val keys = ex.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                extras[k] = ex.optString(k)
            }
        }
        fun str(k: String): String? = if (o.isNull(k)) null else o.optString(k)
        return mapOf(
            "id" to o.optLong("id"),
            "ts" to o.optLong("ts"),
            "cat" to o.optString("cat"),
            "action" to o.optString("action"),
            "summary" to o.optString("summary"),
            "address" to str("address"),
            "name" to str("name"),
            "extras" to extras,
            "persist" to true,
        )
    }
}
