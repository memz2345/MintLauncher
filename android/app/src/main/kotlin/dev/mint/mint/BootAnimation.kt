package dev.mint.mint

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File

/**
 * Android 开机动画（`boots/bootanimation.zip`）的解析。
 *
 * 标准格式：
 * ```
 * 1080 2400 50            // 宽 高 帧率
 * c 1 0 part0             // c = 播完停在最后一帧，p = 循环；count 0 = 全部
 * p 0 0 part1
 * ```
 * MIUI 主题的动画就是这么打的；启动游戏时盖在游戏加载层上播，正好当
 * 「主题开机动画」用 —— 游戏出第一帧就收起。
 */
class BootAnimation private constructor(
    val width: Int,
    val height: Int,
    val fps: Int,
    val parts: List<Part>,
) {
    class Part(
        val frames: List<File>,
        val loop: Boolean,
        val pauseMs: Long,
    )

    fun decode(file: File): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            var sample = 1
            val maxSide = maxOf(bounds.outWidth, bounds.outHeight)
            while (maxSide / sample > 1600) sample *= 2
            BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                },
            )
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        fun load(dir: File): BootAnimation? {
            val desc = File(dir, "desc.txt")
            if (!desc.exists()) return null
            val lines = runCatching { desc.readLines() }.getOrNull() ?: return null
            if (lines.isEmpty()) return null
            val head = lines.first().trim().split(Regex("\\s+"))
            if (head.size < 3) return null
            val width = head[0].toIntOrNull() ?: return null
            val height = head[1].toIntOrNull() ?: return null
            val fps = (head[2].toIntOrNull() ?: 30).coerceIn(1, 120)
            val parts = mutableListOf<Part>()
            for (line in lines.drop(1)) {
                val text = line.trim()
                if (text.isEmpty() || text.startsWith("#")) continue
                val tokens = text.split(Regex("\\s+"))
                if (tokens.size < 4) continue
                val type = tokens[0]
                val count = tokens[1].toIntOrNull() ?: 0
                val pause = tokens[2].toIntOrNull() ?: 0
                val folder = File(dir, tokens[3])
                if (!folder.isDirectory) continue
                val frames = (folder.listFiles() ?: emptyArray())
                    .filter { it.isFile && it.name.lowercase().endsWith(".png") }
                    .sortedBy { it.name }
                    .let { if (count in 1 until it.size) it.subList(0, count) else it }
                if (frames.isEmpty()) continue
                parts.add(
                    Part(
                        frames = frames,
                        loop = type.equals("p", ignoreCase = true),
                        pauseMs = pause * 1000L,
                    ),
                )
            }
            if (parts.isEmpty()) return null
            return BootAnimation(width, height, fps, parts)
        }
    }
}
