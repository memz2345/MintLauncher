package dev.mint.mint.compose

/**
 * 自定义虚拟按键可绑定的键位表。
 *
 * code 是 GLFW keycode，和 [dev.mint.mint.ControlButton] / FclRuntime.sendKey
 * 走同一套；标签只用于界面和按键上的组合键缩写。
 */
data class GameKey(val code: Int, val label: String)

object GameKeyCatalog {
    const val MAX_KEYS = 4

    val letters: List<GameKey> = ('A'..'Z').map { GameKey(it.code, it.toString()) }

    val digits: List<GameKey> = ('0'..'9').map { GameKey(it.code, it.toString()) }

    val function: List<GameKey> = buildList {
        for (i in 1..12) add(GameKey(289 + i, "F$i"))
        add(GameKey(256, "ESC"))
        add(GameKey(258, "TAB"))
        add(GameKey(257, "ENTER"))
        add(GameKey(32, "SPACE"))
        add(GameKey(259, "BACK"))
        add(GameKey(261, "DEL"))
        add(GameKey(260, "INS"))
        add(GameKey(268, "HOME"))
        add(GameKey(269, "END"))
        add(GameKey(266, "PGUP"))
        add(GameKey(267, "PGDN"))
        add(GameKey(265, "UP"))
        add(GameKey(264, "DOWN"))
        add(GameKey(263, "LEFT"))
        add(GameKey(262, "RIGHT"))
        add(GameKey(280, "CAPS"))
        add(GameKey(282, "NUM"))
        add(GameKey(281, "SCRLK"))
        add(GameKey(283, "PRTSC"))
        add(GameKey(284, "PAUSE"))
    }

    val modifiers: List<GameKey> = listOf(
        GameKey(341, "CTRL"),
        GameKey(340, "SHIFT"),
        GameKey(342, "ALT"),
        GameKey(343, "WIN"),
        GameKey(345, "RCTRL"),
        GameKey(344, "RSHIFT"),
        GameKey(346, "RALT"),
        GameKey(347, "RWIN"),
    )

    val symbols: List<GameKey> = listOf(
        GameKey(45, "-"),
        GameKey(61, "="),
        GameKey(91, "["),
        GameKey(93, "]"),
        GameKey(92, "\\"),
        GameKey(59, ";"),
        GameKey(39, "'"),
        GameKey(44, ","),
        GameKey(46, "."),
        GameKey(47, "/"),
        GameKey(96, "`"),
    )

    private val labels: Map<Int, String> =
        (letters + digits + function + modifiers + symbols)
            .associate { it.code to it.label }

    private val modifierCodes: Set<Int> = modifiers.map { it.code }.toSet()

    fun labelOf(code: Int): String = labels[code] ?: "K$code"

    fun isModifier(code: Int): Boolean = code in modifierCodes

    /** 修饰键排前面：CTRL + C 必须先按住 CTRL 再按 C。 */
    fun ordered(keys: List<Int>): List<Int> {
        val clean = keys.distinct()
        return clean.filter { isModifier(it) } + clean.filterNot { isModifier(it) }
    }

    fun comboLabel(keys: List<Int>): String =
        keys.joinToString("+") { labelOf(it) }
}
