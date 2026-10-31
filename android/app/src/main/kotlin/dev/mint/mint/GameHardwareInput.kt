package dev.mint.mint

import android.content.Context
import android.hardware.input.InputManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

/**
 * 安卓 `KeyEvent` 键码 → GLFW 键码（lwjgl3 `GLFW.GLFW_KEY_*`）。
 *
 * 走 GLFW 而不是直接给 Linux input-event code，是为了复用 [FclRuntime.sendKey]
 * / [FclRuntime.sendKeyWithChar] 里那张 GLFW→FCL 的表（那张表是照 FCL 的
 * `LwjglKeycodeMap` 抄的，直接造 Linux 码容易和 FCL 对不上）。
 *
 * 表中没有的键返回 -1，调用方应忽略（FCL 查不到键码会静默丢事件，不会崩）。
 */
object AndroidKeyCodes {
    fun toGlfw(keyCode: Int): Int = when (keyCode) {
        // 字母：KEYCODE_A(29)..KEYCODE_Z(54) → GLFW_KEY_A(65)..Z(90)
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z ->
            keyCode - KeyEvent.KEYCODE_A + 65
        // 数字行：KEYCODE_0(7)..9(16) → GLFW_KEY_0(48)..9(57)
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 ->
            keyCode - KeyEvent.KEYCODE_0 + 48
        // 小键盘：映射到主键盘数字 / 回车，FCL 那张表没有 KP 段，直接发主键盘码。
        in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 ->
            keyCode - KeyEvent.KEYCODE_NUMPAD_0 + 48
        KeyEvent.KEYCODE_NUMPAD_ENTER -> 257 // ENTER
        KeyEvent.KEYCODE_NUMPAD_ADD -> 61 // EQUAL
        KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> 45 // MINUS
        KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> 56 // 8
        KeyEvent.KEYCODE_NUMPAD_DIVIDE -> 47 // SLASH
        KeyEvent.KEYCODE_NUMPAD_DOT -> 46 // PERIOD

        KeyEvent.KEYCODE_SPACE -> 32
        KeyEvent.KEYCODE_ENTER -> 257
        KeyEvent.KEYCODE_ESCAPE -> 256
        KeyEvent.KEYCODE_TAB -> 258
        KeyEvent.KEYCODE_DEL -> 259 // BACKSPACE
        KeyEvent.KEYCODE_FORWARD_DEL -> 261 // DELETE
        KeyEvent.KEYCODE_INSERT -> 260

        KeyEvent.KEYCODE_DPAD_UP -> 265
        KeyEvent.KEYCODE_DPAD_DOWN -> 264
        KeyEvent.KEYCODE_DPAD_LEFT -> 263
        KeyEvent.KEYCODE_DPAD_RIGHT -> 262
        KeyEvent.KEYCODE_MOVE_HOME -> 268
        KeyEvent.KEYCODE_MOVE_END -> 269
        KeyEvent.KEYCODE_PAGE_UP -> 266
        KeyEvent.KEYCODE_PAGE_DOWN -> 267

        KeyEvent.KEYCODE_SHIFT_LEFT -> 340
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 344
        KeyEvent.KEYCODE_CTRL_LEFT -> 341
        KeyEvent.KEYCODE_CTRL_RIGHT -> 345
        KeyEvent.KEYCODE_ALT_LEFT -> 342
        KeyEvent.KEYCODE_ALT_RIGHT -> 346
        KeyEvent.KEYCODE_META_LEFT -> 343
        KeyEvent.KEYCODE_META_RIGHT -> 347
        KeyEvent.KEYCODE_CAPS_LOCK -> 280
        KeyEvent.KEYCODE_NUM_LOCK -> 282
        KeyEvent.KEYCODE_SCROLL_LOCK -> 281
        KeyEvent.KEYCODE_SYSRQ -> 283
        KeyEvent.KEYCODE_BREAK -> 284
        KeyEvent.KEYCODE_MENU -> 348

        // F1(131)..F12(142) → GLFW_KEY_F1(290)..F12(301)
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 ->
            keyCode - KeyEvent.KEYCODE_F1 + 290

        KeyEvent.KEYCODE_COMMA -> 44
        KeyEvent.KEYCODE_PERIOD -> 46
        KeyEvent.KEYCODE_SLASH -> 47
        KeyEvent.KEYCODE_BACKSLASH -> 92
        KeyEvent.KEYCODE_SEMICOLON -> 59
        KeyEvent.KEYCODE_APOSTROPHE -> 39
        KeyEvent.KEYCODE_EQUALS -> 61
        KeyEvent.KEYCODE_MINUS -> 45
        KeyEvent.KEYCODE_LEFT_BRACKET -> 91
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 93
        KeyEvent.KEYCODE_GRAVE -> 96
        KeyEvent.KEYCODE_AT -> 50 // 2
        KeyEvent.KEYCODE_STAR -> 56 // 8
        KeyEvent.KEYCODE_POUND -> 51 // 3
        KeyEvent.KEYCODE_PLUS -> 61

        else -> -1
    }
}

/**
 * 物理输入设备在线状态监听（外接键盘 / 鼠标 / 触控笔不算）。
 *
 * 用 [InputManager.InputDeviceListener] 而不是只查一次：蓝牙键鼠随时会连上或
 * 断开，OSD 的显隐必须跟着变（需求：接上就隐藏触摸按键，断开就恢复）。
 *
 * 判定口径：
 *  - **鼠标**：`SOURCE_MOUSE` / `SOURCE_MOUSE_RELATIVE` / `SOURCE_TRACKBALL`；
 *  - **键盘**：`SOURCE_KEYBOARD` 且键盘类型不是 NONE。虚拟设备（软键盘）与
 *    机顶盒遥控器（`KEYBOARD_TYPE_NON_ALPHABETIC`）不在此列 —— 遥控器那几个
 *    方向键还不足以替代整套 OSD。
 */
class PhysicalInputWatcher(
    context: Context,
    private val onChange: (mouse: Boolean, keyboard: Boolean) -> Unit,
) : InputManager.InputDeviceListener {
    private val inputManager =
        context.getSystemService(Context.INPUT_SERVICE) as? InputManager
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    var hasMouse = false
        private set

    @Volatile
    var hasKeyboard = false
        private set

    val hasAny: Boolean get() = hasMouse || hasKeyboard

    private fun scan() {
        var mouse = false
        var keyboard = false
        for (id in inputManager?.inputDeviceIds ?: IntArray(0)) {
            val d = inputManager?.getInputDevice(id) ?: continue
            if (isVirtual(d)) continue
            val src = d.sources
            if (PhysicalInputWatcher.isMouseSource(src) &&
                hasPointerAxes(d) &&
                d.keyboardType == InputDevice.KEYBOARD_TYPE_NONE
            ) {
                mouse = true
            }
            if (src and InputDevice.SOURCE_KEYBOARD != 0 &&
                d.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC &&
                hasLetterKeys(d)
            ) {
                keyboard = true
            }
        }
        if (mouse == hasMouse && keyboard == hasKeyboard) return
        hasMouse = mouse
        hasKeyboard = keyboard
        onChange(mouse, keyboard)
    }

    fun start() {
        inputManager ?: return
        inputManager.registerInputDeviceListener(this, handler)
        scan()
    }

    fun stop() {
        runCatching { inputManager?.unregisterInputDeviceListener(this) }
    }

    override fun onInputDeviceAdded(deviceId: Int) = scan()
    override fun onInputDeviceRemoved(deviceId: Int) = scan()
    override fun onInputDeviceChanged(deviceId: Int) = scan()

    companion object {
        /**
         * 判断一个 source 掩码是否是鼠标类设备。
         *
         * **不能写成 `sources and (SOURCE_MOUSE or SOURCE_MOUSE_RELATIVE) != 0`**：
         * `SOURCE_MOUSE_RELATIVE`（0x40002）里含 `SOURCE_CLASS_POINTER`（0x2），
         * 而所有触摸屏（`SOURCE_TOUCHSCREEN` = 0x1002）也带这一位 —— 位与测试
         * 会把手指数全部判成鼠标。后果是触摸被硬件路由器整段吞掉：
         * 光标能动、鼠标键不触发、悬浮球也收不到事件。
         * 这里用「完整 source 是否相等」判断。
         */
        fun isMouseSource(source: Int): Boolean =
            source == InputDevice.SOURCE_MOUSE ||
                source == InputDevice.SOURCE_MOUSE_RELATIVE ||
                source == InputDevice.SOURCE_TRACKBALL

        fun isVirtual(d: InputDevice): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && d.isVirtual

        /**
         * 真的指针设备要带 X/Y 位移轴。
         *
         * vivo 的屏下指纹（`vivo_ts_fp` / `vivo_fp`）在 sources 里同时上报
         * `KEYBOARD | MOUSE`、keyboardType 还是 ALPHABETIC，但没有任何位移轴 ——
         * 只看 sources 会在真机上误判「外接键鼠」，把 OSD 整个收起来，
         * 玩家既看不到按键也没法用 LMB 点击。
         */
        fun hasPointerAxes(d: InputDevice): Boolean {
            var hasX = false
            var hasY = false
            for (r in d.motionRanges) {
                if (r.axis == MotionEvent.AXIS_X) hasX = true
                if (r.axis == MotionEvent.AXIS_Y) hasY = true
            }
            return hasX && hasY
        }

        /** 真键盘至少得有字母键；指纹/电源键这类「假键盘」过不了这一关。 */
        fun hasLetterKeys(d: InputDevice): Boolean = d.hasKeys(
            KeyEvent.KEYCODE_A,
            KeyEvent.KEYCODE_Z,
            KeyEvent.KEYCODE_SPACE,
        ).all { it }
    }
}

/**
 * 物理键盘 / 鼠标 → FCL 输入。
 *
 * 由 [GameActivity] 在 `dispatch*` 阶段调用（早于 View 树），这样焦点落在
 * 悬浮球或 Compose 浮层上时按键也不会被吃掉。
 *
 * 两套坐标语义，跟 [GameInputView] 的触摸保持一致：
 *  - **未捕获指针**（游戏菜单 / 背包）：按绝对坐标发 `sendCursorPos`，
 *    坐标换算到**游戏缓冲区**像素（SurfaceView 可能只占屏幕中间一块）；
 *  - **已捕获**（进世界转视角）：发 `sendCursorDelta`，优先用
 *    `AXIS_RELATIVE_X/Y`（部分鼠标给的是相对轴），没有就用相邻两帧差值。
 *
 * 返回 true 表示事件已被消费，宿主不要再往下传。
 */
class GameHardwareInput(
    private val context: Context,
    private val surface: () -> View?,
    private val gameSize: () -> Pair<Int, Int>,
    private val grabbed: () -> Boolean,
    private val onActivity: () -> Unit = {},
) {
    private var lastX = 0f
    private var lastY = 0f
    private var hasLast = false
    private var mouseButtons = 0

    // ───────────────────────── 键盘 ─────────────────────────

    fun onKey(event: KeyEvent): Boolean {
        if (!isPhysicalKeyboard(event)) return false
        val glfw = AndroidKeyCodes.toGlfw(event.keyCode)
        if (glfw < 0) return false
        onActivity()
        val down = event.action == KeyEvent.ACTION_DOWN
        if (event.repeatCount > 0 && down) {
            // 长按重复：Minecraft 自己处理 repeat，重复发 down 会让聊天框
            // 打出一串同样的字符。
            return true
        }
        // unicodeChar 已经把修饰键（Shift/Ctrl）算进去了；0 表示没有可打印
        // 字符（方向键、F1…），传 '\u0000' 让 FCL 走纯键码通道。
        val ch = if (down && event.unicodeChar > 0) {
            event.unicodeChar.toChar()
        } else {
            '\u0000'
        }
        FclRuntime.sendKeyWithChar(context, glfw, ch, down)
        return true
    }

    // ───────────────────────── 鼠标移动 / 滚轮 ─────────────────────────

    fun onGenericMotion(event: MotionEvent): Boolean {
        if (!isMouseEvent(event)) return false
        onActivity()
        when (event.actionMasked) {
            MotionEvent.ACTION_SCROLL -> {
                val v = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                val h = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
                if (abs(v) > 0.01f) FclRuntime.sendScroll(context, v.toDouble())
                if (abs(h) > 0.01f) FclRuntime.sendScroll(context, h.toDouble())
                return true
            }
            MotionEvent.ACTION_HOVER_MOVE -> {
                sendMotion(event)
                return true
            }
        }
        return false
    }

    // ───────────────────────── 鼠标按键 / 触摸板 ─────────────────────────

    /** @return true 表示这是鼠标事件且已处理。 */
    fun onTouch(event: MotionEvent): Boolean {
        if (!isMouseEvent(event)) return false
        onActivity()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                sendMotion(event)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                releaseAllButtons()
                hasLast = false
            }
        }
        handleButtons(event)
        return true
    }

    /** 断开 / 切后台：把按着的鼠标键与缓存坐标清掉，避免视角卡住。 */
    fun reset() {
        releaseAllButtons()
        hasLast = false
    }

    // ───────────────────────── 内部 ─────────────────────────

    private fun sendMotion(event: MotionEvent) {
        if (grabbed()) {
            val rx = event.getAxisValue(MotionEvent.AXIS_RELATIVE_X)
            val ry = event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)
            if (rx != 0f || ry != 0f) {
                FclRuntime.sendCursorDelta(context, rx * RELATIVE_GAIN, ry * RELATIVE_GAIN)
                return
            }
            if (hasLast) {
                FclRuntime.sendCursorDelta(
                    context,
                    (event.x - lastX) * RELATIVE_GAIN,
                    (event.y - lastY) * RELATIVE_GAIN,
                )
            }
            lastX = event.x
            lastY = event.y
            hasLast = true
            return
        }
        val p = toGameCoords(event.x, event.y) ?: return
        FclRuntime.sendPointer(context, p.first, p.second)
    }

    private fun handleButtons(event: MotionEvent) {
        val mask = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE,
            MotionEvent.ACTION_BUTTON_PRESS,
            -> event.buttonState
            MotionEvent.ACTION_BUTTON_RELEASE -> 0
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> 0
            else -> return
        }
        for (i in BUTTONS.indices) {
            val bit = BUTTONS[i]
            val pressed = mask and bit != 0
            val was = mouseButtons and bit != 0
            if (pressed == was) continue
            if (pressed) mouseButtons = mouseButtons or bit else mouseButtons = mouseButtons and bit.inv()
            FclRuntime.sendMouseButton(context, i, pressed)
        }
    }

    private fun releaseAllButtons() {
        for (i in BUTTONS.indices) {
            val bit = BUTTONS[i]
            if (mouseButtons and bit != 0) {
                FclRuntime.sendMouseButton(context, i, false)
            }
        }
        mouseButtons = 0
    }

    /**
     * 屏幕坐标 → 游戏缓冲区坐标。
     *
     * SurfaceView 只占屏幕中间一块（画面比例 / 窗口大小都会缩放它），直接拿
     * 屏幕坐标发进去，鼠标会指到画面外。超出画面的点直接丢弃。
     */
    private fun toGameCoords(x: Float, y: Float): Pair<Float, Float>? {
        val sv = surface() ?: return null
        if (sv.width <= 0 || sv.height <= 0) return null
        val (gw, gh) = gameSize()
        // event.x/y 是宿主内坐标；surfaceView 的位置也是宿主内坐标，直接减。
        val gx = (x - sv.left) / sv.width.toFloat() * gw
        val gy = (y - sv.top) / sv.height.toFloat() * gh
        if (gx < 0 || gy < 0 || gx > gw || gy > gh) return null
        return gx to gy
    }

    private fun isMouseEvent(e: MotionEvent): Boolean {
        if (PhysicalInputWatcher.isMouseSource(e.source)) return true
        val d = InputDevice.getDevice(e.deviceId) ?: return false
        return !PhysicalInputWatcher.isVirtual(d) &&
            PhysicalInputWatcher.isMouseSource(d.sources)
    }

    private fun isPhysicalKeyboard(e: KeyEvent): Boolean {
        val d = e.device ?: return false
        if (PhysicalInputWatcher.isVirtual(d)) return false
        return d.sources and InputDevice.SOURCE_KEYBOARD != 0 &&
            d.keyboardType != InputDevice.KEYBOARD_TYPE_NONE
    }

    companion object {
        /** 相对位移增益：与触摸 OSD 的 0.45 对齐，纯手感系数。 */
        private const val RELATIVE_GAIN = 0.45f

        /** 顺序即 GLFW button index：左 / 右 / 中。 */
        private val BUTTONS = intArrayOf(
            MotionEvent.BUTTON_PRIMARY,
            MotionEvent.BUTTON_SECONDARY,
            MotionEvent.BUTTON_TERTIARY,
        )

    }
}
