package dev.mint.mint

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 系统音量监听通道。
 *
 * 用户在应用里按音量键时，把变化的那条流（媒体 / 铃声 / 闹钟 / 通知）的当前
 * 音量推给 Dart，由 Flutter 画主题的音量条（HyperOS 竖柱样式 + mtz 声明的
 * `miui_volume_*` 配色与 `ic_miui_volume_*` 图标）。
 *
 * 广播只在 Dart 侧 `enable(true)` 之后注册 —— 设置里没开这个功能就完全不占系统回调。
 */
object VolumeBarHost {
    private const val CHANNEL_NAME = "dev.mint.mint/volume"

    // 音量广播的常量在 android.jar 里是 @hide 的，只能自己写字符串键。
    private const val ACTION_VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION"
    private const val EXTRA_VOLUME_STREAM_TYPE =
        "android.media.EXTRA_VOLUME_STREAM_TYPE"

    private var channel: MethodChannel? = null
    private var receiver: BroadcastReceiver? = null
    private var hostActivity: Activity? = null

    private val watchedStreams = setOf(
        AudioManager.STREAM_MUSIC,
        AudioManager.STREAM_RING,
        AudioManager.STREAM_ALARM,
        AudioManager.STREAM_NOTIFICATION,
    )

    fun install(activity: Activity, messenger: BinaryMessenger) {
        hostActivity = activity
        channel?.setMethodCallHandler(null)
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    if (call.argument<Boolean>("on") == true) register(activity) else unregister()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        unregister()
        channel?.setMethodCallHandler(null)
        channel = null
        hostActivity = null
    }

    private fun register(activity: Activity) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != ACTION_VOLUME_CHANGED) return
                push(activity, intent)
            }
        }
        try {
            val filter = IntentFilter(ACTION_VOLUME_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                activity.registerReceiver(r, filter)
            }
            receiver = r
        } catch (_: Throwable) {
            // 注册失败只是没有主题音量条，不影响启动。
        }
    }

    private fun unregister() {
        val r = receiver ?: return
        receiver = null
        try {
            hostActivity?.unregisterReceiver(r)
        } catch (_: Throwable) {
        }
    }

    private fun push(activity: Activity, intent: Intent) {
        val ch = channel ?: return
        val am = activity.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val stream = intent.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1)
        if (stream < 0 || stream !in watchedStreams) return
        val max: Int
        val value: Int
        try {
            max = am.getStreamMaxVolume(stream)
            value = am.getStreamVolume(stream)
        } catch (_: Throwable) {
            return
        }
        ch.invokeMethod(
            "onVolumeChanged",
            mapOf(
                "stream" to stream,
                "value" to value,
                "max" to max,
                "muted" to (value <= 0),
            ),
        )
    }
}
