package com.hydrosense.hydro_sense

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Notification
import android.os.Build

/**
 * Creates the "Alerts" notification channel when the app process starts, even
 * when it starts only to receive a push. High importance is what makes Android
 * pop an alert up on screen (a heads-up banner, like a chat message), with
 * sound, vibration and on the lock screen. A channel's importance cannot be
 * changed after it exists, so a new behaviour needs a new channel ID.
 */
class HydroSenseApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ALERTS_CHANNEL,
                "Water alerts",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "No water, low flow, offline and low battery"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    companion object {
        /** Keep in step with ALERT_CHANNEL_ID (functions) and the manifest. */
        const val ALERTS_CHANNEL = "alerts"
    }
}
