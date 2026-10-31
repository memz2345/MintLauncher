package dev.mint.mint

import android.util.Log
import android.graphics.Typeface

/// 从 Flutter assets 里加载图标字体（原生底栏渲染 MaterialIcons 字形用）。
/// 从 NaviFlash NativeMenuHost 中的 IconFonts 提取。
internal object IconFonts {
    private val cache = HashMap<String, Typeface?>()

    fun load(context: android.content.Context, family: String?): Typeface? {
        val key = family ?: "MaterialIcons"
        synchronized(cache) {
            if (cache.containsKey(key)) return cache[key]
        }
        val tf = runCatching { resolve(context, key) }.getOrNull()
        synchronized(cache) { cache[key] = tf }
        return tf
    }

    private fun resolve(context: android.content.Context, family: String): Typeface? {
        val assets = context.assets
        if (family.startsWith("MaterialIcons")) {
            return Typeface.createFromAsset(assets, "flutter_assets/fonts/MaterialIcons-Regular.otf")
        }
        val wanted = family.lowercase().filter { it.isLetterOrDigit() }
        val dirs = listOf(
            "flutter_assets/fonts",
            "flutter_assets/assets/fonts",
            "flutter_assets",
        )
        for (dir in dirs) {
            val names = assets.list(dir) ?: continue
            for (name in names) {
                if (!name.endsWith(".ttf", true) && !name.endsWith(".otf", true)) continue
                val stem = name.substringBeforeLast('.').lowercase().filter { it.isLetterOrDigit() }
                if (stem == wanted || stem.startsWith(wanted)) {
                    return Typeface.createFromAsset(assets, "$dir/$name")
                }
            }
        }
        Log.w("IconFonts", "icon font not found: $family")
        return null
    }
}
