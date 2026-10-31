package dev.mint.mint.compose

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 游戏崩溃 / 启动失败的日志弹窗（FCL JVMCrashActivity 的 Compose 版）。
 *
 * 和加载层一样放在**独立 Dialog 窗口**里：SurfaceView 是单独的 SurfaceFlinger
 * 图层，普通 View 盖不住；JVM 崩掉以后 Activity 还剩这一层窗口可以展示日志。
 */
class GameCrashOverlay(
    private val activity: Activity,
    private val onBackToLauncher: () -> Unit,
    private val onExit: () -> Unit,
) {
    private var dialog: Dialog? = null
    private var host: ComposeHostOwner? = null

    val showing: Boolean get() = dialog != null

    fun show(
        title: String,
        versionLabel: String,
        summary: String,
        detail: String,
        log: String,
    ) {
        if (dialog != null) return
        val d = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        val compose = ComposeView(activity)
        val owner = ComposeHostOwner()
        owner.start()
        owner.attachTo(compose)
        compose.setContent {
            MintGameTheme {
                CrashScreen(
                    title = title,
                    versionLabel = versionLabel,
                    summary = summary,
                    detail = detail,
                    log = log,
                    onCopy = { copyLog("$detail\n\n$log") },
                    onBack = {
                        dismiss()
                        onBackToLauncher()
                    },
                    onExit = {
                        dismiss()
                        onExit()
                    },
                )
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
        window?.decorView?.post { window?.let { hideSystemBars(it) } }
    }

    fun dismiss() {
        val d = dialog ?: return
        val owner = host
        dialog = null
        host = null
        try {
            if (d.isShowing) d.dismiss()
        } catch (_: Throwable) {
        }
        owner?.destroy()
    }

    private fun copyLog(text: String) {
        try {
            val cm = activity.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("Mint crash log", text))
        } catch (_: Throwable) {
        }
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

@Composable
private fun CrashScreen(
    title: String,
    versionLabel: String,
    summary: String,
    detail: String,
    log: String,
    onCopy: () -> Unit,
    onBack: () -> Unit,
    onExit: () -> Unit,
) {
    // 游戏内浮层恒定 Material：颜色一律取 MaterialTheme 的语义色，不写死
    // miuix 那套手抄色值。这样换主题 / 换 M3 版本时观感跟着走，也不会出现
    // 「按钮是 Material 形状、颜色却是另一套」的割裂感。
    val cs = MaterialTheme.colorScheme
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(cs.surface, cs.background),
                    radius = 1400f,
                ),
            )
            .padding(horizontal = 18.dp, vertical = 22.dp),
        contentAlignment = Alignment.Center,
    ) {
        val maxHeight = LocalConfiguration.current.screenHeightDp.dp - 44.dp
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = maxHeight)
                .background(cs.surfaceContainerHigh, RoundedCornerShape(26.dp))
                .padding(20.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(42.dp)
                        .background(cs.error.copy(alpha = 0.16f), RoundedCornerShape(14.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.BugReport,
                        contentDescription = null,
                        tint = cs.error,
                        modifier = Modifier.size(24.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        title,
                        color = cs.onSurface,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        versionLabel.ifBlank { "Minecraft" },
                        color = cs.onSurfaceVariant,
                        fontSize = 11.5.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.height(14.dp))
            if (summary.isNotBlank()) {
                Text(
                    summary,
                    color = cs.error,
                    fontSize = 12.5.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(Modifier.height(5.dp))
            }
            if (detail.isNotBlank()) {
                Text(
                    detail,
                    color = cs.onSurfaceVariant,
                    fontSize = 11.5.sp,
                    lineHeight = 16.sp,
                )
                Spacer(Modifier.height(10.dp))
            }
            Text(
                "日志",
                color = cs.onSurfaceVariant,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(6.dp))
            val logScroll = rememberScrollState()
            LaunchedEffect(log) {
                // 崩溃信息在日志末尾，打开时直接滚到底。
                withFrameNanos { }
                withFrameNanos { }
                logScroll.scrollTo(logScroll.maxValue)
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .heightIn(min = 120.dp)
                    .background(cs.surfaceContainerLowest, RoundedCornerShape(14.dp))
                    .padding(12.dp),
            ) {
                SelectionContainer {
                    Text(
                        log.ifBlank { "（没有捕获到日志）" },
                        color = cs.onSurface.copy(alpha = 0.82f),
                        fontSize = 9.5.sp,
                        lineHeight = 13.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.verticalScroll(logScroll),
                    )
                }
            }
            Spacer(Modifier.height(14.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onCopy) {
                    Text("复制日志", color = cs.onSurfaceVariant, fontSize = 12.5.sp)
                }
                Spacer(Modifier.width(4.dp))
                TextButton(onClick = onExit) {
                    Text("退出游戏", color = cs.error, fontSize = 12.5.sp)
                }
                Spacer(Modifier.width(4.dp))
                Button(
                    onClick = onBack,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = cs.primary,
                        contentColor = cs.onPrimary,
                    ),
                    shape = RoundedCornerShape(14.dp),
                ) {
                    Text("返回启动器", fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}
