package dev.mint.mint

import android.app.Activity
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 系统 Toast 通道（local2api `showAppToast` 的 Android 原生分支）。
 *
 * Flutter 自绘的 SnackBar 会被系统导航栏 / 输入法顶来顶去，短提示用
 * 系统 Toast 更稳，也不占页面布局。
 */
object NativeToastHost {
    private const val CHANNEL_NAME = "dev.mint.mint/toast"
    private var channel: MethodChannel? = null

    fun install(activity: Activity, messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val long = call.argument<Boolean>("long") ?: false
                    if (text.isNotEmpty()) {
                        Toast.makeText(
                            activity,
                            text,
                            if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT,
                        ).show()
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
