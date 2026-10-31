package dev.mint.mint

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * 游戏体验微调设置（灵敏度 / 陀螺仪 / 高刷 / 内存叠层）。
 *
 * 与 [GameDisplaySettings] 同一套思路：游戏内菜单（`:game` 进程）和启动器
 * 设置页（主进程）共用一份 JSON（filesDir/game_tweaks.json），避开
 * SharedPreferences 的跨进程缓存；启动器改完广播 [GameActivity.ACTION_TWEAKS]
 * 让后台游戏立刻重读。
 *
 * 各项的来源与取值参照 FCL：
 *  - 视角灵敏度 ← FCL `MenuSetting.mouseSensitivity`（TouchPad 拖动乘系数）；
 *  - 陀螺仪开关 / 反转 / 灵敏度 ← FCL `MenuSetting.enableGyroscope` 等四项；
 *  - 最高刷新率 ← FCL `MenuSetting.requestMaxRefreshRate`（JVMActivity 的
 *    applyMaxRefreshRatePolicy）；
 *  - 内存叠层 ← FCL `MenuSetting.showMemory`。
 */
data class GameTweaksSettings(
    /** 捕获指针后拖动转视角的灵敏度倍率（1.0 = Mint 原始手感）。 */
    val lookSensitivity: Float = 1f,
    /** 陀螺仪转视角总开关（设备没有陀螺仪时上层应禁用入口）。 */
    val enableGyroscope: Boolean = false,
    /** 陀螺仪灵敏度（1–50，FCL 默认 10）。 */
    val gyroscopeSensitivity: Int = 10,
    /** 陀螺仪水平 / 垂直轴反转。 */
    val invertGyroscopeX: Boolean = false,
    val invertGyroscopeY: Boolean = false,
    /** FPS 叠层下面再加一行 JVM 堆内存用量。 */
    val showMemory: Boolean = false,
    /** 游戏运行时把屏幕切到同分辨率下的最高刷新率档。 */
    val requestMaxRefreshRate: Boolean = true,
    /**
     * 接上物理键盘 / 鼠标后自动隐藏触摸按键（OSD），断开就恢复。
     *
     * 外设有自己的按键和指针，屏幕上一排虚拟按钮纯属挡视线；拔掉外设时又
     * 必须立刻回来，否则只能靠悬浮球进菜单重新开。
     */
    val autoHideControlsOnPhysicalInput: Boolean = true,
) {
    /** MethodChannel 返回给 Dart 侧的扁平 map。 */
    fun toMap(): Map<String, Any> = mapOf(
        "lookSensitivity" to lookSensitivity,
        "enableGyroscope" to enableGyroscope,
        "gyroscopeSensitivity" to gyroscopeSensitivity,
        "invertGyroscopeX" to invertGyroscopeX,
        "invertGyroscopeY" to invertGyroscopeY,
        "showMemory" to showMemory,
        "requestMaxRefreshRate" to requestMaxRefreshRate,
        "autoHideControlsOnPhysicalInput" to autoHideControlsOnPhysicalInput,
    )

    /**
     * 用 channel 传入的部分字段生成新设置：只覆盖 Dart 侧给出的键，
     * 这样启动器只改一项时不会把游戏内菜单没保存的其它改动冲掉。
     */
    fun withArguments(args: Any?): GameTweaksSettings {
        val map = args as? Map<*, *> ?: return this
        fun bool(key: String, current: Boolean) =
            (map[key] as? Boolean) ?: current
        fun num(key: String, current: Float) =
            (map[key] as? Number)?.toFloat() ?: current
        fun int(key: String, current: Int) =
            (map[key] as? Number)?.toInt() ?: current
        return copy(
            lookSensitivity = num(
                "lookSensitivity", lookSensitivity,
            ).coerceIn(MIN_LOOK_SENSITIVITY, MAX_LOOK_SENSITIVITY),
            enableGyroscope = bool("enableGyroscope", enableGyroscope),
            gyroscopeSensitivity = int(
                "gyroscopeSensitivity", gyroscopeSensitivity,
            ).coerceIn(MIN_GYRO_SENSITIVITY, MAX_GYRO_SENSITIVITY),
            invertGyroscopeX = bool("invertGyroscopeX", invertGyroscopeX),
            invertGyroscopeY = bool("invertGyroscopeY", invertGyroscopeY),
            showMemory = bool("showMemory", showMemory),
            requestMaxRefreshRate = bool(
                "requestMaxRefreshRate", requestMaxRefreshRate,
            ),
            autoHideControlsOnPhysicalInput = bool(
                "autoHideControlsOnPhysicalInput",
                autoHideControlsOnPhysicalInput,
            ),
        )
    }

    companion object {
        const val MIN_LOOK_SENSITIVITY = 0.2f
        const val MAX_LOOK_SENSITIVITY = 3f
        const val MIN_GYRO_SENSITIVITY = 1
        const val MAX_GYRO_SENSITIVITY = 50

        private const val FILE = "game_tweaks.json"

        private fun file(context: Context) = File(context.filesDir, FILE)

        fun load(context: Context): GameTweaksSettings {
            val f = file(context)
            if (!f.exists()) return GameTweaksSettings()
            return runCatching {
                val json = JSONObject(f.readText())
                GameTweaksSettings(
                    lookSensitivity = json.optDouble("lookSensitivity", 1.0)
                        .toFloat()
                        .coerceIn(MIN_LOOK_SENSITIVITY, MAX_LOOK_SENSITIVITY),
                    enableGyroscope = json.optBoolean("enableGyroscope"),
                    gyroscopeSensitivity = json.optInt(
                        "gyroscopeSensitivity", 10,
                    ).coerceIn(MIN_GYRO_SENSITIVITY, MAX_GYRO_SENSITIVITY),
                    invertGyroscopeX = json.optBoolean("invertGyroscopeX"),
                    invertGyroscopeY = json.optBoolean("invertGyroscopeY"),
                    showMemory = json.optBoolean("showMemory"),
                    requestMaxRefreshRate = json.optBoolean(
                        "requestMaxRefreshRate", true,
                    ),
                    autoHideControlsOnPhysicalInput = json.optBoolean(
                        "autoHideControlsOnPhysicalInput", true,
                    ),
                )
            }.getOrDefault(GameTweaksSettings())
        }

        fun save(context: Context, settings: GameTweaksSettings) {
            runCatching {
                file(context).writeText(
                    JSONObject()
                        .put("lookSensitivity", settings.lookSensitivity.toDouble())
                        .put("enableGyroscope", settings.enableGyroscope)
                        .put(
                            "gyroscopeSensitivity",
                            settings.gyroscopeSensitivity,
                        )
                        .put("invertGyroscopeX", settings.invertGyroscopeX)
                        .put("invertGyroscopeY", settings.invertGyroscopeY)
                        .put("showMemory", settings.showMemory)
                        .put(
                            "requestMaxRefreshRate",
                            settings.requestMaxRefreshRate,
                        )
                        .put(
                            "autoHideControlsOnPhysicalInput",
                            settings.autoHideControlsOnPhysicalInput,
                        )
                        .toString(),
                )
            }
        }
    }
}
