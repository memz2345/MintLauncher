package dev.mint.mint

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.Gravity
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.util.fastCoerceIn
import androidx.compose.ui.util.fastRoundToInt
import androidx.compose.ui.util.lerp
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberCanvasBackdrop
import com.kyant.backdrop.backdrops.rememberCombinedBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.effects.vibrancy
import com.kyant.backdrop.highlight.Highlight
import dev.mint.mint.compose.ComposeHostOwner
import com.kyant.backdrop.shadow.InnerShadow
import com.kyant.backdrop.shadow.Shadow
import com.kyant.shapes.Capsule
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.vector.PathParser
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sign

   
                                          
   
data class LiquidBarTab(
    val id: String,
    val label: String,
    val iconCodePoint: Int?,
    val iconFontFamily: String?,
    val selectedIconCodePoint: Int?,
    /* miuix 矢量图标的 SVG 路径串（原始 d 数据）+ 视口 + 是否绕中心翻转 Y。
       非空时优先渲染矢量（PathParser），否则回落字体字形。 */
    val iconPath: String?,
    val iconViewport: Float,
    val iconFlipY: Boolean,
    /* 图标右上角的小红点（下载 tab 有进行中的任务时）。 */
    val badge: Boolean = false,
)

   
                                        
  
                                                  
                                         
   
data class BackdropFrame(
    val image: ImageBitmap,
    val srcLeftPx: Int,
    val srcTopPx: Int,
    /* 该帧内容对应的 Flutter 绝对滚动位置（px）与内容代次：绘制时用
       「当前位置 - 该帧位置」平移旧图，代次不符则不平移。 */
    val capturedOffsetPx: Float,
    val epoch: Int,
)

   
                      
  
                                                 
           
                                                                
                                                               
                                                                 
                                                 
  
                                              
                                                                   
  
                                                
                          
   
object LiquidGlassBarHost {

    private const val TAG = "LiquidGlassBarHost"
    const val CHANNEL_NAME = "dev.mint.mint/liquid_bar"

       
                                 
      
                                                        
                        
                                                     
                                                                  
                                             
                                                 
                                                                
                                           
      
                                            
                                             
                                                           
                                          
       
    private const val BACKDROP_ACTIVE_MIN_GAP_MS = 16L
    private const val BACKDROP_INTERVAL_IDLE_MS = 500L
    private const val BACKDROP_ACTIVE_WINDOW_MS = 220L

                            
    private const val BACKDROP_PAD_DP = 40f

       
                     
      
                                                   
                                               
                              
       
    // 旧图平移补偿的上限：抓到的位图比胶囊每边多出 backdropPadPx，
    // 平移超过 pad 就会采到位图外的空区域（玻璃里直接透出「无内容」）。
    private const val BACKDROP_MAX_COMPENSATION_DP = BACKDROP_PAD_DP

       
                      
      
                                                       
                                                     
                                       
       
    private const val INDICATOR_OVERFLOW_DP = 20f

       
                                                  
                                                  
                                         
                                         
                                                     
      
                                                            
                                  
       
    private const val TAB_WIDTH_DP = 76f

    private const val TELEMETRY_WINDOW_MS = 2000L
    private const val BOTTOM_GAP_DP = 12f
    private const val INNER_PAD_DP = 4f

    private val handler = Handler(Looper.getMainLooper())

    private var channel: MethodChannel? = null
    private var hostRoot: ViewGroup? = null
    private var hostView: View? = null
    private var hostOwner: ComposeHostOwner? = null

    private var tabs: List<LiquidBarTab> = emptyList()
    private var indexState: MutableState<Int>? = null
    private var backdropState: MutableState<BackdropFrame?>? = null

       
                                           
                         
      
                                           
                                                          
                                        
      
                                                     
                                  
       
    // Flutter 内容的绝对滚动位置（px）。补偿量 = 当前位置 − 该帧抓取时的位置；
    // 用绝对值而非累加增量，避免每次抓取落地归零造成的回跳抖动。
    private var contentOffsetState: MutableState<Float>? = null

    // 内容代号：切页 / 重新 show / 布局变化时 +1，跨代次的旧图不做平移补偿
    private var contentEpochState: MutableState<Int>? = null

                                                       
    // 收到内容信号 / 心跳时置位，抓取真正发起时清掉
    private var captureRequested = false

    private var barHeightPx = 0
    private var surfaceView: SurfaceView? = null

                                                     
                                                
    private val backdropBuffers = arrayOfNulls<Bitmap>(3)
    private var backdropBufferCursor = 0
    private var backdropBufferW = 0
    private var backdropBufferH = 0

                                                                   
                                                               
                   

       
                                                      
                                              
                                    
       

                                                 
    private var lastContentSignalAt = 0L

                                         
                                              
                 
    private var hostWidthPx = 0
    private var hostHeightPx = 0
    private var capsuleTopPx = 0
    private var capsuleLeftPx = 0
    private var capsuleWidthPx = 0
    private var capsuleHeightPx = 0
    private var backdropPadPx = 0
    private var innerPadPx = 0
    private var tabWidthPx = 0f
    private var activityRef: Activity? = null

                                                               
    private var maxCompensationPx = 0f

                                   
                                
    private var backdropLoopRunning = false

                                                 
    private var copyInFlight = false

                                     
    private var lastCaptureStartedAt = 0L

    // 已挂起一帧 Choreographer 回调
    private var ticking = false

    // 上次抓取时的内容位置 / 代次，用来判断「画面是否已经和上次抓取不同」
    private var lastCapturedOffsetPx = Float.NaN
    private var lastCapturedEpoch = -1

    private val choreographer = Choreographer.getInstance()

                                        
    private val activeFrameCallback = Choreographer.FrameCallback { onVsync() }

                                
    private val idleTick = Runnable {
        captureRequested = true
        ensureTicking()
    }

                                      
    private var loggedCopyFailure = false
    private var loggedPixelSample = false

    // ---- 同步遥测：每 ~1s 汇总一行，用于量化抓取速率 / 单次抓取耗时 / 背景滞后量 ----
    private var telemetryCaptures = 0
    private var telemetryCopyMs = 0L
    private var telemetryCopyMaxMs = 0L
    private var telemetryStalePx = 0f
    private var telemetryStaleMaxPx = 0f
    private var telemetryWindowStartAt = 0L
    private var telemetryTicks = 0
    private var telemetrySkipInFlight = 0
    private var telemetrySkipGap = 0
    private var telemetryDartRefresh = 0
    private var telemetrySkipSame = 0
    private var telemetryIdle = 0

    private fun resetTelemetry() {
        telemetryWindowStartAt = 0L
        telemetryCaptures = 0
        telemetryCopyMs = 0L
        telemetryCopyMaxMs = 0L
        telemetryStalePx = 0f
        telemetryStaleMaxPx = 0f
        telemetryTicks = 0
        telemetrySkipInFlight = 0
        telemetrySkipGap = 0
        telemetrySkipSame = 0
        telemetryDartRefresh = 0
        telemetryIdle = 0
    }

    /**
     * compPx = 抓取落地瞬间「背景还要平移多少才对得上当前画面」，
     * 也就是滞后量：静止时应收敛到 0，滚动中越接近 pad 说明补偿越吃紧。
     */
    private fun logTelemetryWindow(copyLatencyMs: Long, compPx: Float) {
        val now = SystemClock.uptimeMillis()
        if (telemetryWindowStartAt == 0L) telemetryWindowStartAt = now
        telemetryCaptures++
        telemetryCopyMs += copyLatencyMs
        telemetryCopyMaxMs = maxOf(telemetryCopyMaxMs, copyLatencyMs)
        telemetryStalePx += abs(compPx)
        telemetryStaleMaxPx = maxOf(telemetryStaleMaxPx, abs(compPx))
        val elapsed = now - telemetryWindowStartAt
        // 只在真正有交互时打点：静止时的心跳抓取不该往 logcat 里灌日志
        if (elapsed < TELEMETRY_WINDOW_MS || telemetryDartRefresh == 0) return
        val fps = telemetryCaptures * 1000f / elapsed
        Log.d(
            TAG,
            "sync: %.1f cap/s copy avg=${telemetryCopyMs / telemetryCaptures}ms ".format(fps) +
                "max=${telemetryCopyMaxMs}ms comp avg=${"%.1f".format(telemetryStalePx / telemetryCaptures)}px " +
                "max=${"%.1f".format(telemetryStaleMaxPx)}px | tick=%.1f/s ".format(
                    telemetryTicks * 1000f / elapsed
                ) +
                "skipFlight=$telemetrySkipInFlight skipGap=$telemetrySkipGap " +
                "skipSame=$telemetrySkipSame dart=$telemetryDartRefresh idle=$telemetryIdle",
        )
        resetTelemetry()
        telemetryWindowStartAt = now
    }

    fun install(activity: Activity, messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "showBar" -> result.success(show(activity, call.arguments as? Map<*, *>))
                "updateIndex" -> {
                    val idx = (call.arguments as? Map<*, *>?)?.get("index") as? Number
                    indexState?.value = idx?.toInt() ?: 0
                    // 换页 = 内容整体不连续变化：旧图作废，只等一次新抓取
                    bumpEpoch()
                    result.success(null)
                }
                "sync" -> {
                    // Dart 每渲染一帧发一次，pixels = 可见页的绝对滚动位置（逻辑像素）。
                    // 这里只记录位置与「待抓取」标记，真正的 PixelCopy 一律由
                    // Choreographer 帧头发起，保证抓取与 vsync 对齐。
                    val args = call.arguments as? Map<*, *>
                    lastContentSignalAt = SystemClock.uptimeMillis()
                    telemetryDartRefresh++
                    val density = activityRef?.resources?.displayMetrics?.density ?: 1f
                    (args?.get("pixels") as? Number)?.let { px ->
                        contentOffsetState?.value = px.toFloat() * density
                    }
                    captureRequested = true
                    ensureTicking()
                    result.success(null)
                }
                "hideBar" -> {
                    Log.d(TAG, "hideBar（首页被盖住 / 离开）")
                    dismiss()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        dismiss()
    }

    fun dismiss() {
        stopBackdropLoop()
        releaseBackdropBuffers()
        val root = hostRoot
        val view = hostView
        val owner = hostOwner
        hostRoot = null
        hostView = null
        hostOwner = null
        indexState = null
        backdropState = null
        contentOffsetState = null
        contentEpochState = null
        captureRequested = false
        surfaceView = null
        activityRef = null
        if (root != null && view != null && view.parent === root) {
            root.removeView(view)
        }
        owner?.destroy()
    }

                                                         
    private fun releaseBackdropBuffers() {
        backdropBuffers.fill(null)
        backdropBufferCursor = 0
        backdropBufferW = 0
        backdropBufferH = 0
    }

    private fun show(activity: Activity, args: Map<*, *>?): Boolean {
        if (args == null) return false
        val parsed = parseTabs(args["tabs"])
        if (parsed.isEmpty()) return false

        dismiss()

        val density = activity.resources.displayMetrics.density
        val bottomInset = ((args["bottomInset"] as? Number)?.toFloat() ?: 0f) * density
        val barHeight = ((args["height"] as? Number)?.toFloat() ?: 64f) * density
                                                    
                                                
        val overflowPx = (INDICATOR_OVERFLOW_DP * density).roundToInt()
        val bottomGapPx = (BOTTOM_GAP_DP * density).roundToInt()
        barHeightPx = (barHeight.toInt() + bottomGapPx + bottomInset.toInt() + overflowPx)
            .coerceAtLeast(1)
        val dark = args["dark"] as? Boolean ?: false
        val accent = (args["accent"] as? Number)?.toInt()
        val startIndex = (args["index"] as? Number)?.toInt() ?: 0

        val root = activity.findViewById<ViewGroup>(android.R.id.content) ?: return false
        tabs = parsed
        val idx = mutableStateOf(startIndex)
        val backdrop = mutableStateOf<BackdropFrame?>(null)
        val contentOffset = mutableFloatStateOf(0f)
        val contentEpoch = mutableIntStateOf(0)
        indexState = idx
        backdropState = backdrop
        contentOffsetState = contentOffset
        contentEpochState = contentEpoch
        val surface = findSurfaceView(root)
        surfaceView = surface
        activityRef = activity

                              
                                               
                                                  
                                          
        val hostW = listOf(surface?.width, root.width)
            .firstOrNull { it != null && it > 0 }
            ?: activity.resources.displayMetrics.widthPixels
        val hostH = listOf(surface?.height, root.height)
            .firstOrNull { it != null && it > 0 }
            ?: activity.resources.displayMetrics.heightPixels
        hostWidthPx = hostW
        hostHeightPx = hostH
        val insetPx = bottomInset.roundToInt()
        val targetW = (parsed.size * TAB_WIDTH_DP * density).roundToInt()
        val capsuleW = targetW.coerceAtMost(hostW)
        capsuleWidthPx = capsuleW
        capsuleLeftPx = (hostW - capsuleW) / 2
        capsuleHeightPx = barHeight.roundToInt().coerceAtLeast(1)
        capsuleTopPx = (hostH - insetPx - bottomGapPx - capsuleHeightPx).coerceAtLeast(0)
        backdropPadPx = (BACKDROP_PAD_DP * density).roundToInt()
        innerPadPx = (INNER_PAD_DP * density).roundToInt()
        tabWidthPx = (capsuleW - 2f * innerPadPx) / parsed.size.coerceAtLeast(1)
        maxCompensationPx = BACKDROP_MAX_COMPENSATION_DP * density
        loggedCopyFailure = false
        Log.d(
            TAG,
            "show: surface=$surface host=${hostW}x$hostH capsule=($capsuleLeftPx,$capsuleTopPx," +
                "${capsuleW}x$capsuleHeightPx) inset=$insetPx gap=$bottomGapPx",
        )

        val ch = channel
        val view = ComposeView(activity)
        val owner = ComposeHostOwner()
        owner.start()
        owner.attachTo(view)
        view.setContent {
            MaterialTheme(colorScheme = barColorScheme(dark)) {
                LiquidGlassBar(
                    tabs = tabs,
                    index = idx.value,
                                                         
                    backdropSource = backdrop,
                    contentOffset = contentOffset,
                    contentEpoch = contentEpoch,
                    barHeightDp = barHeight / density,
                    bottomInsetDp = bottomInset / density,
                    bottomGapDp = bottomGapPx / density,
                    accent = accent?.let { Color(it) },
                                                  
                                                    
                                                        
                    onSelect = { i ->
                        if (i != idx.value) idx.value = i
                        ch?.invokeMethod("onTabSelected", mapOf("index" to i))
                    },
                )
            }
        }
        root.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                barHeightPx,
                Gravity.BOTTOM,
            ),
        )
        hostRoot = root
        hostView = view
        hostOwner = owner

                                         
        startBackdropLoop()
        return true
    }

       
                                       
      
                                                 
                                              
                                                
                          
       
    private fun startBackdropLoop() {
        stopBackdropLoop()
        backdropLoopRunning = true
        copyInFlight = false
        ticking = false
        lastCapturedOffsetPx = Float.NaN
        lastCapturedEpoch = -1
        resetTelemetry()
        lastContentSignalAt = SystemClock.uptimeMillis()
        lastCaptureStartedAt = 0L
        // 底栏刚出现时立刻抓一帧，避免玻璃里闪一下旧画面
        captureRequested = true
        ensureTicking()
    }

    private fun stopBackdropLoop() {
        backdropLoopRunning = false
        captureRequested = false
        choreographer.removeFrameCallback(activeFrameCallback)
        handler.removeCallbacks(idleTick)
    }

    /** 内容不连续变化（切页 / 重新 show / 尺寸变化）：旧图作废，只等一次新抓取。 */
    private fun bumpEpoch() {
        contentEpochState?.let { it.value = it.value + 1 }
        captureRequested = true
        lastContentSignalAt = SystemClock.uptimeMillis()
        ensureTicking()
    }

    /** 有待办时挂一帧 Choreographer 回调；重复调用只保留一个。 */
    private fun ensureTicking() {
        if (!backdropLoopRunning || ticking) return
        handler.removeCallbacks(idleTick)
        ticking = true
        choreographer.postFrameCallback(activeFrameCallback)
    }

    /**
     * vsync 帧头决策：抓取一律在这里发起，不再从通道回调里直接抓，
     * 这样每次 PixelCopy 都对齐一次帧边界，玻璃与内容的相位差才是稳定的。
     */
    private fun onVsync() {
        ticking = false
        if (!backdropLoopRunning) return
        telemetryTicks++
        val now = SystemClock.uptimeMillis()
        if (copyInFlight) {
            telemetrySkipInFlight++
        } else if (!captureRequested && !contentMoved()) {
            telemetrySkipSame++
        } else if (now - lastCaptureStartedAt >= BACKDROP_ACTIVE_MIN_GAP_MS) {
            requestCapture()
        } else {
            telemetrySkipGap++
        }
        if (captureRequested || now - lastContentSignalAt < BACKDROP_ACTIVE_WINDOW_MS) {
            ensureTicking()
        } else {
            // 内容静止：退回低频心跳，兜住「不是滚动引起的画面变化」（动画 / 数值刷新）
            telemetryIdle++
            handler.postDelayed(idleTick, BACKDROP_INTERVAL_IDLE_MS)
        }
    }

    /** 画面是否已经和上次抓取的内容不一致（位置变了或换了代次）。 */
    private fun contentMoved(): Boolean {
        val offset = contentOffsetState?.value ?: 0f
        val epoch = contentEpochState?.value ?: 0
        return offset != lastCapturedOffsetPx || epoch != lastCapturedEpoch
    }

    private fun acquireBuffer(w: Int, h: Int): Bitmap {
        if (backdropBufferW != w || backdropBufferH != h) {
            backdropBuffers.fill(null)
            backdropBufferW = w
            backdropBufferH = h
            backdropBufferCursor = 0
        }
        backdropBufferCursor = (backdropBufferCursor + 1) % backdropBuffers.size
        val existing = backdropBuffers[backdropBufferCursor]
        if (existing != null) return existing
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also {
            backdropBuffers[backdropBufferCursor] = it
        }
    }

    /**
     * 抓 Flutter SurfaceView 上的一条横带做折射背景。
     *
     * 只走 CPU 位图：PixelCopy 的目标位图必须可变，而 Bitmap.wrapHardwareBuffer
     * 拿到的位图恒为 immutable，会被 validateBitmapDest 直接拒掉
     * （IllegalArgumentException: Bitmap is immutable），所以零拷贝路径在这套 API
     * 下根本跑不通，之前的实现每次 show 都会白抛一次异常再退回 CPU 路径。
     */
    private fun requestCapture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (copyInFlight) return
        val state = backdropState ?: return
        val surface = surfaceView
        val surfaceW = surface?.width ?: 0
        val surfaceH = surface?.height ?: 0
        val availW = if (surfaceW > 0) minOf(hostWidthPx, surfaceW) else hostWidthPx
        val availH = if (surfaceH > 0) minOf(hostHeightPx, surfaceH) else hostHeightPx
        val capW = capsuleWidthPx
        val capH = capsuleHeightPx
        if (capW <= 0 || capH <= 0 || availW <= 0 || availH <= 0) return
        val pad = backdropPadPx
        val left = (capsuleLeftPx - pad).coerceAtLeast(0)
        val top = (capsuleTopPx - pad).coerceAtLeast(0)
        val right = (capsuleLeftPx + capW + pad).coerceAtMost(availW)
        val bottom = (capsuleTopPx + capH + pad).coerceAtMost(availH)
        if (right - left < capW || bottom - top < capH) return
        val bmpW = right - left
        val bmpH = bottom - top
        val rect = Rect(left, top, right, bottom)

        val bmp = acquireBuffer(bmpW, bmpH)
        val capturedOffset = contentOffsetState?.value ?: 0f
        val capturedEpoch = contentEpochState?.value ?: 0
        lastCapturedOffsetPx = capturedOffset
        lastCapturedEpoch = capturedEpoch
        captureRequested = false
        copyInFlight = true
        lastCaptureStartedAt = SystemClock.uptimeMillis()

        val finish = PixelCopy.OnPixelCopyFinishedListener { result ->
            copyInFlight = false
            if (!backdropLoopRunning || backdropState == null) {
                return@OnPixelCopyFinishedListener
            }
            if (result == PixelCopy.SUCCESS) {
                val now = SystemClock.uptimeMillis()
                logTelemetryWindow(
                    now - lastCaptureStartedAt,
                    (contentOffsetState?.value ?: 0f) - capturedOffset,
                )
                if (!loggedPixelSample) {
                    loggedPixelSample = true
                    val px = bmp.getPixel(bmp.width / 2, bmp.height / 2)
                    Log.d(
                        TAG,
                        "backdrop ok ${bmp.width}x${bmp.height} src=($left,$top) center=0x" +
                            Integer.toHexString(px),
                    )
                }
                state.value = BackdropFrame(
                    image = bmp.asImageBitmap(),
                    srcLeftPx = left,
                    srcTopPx = top,
                    capturedOffsetPx = capturedOffset,
                    epoch = capturedEpoch,
                )
            } else if (!loggedCopyFailure) {
                loggedCopyFailure = true
                Log.w(
                    TAG,
                    "PixelCopy 失败 result=$result surface=${surface != null} rect=$rect",
                )
            }
            ensureTicking()
        }

        if (surface != null && surfaceW >= rect.right && surfaceH >= rect.bottom) {
            runCatching { PixelCopy.request(surface, rect, bmp, finish, handler) }
                .onFailure {
                    copyInFlight = false
                    Log.w(TAG, "PixelCopy(surface) 抛异常", it)
                    ensureTicking()
                }
            return
        }

        // 找不到 Flutter 的 SurfaceView（例如 TextureView 模式）时退回整窗抓取
        val activity = activityRef
        val window = activity?.window
        if (window == null) {
            copyInFlight = false
            ensureTicking()
            return
        }
        val location = IntArray(2)
        window.decorView.getLocationOnScreen(location)
        runCatching {
            PixelCopy.request(
                window,
                Rect(
                    rect.left,
                    rect.top + location[1],
                    rect.right,
                    rect.bottom + location[1],
                ),
                bmp,
                finish,
                handler,
            )
        }.onFailure {
            copyInFlight = false
            Log.w(TAG, "PixelCopy(window) 抛异常", it)
            ensureTicking()
        }
    }

    private fun parseTabs(raw: Any?): List<LiquidBarTab> {
        val list = raw as? List<*> ?: return emptyList()
        return list.mapNotNull { any ->
            val m = any as? Map<*, *> ?: return@mapNotNull null
            LiquidBarTab(
                id = m["id"] as? String ?: return@mapNotNull null,
                label = m["label"] as? String ?: "",
                iconCodePoint = (m["iconCodePoint"] as? Number)?.toInt(),
                iconFontFamily = m["iconFontFamily"] as? String,
                selectedIconCodePoint = (m["selectedIconCodePoint"] as? Number)?.toInt(),
                iconPath = m["iconPath"] as? String,
                iconViewport = (m["iconViewport"] as? Number)?.toFloat() ?: 24f,
                iconFlipY = m["iconFlipY"] as? Boolean ?: false,
                badge = m["badge"] as? Boolean ?: false,
            )
        }
    }

    private fun findSurfaceView(root: View): SurfaceView? {
        if (root is SurfaceView) return root
        if (root is ViewGroup) {
            for (i in 0 until root.childCount) {
                val found = findSurfaceView(root.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }

    @Composable
    private fun barColorScheme(dark: Boolean): ColorScheme {
        val context = LocalContext.current
        return remember(dark, context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            } else {
                if (dark) darkColorScheme() else lightColorScheme()
            }
        }
    }

       
                                          
      
             
                                                              
                                                    
                                                  
                                                            
                                            
       
    @Composable
    private fun rememberScreenBackdrop(
        source: State<BackdropFrame?>,
        contentOffset: State<Float>,
        contentEpoch: State<Int>,
        nodeLeft: () -> Int,
        nodeTop: () -> Int,
    ): Backdrop {
        /* onDraw 会被长期缓存，里面只能读 object 字段和 State，不能捕获组合期的
           局部坐标：否则切页 / 旋屏 / inset 变化之后采样区会一直停在首次组合时的
           坐标上，玻璃里的画面和它身后的内容就是错位的。 */
        val onDrawBackdrop: DrawScope.() -> Unit =
            remember(source, contentOffset, contentEpoch) {
            {
                val frame = source.value
                if (frame != null && size.width > 0f && size.height > 0f) {
                                                       
                                                     
                                                       
                      
                                               
                                                                
                                                 
                                                              
                    val dy = if (frame.epoch == contentEpoch.value) {
                        (contentOffset.value - frame.capturedOffsetPx)
                            .fastCoerceIn(-maxCompensationPx, maxCompensationPx)
                            .roundToInt()
                    } else {
                        0
                    }
                    drawImage(
                        image = frame.image,
                        dstOffset = IntOffset(
                            frame.srcLeftPx - nodeLeft(),
                            frame.srcTopPx - nodeTop() - dy,
                        ),
                        dstSize = IntSize(frame.image.width, frame.image.height),
                    )
                }
            }
        }
        return rememberCanvasBackdrop(onDrawBackdrop)
    }

       
                                                                     
                                                       
      
                                                               
                                 
                                                             
                                   
                                                  
      
                                                           
                                                     
                  
       
    @Composable
    private fun LiquidGlassBar(
        tabs: List<LiquidBarTab>,
        index: Int,
        backdropSource: State<BackdropFrame?>,
        contentOffset: State<Float>,
        contentEpoch: State<Int>,
        barHeightDp: Float,
        bottomInsetDp: Float,
        bottomGapDp: Float,
        accent: Color?,
        onSelect: (Int) -> Unit,
    ) {
        val cs = MaterialTheme.colorScheme
        val tint = accent ?: cs.primary
        val isLight = cs.surface != Color.Black
        val tabCount = tabs.size.coerceAtLeast(1)
        val density = LocalDensity.current
        val isLtr = LocalLayoutDirection.current == LayoutDirection.Ltr
                                          
                           
        val touchSlop = LocalViewConfiguration.current.touchSlop
        val animationScope = rememberCoroutineScope()
                                           
        val tabsBackdrop = rememberLayerBackdrop()
        val indicatorHeightDp = barHeightDp - 8f

                                            
        var currentIndex by remember { mutableIntStateOf(index) }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = (bottomGapDp + bottomInsetDp).dp),
            contentAlignment = Alignment.BottomCenter,
        ) {
                                    
            BoxWithConstraints(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(barHeightDp.dp),
            ) {
                val barWidthDp = minOf(
                    tabCount * TAB_WIDTH_DP,
                    constraints.maxWidth.toFloat() / density.density,
                )
                               
                BoxWithConstraints(
                    modifier = Modifier
                        .width(barWidthDp.dp)
                        .height(barHeightDp.dp)
                        .align(Alignment.BottomCenter),
                    contentAlignment = Alignment.CenterStart,
                ) {
                                                               
                                                                
                                                               
                    val backdrop = rememberScreenBackdrop(
                        backdropSource,
                        contentOffset,
                        contentEpoch,
                        nodeLeft = { capsuleLeftPx },
                        nodeTop = { capsuleTopPx },
                    )
                    val innerBackdrop = rememberScreenBackdrop(
                        backdropSource,
                        contentOffset,
                        contentEpoch,
                        nodeLeft = { capsuleLeftPx + innerPadPx },
                        nodeTop = { capsuleTopPx + innerPadPx },
                    )

                                                   
                val offsetAnimation = remember { Animatable(0f) }
                val panelOffset = remember(density) {
                    derivedStateOf {
                        val fraction =
                            (offsetAnimation.value / constraints.maxWidth.toFloat())
                                .fastCoerceIn(-1f, 1f)
                        with(density) {
                            4f.dp.toPx() * fraction.sign * EaseOut.transform(abs(fraction))
                        }
                    }
                }

                                                               
                                                
                val realIndex by rememberUpdatedState(index)
                val dampedDragAnimation = remember(animationScope) {
                    DampedDragAnimation(
                        animationScope = animationScope,
                        initialValue = index.toFloat(),
                        valueRange = 0f..(tabCount - 1).toFloat(),
                        visibilityThreshold = 0.001f,
                        initialScale = 1f,
                        pressedScale = 78f / 56f,
                        touchSlop = touchSlop,
                                                     
                                                           
                                                               
                                                        
                        onDragStarted = { position, gestureSize ->
                            val px = if (isLtr) {
                                position.x
                            } else {
                                gestureSize.width - position.x
                            }
                                                           
                                                                      
                                                                     
                            val target = ((px - innerPadPx.toFloat()) / tabWidthPx)
                                .toInt()
                                .fastCoerceIn(0, tabCount - 1)
                                                                    
                            pressTargetIndex = target
                            if (target.toFloat() != targetValue) {
                                updateValue(target.toFloat())
                            }
                        },
                        onDragStopped = {
                            val targetIndex =
                                targetValue.fastRoundToInt().fastCoerceIn(0, tabCount - 1)
                            currentIndex = targetIndex
                            animateToValue(targetIndex.toFloat())
                            animationScope.launch {
                                offsetAnimation.animateTo(0f, spring(1f, 300f, 0.5f))
                            }
                                                       
                                      
                            if (targetIndex != realIndex) onSelect(targetIndex)
                        },
                                                       
                                                      
                        onTap = { targetIndex ->
                            currentIndex = targetIndex
                            animateToValue(targetIndex.toFloat())
                            animationScope.launch {
                                offsetAnimation.animateTo(0f, spring(1f, 300f, 0.5f))
                            }
                            onSelect(targetIndex)
                        },
                                                  
                        onLongPress = {
                            currentIndex = realIndex
                            animateToValue(realIndex.toFloat())
                            animationScope.launch {
                                offsetAnimation.animateTo(0f, spring(1f, 300f, 0.5f))
                            }
                        },
                        onDrag = { _, dragAmount ->
                            updateValue(
                                (
                                    targetValue +
                                        dragAmount.x / tabWidthPx * (if (isLtr) 1f else -1f)
                                    ).fastCoerceIn(0f, (tabCount - 1).toFloat()),
                            )
                            animationScope.launch {
                                offsetAnimation.snapTo(offsetAnimation.value + dragAmount.x)
                            }
                        },
                    )
                }

                                                    
                LaunchedEffect(index) {
                    if (index != currentIndex) {
                        currentIndex = index
                        dampedDragAnimation.animateToValue(index.toFloat())
                    }
                }

                                                         
                                                       
                                                                       
                val tabScale: () -> Float = {
                    lerp(1f, 1.2f, dampedDragAnimation.pressProgress)
                }

                val interactiveHighlight = remember(animationScope) {
                    InteractiveHighlight(
                        animationScope = animationScope,
                        position = { size, _ ->
                            Offset(
                                if (isLtr) {
                                    innerPadPx.toFloat() +
                                        (dampedDragAnimation.value + 0.5f) * tabWidthPx +
                                        panelOffset.value
                                } else {
                                    size.width - innerPadPx.toFloat() -
                                        (dampedDragAnimation.value + 0.5f) * tabWidthPx +
                                        panelOffset.value
                                },
                                size.height / 2f,
                            )
                        },
                    )
                }

                                              
                Row(
                    Modifier
                        .graphicsLayer { translationX = panelOffset.value }
                        .drawBackdrop(
                            backdrop = backdrop,
                            shape = { Capsule() },
                            effects = {
                                vibrancy()
                                blur(with(density) { 8.dp.toPx() })
                                lens(
                                    with(density) { 24.dp.toPx() },
                                    with(density) { 24.dp.toPx() },
                                )
                            },
                            layerBlock = {
                                val progress = dampedDragAnimation.pressProgress
                                val scale = lerp(1f, 1f + 16.dp.toPx() / size.width, progress)
                                scaleX = scale
                                scaleY = scale
                            },
                                                        
                                             
                        )
                        .then(interactiveHighlight.modifier)
                        .height(barHeightDp.dp)
                        .fillMaxWidth()
                        .padding(horizontal = INNER_PAD_DP.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {}

                                                                   
                                                      
                                                                  
                                                                
                                 
                Row(
                    Modifier
                        .graphicsLayer { translationX = panelOffset.value }
                        .alpha(0f)
                        .layerBackdrop(tabsBackdrop)
                        .drawBackdrop(
                            backdrop = innerBackdrop,
                            shape = { Capsule() },
                            effects = {
                                vibrancy()
                                blur(with(density) { 8.dp.toPx() })
                                lens(
                                    with(density) {
                                        24.dp.toPx() * dampedDragAnimation.pressProgress
                                    },
                                    with(density) {
                                        24.dp.toPx() * dampedDragAnimation.pressProgress
                                    },
                                )
                            },
                            highlight = {
                                Highlight.Default.copy(
                                    alpha = dampedDragAnimation.pressProgress,
                                )
                            },
                                          
                        )
                        .height(indicatorHeightDp.dp)
                        .fillMaxWidth()
                        .padding(horizontal = INNER_PAD_DP.dp)
                        .graphicsLayer(colorFilter = ColorFilter.tint(tint)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    tabs.forEachIndexed { i, tab ->
                        BarTab(
                            tab = tab,
                            selected = i == currentIndex,
                            tint = tint,
                            scale = tabScale,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                                                 
                                                        
                                                         
                                                           
                            
                Row(
                    Modifier
                        .graphicsLayer { translationX = panelOffset.value }
                        .height(indicatorHeightDp.dp)
                        .fillMaxWidth()
                        .padding(horizontal = INNER_PAD_DP.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    tabs.forEachIndexed { i, tab ->
                        BarTab(
                            tab = tab,
                            selected = i == currentIndex,
                            tint = tint,
                            scale = tabScale,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                                                 
                                                  
                                                          
                val indicatorBackdrop = rememberScreenBackdrop(
                    backdropSource,
                    contentOffset,
                    contentEpoch,
                    nodeLeft = {
                        capsuleLeftPx + innerPadPx +
                            (dampedDragAnimation.value * tabWidthPx).roundToInt() +
                            panelOffset.value.roundToInt()
                    },
                    nodeTop = { capsuleTopPx + innerPadPx },
                )
                Box(
                    Modifier
                        .padding(horizontal = INNER_PAD_DP.dp)
                        .graphicsLayer {
                            translationX =
                                dampedDragAnimation.value * tabWidthPx + panelOffset.value
                        }
                        .drawBackdrop(
                                                                 
                            backdrop = rememberCombinedBackdrop(
                                indicatorBackdrop,
                                tabsBackdrop,
                            ),
                            shape = { Capsule() },
                            effects = {
                                val progress = dampedDragAnimation.pressProgress
                                lens(
                                    with(density) { 10.dp.toPx() } * progress,
                                    with(density) { 14.dp.toPx() } * progress,
                                    chromaticAberration = true,
                                )
                            },
                            highlight = {
                                Highlight.Default.copy(
                                    alpha = dampedDragAnimation.pressProgress,
                                )
                            },
                            shadow = { Shadow(alpha = dampedDragAnimation.pressProgress) },
                            innerShadow = {
                                val progress = dampedDragAnimation.pressProgress
                                InnerShadow(radius = 8.dp * progress, alpha = progress)
                            },
                            layerBlock = {
                                                         
                                                     
                                scaleX = dampedDragAnimation.scaleX
                                scaleY = dampedDragAnimation.scaleY
                                val velocity = dampedDragAnimation.velocity / 10f
                                scaleX /= 1f - (velocity * 0.75f).fastCoerceIn(-0.2f, 0.2f)
                                scaleY *= 1f - (velocity * 0.25f).fastCoerceIn(-0.2f, 0.2f)
                            },
                                                                      
                                                         
                                              
                            onDrawSurface = {
                                val progress = dampedDragAnimation.pressProgress
                                drawRect(
                                    if (isLight) {
                                        Color.Black.copy(alpha = 0.1f)
                                    } else {
                                        Color.White.copy(alpha = 0.1f)
                                    },
                                    alpha = 1f - progress,
                                )
                                drawRect(Color.Black.copy(alpha = 0.03f * progress))
                            },
                        )
                        .height(indicatorHeightDp.dp)
                        .fillMaxWidth(1f / tabCount),
                )

                                                     
                                                
                                                             
                                                 
                                                       
                                                     
                Box(
                    Modifier
                        .fillMaxSize()
                        .then(interactiveHighlight.gestureModifier)
                        .then(dampedDragAnimation.modifier),
                )
                }
            }
        }
    }

    @Composable
    private fun BarTab(
        tab: LiquidBarTab,
        selected: Boolean,
        tint: Color,
        scale: () -> Float,
        modifier: Modifier = Modifier,
    ) {
        val cs = MaterialTheme.colorScheme
        val context = LocalContext.current
        val codePoint = if (selected) {
            tab.selectedIconCodePoint ?: tab.iconCodePoint
        } else {
            tab.iconCodePoint
        }
        val typeface = remember(tab.iconFontFamily) {
            codePoint?.let { IconFonts.load(context, tab.iconFontFamily) }
        }
        // miuix 矢量：PathParser 解析一次（remember 缓存），绘制时按视口等比
        // 缩放；flipY 时先平移视口高再绕 X 翻转 —— 与 Flutter 侧
        // `_flipY(vp) = translate(0, vp) · scale(1, -1)` 完全一致。
        val vectorPath = remember(tab.iconPath, tab.iconViewport, tab.iconFlipY) {
            tab.iconPath?.let { data ->
                runCatching {
                    val vp = tab.iconViewport.coerceAtLeast(0.1f)
                    val raw = Path().also {
                        PathParser().parsePathString(data).toPath(it)
                    }
                    // 一次性把路径从 miuix 视口归一化到 24dp 图标视口；flipY 时
                    // y 镜像再平移回视口（等价 miuix 生成数据里的
                    // group(scaleY = -1, translationY = vp)）。
                    // 注意：Compose Matrix.values 是**列主序**（见其常量表
                    // ScaleX=0、ScaleY=5、TranslateY=13、Perspective1=7），
                    // 平移必须写 values[13]；写 [7] 会改到透视行，让
                    // w' = 1 + 24·y（y 为 ~1000 的原始坐标）把整条路径
                    // 塌缩成一个亚像素点 —— 图标整体消失。
                    val k = 24f / vp
                    val matrix = Matrix()
                    val v = matrix.values
                    v[0] = k
                    v[5] = if (tab.iconFlipY) -k else k
                    v[13] = if (tab.iconFlipY) 24f else 0f
                    v[15] = 1f
                    raw.transform(matrix)
                    raw
                }.getOrNull()
            }
        }
        val fg = if (selected) tint else cs.onSurfaceVariant
        Column(
                                                     
                                                         
                               
            modifier = modifier
                .clip(Capsule())
                .fillMaxHeight()
                .graphicsLayer {
                    val s = scale()
                    scaleX = s
                    scaleY = s
                },
            verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                when {
                    vectorPath != null -> Canvas(Modifier.size(24.dp)) {
                        drawPath(vectorPath, fg)
                    }
                    codePoint != null && typeface != null -> Text(
                        text = String(Character.toChars(codePoint)),
                        fontFamily = FontFamily(typeface),
                        fontSize = 22.sp,
                        color = fg,
                    )
                    else -> Icon(
                        imageVector = Icons.Filled.Circle,
                        contentDescription = null,
                        tint = fg,
                        modifier = Modifier.size(20.dp),
                    )
                }
                if (tab.badge) {
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .offset(x = 3.dp, y = (-1).dp)
                            .size(7.dp)
                            .background(Color(0xFFE5484D), CircleShape)
                    )
                }
            }
            Spacer(Modifier.size(2.dp))
            Text(
                text = tab.label,
                fontSize = 10.sp,
                color = fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}
