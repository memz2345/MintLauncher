package dev.mint.mint.compose

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 游戏内浮层的 Miuix 观感（深色 + #4C6FFF）。
 *
 * 没有直接依赖 compose-miuix-ui：那个库要求 Kotlin 2.4.21 / Compose 1.12.2，
 * 和工程现有（Kotlin 2.4.10 / Compose 1.12.1）差一档。这里的卡片、开关、
 * 滑块、胶囊按钮都是按 miuix 的规格手写的，成本比冒构建风险低。
 */
val MintBlue = Color(0xFF4C6FFF)
val MintDanger = Color(0xFFFF5A5F)
val MintBg = Color(0xFF141417)
val MintSheet = Color(0xF2141417)
val MintCard = Color(0xFF232327)
val MintCardPressed = Color(0xFF2C2C32)
val MintLine = Color(0x1FFFFFFF)
val MintText = Color(0xFFF4F4F7)
val MintTextVariant = Color(0xFFA9A9B2)

private val MintColorScheme = darkColorScheme(
    primary = MintBlue,
    onPrimary = Color.White,
    background = MintBg,
    onBackground = MintText,
    surface = MintSheet,
    onSurface = MintText,
    surfaceVariant = MintCard,
    onSurfaceVariant = MintTextVariant,
    error = MintDanger,
    onError = Color.White,
    outline = MintLine,
    outlineVariant = Color(0x14FFFFFF),
)

@Composable
fun MintGameTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = MintColorScheme) {
        CompositionLocalProvider(
            LocalContentColor provides MintText,
            content = content,
        )
    }
}

/**
 * 浮层主面板：Kimi 那套 LiquidGlass 观感。
 *
 * 身后那块游戏画面被裁圆角 + 模糊后当底，上面压一层深色渐变保证文字对比度，
 * 再叠一圈**方向性边缘高光**（朝光的边亮、背光的边暗）。抓不到画面时
 * （Android 12 以下 / PixelCopy 失败）自动退化成半透明深色卡。
 */
@Composable
fun MintPanel(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    GlassPanel(
        modifier = modifier.clickable(
            interactionSource = interaction,
            indication = null,
        ) {},
        cornerRadius = 24.dp,
        blurRadius = 36.dp,
        highlightAlpha = 0.30f,
        baseAlpha = 0.09f,
        content = content,
    )
}

/** 面板内的分组卡：同一套玻璃语言，圆角更小、高光更轻。 */
@Composable
fun MintGroup(content: @Composable ColumnScope.() -> Unit) {
    GlassCard(content = content)
}

@Composable
fun MintGroupDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp)
            .height(1.dp)
            .background(Color(0x0FFFFFFF)),
    )
}

@Composable
fun MintSectionLabel(text: String) {
    Text(
        text,
        modifier = Modifier.padding(start = 6.dp, top = 6.dp, bottom = 6.dp),
        color = MintTextVariant,
        fontSize = 11.5.sp,
        fontWeight = FontWeight.SemiBold,
    )
}

@Composable
fun MintSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    val track by animateColorAsState(
        if (checked) MintBlue else Color(0xFF4A4A52),
        label = "track",
    )
    val thumbX by animateDpAsState(
        if (checked) 21.dp else 2.dp,
        label = "thumb",
    )
    Box(
        Modifier
            .width(46.dp)
            .height(28.dp)
            .clip(CircleShape)
            .background(track)
            .clickable(enabled = enabled) { onCheckedChange(!checked) },
    ) {
        Box(
            Modifier
                .offset(x = thumbX, y = 3.dp)
                .size(22.dp)
                .shadow(2.dp, CircleShape)
                .clip(CircleShape)
                .background(if (enabled) Color.White else Color(0xFFB0B0B6)),
        )
    }
}

@Composable
fun MintSwitchRow(
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled) { onCheckedChange(!checked) }
            .padding(horizontal = 15.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, color = if (enabled) MintText else MintTextVariant)
            if (!subtitle.isNullOrEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(subtitle, fontSize = 11.sp, color = MintTextVariant, lineHeight = 15.sp)
            }
        }
        Spacer(Modifier.width(12.dp))
        MintSwitch(checked, onCheckedChange, enabled)
    }
}

@Composable
fun MintActionRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (danger) MintDanger else MintText,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                fontSize = 14.sp,
                color = if (danger) MintDanger else MintText,
            )
            if (!subtitle.isNullOrEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(subtitle, fontSize = 11.sp, color = MintTextVariant)
            }
        }
        Icon(
            Icons.Rounded.ChevronRight,
            contentDescription = null,
            tint = Color(0xFF6E6E78),
            modifier = Modifier.size(19.dp),
        )
    }
}

@Composable
fun MintSliderRow(
    label: String,
    valueText: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, fontSize = 13.5.sp, color = MintText, modifier = Modifier.weight(1f))
            Text(valueText, fontSize = 12.sp, color = MintTextVariant)
        }
        Spacer(Modifier.height(2.dp))
        MintSlider(value, valueRange, onValueChange, onValueChangeFinished)
    }
}

@Composable
fun MintSlider(
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
) {
    var widthPx by remember { mutableFloatStateOf(1f) }
    val density = LocalDensity.current
    val padPx = with(density) { 9.dp.toPx() }
    val span = (valueRange.endInclusive - valueRange.start).takeIf { it > 0f } ?: 1f
    fun valueAt(x: Float): Float {
        val usable = (widthPx - padPx * 2f).coerceAtLeast(1f)
        val fraction = ((x - padPx) / usable).coerceIn(0f, 1f)
        return valueRange.start + span * fraction
    }

    Box(
        Modifier
            .fillMaxWidth()
            .height(30.dp)
            .onSizeChanged { widthPx = it.width.toFloat() }
            .pointerInput(valueRange, widthPx) {
                detectTapGestures { offset ->
                    onValueChange(valueAt(offset.x))
                    onValueChangeFinished()
                }
            }
            .pointerInput(valueRange, widthPx) {
                detectHorizontalDragGestures(
                    onDragEnd = onValueChangeFinished,
                    onDragCancel = onValueChangeFinished,
                    onHorizontalDrag = { change, _ ->
                        change.consume()
                        onValueChange(valueAt(change.position.x))
                    },
                )
            },
    ) {
        Canvas(Modifier.fillMaxWidth().height(30.dp)) {
            val cy = size.height / 2f
            val trackH = 4.dp.toPx()
            val fraction = ((value - valueRange.start) / span).coerceIn(0f, 1f)
            val usable = (size.width - padPx * 2f).coerceAtLeast(1f)
            drawRoundRect(
                color = Color(0xFF47474F),
                topLeft = Offset(padPx, cy - trackH / 2f),
                size = Size(size.width - padPx * 2f, trackH),
                cornerRadius = CornerRadius(trackH / 2f),
            )
            if (fraction > 0f) {
                drawRoundRect(
                    color = MintBlue,
                    topLeft = Offset(padPx, cy - trackH / 2f),
                    size = Size(usable * fraction, trackH),
                    cornerRadius = CornerRadius(trackH / 2f),
                )
            }
            drawCircle(
                color = Color.White,
                radius = 9.dp.toPx(),
                center = Offset(padPx + usable * fraction, cy),
            )
        }
    }
}

@Composable
fun MintSegment(
    options: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(13.dp))
            .background(Color(0xFF2A2A30))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEachIndexed { index, text ->
            val active = index == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (active) MintBlue else Color.Transparent)
                    .clickable { onSelect(index) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text,
                    fontSize = 12.5.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (active) Color.White else MintTextVariant,
                )
            }
        }
    }
}

@Composable
fun MintCapsuleButton(
    text: String,
    onClick: () -> Unit,
    danger: Boolean = false,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Button(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(48.dp),
        shape = CircleShape,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (danger) MintDanger else MintBlue,
            contentColor = Color.White,
        ),
        elevation = ButtonDefaults.buttonElevation(0.dp),
    ) {
        Text(text, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun MintQuietButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TextButton(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(46.dp),
        shape = CircleShape,
    ) {
        Text(text, fontSize = 14.sp, color = MintText)
    }
}

@Composable
fun MintPill(
    text: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .clip(CircleShape)
            .background(if (selected) MintBlue else Color(0xFF2A2A30))
            .border(1.dp, if (selected) Color.Transparent else MintLine, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 7.dp),
    ) {
        Text(
            text,
            fontSize = 12.sp,
            color = if (selected) Color.White else MintTextVariant,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}
