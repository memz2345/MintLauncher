@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package dev.mint.mint.compose

import dev.mint.mint.BootAnimation

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ContainedLoadingIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color as ComposeColor
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max

/**
 * 跳到游戏 Activity 时的首帧加载层（Compose M3E LoadingIndicator）。
 *
 * JVM + LWJGL 初始化要几十秒，这段时间 SurfaceView 是纯黑的。加载层放在
 * **独立 Dialog 窗口**里：SurfaceView 的 surface 是单独的 SurfaceFlinger
 * 图层，普通 View / ComposeView 即使 elevation 再高也可能被它盖住；独立
 * 窗口一定在 Activity 窗口之上。FCL 的 FPS 计数器一涨（游戏真的画出第一
 * 帧）就淡出，把画面交还给游戏。
 */
class GameLoadingOverlay(private val activity: Activity) {
    private var dialog: Dialog? = null
    private var host: ComposeHostOwner? = null

    fun show(versionLabel: String, bootAnimationDir: String = "") {
        if (dialog != null) return
        val d = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        val compose = ComposeView(activity)
        val owner = ComposeHostOwner()
        owner.start()
        owner.attachTo(compose)
        compose.setContent {
            MintGameTheme {
                if (bootAnimationDir.isNotEmpty()) {
                    BootAnimationScreen(
                        dir = bootAnimationDir,
                        versionLabel = versionLabel.ifBlank { "Minecraft" },
                    )
                } else {
                    LoadingScreen(versionLabel.ifBlank { "Minecraft" })
                }
            }
        }
        d.setContentView(compose)
        d.setCancelable(false)
        d.setCanceledOnTouchOutside(false)
        val window = d.window
        if (window != null) {
            owner.attachTo(window.decorView)
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            window.addFlags(
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_FULLSCREEN,
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                window.attributes = window.attributes.apply {
                    layoutInDisplayCutoutMode =
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
            hideSystemBars(window)
        }
        d.show()
        dialog = d
        host = owner
        // 窗口 attach 之后再把系统栏藏掉才稳（show 之前设置会被部分 ROM 重置）。
        window?.decorView?.post { window?.let { hideSystemBars(it) } }
    }

    fun dismiss() {
        val d = dialog ?: return
        val owner = host
        dialog = null
        host = null
        val content = d.window?.decorView
        if (content == null || activity.isFinishing || activity.isDestroyed) {
            try {
                if (d.isShowing) d.dismiss()
            } catch (_: Throwable) {
            }
            owner?.destroy()
            return
        }
        content.animate()
            .alpha(0f)
            .setDuration(260L)
            .withEndAction {
                // 淡出期间 Activity 可能已经被系统回收 / finish；此时
                // Dialog 的 DecorView 已脱离 WindowManager，再 dismiss
                // 会抛 "View not attached to window manager"。
                try {
                    if (d.isShowing && !activity.isFinishing && !activity.isDestroyed) {
                        d.dismiss()
                    }
                } catch (_: Throwable) {
                }
                owner?.destroy()
            }
            .start()
    }

    private fun hideSystemBars(window: android.view.Window) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                )
        }
    }
}

/**
 * 主题开机动画（MIUI `boots/bootanimation.zip`）。
 *
 * 逐帧解码在 IO 线程，播到最后一组循环（`p` 组）直到游戏出第一帧；
 * 解析失败 / 没有可用帧就退回普通加载层。
 */
@Composable
private fun BootAnimationScreen(dir: String, versionLabel: String) {
    var bitmap by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var failed by remember { mutableStateOf(false) }

    LaunchedEffect(dir) {
        val animation = withContext(Dispatchers.IO) { BootAnimation.load(File(dir)) }
        if (animation == null) {
            failed = true
            return@LaunchedEffect
        }
        var partIndex = 0
        while (true) {
            val part = animation.parts[partIndex]
            for (frame in part.frames) {
                val decoded = withContext(Dispatchers.IO) { animation.decode(frame) }
                if (decoded != null) bitmap = decoded.asImageBitmap()
                delay(max(16L, 1000L / animation.fps))
            }
            if (part.pauseMs > 0) delay(part.pauseMs)
            partIndex = if (partIndex + 1 < animation.parts.size) {
                partIndex + 1
            } else {
                animation.parts.indexOfLast { it.loop }.coerceAtLeast(0)
            }
        }
    }

    if (failed) {
        LoadingScreen(versionLabel)
        return
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(ComposeColor.Black),
        contentAlignment = Alignment.Center,
    ) {
        bitmap?.let {
            Image(
                bitmap = it,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
        }
        Text(
            versionLabel,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 26.dp),
            color = MintTextVariant,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun LoadingScreen(versionLabel: String) {
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(ComposeColor(0xFF1B1B23), ComposeColor(0xFF0E0E12)),
                    radius = 1400f,
                ),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            ContainedLoadingIndicator(
                modifier = Modifier.size(96.dp),
                containerColor = MintBlue.copy(alpha = 0.16f),
                indicatorColor = MintBlue,
                containerShape = RoundedCornerShape(28.dp),
            )
            Spacer(Modifier.height(26.dp))
            Text(
                versionLabel,
                color = MintText,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 32.dp),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "正在启动 Minecraft…",
                color = MintTextVariant,
                fontSize = 12.5.sp,
            )
        }
        Text(
            "MINT",
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = 24.dp, bottom = 22.dp),
            color = MintTextVariant.copy(alpha = 0.45f),
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 2.sp,
        )
    }
}
