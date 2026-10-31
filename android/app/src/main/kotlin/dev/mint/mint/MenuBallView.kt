package dev.mint.mint

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.ImageView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * FCL 同款游戏内悬浮球：40dp 圆形、应用图标、细描边，可拖动换位置，
 * 轻点打开左右两侧菜单。位置按屏幕比例持久化。
 *
 * 故意不做自绘 Canvas：图标是 ImageView，圆是 GradientDrawable。
 */
@SuppressLint("ClickableViewAccessibility")
class MenuBallView(context: Context) : ImageView(context) {
    var onTap: (() -> Unit)? = null

    var locked: Boolean = false
        set(value) {
            field = value
        }

    private val density = resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val longPressTimeout = ViewConfiguration.getLongPressTimeout()

    private var downX = 0f
    private var downY = 0f
    private var downRawX = 0f
    private var downRawY = 0f
    private var downAt = 0L
    private var moved = false

    init {
        setImageResource(R.mipmap.ic_launcher)
        scaleType = ScaleType.FIT_CENTER
        val pad = (7 * density).roundToInt()
        setPadding(pad, pad, pad, pad)
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0x4D000000)
            setStroke((1.4f * density).roundToInt(), 0x80FFFFFF.toInt())
        }
        elevation = 10 * density
        isClickable = true
        isFocusable = false

        setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    InputDebug.log("悬浮球 DOWN x=${event.x} y=${event.y} w=$width h=$height")
                    downX = event.x
                    downY = event.y
                    downRawX = event.rawX
                    downRawY = event.rawY
                    downAt = event.eventTime
                    moved = false
                    animate().scaleX(0.92f).scaleY(0.92f).setDuration(70L).start()
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!locked) {
                        val parentW = (parent as? android.view.View)?.width ?: return@setOnTouchListener true
                        val parentH = (parent as? android.view.View)?.height ?: return@setOnTouchListener true
                        val dx = event.x - downX
                        val dy = event.y - downY
                        if (abs(event.rawX - downRawX) > touchSlop ||
                            abs(event.rawY - downRawY) > touchSlop
                        ) {
                            moved = true
                        }
                        if (moved) {
                            x = (x + dx).coerceIn(0f, (parentW - width).toFloat())
                            y = (y + dy).coerceIn(0f, (parentH - height).toFloat())
                        }
                    }
                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    animate().scaleX(1f).scaleY(1f).setDuration(90L).start()
                    val tapped = !moved &&
                        abs(event.rawX - downRawX) <= touchSlop &&
                        abs(event.rawY - downRawY) <= touchSlop &&
                        event.eventTime - downAt <= longPressTimeout
                    if (moved && !locked) savePosition()
                    InputDebug.log(
                        "悬浮球 UP moved=$moved tapped=$tapped dt=${event.eventTime - downAt}",
                    )
                    if (tapped && event.actionMasked == MotionEvent.ACTION_UP) {
                        performClick()
                        onTap?.invoke()
                    }
                    true
                }

                else -> true
            }
        }
    }

    /** 由 Activity 在根布局量好之后调用，把归一化位置还原成像素坐标。 */
    fun restorePosition() {
        post {
            val parentView = parent as? android.view.View ?: return@post
            val parentW = parentView.width
            val parentH = parentView.height
            if (parentW <= 0 || parentH <= 0) return@post
            val nx = GameMenuPrefs.ballX(context)
            val ny = GameMenuPrefs.ballY(context)
            x = (parentW * nx - width / 2f)
                .coerceIn(0f, (parentW - width).toFloat())
            y = (parentH * ny - height / 2f)
                .coerceIn(0f, (parentH - height).toFloat())
        }
    }

    private fun savePosition() {
        val parentView = parent as? android.view.View ?: return
        val parentW = parentView.width
        val parentH = parentView.height
        if (parentW <= 0 || parentH <= 0) return
        val nx = (x + width / 2f) / parentW
        val ny = (y + height / 2f) / parentH
        GameMenuPrefs.saveBall(context, nx, ny)
    }
}
