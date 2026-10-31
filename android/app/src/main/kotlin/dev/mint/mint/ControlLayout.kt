package dev.mint.mint

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** 控制元件的类型。 */
enum class ControlKind {
    /** 普通按键：按下发 keyboard（W/A/S/D、SPACE…）。 */
    BUTTON,

    /** 鼠标键：按下发 mouse button。 */
    MOUSE,
}

/**
 * 一个可放置的控制元件。
 *
 * 坐标是**归一化**的（0..1，相对游戏画面矩形），这样换分辨率 / 换设备时
 * 布局不会跑位。尺寸用 dp，跟屏幕密度走。
 */
class ControlButton(
    val id: String,
    var label: String,
    var keyCode: Int,
    var mouseButton: Int,
    var nx: Float,
    var ny: Float,
    var sizeDp: Float,
    var kind: ControlKind,
    /** 按下时依次按下的键（组合键在释放时倒序松开）。单键按钮只有一项。 */
    var keys: MutableList<Int> = mutableListOf(keyCode),
    /** 用户自建按键：可以在自定义页面里改绑定 / 删除。 */
    var custom: Boolean = false,
) {
    val isMouse: Boolean get() = kind == ControlKind.MOUSE

    fun copyOf(): ControlButton =
        ControlButton(
            id,
            label,
            keyCode,
            mouseButton,
            nx,
            ny,
            sizeDp,
            kind,
            keys.toMutableList(),
            custom,
        )

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("label", label)
        put("key", keyCode)
        put("keys", JSONArray(keys))
        put("mouse", mouseButton)
        put("nx", nx.toDouble())
        put("ny", ny.toDouble())
        put("size", sizeDp.toDouble())
        put("kind", kind.name)
        put("custom", custom)
    }

    companion object {
        fun fromJson(o: JSONObject): ControlButton {
            val kind = runCatching { ControlKind.valueOf(o.optString("kind")) }
                .getOrDefault(ControlKind.BUTTON)
            val keys = mutableListOf<Int>()
            o.optJSONArray("keys")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val key = arr.optInt(i, 0)
                    if (key > 0) keys.add(key)
                }
            }
            // v3 之前的布局只有单个 key。
            if (keys.isEmpty() && kind == ControlKind.BUTTON) {
                o.optInt("key").takeIf { it > 0 }?.let { keys.add(it) }
            }
            return ControlButton(
                id = o.optString("id"),
                label = o.optString("label"),
                keyCode = keys.firstOrNull() ?: o.optInt("key"),
                mouseButton = o.optInt("mouse", -1),
                nx = o.optDouble("nx", 0.5).toFloat(),
                ny = o.optDouble("ny", 0.5).toFloat(),
                sizeDp = o.optDouble("size", 52.0).toFloat(),
                kind = kind,
                keys = keys,
                custom = o.optBoolean("custom", false),
            )
        }
    }
}

/**
 * FCL 风格控制面板的布局与外观，持久化在 SharedPreferences 里。
 *
 * 默认布局照 FCL 的「按键模式」排：左下 WASD 十字、右下动作键、右上功能键。
 * 编辑模式下拖动即可改位置，大小 / 透明度走菜单里的滑杆（FCL 是在按键右下
 * 角拖拽改大小，单手在手机上很难命中，滑杆更实用）。
 */
object ControlLayout {
    private const val PREFS = "mint_game_controls"
    // v2：摇杆布局换成 WASD 按键，旧布局直接弃用重铺默认。
    private const val KEY_LAYOUT = "layout.v2"
    private const val KEY_SCALE = "scale"
    private const val KEY_ALPHA = "alpha"

    // GLFW key codes（发给 FclRuntime.sendKey 后再换算成 FCL 键码）
    private const val KEY_W = 87
    private const val KEY_A = 65
    private const val KEY_S = 83
    private const val KEY_D = 68
    private const val KEY_SPACE = 32
    private const val KEY_E = 69
    private const val KEY_Q = 81
    private const val KEY_T = 84
    private const val KEY_ESC = 256
    private const val KEY_LEFT_SHIFT = 340
    private const val KEY_LEFT_CONTROL = 341
    private const val KEY_F5 = 294
    private const val KEY_TAB = 258
    private const val KEY_1 = 49

    /** 全局按键缩放（0.7–1.6）。 */
    var scale: Float = 1f

    /** 全局不透明度（0.25–1）。 */
    var alpha: Float = 1f

    fun defaults(): MutableList<ControlButton> = mutableListOf(
        // 左下：FCL「按键模式」那样的 WASD 十字 —— 按住即走，比摇杆更好按准
        // 间距按画面 640×360dp 算：0.09 ≈ 57dp，刚好不重叠（键宽 52dp）。
        ControlButton("forward", "W", KEY_W, -1, 0.150f, 0.550f, 52f, ControlKind.BUTTON),
        ControlButton("left", "A", KEY_A, -1, 0.060f, 0.780f, 52f, ControlKind.BUTTON),
        ControlButton("back", "S", KEY_S, -1, 0.150f, 0.780f, 52f, ControlKind.BUTTON),
        ControlButton("right", "D", KEY_D, -1, 0.240f, 0.780f, 52f, ControlKind.BUTTON),
        // 右下：动作 —— 标签直接显示键位名
        ControlButton("jump", "SPACE", KEY_SPACE, -1, 0.88f, 0.80f, 66f, ControlKind.BUTTON),
        ControlButton("sneak", "SHIFT", KEY_LEFT_SHIFT, -1, 0.74f, 0.88f, 52f, ControlKind.BUTTON),
        ControlButton("sprint", "CTRL", KEY_LEFT_CONTROL, -1, 0.74f, 0.70f, 52f, ControlKind.BUTTON),
        ControlButton("attack", "LMB", 0, 0, 0.90f, 0.58f, 60f, ControlKind.MOUSE),
        ControlButton("use", "RMB", 0, 1, 0.80f, 0.44f, 56f, ControlKind.MOUSE),
        // 右上：功能
        ControlButton("inventory", "E", KEY_E, -1, 0.955f, 0.14f, 46f, ControlKind.BUTTON),
        ControlButton("drop", "Q", KEY_Q, -1, 0.875f, 0.14f, 46f, ControlKind.BUTTON),
        ControlButton("perspective", "F5", KEY_F5, -1, 0.795f, 0.14f, 46f, ControlKind.BUTTON),
        ControlButton("chat", "T", KEY_T, -1, 0.955f, 0.27f, 46f, ControlKind.BUTTON),
        ControlButton("tab", "TAB", KEY_TAB, -1, 0.875f, 0.27f, 46f, ControlKind.BUTTON),
        ControlButton("slot1", "1", KEY_1, -1, 0.795f, 0.27f, 46f, ControlKind.BUTTON),
        // ESC 必须避开左上角那两个宿主按钮（× 退出 / ≡ 控制面板）：放右侧
        // 中段，和 use / attack 保持一个身位以上。
        ControlButton("esc", "ESC", KEY_ESC, -1, 0.955f, 0.40f, 46f, ControlKind.BUTTON),
    )

    fun load(context: Context): MutableList<ControlButton> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        scale = prefs.getFloat(KEY_SCALE, 1f)
        alpha = prefs.getFloat(KEY_ALPHA, 1f)
        val raw = prefs.getString(KEY_LAYOUT, null) ?: return defaults()
        return try {
            val arr = JSONArray(raw)
            val out = mutableListOf<ControlButton>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(ControlButton.fromJson(o))
            }
            // 旧布局存的是「跳 / 潜行 / 菜单」这类中文标签；按键 id 不变，
            // 载入时把已知 id 的标签换成键位名（不丢用户拖过的位置）。
            val names = defaults().associate { it.id to it.label }
            for (b in out) names[b.id]?.let { b.label = it }
            // 布局里缺的键（升级新增的）补回默认位置，别让游戏里少按键。
            val known = out.map { it.id }.toSet()
            out.addAll(defaults().filter { it.id !in known })
            out
        } catch (_: Throwable) {
            defaults()
        }
    }

    fun save(context: Context, buttons: List<ControlButton>) {
        val arr = JSONArray()
        for (b in buttons) arr.put(b.toJson())
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_LAYOUT, arr.toString())
            .putFloat(KEY_SCALE, scale)
            .putFloat(KEY_ALPHA, alpha)
            .apply()
    }

    fun saveAppearance(context: Context, scaleValue: Float, alphaValue: Float) {
        scale = scaleValue.coerceIn(0.7f, 1.6f)
        alpha = alphaValue.coerceIn(0.25f, 1f)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putFloat(KEY_SCALE, scale)
            .putFloat(KEY_ALPHA, alpha)
            .apply()
    }
}
