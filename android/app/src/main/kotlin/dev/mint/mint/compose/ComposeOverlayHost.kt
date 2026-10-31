package dev.mint.mint.compose

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.ComposeView

/**
 * 游戏内 Compose 浮层的宿主。
 *
 * 平时完全不占视图（不拦截触摸，游戏按键照常工作）；点悬浮球时才把一层
 * 全屏 ComposeView 盖上去，关掉就移除。
 *
 * [surface] 是游戏的 SurfaceView：浮层可见期间由 [GlassBackdropCapture] 低频
 * 抓它的画面，面板才能做出「透过毛玻璃看游戏」的真玻璃效果（Compose 自己
 * 拿不到 backdrop）。
 */
class ComposeOverlayHost(
    private val activity: Activity,
    private val parent: ViewGroup,
    private val surface: View?,
) {
    private var view: ComposeView? = null
    private var owner: ComposeHostOwner? = null
    private var capture: GlassBackdropCapture? = null

    /** 抓到的游戏画面，通过 CompositionLocal 发给所有玻璃面板。 */
    val backdrop = GlassBackdrop()

    val visible: Boolean get() = view != null

    fun show(content: @Composable () -> Unit) {
        if (view != null) return
        val compose = ComposeView(activity)
        val host = ComposeHostOwner()
        host.start()
        // ComposeView 的 WindowRecomposer 是从**父视图**向上找 LifecycleOwner，
        // 只挂在 ComposeView 自己身上不够（普通 Activity 的根布局没有 owner）。
        host.attachTo(compose)
        host.attachTo(parent)
        compose.setContent {
            MintGameTheme {
                CompositionLocalProvider(LocalGlassBackdrop provides backdrop) {
                    content()
                }
            }
        }
        compose.alpha = 0f
        // 悬浮球有 elevation，光靠 addView 顺序压不住；浮层必须比它高。
        compose.elevation = 24f * activity.resources.displayMetrics.density
        parent.addView(
            compose,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        compose.animate().alpha(1f).setDuration(140L).start()
        view = compose
        owner = host
        surface?.let { source ->
            GlassBackdropCapture(source, backdrop).also { capture = it }.start()
        }
    }

    fun dismiss() {
        val compose = view ?: return
        val host = owner
        view = null
        owner = null
        capture?.stop()
        capture = null
        parent.removeView(compose)
        host?.destroy()
    }
}
