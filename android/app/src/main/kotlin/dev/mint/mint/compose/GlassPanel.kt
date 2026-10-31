package dev.mint.mint.compose

import android.graphics.Bitmap
import android.view.PixelCopy
import android.graphics.RuntimeShader
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * 游戏内浮层的「真玻璃」：抓一份游戏画面当背景 + 方向性边缘高光。
 *
 * Compose 的 `Modifier.blur` 只能糊自己这一层，糊不到身后的内容；而游戏画面
 * 是另一个 SurfaceView（JVM 在里面渲染），浮层拿不到 backdrop。所以照启动器
 * 侧 [dev.mint.mint.LiquidGlassBarHost] 的思路：用 **PixelCopy 抓一份窗口内容**，
 * 浮层打开期间低频刷新，面板把自己身后那一块画进去再模糊，看起来就是隔着
 * 毛玻璃看游戏。
 *
 * 边缘高光用 Kimi 那套 AGSL（圆角矩形 SDF 梯度 · 光向，见其
 * `assets` 里 `Ambient` / `Default` 两个 RuntimeShader）：朝光的边亮、背光的
 * 边暗 —— 玻璃的「厚度感」主要来自这条 rim，不是整体提亮。
 */

/**
 * 抓到的一帧游戏画面（已降采样）+ 它在窗口坐标系里的位置与尺寸。
 *
 * 只抓游戏的 SurfaceView，**不抓整个窗口**：整窗口截图会把浮层自己也拍进去，
 * 玻璃里就出现「玻璃套玻璃」的递归糊。
 */
class GlassBackdropFrame(
    val image: ImageBitmap,
    val leftPx: Float,
    val topPx: Float,
    val widthPx: Float,
    val heightPx: Float,
)

/** 浮层共享的背景状态：抓取回调写，Compose 读。 */
class GlassBackdrop {
    var frame by mutableStateOf<GlassBackdropFrame?>(null)
        internal set

    /** 换帧计数：让 Compose 认得出内容变了（位图对象是复用的）。 */
    var stamp by mutableLongStateOf(0L)
        internal set
}

val LocalGlassBackdrop = compositionLocalOf<GlassBackdrop?> { null }

/**
 * 浮层可见期间周期性抓窗口内容。
 *
 * 120ms ≈ 8fps：玻璃背后的画面轻微滞后看不出来，但比逐帧抓省一个数量级开销。
 * 位图降采样到最多 720px 宽（反正要糊掉），双缓冲避免「正在被读的那张被覆写」。
 */
internal class GlassBackdropCapture(
    private val surface: View,
    private val backdrop: GlassBackdrop,
    private val intervalMs: Long = 120L,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val buffers = arrayOfNulls<Bitmap>(2)
    private var slot = 0
    private var running = false

    private val tick = Runnable { if (running) request() }

    fun start() {
        if (running || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        running = true
        request()
    }

    fun stop() {
        running = false
        handler.removeCallbacks(tick)
        backdrop.frame = null
    }

    private fun request() {
        val vw = surface.width
        val vh = surface.height
        if (!surface.isShown || vw <= 0 || vh <= 0) {
            handler.postDelayed(tick, intervalMs)
            return
        }
        // 降采样到最多 720px 宽：反正要糊掉，省的是每帧的拷贝与 GC 压力。
        val scale = if (vw > 720) 720f / vw else 1f
        val bw = (vw * scale).toInt().coerceAtLeast(16)
        val bh = (vh * scale).toInt().coerceAtLeast(16)
        val next = 1 - slot
        val reused = buffers[next]
        val bitmap = if (reused != null && reused.width == bw && reused.height == bh) {
            reused
        } else {
            Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888).also { buffers[next] = it }
        }
        slot = next
        val here = IntArray(2).also { surface.getLocationInWindow(it) }
        val frame = GlassBackdropFrame(
            image = bitmap.asImageBitmap(),
            leftPx = here[0].toFloat(),
            topPx = here[1].toFloat(),
            widthPx = vw.toFloat(),
            heightPx = vh.toFloat(),
        )
        try {
            PixelCopy.request(surface as android.view.SurfaceView, bitmap, { result ->
                if (result == PixelCopy.SUCCESS && running) {
                    backdrop.stamp++
                    backdrop.frame = frame
                }
                handler.postDelayed(tick, intervalMs)
            }, handler)
        } catch (_: Throwable) {
            // Surface 还没就绪 / 正在销毁：晚点再试。
            handler.postDelayed(tick, intervalMs * 2)
        }
    }
}

/** 圆角矩形 SDF 梯度（与 Kimi / liquid-glass-widgets 同源）。 */
private const val RoundedRectSdf = """
float radiusAt(float2 coord, float4 radii) {
    if (coord.x >= 0.0) {
        if (coord.y <= 0.0) return radii.y;
        else return radii.z;
    } else {
        if (coord.y <= 0.0) return radii.x;
        else return radii.w;
    }
}

float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        return sign(coord) * normalize(max(cornerCoord, 0.0));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sign(coord) * float2(gradX, 1.0 - gradX);
    }
}"""

/** 方向性边缘高光：`intensity = pow(|dot(表面梯度, 光向)|, falloff)`。 */
private const val RimAgsl = """
uniform float2 size;
uniform float4 cornerRadii;
uniform float angle;
uniform float falloff;
uniform float rimWidth;
uniform float4 tint;

$RoundedRectSdf

half4 main(float2 coord) {
    float2 halfSize = size * 0.5;
    float2 centeredCoord = coord - halfSize;
    float radius = radiusAt(centeredCoord, cornerRadii);
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    float2 grad = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
    float2 normal = float2(cos(angle), sin(angle));
    float d = dot(grad, normal);
    // 只保留靠边的一条 rim：整块铺会把内部画成一堆 X 形亮带（Kimi 也是
    // 把它当边缘层用的）。sd 在内部为负，-sd 就是离边多远。
    float sd = sdRoundedRect(centeredCoord, halfSize, radius);
    float band = 1.0 - smoothstep(0.0, rimWidth, -sd);
    float intensity = pow(abs(d), falloff) * band;
    return tint * intensity;
}"""

private val rimCache = HashMap<Int, RuntimeShader?>()

/**
 * 设 uniform。
 *
 * Android 16（SDK 36）把 `setFloat` / `setFloat2` / `setFloat4` 改名成了
 * `setFloatUniform`，而 31~35 上只有旧名字 —— 编译期只能看到一个（compileSdk 37
 * 的 android.jar 里已经没有 setFloat 了），所以这里按 arity 反射找可用的那个。
 */
private val uniformMethods = HashMap<Int, java.lang.reflect.Method?>()

private fun RuntimeShader.uniform(name: String, vararg values: Float) {
    val method = uniformMethods.getOrPut(values.size) {
        val candidates = when (values.size) {
            1 -> listOf("setFloatUniform", "setFloat")
            2 -> listOf("setFloatUniform", "setFloat2")
            3 -> listOf("setFloatUniform", "setFloat3")
            4 -> listOf("setFloatUniform", "setFloat4")
            else -> emptyList()
        }
        candidates.firstNotNullOfOrNull { n ->
            runCatching {
                javaClass.getMethod(
                    n,
                    String::class.java,
                    *FloatArray(values.size).map { Float::class.javaPrimitiveType }
                        .toTypedArray(),
                )
            }.getOrNull()
        }
    } ?: return
    runCatching { method.invoke(this, name, *values.map { it as java.lang.Float }.toTypedArray()) }
}

private fun rimShader(radiusPx: Int): RuntimeShader? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
    return rimCache.getOrPut(radiusPx) {
        runCatching { RuntimeShader(RimAgsl) }.getOrNull()
    }
}

/**
 * 玻璃边缘：AGSL 方向高光 + 一圈细描边。
 *
 * [lightAngleDegrees] 是屏幕坐标系角度（0 = 正右、90 = 正下），默认 -60°
 * ≈ 光从左上方来。系统不支持 AGSL（< Android 13）时退回自上而下的亮边。
 */
fun Modifier.glassRim(
    cornerRadius: Float,
    lightAngleDegrees: Float = -60f,
    falloff: Float = 1.6f,
    rimWidth: Float = 26f,
    highlight: Color = Color.White,
    highlightAlpha: Float = 0.34f,
    baseAlpha: Float = 0.10f,
    borderWidth: Float = 1.5f,
): Modifier = drawWithContent {
    drawContent()
    val radius = cornerRadius.coerceAtMost(size.minDimension / 2f)
    val shader = rimShader(radius.toInt())
    val corner = CornerRadius(radius)
    if (shader != null) {
        shader.uniform("size", size.width, size.height)
        shader.uniform("cornerRadii", radius, radius, radius, radius)
        shader.uniform("angle", Math.toRadians(lightAngleDegrees.toDouble()).toFloat())
        shader.uniform("falloff", falloff)
        shader.uniform("rimWidth", rimWidth)
        shader.uniform(
            "tint",
            highlight.red * highlightAlpha,
            highlight.green * highlightAlpha,
            highlight.blue * highlightAlpha,
            highlightAlpha,
        )
        // 着色器创建/绘制失败不能把整块面板带走。
        runCatching {
            drawRoundRect(
                brush = ShaderBrush(shader),
                cornerRadius = corner,
            )
        }
    } else {
        drawRoundRect(
            brush = Brush.linearGradient(
                colors = listOf(
                    highlight.copy(alpha = highlightAlpha),
                    highlight.copy(alpha = baseAlpha * 0.4f),
                ),
                start = Offset.Zero,
                end = Offset(0f, size.height),
            ),
            cornerRadius = corner,
        )
    }
    drawRoundRect(
        color = highlight.copy(alpha = baseAlpha),
        cornerRadius = corner,
        style = Stroke(width = borderWidth),
    )
}

/**
 * 一块玻璃面板：身后那块游戏画面 → 裁圆角 → 模糊 → 压深色底 → 边缘高光。
 *
 * 抓不到背景（老系统 / 抓取失败）时退化成半透明深色卡，文字照样能读，
 * 不会画成「透明到看不清」。
 */
@Composable
fun GlassPanel(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 26.dp,
    blurRadius: Dp = 32.dp,
    lightAngleDegrees: Float = -60f,
    highlightAlpha: Float = 0.34f,
    baseAlpha: Float = 0.10f,
    content: @Composable ColumnScope.() -> Unit,
) {
    val backdrop = LocalGlassBackdrop.current
    val frame = backdrop?.frame
    val density = LocalDensity.current
    // 面板相对窗口的位置：背景图按整屏铺好后要反向平移这么多，
    // 才能「看见自己身后那一块」。
    var origin by remember { mutableStateOf(Offset.Zero) }
    // localToWindow：这版 LayoutCoordinates 没有 positionInWindow / boundsInWindow。
    val shape = RoundedCornerShape(cornerRadius)
    Box(
        modifier
            .onGloballyPositioned { coords -> origin = coords.localToWindow(Offset.Zero) }
            .clip(shape),
    ) {
        if (frame != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    // 背景按它在窗口里的真实位置摆好，再反向平移面板自己的位置，
                    // 于是面板里露出的正好是「自己身后那一块」游戏画面。
                    .offset {
                        IntOffset(
                            (frame.leftPx - origin.x).roundToInt(),
                            (frame.topPx - origin.y).roundToInt(),
                        )
                    }
                    .requiredSize(
                        width = with(density) { frame.widthPx.toDp() },
                        height = with(density) { frame.heightPx.toDp() },
                    )
                    .blur(blurRadius),
            ) {
                Image(
                    bitmap = frame.image,
                    contentDescription = null,
                    contentScale = ContentScale.FillBounds,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        // 深色压底：游戏里可能一片雪白，只靠模糊不够保证对比度。
        Box(
            Modifier
                .fillMaxSize()
                .drawWithContent {
                    drawRect(
                        brush = Brush.verticalGradient(
                            colors = listOf(Color(0xF01B1B20), Color(0xE6151518)),
                        ),
                    )
                    drawContent()
                },
        )
        Column(
            Modifier
                .fillMaxSize()
                .glassRim(
                    cornerRadius = with(density) { cornerRadius.toPx() },
                    lightAngleDegrees = lightAngleDegrees,
                    highlightAlpha = highlightAlpha,
                    baseAlpha = baseAlpha,
                )
                .padding(14.dp),
            content = content,
        )
    }
}

/** 卡片级（面板内的小组）玻璃：更小的圆角与更轻的高光。 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val density = LocalDensity.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .drawWithContent {
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(Color(0x2EFFFFFF), Color(0x14FFFFFF)),
                    ),
                )
                drawContent()
            }
            .glassRim(
                cornerRadius = with(density) { 18.dp.toPx() },
                highlightAlpha = 0.20f,
                baseAlpha = 0.07f,
                borderWidth = 1f,
            )
            .padding(vertical = 2.dp),
        content = content,
    )
}
