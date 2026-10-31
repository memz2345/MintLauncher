package dev.mint.mint

import android.content.Context
import android.util.Log
import java.io.File

/**
 * 真机输入诊断日志。
 *
 * vivo 的 logcat 对普通应用整个吞掉（连 `Log.i` 都看不到），排查触摸/鼠标
 * 只能走应用自己的外部目录：
 *   `/sdcard/Android/data/dev.mint.mint/files/logs/mint-input.log`
 * adb shell 可直接 cat / rm。
 *
 * 同一目录下的 `input_queue` 文件（内容 "0" / "1"）用来临时覆盖 GLFW
 * 输入队列开关；不写就用版本参数推导值。
 */
object InputDebug {
    private const val TAG = "MintInput"

    @Volatile private var file: File? = null
    private val stamp = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US)

    fun init(context: Context) {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(base, "logs").apply { mkdirs() }
        file = File(dir, "mint-input.log")
        runCatching { file?.writeText("") }
        Log.i(TAG, "输入诊断日志：${file?.absolutePath}")
    }

    fun log(message: String) {
        Log.i(TAG, message)
        val target = file ?: return
        runCatching {
            target.appendText("${stamp.format(java.util.Date())} $message\n")
        }
    }

    /** `null` = 没有覆盖；0/1 = 强制关/开 GLFW input stack queue。 */
    fun queueOverride(context: Context): Boolean? {
        val base = context.getExternalFilesDir(null) ?: return null
        val f = File(base, "input_queue")
        if (!f.exists()) return null
        val raw = runCatching { f.readText().trim() }.getOrNull() ?: return null
        return when (raw) {
            "0" -> false
            "1" -> true
            else -> null
        }
    }
}
