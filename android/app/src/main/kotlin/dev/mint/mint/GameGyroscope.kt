package dev.mint.mint

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Surface
import kotlin.math.abs

/**
 * 陀螺仪转视角（行为与思路来自 FCL 的 `Gyroscope.java`，GPL-3.0，仅重写不照抄）：
 * 仅在游戏捕获指针（进世界转视角）时生效，把角速度积分成相对增量下发。
 *
 * FCL 的关键处理这里全部保留：
 *  - 滑动窗口平均抑制手抖，低于死区的角速度视为传感器噪声忽略；
 *  - 轴映射随屏幕旋转自适应（竖屏转头绕 Y 轴、点头绕 X 轴，横屏反过来）；
 *  - X/Y 轴可独立反转；
 *  - 非捕获状态不累计时间戳，重新进入时从当前帧起步，避免大步长突跳；
 *  - 关闭传感器时不补发绝对坐标，否则会把视角拽回开启时的位置。
 */
class GameGyroscope(
    private val context: Context,
    private val tweaksProvider: () -> GameTweaksSettings,
    private val isCaptured: () -> Boolean,
) : SensorEventListener {

    companion object {
        /**
         * 角速度积分的时间系数：沿用 FCL 的历史标定值（含手感放大倍率，
         * 并非真实纳秒到秒换算）。
         */
        private const val TIME_SCALE = 1f / 40000000f

        /** 滑动平均窗口长度，越大越平滑但响应越迟。 */
        private const val SMOOTHING_WINDOW = 4

        /** 死区阈值（rad/s），低于该值的角速度不驱动视角。 */
        private const val DEAD_ZONE = 0.02f
    }

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val displayManager =
        context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val sensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 屏幕旋转缓存：由 DisplayListener 推送刷新，避免每个传感器事件都查显示服务。 */
    private var rotation = Surface.ROTATION_0

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId == Display.DEFAULT_DISPLAY) refreshRotation()
        }
    }

    // 平滑环形缓冲与窗口内累计和
    private val buffer = Array(SMOOTHING_WINDOW) { FloatArray(2) }
    private var xTotal = 0f
    private var yTotal = 0f
    private var historyIndex = 0
    private var timestamp = 0L

    // 轴映射：swapXY 表示水平/垂直视角交换传感器轴，factor 为各轴方向
    private var swapXY = false
    private var xFactor = 1f
    private var yFactor = 1f

    /** 设备是否具备陀螺仪传感器。 */
    fun isAvailable(): Boolean = sensor != null

    fun start() {
        if (!isAvailable()) return
        refreshRotation()
        displayManager.registerDisplayListener(displayListener, mainHandler)
        reset()
        sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
    }

    fun stop() {
        if (!isAvailable()) return
        sensorManager.unregisterListener(this)
        displayManager.unregisterDisplayListener(displayListener)
        reset()
    }

    override fun onSensorChanged(event: SensorEvent) {
        // 非捕获状态不累计时间戳，重新进入时从当前帧重新起步，避免突跳。
        if (!isCaptured()) {
            timestamp = 0
            return
        }
        if (timestamp == 0L) {
            timestamp = event.timestamp
            return
        }
        val dT = (event.timestamp - timestamp) * TIME_SCALE
        timestamp = event.timestamp
        if (dT <= 0) return

        updateFactors()
        val tweaks = tweaksProvider()

        val x = event.values[0]
        val y = event.values[1]
        // 屏幕旋转后水平/垂直视角对应的传感器轴与方向随之变化。
        var vx = (if (swapXY) y else x) * xFactor
        var vy = (if (swapXY) x else y) * yFactor

        // 滑动平均：新值入环形缓冲，以窗口均值替代瞬时值。
        historyIndex = (historyIndex + 1) % SMOOTHING_WINDOW
        xTotal -= buffer[historyIndex][0]
        yTotal -= buffer[historyIndex][1]
        buffer[historyIndex][0] = vx
        buffer[historyIndex][1] = vy
        xTotal += vx
        yTotal += vy
        vx = xTotal / SMOOTHING_WINDOW
        vy = yTotal / SMOOTHING_WINDOW

        if (abs(vx) < DEAD_ZONE) vx = 0f
        if (abs(vy) < DEAD_ZONE) vy = 0f
        if (vx == 0f && vy == 0f) return

        // FCL 的灵敏度取值 1–50，内部再除以 10 归一到 0.1–5 倍。
        val sens = tweaks.gyroscopeSensitivity / 10f
        FclRuntime.sendCursorDelta(
            context,
            vx * dT * sens,
            vy * dT * sens,
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    /** 按当前屏幕旋转计算轴映射：水平视角取自竖直轴的角速度，垂直反之。 */
    private fun updateFactors() {
        val tweaks = tweaksProvider()
        when (rotation) {
            Surface.ROTATION_0 -> { // 竖屏：左右转头绕 Y 轴，上下点头绕 X 轴
                swapXY = true
                xFactor = -1f
                yFactor = 1f
            }
            Surface.ROTATION_180 -> { // 倒置竖屏：两轴相对竖屏反向
                swapXY = true
                xFactor = 1f
                yFactor = -1f
            }
            Surface.ROTATION_270 -> { // 右横屏：两轴相对左横屏反向
                swapXY = false
                xFactor = 1f
                yFactor = -1f
            }
            else -> { // ROTATION_90 左横屏，历史标定方向
                swapXY = false
                xFactor = -1f
                yFactor = 1f
            }
        }
        if (tweaks.invertGyroscopeX) xFactor *= -1f
        if (tweaks.invertGyroscopeY) yFactor *= -1f
    }

    private fun refreshRotation() {
        val display = displayManager.getDisplay(Display.DEFAULT_DISPLAY)
        if (display != null) rotation = display.rotation
    }

    /** 清空平滑缓冲与时间戳，在启停 / 进出捕获态时调用，避免旧状态造成跳变。 */
    private fun reset() {
        timestamp = 0
        historyIndex = 0
        xTotal = 0f
        yTotal = 0f
        for (axis in buffer) axis.fill(0f)
    }
}
