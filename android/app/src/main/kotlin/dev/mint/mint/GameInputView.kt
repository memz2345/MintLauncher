package dev.mint.mint

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import java.util.UUID
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * FCL 风格的虚拟操作面板（纯按键，不用摇杆）。
 *
 * 按键是一组可编辑的**归一化**元件（[ControlButton]），布局存在
 * SharedPreferences 里，游戏内菜单可以随时进出编辑模式拖动位置。
 *
 * 两种元件：
 *  - **按键**（[ControlKind.BUTTON]）：按住发 GLFW keycode（W/A/S/D、SPACE…）；
 *  - **鼠标键**（[ControlKind.MOUSE]）：按住发 mouse button（攻击 / 使用）。
 *
 * 未捕获鼠标时（游戏内菜单 / 背包界面）整层让位给「触摸板」：点哪里光标去
 * 哪里并点一下，拖动则移动光标 —— 这就是 FCL 在菜单里的操作方式。
 */
@SuppressLint("ViewConstructor")
class GameInputView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private val margin = 8f * density

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.6f * density
    }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = 13f * density
        setShadowLayer(3f * density, 0f, 1f * density, Color.argb(150, 0, 0, 0))
    }
    private val editStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.2f * density
        color = Color.argb(190, 255, 255, 255)
        pathEffect = DashPathEffect(floatArrayOf(6f * density, 4f * density), 0f)
    }

    /** 当前布局（可变）。 */
    val buttons: MutableList<ControlButton> = ControlLayout.load(context)

    /** 编辑模式：按键可拖动，且不触发游戏输入。 */
    var editMode: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            releaseEverything()
            invalidate()
        }

    /**
     * 按键是否画出来。
     *
     * 接了物理键鼠时置 false：**收起的是画面上的按钮，不是这层视图** ——
     * 触摸仍然走下面的「触摸板」逻辑（未捕获态点哪指哪、捕获态拖动转视角），
     * 不然接上蓝牙键盘后触摸屏就整个废了。编辑模式下强制画，否则没法拖。
     */
    var controlsVisible: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            releaseEverything()
            invalidate()
        }

    /** 编辑模式下被选中的元件（高亮 + 顶栏显示名字）。 */
    private var selected: ControlButton? = null

    private var dragPointer = -1
    private var dragDx = 0f
    private var dragDy = 0f

    private var lookPointer = -1
    private var lookMoved = false
    private var lastLookX = 0f
    private var lastLookY = 0f

    /**
     * 菜单态（未捕获指针）的「触摸板点击」状态。
     *
     * FCL TouchPad 的 CLICK 模式不是按下即发 LMB：先把指针位置推进游戏，
     * 再用 Choreographer 延后一帧投递鼠标键。GLFW 的 cursorPos 与 mouseButton
     * 在输入队列里跨帧到达时，同帧投递会让背包 / 菜单收到「上一帧的光标位置」
     * 的点击 —— 表现就是物品栏点不动。这里照同样的顺序延迟，[MENU_CLICK_DELAY_MS]
     * 取 33ms（FCL 同值）。
     */
    private var menuClickGesture = false
    private var menuClickPending = false
    private var menuClickHeld = false
    private var menuClickGeneration = 0

    /**
     * 视角灵敏度倍率（FCL MenuSetting.mouseSensitivity 对应物）：捕获态
     * 拖动转视角时乘在原始增量上，1.0 = 原始手感；由 GameActivity 在设置
     * 变化时推过来。
     */
    @Volatile
    private var lookSensitivity = 1f

    /** 本次启动的渲染尺寸（由 GameActivity 在 JVM 启动前推过来）。 */
    private var gameWidth = 1280
    private var gameHeight = 720

    fun setGameSize(width: Int, height: Int) {
        gameWidth = width.coerceAtLeast(1)
        gameHeight = height.coerceAtLeast(1)
    }

    /**
     * 每个键当前被几个虚拟按键按住。组合键里的修饰键可能被两个按钮共用，
     * 直接 set 会在松开其中一个时把另一个的 Ctrl / Shift 也弹起来。
     */
    private val keyHolders = mutableMapOf<Int, Int>()
    private val heldPointers = mutableMapOf<Int, ControlButton>()

    // ───────────────────────── 几何 ─────────────────────────

    /** 按键是 FCL 那种圆角方块，sizeDp 当边长用。 */
    private fun sideOf(b: ControlButton): Float =
        max(36f * density, b.sizeDp * ControlLayout.scale * density)

    private fun rectOf(b: ControlButton): RectF {
        val c = centerOf(b)
        val half = sideOf(b) * 0.5f
        return RectF(c.x - half, c.y - half, c.x + half, c.y + half)
    }

    private fun centerOf(b: ControlButton): PointF {
        val half = sideOf(b) * 0.5f
        val x = (b.nx * width).coerceIn(half + margin, max(half + margin, width - half - margin))
        val y = (b.ny * height).coerceIn(half + margin, max(half + margin, height - half - margin))
        return PointF(x, y)
    }

    private fun buttonAt(x: Float, y: Float): ControlButton? {
        // 后画的在上层，命中判定也按倒序。
        for (i in buttons.indices.reversed()) {
            val b = buttons[i]
            val rect = rectOf(b)
            rect.inset(-5f * density, -5f * density)
            if (rect.contains(x, y)) return b
        }
        return null
    }

    // ───────────────────────── 绘制 ─────────────────────────

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val a = ControlLayout.alpha
        if (editMode) {
            drawEditLayer(canvas)
            return
        }
        // 接了物理键鼠：整层变透明，但 [onTouchEvent] 照常工作 —— 触摸退化成
        // 触摸板，不画按键而已。
        if (!controlsVisible) return
        // FCL 的按键层在 GUI（背包 / 聊天）里也保持可见可点，不再只在
        // 捕获鼠标时绘制 —— 否则开背包想按 E 关闭时按键全消失。
        for (b in buttons) {
            val c = centerOf(b)
            val isHeld = heldPointers.containsValue(b)
            // FCL 默认风格：透明底 + 细描边 + 白字。按下时提亮一点。
            fill.color = if (isHeld) {
                Color.argb((a * 118).toInt(), 255, 255, 255)
            } else {
                Color.argb((a * 30).toInt(), 0, 0, 0)
            }
            stroke.color = Color.argb((a * (if (isHeld) 205 else 120)).toInt(), 255, 255, 255)
            text.color = Color.argb((a * 235).toInt(), 255, 255, 255)

            val rect = rectOf(b)
            val radius = rect.width() * 0.22f
            canvas.drawRoundRect(rect, radius, radius, fill)
            canvas.drawRoundRect(rect, radius, radius, stroke)
            drawLabel(canvas, b.label, c.x, c.y)
        }
    }

    private fun drawEditLayer(canvas: Canvas) {
        for (b in buttons) {
            val c = centerOf(b)
            val isSel = selected?.id == b.id
            fill.color = if (isSel) {
                Color.argb(96, 255, 255, 255)
            } else {
                Color.argb(30, 0, 0, 0)
            }
            text.color = Color.argb(235, 255, 255, 255)
            val rect = rectOf(b)
            val radius = rect.width() * 0.22f
            canvas.drawRoundRect(rect, radius, radius, fill)
            canvas.drawRoundRect(rect, radius, radius, editStroke)
            drawLabel(canvas, b.label, c.x, c.y)
        }
    }

    private fun drawLabel(canvas: Canvas, label: String, x: Float, centerY: Float) {
        // 组合键（CTRL+SHIFT+F5）横向太长，按 "+" 拆成多行竖排；单键仍用
        // 原来的按长度缩字号规则。
        if (label.length > 5 && label.contains('+')) {
            val parts = label.split('+').filter { it.isNotEmpty() }
            if (parts.size > 1) {
                text.textSize = 8.2f * density
                val line = text.textSize * 1.02f
                val top = centerY - (parts.size - 1) * line / 2f +
                    text.textSize * 0.36f
                for (i in parts.indices) {
                    canvas.drawText(parts[i], x, top + i * line, text)
                }
                text.textSize = 13f * density
                return
            }
        }
        // 键位名（E / ESC / SHIFT / SPACE / LMB）比中文长，按长度缩字号，
        // 别顶出按键轮廓。
        text.textSize = when {
            label.length <= 2 -> 13f * density
            label.length == 3 -> 11.5f * density
            label.length == 4 -> 10.5f * density
            else -> 9.2f * density
        }
        canvas.drawText(label, x, centerY + text.textSize * 0.36f, text)
        text.textSize = 13f * density
    }

    // ───────────────────────── 触摸 ─────────────────────────

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (editMode) return handleEditTouch(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = event.actionIndex
                val x = event.getX(idx)
                val y = event.getY(idx)
                val id = event.getPointerId(idx)
                val gaming = FclRuntime.cursorGrabbed
                val hit = buttonAt(x, y)
                InputDebug.log(
                    "OSD DOWN x=$x y=$y gaming=$gaming hit=${hit?.id} w=$width h=$height",
                )
                // 命中按键就发键，不管当前是否捕获鼠标：FCL 在背包 / 聊天
                // 里也能直接用 OSD（例如按 E 关背包）。
                if (hit != null) {
                    if (heldPointers.values.none { it.id == hit.id }) {
                        heldPointers[id] = hit
                        when (hit.kind) {
                            ControlKind.MOUSE ->
                                FclRuntime.sendMouseButton(context, hit.mouseButton, true)
                            else -> pressKeys(hit.keys)
                        }
                    }
                    invalidate()
                    return true
                }
                if (lookPointer == -1) {
                    lookPointer = id
                    lookMoved = false
                    lastLookX = x
                    lastLookY = y
                    if (!gaming) {
                        sendAbsolute(x, y)
                        beginMenuClick()
                        InputDebug.log("OSD 触摸板按下：已发送指针，等待一帧再按 LMB")
                    }
                }
            }

            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.pointerCount) {
                    val id = event.getPointerId(i)
                    val x = event.getX(i)
                    val y = event.getY(i)
                    if (id == lookPointer) {
                        val dx = x - lastLookX
                        val dy = y - lastLookY
                        if (hypot(dx, dy) > 2f) lookMoved = true
                        if (FclRuntime.cursorGrabbed) {
                            FclRuntime.sendCursorDelta(
                                context,
                                dx * 0.45f * lookSensitivity,
                                dy * 0.45f * lookSensitivity,
                            )
                        } else {
                            sendAbsolute(x, y)
                        }
                        lastLookX = x
                        lastLookY = y
                    } else {
                        // 手指从按键上滑出去：松开它（跟 FCL 一致）。
                        val held = heldPointers[id]
                        if (held != null) {
                            val c = centerOf(held)
                            if (hypot(x - c.x, y - c.y) > sideOf(held) * 0.85f) {
                                releaseHeld(id)
                                invalidate()
                            }
                        }
                    }
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> {
                val id = event.getPointerId(event.actionIndex)
                if (id == lookPointer) {
                    InputDebug.log(
                        "OSD UP gaming=${FclRuntime.cursorGrabbed} moved=$lookMoved menu=$menuClickGesture",
                    )
                    if (menuClickGesture) {
                        if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
                            cancelMenuClick()
                        } else {
                            finishMenuClick()
                        }
                    } else if (FclRuntime.cursorGrabbed && !lookMoved) {
                        // 游戏里轻点画面 = 左键单击（挖 / 攻击）。
                        FclRuntime.sendMouseButton(context, 0, true)
                        releaseClick()
                    }
                    lookPointer = -1
                }
                releaseHeld(id)
                if (event.actionMasked == MotionEvent.ACTION_UP ||
                    event.actionMasked == MotionEvent.ACTION_CANCEL
                ) {
                    // 抬起的手指不一定是发起手势的那根（多指 / 系统打断），
                    // 收尾的点击也要在这里兜住，否则菜单 LMB 会一直按着。
                    if (menuClickGesture) {
                        if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
                            cancelMenuClick()
                        } else {
                            finishMenuClick()
                        }
                    }
                    // 多指 / 被系统打断时 ACTION_UP 的 id 不一定是原来那个，
                    // 统一释放，避免 W / 空格 / 鼠标键卡住。菜单点击的延迟
                    // 释放交给 finishMenuClick，这里别把它取消掉。
                    releaseEverything(cancelClick = false)
                }
                invalidate()
            }
        }
        return true
    }

    private fun handleEditTouch(event: MotionEvent): Boolean {
        val idx = event.actionIndex
        val x = event.getX(idx)
        val y = event.getY(idx)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val hit = buttonAt(x, y)
                selected = hit
                if (hit != null) {
                    dragPointer = event.getPointerId(idx)
                    val c = centerOf(hit)
                    dragDx = c.x - x
                    dragDy = c.y - y
                }
                invalidate()
            }
            MotionEvent.ACTION_MOVE -> {
                if (dragPointer >= 0) {
                    val i = event.findPointerIndex(dragPointer)
                    if (i >= 0) {
                        val b = selected ?: return true
                        val cx = event.getX(i) + dragDx
                        val cy = event.getY(i) + dragDy
                        b.nx = (cx / width).coerceIn(0.02f, 0.98f)
                        b.ny = (cy / height).coerceIn(0.02f, 0.98f)
                        invalidate()
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragPointer >= 0) {
                    ControlLayout.save(context, buttons)
                }
                dragPointer = -1
                invalidate()
            }
        }
        return true
    }

    // ───────────────────────── 输入映射 ─────────────────────────

    private fun pressKeys(keys: List<Int>) {
        for (key in keys) {
            if (key <= 0) continue
            val n = keyHolders[key] ?: 0
            keyHolders[key] = n + 1
            if (n == 0) FclRuntime.sendKey(context, key, true)
        }
    }

    private fun releaseKeys(keys: List<Int>) {
        for (key in keys.asReversed()) {
            if (key <= 0) continue
            val n = keyHolders[key] ?: 0
            if (n <= 1) {
                keyHolders.remove(key)
                if (n == 1) FclRuntime.sendKey(context, key, false)
            } else {
                keyHolders[key] = n - 1
            }
        }
    }

    /** 编辑器里长按键位 / 试按组合：按下后短暂保持，再自动松开。 */
    fun tapKeys(keys: List<Int>, holdMs: Long = 180) {
        val clean = keys.distinct().filter { it > 0 }
        if (clean.isEmpty()) return
        pressKeys(clean)
        postDelayed({ releaseKeys(clean) }, holdMs)
    }

    private fun releaseHeld(pointerId: Int) {
        val b = heldPointers.remove(pointerId) ?: return
        when (b.kind) {
            ControlKind.MOUSE -> FclRuntime.sendMouseButton(context, b.mouseButton, false)
            ControlKind.BUTTON -> releaseKeys(b.keys)
        }
    }

    private fun releaseEverything(cancelClick: Boolean = true) {
        lookPointer = -1
        dragPointer = -1
        if (cancelClick) cancelMenuClick()
        for (id in heldPointers.keys.toList()) releaseHeld(id)
        // 试按的延时松开可能还没跑；这里直接清掉，别让键卡在按下状态。
        for (key in keyHolders.keys.toList()) {
            if ((keyHolders[key] ?: 0) > 0) FclRuntime.sendKey(context, key, false)
        }
        keyHolders.clear()
        // 菜单点击的 LMB 由 cancelMenuClick / finishMenuClick 负责收尾：
        // 这里再补一次 up 会把「延迟按下」的顺序打乱（up 先于 down 到达）。
        invalidate()
    }

    private fun sendAbsolute(x: Float, y: Float) {
        val w = width.coerceAtLeast(1)
        val h = height.coerceAtLeast(1)
        FclRuntime.sendPointer(
            context,
            x / w * gameWidth.toFloat(),
            y / h * gameHeight.toFloat(),
        )
    }

    /** 菜单按钮 / 世界列表需要按住一小段时间才会稳定触发。 */
    private fun releaseClick() {
        postDelayed({ FclRuntime.sendMouseButton(context, 0, false) }, 60)
    }

    /**
     * 菜单态点击：指针先走，LMB 延后一帧再按下（FCL TouchPad CLICK 模式）。
     * 背包里「点一下什么都没发生」就是因为按下和移动同帧到达，游戏拿旧坐标
     * 判定命中。
     */
    private fun beginMenuClick() {
        cancelMenuClick()
        val generation = ++menuClickGeneration
        menuClickGesture = true
        menuClickPending = true
        postDelayed({
            if (generation != menuClickGeneration || !menuClickPending) {
                return@postDelayed
            }
            menuClickPending = false
            // 期间切进捕获态（比如背包里按了 ESC）就不要再补这一下。
            if (!FclRuntime.cursorGrabbed) {
                FclRuntime.sendMouseButton(context, 0, true)
                menuClickHeld = true
            }
        }, MENU_CLICK_DELAY_MS)
    }

    /** 松手：等延迟按下真正发生后再补释放，保证 press → release 的顺序。 */
    private fun finishMenuClick() {
        menuClickGesture = false
        val generation = menuClickGeneration
        val wait = if (menuClickPending) MENU_CLICK_DELAY_MS + 30L else 30L
        postDelayed({
            if (generation != menuClickGeneration) return@postDelayed
            if (menuClickHeld) {
                FclRuntime.sendMouseButton(context, 0, false)
                menuClickHeld = false
            }
            menuClickPending = false
        }, wait)
    }

    private fun cancelMenuClick() {
        menuClickGeneration++
        menuClickGesture = false
        menuClickPending = false
        if (menuClickHeld) {
            FclRuntime.sendMouseButton(context, 0, false)
            menuClickHeld = false
        }
    }

    /** 界面切换 / 退到后台时清掉按住状态，避免 W 键卡住。 */
    fun resetInput() {
        releaseEverything()
    }

    /** 恢复默认布局（菜单里「重置按键」）。 */
    fun resetToDefault() {
        releaseEverything()
        val custom = buttons.filter { it.custom }
        buttons.clear()
        buttons.addAll(ControlLayout.defaults())
        buttons.addAll(custom)
        ControlLayout.scale = 1f
        ControlLayout.alpha = 1f
        ControlLayout.save(context, buttons)
        selected = null
        invalidate()
    }

    /** 用户自建按键（自定义页面用来列出来编辑 / 删除）。 */
    fun customButtons(): List<ControlButton> = buttons.filter { it.custom }

    /**
     * 新建一个自定义键，落到离画面中心最近、不和现有按键重叠的空位。
     * 位置仍然可拖动；这里只保证刚创建时不会压在别的键上。
     */
    fun addCustomButton(label: String, keys: List<Int>): ControlButton? {
        val clean = keys.distinct().filter { it > 0 }
        if (clean.isEmpty()) return null
        releaseEverything()
        val (nx, ny) = freeSpotFor(52f)
        val button = ControlButton(
            id = "custom_" + UUID.randomUUID().toString().take(8),
            label = label,
            keyCode = clean.first(),
            mouseButton = -1,
            nx = nx,
            ny = ny,
            sizeDp = 52f,
            kind = ControlKind.BUTTON,
            keys = clean.toMutableList(),
            custom = true,
        )
        buttons.add(button)
        ControlLayout.save(context, buttons)
        invalidate()
        return button
    }

    fun updateCustomButton(id: String, label: String, keys: List<Int>): Boolean {
        val button = buttons.firstOrNull { it.id == id && it.custom } ?: return false
        val clean = keys.distinct().filter { it > 0 }
        if (clean.isEmpty()) return false
        releaseEverything()
        button.keys.clear()
        button.keys.addAll(clean)
        button.keyCode = clean.first()
        button.label = label
        ControlLayout.save(context, buttons)
        invalidate()
        return true
    }

    fun removeCustomButton(id: String): Boolean {
        val button = buttons.firstOrNull { it.id == id && it.custom } ?: return false
        releaseEverything()
        buttons.remove(button)
        if (selected?.id == id) selected = null
        ControlLayout.save(context, buttons)
        invalidate()
        return true
    }

    private fun freeSpotFor(sizeDp: Float): Pair<Float, Float> {
        if (width <= 0 || height <= 0) return 0.5f to 0.5f
        val side = max(36f * density, sizeDp * ControlLayout.scale * density)
        val halfW = side / 2f / width
        val halfH = side / 2f / height
        fun free(nx: Float, ny: Float): Boolean {
            for (b in buttons) {
                val bw = sideOf(b) / 2f / width
                val bh = sideOf(b) / 2f / height
                if (abs(nx - b.nx) < halfW + bw + 0.012f &&
                    abs(ny - b.ny) < halfH + bh + 0.012f
                ) {
                    return false
                }
            }
            return true
        }
        // 避开屏幕中心（准星/菜单按钮区），优先右上、左上这类常被忽略的空位
        val xs = listOf(0.66f, 0.60f, 0.72f, 0.54f, 0.30f, 0.36f, 0.24f, 0.78f)
        val ys = listOf(0.34f, 0.46f, 0.22f, 0.58f, 0.70f)
        for (y in ys) {
            for (x in xs) {
                if (free(x, y)) return x to y
            }
        }
        return 0.66f to 0.34f
    }

    /** 外观滑杆变化后调用：重绘即可（尺寸在 sideOf 里实时算）。 */
    fun refreshAppearance() {
        invalidate()
    }

    /** 视角灵敏度变化后调用（设置页 / 游戏内菜单改设置时）。 */
    fun setLookSensitivity(value: Float) {
        lookSensitivity = value.coerceIn(
            GameTweaksSettings.MIN_LOOK_SENSITIVITY,
            GameTweaksSettings.MAX_LOOK_SENSITIVITY,
        )
    }

    /** 布局里最大的按键边长（dp），菜单用来算滑杆上限，避免按键糊在一起。 */
    fun largestButtonDp(): Float = buttons.maxOfOrNull { it.sizeDp } ?: 66f

    /** 供 GameActivity 判断是否还有未保存的编辑。 */
    fun persist() {
        ControlLayout.save(context, buttons)
    }

    private companion object {
        /** FCL TouchPad 的点击延迟：等指针位置先被游戏处理一帧。 */
        const val MENU_CLICK_DELAY_MS = 33L
    }
}
