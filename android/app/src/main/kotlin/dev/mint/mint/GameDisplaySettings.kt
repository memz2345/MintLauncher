package dev.mint.mint

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Android 游戏画面的窗口与渲染设置。
 *
 * 不放在 Dart 的 SettingsService 里，是因为游戏内菜单也要改它，而游戏跑在
 * `:game` 独立进程 —— 两边共用一个 JSON 文件（filesDir/game_display.json）
 * 最省事，也不会遇到 SharedPreferences 的跨进程缓存。
 *
 * 两个维度互相独立：
 *  - **窗口大小**（[windowWidth] / [windowHeight]）= 画面在屏幕上占多大一块，
 *    按屏幕的宽/高百分比算，拖动即时生效（只是重排 SurfaceView，不动 GL
 *    surface）。拉小后四周出现黑边是预期效果。
 *  - **渲染分辨率**（[mode] / [ratio] / [resolutionScale]）= GL 缓冲实际画多少
 *    像素。**100% = 屏幕原生高度**（横屏短边），宽度按目标比例算
 *    （1260p + 16:9 → 2240×1260，75% → 1680×945）。以前基准写死 720，
 *    1.5K 屏最多只能到 1080p —— 这是「100% 渲染还是 1080p」的根因。
 *    缓冲与屏幕矩形始终保持同一比例做**等比缩放**，任何情况下都不拉伸画面；
 *    运行中改走 framebuffer-size 事件即时生效，启动时写进 `--width/--height`
 *    与 options.txt。
 */
data class GameDisplaySettings(
    val mode: Mode = Mode.FIT,
    val ratio: Float = 16f / 9f,
    val windowWidth: Float = 1f,
    val windowHeight: Float = 1f,
    /** 渲染精度：相对**屏幕原生高度**的倍率（1.0 = 原生）。 */
    val resolutionScale: Float = 1f,
) {
    enum class Mode(val id: String, val label: String) {
        FIT("fit", "适应屏幕"),
        FILL("fill", "铺满屏幕"),
        CUSTOM("custom", "自定义比例");

        companion object {
            fun fromId(id: String?): Mode = when (id) {
                // 旧版本的「拉伸铺满」迁移成按屏幕比例改横向分辨率。
                "stretch" -> FILL
                else -> entries.firstOrNull { it.id == id } ?: FIT
            }
        }
    }

    /** 目标宽高比。[screenAspect] 是横屏屏幕的宽高比（FILL 模式使用）。 */
    fun targetAspect(screenAspect: Float): Float = when (mode) {
        Mode.FIT -> 16f / 9f
        Mode.FILL -> if (screenAspect > 0f) screenAspect else 16f / 9f
        Mode.CUSTOM -> ratio.coerceIn(MIN_RATIO, MAX_RATIO)
    }

    /** 渲染高度：屏幕原生高度 × 精度倍率（取偶数，避免个位数 GPU 驱动挑宽度）。 */
    fun renderHeight(screenHeightPx: Int): Int {
        val base = if (screenHeightPx > 0) screenHeightPx else DEFAULT_SCREEN_HEIGHT
        val height = (base * resolutionScale).roundToInt()
        return (if (height % 2 == 0) height else height + 1).coerceIn(240, 4320)
    }

    /** 目标渲染尺寸：高度按精度倍率，宽度按比例（取偶数）。 */
    fun renderSize(screenAspect: Float, screenHeightPx: Int): Pair<Int, Int> {
        val height = renderHeight(screenHeightPx)
        val width = (height * targetAspect(screenAspect)).roundToInt()
        return (if (width % 2 == 0) width else width + 1) to height
    }

    fun ratioLabel(): String =
        ratioLabel(if (mode == Mode.CUSTOM) ratio else 16f / 9f)

    /** 渲染精度文案：原生 · 2800×1260 / 75% · 2100×945。 */
    fun resolutionLabel(screenAspect: Float, screenHeightPx: Int): String {
        val (w, h) = renderSize(screenAspect, screenHeightPx)
        val scale = if (resolutionScale >= 0.995f) "原生"
        else "${(resolutionScale * 100).roundToInt()}%"
        return "$scale · ${w}×$h"
    }

    /** 游戏内菜单主页的一行摘要。 */
    fun modeSummary(screenHeightPx: Int): String = when (mode) {
        Mode.FIT -> "16:9 · ${resolutionLabel(16f / 9f, screenHeightPx)}"
        Mode.FILL -> "铺满屏幕 · 按屏幕比例"
        Mode.CUSTOM -> "横向 ${ratioLabel(ratio)}"
    }

    /** 窗口大小文案：全屏 / 「80% × 60%」，游戏内菜单与启动器共用。 */
    fun windowLabel(): String = if (isFullscreen) "全屏"
    else "${(windowWidth * 100).roundToInt()}% × ${(windowHeight * 100).roundToInt()}%"

    val isFullscreen: Boolean
        get() = windowWidth >= 0.995f && windowHeight >= 0.995f

    companion object {
        /** 1.5K / 1080p 之外的兜底高度；真实值由 Activity 的屏幕尺寸传入。 */
        const val DEFAULT_SCREEN_HEIGHT = 1080

        /** 旧版把 100% 定为 720p；迁移时用它换算成「屏幕原生」的相对倍率。 */
        private const val LEGACY_BASE_HEIGHT = 720

        const val MIN_RATIO = 4f / 3f
        const val MAX_RATIO = 21f / 9f

        /** 精度低于 25% 画面已经没法看；100% 就是原生，不再超采样。 */
        const val MIN_SCALE = 0.25f
        const val MAX_SCALE = 1f

        /** 窗口最小只能拉到屏幕的 35%，否则画面小到没法玩。 */
        const val MIN_WINDOW = 0.35f
        const val MAX_WINDOW = 1f

        private const val FILE = "game_display.json"

        /** 精度语义版本：有它 = 相对屏幕原生；没有 = 旧版相对 720p。 */
        private const val KEY_SCALE_BASE = "scaleBase"
        private const val SCALE_BASE_SCREEN = "screen"

        fun clampWindow(value: Float): Float = value.coerceIn(MIN_WINDOW, MAX_WINDOW)

        fun screenHeightPx(context: Context): Int {
            val dm = context.resources.displayMetrics
            return min(dm.widthPixels, dm.heightPixels).coerceAtLeast(240)
        }

        /** 游戏内面板一行放得下的三档快速缩放。 */
        fun presetWindows(): List<Pair<String, Float>> = listOf(
            "100%" to 1f,
            "70%" to 0.7f,
            "40%" to 0.4f,
        )

        fun presetRatios(): List<Pair<String, Float>> = listOf(
            "4:3" to 4f / 3f,
            "16:9" to 16f / 9f,
            "18:9" to 2f,
            "19.5:9" to 19.5f / 9f,
            "21:9" to 21f / 9f,
        )

        /** 渲染精度预设：100% = 屏幕原生；卡顿时先降 75% / 50%。 */
        fun presetScales(): List<Pair<String, Float>> = listOf(
            "25%" to 0.25f,
            "50%" to 0.5f,
            "75%" to 0.75f,
            "原生" to 1f,
        )

        fun ratioLabel(ratio: Float): String {
            for ((label, value) in presetRatios()) {
                if (abs(ratio - value) < 0.015f) return label
            }
            return String.format(Locale.US, "%.2f:1", ratio)
        }

        private fun file(context: Context) = File(context.filesDir, FILE)

        fun load(context: Context): GameDisplaySettings {
            val f = file(context)
            if (!f.exists()) return GameDisplaySettings()
            return runCatching {
                val json = JSONObject(f.readText())
                val screenHeight = screenHeightPx(context)
                val rawScale = json.optDouble("resolutionScale", 1.0).toFloat()
                // 旧版 100% = 720p：按像素高度等价换算成「相对屏幕原生」的倍率，
                // 用户升级后看到的画面尺寸不变（1.5K 屏上的 1080p 仍是 1080p）。
                val scale = if (json.optString(KEY_SCALE_BASE) == SCALE_BASE_SCREEN) {
                    rawScale
                } else {
                    rawScale * LEGACY_BASE_HEIGHT / screenHeight
                }
                GameDisplaySettings(
                    mode = Mode.fromId(json.optString("mode")),
                    ratio = json.optDouble("ratio", 16.0 / 9.0)
                        .toFloat()
                        .coerceIn(MIN_RATIO, MAX_RATIO),
                    windowWidth = clampWindow(
                        json.optDouble("windowWidth", 1.0).toFloat(),
                    ),
                    windowHeight = clampWindow(
                        json.optDouble("windowHeight", 1.0).toFloat(),
                    ),
                    resolutionScale = scale.coerceIn(MIN_SCALE, MAX_SCALE),
                )
            }.getOrDefault(GameDisplaySettings())
        }

        fun save(context: Context, settings: GameDisplaySettings) {
            runCatching {
                file(context).writeText(
                    JSONObject()
                        .put("mode", settings.mode.id)
                        .put("ratio", settings.ratio.toDouble())
                        .put("windowWidth", clampWindow(settings.windowWidth).toDouble())
                        .put("windowHeight", clampWindow(settings.windowHeight).toDouble())
                        .put(
                            "resolutionScale",
                            settings.resolutionScale
                                .coerceIn(MIN_SCALE, MAX_SCALE)
                                .toDouble(),
                        )
                        .put(KEY_SCALE_BASE, SCALE_BASE_SCREEN)
                        .toString(),
                )
            }
        }
    }
}
