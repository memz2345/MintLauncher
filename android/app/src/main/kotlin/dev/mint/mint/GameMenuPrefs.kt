package dev.mint.mint

import android.content.Context

/** 游戏内菜单的少量偏好（悬浮球位置 / 锁定状态）。只在 `:game` 进程用。 */
object GameMenuPrefs {
    private const val PREFS = "mint_game_menu"
    private const val KEY_X = "ball.x"
    private const val KEY_Y = "ball.y"
    private const val KEY_LOCKED = "ball.locked"

    fun ballX(context: Context): Float =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(KEY_X, 0.5f)

    fun ballY(context: Context): Float =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getFloat(KEY_Y, 0.12f)

    fun saveBall(context: Context, nx: Float, ny: Float) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putFloat(KEY_X, nx.coerceIn(0f, 1f))
            .putFloat(KEY_Y, ny.coerceIn(0f, 1f))
            .apply()
    }

    fun locked(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_LOCKED, false)

    fun setLocked(context: Context, locked: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_LOCKED, locked)
            .apply()
    }
}
