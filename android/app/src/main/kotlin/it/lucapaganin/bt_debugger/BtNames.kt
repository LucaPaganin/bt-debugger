package it.lucapaganin.bt_debugger

/** Traduzione dei codici numerici dello stack Bluetooth Android in nomi leggibili. */
object BtNames {
    fun adapterState(s: Int): String = when (s) {
        10 -> "OFF"
        11 -> "TURNING_ON"
        12 -> "ON"
        13 -> "TURNING_OFF"
        14 -> "BLE_TURNING_ON"
        15 -> "BLE_ON"
        16 -> "BLE_TURNING_OFF"
        else -> "?($s)"
    }

    fun connState(s: Int): String = when (s) {
        0 -> "DISCONNECTED"
        1 -> "CONNECTING"
        2 -> "CONNECTED"
        3 -> "DISCONNECTING"
        else -> "?($s)"
    }

    fun bondState(s: Int): String = when (s) {
        10 -> "NONE"
        11 -> "BONDING"
        12 -> "BONDED"
        else -> "?($s)"
    }

    /** Valori dell'extra nascosto android.bluetooth.device.extra.REASON su BOND_STATE_CHANGED. */
    fun unbondReason(r: Int): String = when (r) {
        0 -> "SUCCESS"
        1 -> "AUTH_FAILED (autenticazione fallita)"
        2 -> "AUTH_REJECTED (rifiutata dal remoto)"
        3 -> "AUTH_CANCELED"
        4 -> "REMOTE_DEVICE_DOWN (remoto non raggiungibile)"
        5 -> "DISCOVERY_IN_PROGRESS"
        6 -> "AUTH_TIMEOUT"
        7 -> "REPEATED_ATTEMPTS"
        8 -> "REMOTE_AUTH_CANCELED"
        9 -> "REMOVED (bond rimosso)"
        else -> "?($r)"
    }

    /** Tipo di pairing richiesto: dice se il remoto usa il legacy PIN o il Secure Simple Pairing. */
    fun pairingVariant(v: Int): String = when (v) {
        0 -> "PIN (legacy pairing, BT ≤ 2.0)"
        1 -> "PASSKEY"
        2 -> "PASSKEY_CONFIRMATION (SSP numeric comparison, BT ≥ 2.1)"
        3 -> "CONSENT (SSP Just Works)"
        4 -> "DISPLAY_PASSKEY (SSP passkey entry)"
        5 -> "DISPLAY_PIN"
        6 -> "OOB_CONSENT"
        7 -> "PIN_16_DIGITS"
        else -> "?($v)"
    }

    fun transport(t: Int): String = when (t) {
        0 -> "AUTO"
        1 -> "BR/EDR (Classic)"
        2 -> "LE"
        else -> "?($t)"
    }

    fun deviceType(t: Int): String = when (t) {
        0 -> "UNKNOWN"
        1 -> "CLASSIC"
        2 -> "LE"
        3 -> "DUAL"
        else -> "?($t)"
    }

    fun a2dpPlaying(s: Int): String = when (s) {
        10 -> "PLAYING"
        11 -> "NOT_PLAYING"
        else -> "?($s)"
    }

    fun headsetAudio(s: Int): String = when (s) {
        10 -> "AUDIO_DISCONNECTED"
        11 -> "AUDIO_CONNECTING"
        12 -> "AUDIO_CONNECTED"
        else -> "?($s)"
    }

    fun scanMode(m: Int): String = when (m) {
        20 -> "NONE"
        21 -> "CONNECTABLE"
        23 -> "CONNECTABLE_DISCOVERABLE"
        else -> "?($m)"
    }

    /** Codici errore HCI più frequenti (Core Spec Vol 1 Part F). */
    fun hciError(c: Int): String? = when (c) {
        0x00 -> "Success"
        0x02 -> "Unknown Connection Identifier"
        0x04 -> "Page Timeout"
        0x05 -> "Authentication Failure"
        0x06 -> "PIN or Key Missing"
        0x08 -> "Connection Timeout"
        0x0E -> "Connection Rejected (security)"
        0x13 -> "Remote User Terminated Connection"
        0x14 -> "Remote Terminated (low resources)"
        0x15 -> "Remote Terminated (power off)"
        0x16 -> "Connection Terminated by Local Host"
        0x1A -> "Unsupported Remote Feature"
        0x22 -> "LMP Response Timeout"
        0x23 -> "LMP Error Transaction Collision"
        0x25 -> "Encryption Mode Not Acceptable"
        0x29 -> "Pairing With Unit Key Not Supported"
        0x3D -> "Connection Terminated due to MIC Failure"
        else -> null
    }
}
