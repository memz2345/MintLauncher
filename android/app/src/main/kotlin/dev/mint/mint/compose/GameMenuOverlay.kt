package dev.mint.mint.compose

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.ExitToApp
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.VideogameAsset
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.mint.mint.GameDisplaySettings
import dev.mint.mint.GameTweaksSettings
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

enum class GameMenuScreen { MENU, RATIO, WINDOW, EXIT, INPUT, CUSTOM }

/** 自定义按键在菜单里的快照；真正的按键对象在 GameInputView.buttons 里。 */
data class CustomKeyInfo(
    val id: String,
    val label: String,
    val keys: List<Int>,
)

/**
 * 游戏内悬浮窗的状态。Activity 只负责把状态接出来 / 应用回去；Compose
 * 不直接碰 View，改起来不受宿主那套 FrameLayout 约束。
 */
class GameMenuState(
    val versionLabel: String,
    val rendererLabel: String,
    editMode: Boolean,
    showFps: Boolean,
    buttonScale: Float,
    buttonAlpha: Float,
    ballLocked: Boolean,
    display: GameDisplaySettings,
    tweaks: GameTweaksSettings = GameTweaksSettings(),
    gyroscopeAvailable: Boolean = false,
    /**
     * 当前是否接了物理键盘 / 鼠标。
     *
     * 「外接键鼠时隐藏按键」开关的说明文字要跟着它变（接了就说清楚触摸按键
     * 为什么不见了），而菜单是瞬时快照，所以由 Activity 在打开菜单时灌进来。
     */
    externalInputAttached: Boolean = false,
    renderWidth: Int = 1280,
    renderHeight: Int = 720,
    screenAspect: Float = 16f / 9f,
    screenWidthPx: Int = 0,
    screenHeightPx: Int = 0,
    initialCustomKeys: List<CustomKeyInfo> = emptyList(),
) {
    var screen by mutableStateOf(GameMenuScreen.MENU)
    var editMode by mutableStateOf(editMode)
    var showFps by mutableStateOf(showFps)
    var buttonScale by mutableFloatStateOf(buttonScale)
    var buttonAlpha by mutableFloatStateOf(buttonAlpha)
    var ballLocked by mutableStateOf(ballLocked)
    var display by mutableStateOf(display)
    var tweaks by mutableStateOf(tweaks)
    val gyroscopeAvailable = gyroscopeAvailable
    var externalInputAttached by mutableStateOf(externalInputAttached)

    /**
     * 本次启动的 GL 缓冲尺寸：窗口页要按它的比例画画面框。
     *
     * 用可变状态而不是构造时快照 —— 拖动窗口会连带改渲染比例，
     * Activity 实时下发新缓冲后要把尺寸回灌进来，标签才不会停在旧值。
     */
    var renderWidth by mutableIntStateOf(renderWidth)
    var renderHeight by mutableIntStateOf(renderHeight)

    /** 横屏屏幕宽高比：把「窗口占屏幕的百分比」换算成画面比例。 */
    val screenAspect = screenAspect

    /**
     * 屏幕真实像素（= GameActivity 根布局尺寸）。
     *
     * 窗口页的虚线框必须和 SurfaceView 用同一套坐标，用 Compose 约束里的
     * 尺寸会因安全区 / 内边距错开一圈，拖角标时手感就对不上。
     */
    var screenWidthPx by mutableIntStateOf(screenWidthPx)
    var screenHeightPx by mutableIntStateOf(screenHeightPx)

    /** 自定义按键列表（Compose 侧镜像，增删后立即刷新页面）。 */
    val customKeys = mutableStateListOf<CustomKeyInfo>().apply {
        addAll(initialCustomKeys)
    }

    var onEditMode: (Boolean) -> Unit = {}
    var onShowFps: (Boolean) -> Unit = {}
    var onButtonScale: (value: Float, finished: Boolean) -> Unit = { _, _ -> }
    var onButtonAlpha: (value: Float, finished: Boolean) -> Unit = { _, _ -> }
    var onBallLocked: (Boolean) -> Unit = {}
    var onResetControls: () -> Unit = {}
    var onDisplay: (GameDisplaySettings, Boolean) -> Unit = { _, _ -> }
    var onAddCustomKey: (label: String, keys: List<Int>) -> Unit = { _, _ -> }
    var onUpdateCustomKey: (id: String, label: String, keys: List<Int>) -> Unit =
        { _, _, _ -> }
    var onDeleteCustomKey: (id: String) -> Unit = {}
    var onTestKeys: (keys: List<Int>) -> Unit = {}

    /** 微调设置变化（persist=false 表示滑杆拖动中，落盘等停下再做）。 */
    var onTweaks: (GameTweaksSettings, Boolean) -> Unit = { _, _ -> }

    /** 输入屏确认：整串文字逐字符发进游戏（末尾补回车）。 */
    var onSendText: (String) -> Unit = {}
    var onBackToLauncher: () -> Unit = {}
    var onQuit: () -> Unit = {}
    var onClose: () -> Unit = {}

    fun setScale(value: Float, finished: Boolean = false) {
        buttonScale = value
        onButtonScale(value, finished)
    }

    fun setAlpha(value: Float, finished: Boolean = false) {
        buttonAlpha = value
        onButtonAlpha(value, finished)
    }

    fun setDisplay(
        mode: GameDisplaySettings.Mode,
        ratio: Float,
        persist: Boolean = true,
    ) = update(
        display.copy(
            mode = mode,
            ratio = ratio.coerceIn(
                GameDisplaySettings.MIN_RATIO,
                GameDisplaySettings.MAX_RATIO,
            ),
        ),
        persist,
    )

    /**
     * 渲染精度倍率：只改 GL 缓冲高度（屏幕原生 × 倍率），画面比例不变。
     * 100% = 原生；帧率不够时先降精度。
     */
    fun setResolutionScale(scale: Float, persist: Boolean = true) = update(
        display.copy(
            resolutionScale = scale.coerceIn(
                GameDisplaySettings.MIN_SCALE,
                GameDisplaySettings.MAX_SCALE,
            ),
        ),
        persist,
    )

    /**
     * 窗口大小（画面占屏幕宽 / 高的百分比）：拖动即时生效。
     *
     * 矩形变形的同时把**渲染分辨率的比例跟着改**（缓冲宽高比 = 矩形宽高比），
     * 这样 compositor 永远只做等比缩放，画面不变形；拉小后四周出现黑边是
     * 预期效果。比例被 [GameDisplaySettings.MIN_RATIO] / [GameDisplaySettings.MAX_RATIO]
     * 夹住时，超出部分退化成黑边。
     */
    fun setWindow(
        width: Float,
        height: Float,
        persist: Boolean = true,
    ) {
        val w = GameDisplaySettings.clampWindow(width)
        val h = GameDisplaySettings.clampWindow(height)
        val aspect = (screenAspect * w / h).coerceIn(
            GameDisplaySettings.MIN_RATIO,
            GameDisplaySettings.MAX_RATIO,
        )
        update(
            display.copy(
                mode = GameDisplaySettings.Mode.CUSTOM,
                ratio = aspect,
                windowWidth = w,
                windowHeight = h,
            ),
            persist,
        )
    }

    private fun update(next: GameDisplaySettings, persist: Boolean) {
        display = next
        onDisplay(next, persist)
    }

    fun setTweaks(next: GameTweaksSettings, persist: Boolean = true) {
        tweaks = next
        onTweaks(next, persist)
    }
}

@Composable
fun GameMenuOverlay(state: GameMenuState) {
    Box(
        Modifier
            .fillMaxSize()
                .background(
                    Color.Black.copy(
                        alpha = when (state.screen) {
                            GameMenuScreen.MENU -> 0.34f
                            // 退出确认是浮层里的 miuix 确认卡，自己压一层 scrim。
                            GameMenuScreen.EXIT -> 0.50f
                            GameMenuScreen.RATIO -> 0.66f
                            // 窗口页要看得见画面和黑边，只淡淡压一层。
                            GameMenuScreen.WINDOW -> 0.16f
                            GameMenuScreen.INPUT -> 0.66f
                            GameMenuScreen.CUSTOM -> 0.66f
                        },
                    ),
                ),
    ) {
        // 点空白处关菜单；比例页 / 退出确认则先回到菜单。
        Box(
            Modifier
                .fillMaxSize()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {
                    when (state.screen) {
                        GameMenuScreen.MENU -> state.onClose()
                        GameMenuScreen.WINDOW -> state.screen = GameMenuScreen.MENU
                        else -> state.screen = GameMenuScreen.MENU
                    }
                },
        )
        when (state.screen) {
            GameMenuScreen.MENU -> MenuDrawers(state)
            GameMenuScreen.EXIT -> ExitConfirm(state)
            GameMenuScreen.RATIO -> RatioPage(state)
            GameMenuScreen.WINDOW -> WindowPage(state)
            GameMenuScreen.INPUT -> InputPage(state)
            GameMenuScreen.CUSTOM -> CustomKeysPage(state)
        }
    }
}

/**
 * 顶部居中的**游戏标题条**。
 *
 * 悬浮球菜单一打开就能确认「现在跑的是哪个版本」—— 装了五六个版本、又常
 * 常后台挂着的时候，这条比进二级页看设置省事得多。
 *
 * 用 Material 3 的 [Surface]（surfaceContainerHigh + 圆角胶囊 + 色调高度），
 * 和下面的退出对话框同一套语言：游戏内浮层**恒定走 Material**，不跟启动器
 * 的 miuix / fluent 风格走 —— 玩家在游戏里期待的是安卓原生那套手感。
 */
@Composable
private fun GameTitleBar(state: GameMenuState, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(50),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.onSurface,
        tonalElevation = 3.dp,
        shadowElevation = 6.dp,
    ) {
        Row(
            Modifier.padding(horizontal = 15.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Rounded.VideogameAsset,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(9.dp))
            Column {
                Text(
                    state.versionLabel,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${state.rendererLabel} · ${state.renderWidth}×${state.renderHeight}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun MenuDrawers(state: GameMenuState) {
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        val panelWidth = minOf(300.dp, (maxWidth - 24.dp) / 2)
        var shown by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { shown = true }
        Box(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AnimatedVisibility(
                    visible = shown,
                    enter = slideInHorizontally { -it / 3 } + fadeIn(),
                ) {
                    ControlPanel(state, Modifier.width(panelWidth).fillMaxHeight())
                }
                AnimatedVisibility(
                    visible = shown,
                    enter = slideInHorizontally { it / 3 } + fadeIn(),
                ) {
                    FunctionPanel(state, Modifier.width(panelWidth).fillMaxHeight())
                }
            }
            // 标题条浮在两栏之间的空档上方；中间是「点空白关菜单」的热区，
            // 所以自己吞掉点击，别点到就关了。
            AnimatedVisibility(
                visible = shown,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 2.dp)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) {},
                enter = fadeIn(),
            ) {
                GameTitleBar(state)
            }
        }
    }
}

@Composable
private fun PanelHeader(title: String, subtitle: String, onClose: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 0.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            Text(
                subtitle,
                fontSize = 10.5.sp,
                color = MintTextVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(Color(0x332C2C33))
                .clickable(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Close, null, tint = MintText, modifier = Modifier.size(17.dp))
        }
    }
}

@Composable
private fun ControlPanel(state: GameMenuState, modifier: Modifier = Modifier) {
    MintPanel(modifier) {
        PanelHeader("控制", "按键 / 悬浮球 / 帧率", state.onClose)
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
        ) {
            MintSectionLabel("布局")
            MintGroup {
                MintSwitchRow(
                    title = "编辑按键位置",
                    subtitle = "开启后拖动按键，点悬浮球回来关闭",
                    checked = state.editMode,
                    onCheckedChange = {
                        state.editMode = it
                        state.onEditMode(it)
                    },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "显示 FPS",
                    subtitle = "左上角实时帧率",
                    checked = state.showFps,
                    onCheckedChange = {
                        state.showFps = it
                        state.onShowFps(it)
                    },
                )
            }
            MintSectionLabel("视角")
            MintGroup {
                MintSliderRow(
                    label = "转视角灵敏度",
                    valueText = "${(state.tweaks.lookSensitivity * 100).toInt()}%",
                    value = state.tweaks.lookSensitivity,
                    valueRange =
                        GameTweaksSettings.MIN_LOOK_SENSITIVITY..
                            GameTweaksSettings.MAX_LOOK_SENSITIVITY,
                    onValueChange = {
                        state.setTweaks(state.tweaks.copy(lookSensitivity = it), false)
                    },
                    onValueChangeFinished = {
                        state.setTweaks(state.tweaks, true)
                    },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "陀螺仪转视角",
                    subtitle = if (state.gyroscopeAvailable) {
                        "倾斜设备即可转动视角，进世界后生效"
                    } else {
                        "此设备没有陀螺仪传感器"
                    },
                    checked = state.tweaks.enableGyroscope,
                    enabled = state.gyroscopeAvailable,
                    onCheckedChange = {
                        state.setTweaks(state.tweaks.copy(enableGyroscope = it))
                    },
                )
                if (state.tweaks.enableGyroscope && state.gyroscopeAvailable) {
                    MintGroupDivider()
                    MintSliderRow(
                        label = "陀螺仪灵敏度",
                        valueText = "${state.tweaks.gyroscopeSensitivity}",
                        value = state.tweaks.gyroscopeSensitivity.toFloat(),
                        valueRange =
                            GameTweaksSettings.MIN_GYRO_SENSITIVITY.toFloat()..
                                GameTweaksSettings.MAX_GYRO_SENSITIVITY.toFloat(),
                        onValueChange = {
                            state.setTweaks(
                                state.tweaks.copy(gyroscopeSensitivity = it.toInt()),
                                false,
                            )
                        },
                        onValueChangeFinished = {
                            state.setTweaks(state.tweaks, true)
                        },
                    )
                    MintGroupDivider()
                    // 反转做成两个开关而不是 FCL 那种拆两行分组：面板高度有限。
                    MintSwitchRow(
                        title = "水平轴反转",
                        checked = state.tweaks.invertGyroscopeX,
                        onCheckedChange = {
                            state.setTweaks(
                                state.tweaks.copy(invertGyroscopeX = it),
                            )
                        },
                    )
                    MintGroupDivider()
                    MintSwitchRow(
                        title = "垂直轴反转",
                        checked = state.tweaks.invertGyroscopeY,
                        onCheckedChange = {
                            state.setTweaks(
                                state.tweaks.copy(invertGyroscopeY = it),
                            )
                        },
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            MintSectionLabel("外观")
            MintGroup {
                MintSliderRow(
                    label = "按键大小",
                    valueText = "${(state.buttonScale * 100).toInt()}%",
                    value = state.buttonScale,
                    valueRange = 0.7f..1.6f,
                    onValueChange = { state.setScale(it) },
                    onValueChangeFinished = { state.setScale(state.buttonScale, true) },
                )
                MintGroupDivider()
                MintSliderRow(
                    label = "按键不透明度",
                    valueText = "${(state.buttonAlpha * 100).toInt()}%",
                    value = state.buttonAlpha,
                    valueRange = 0.25f..1f,
                    onValueChange = { state.setAlpha(it) },
                    onValueChangeFinished = { state.setAlpha(state.buttonAlpha, true) },
                )
            }
            Spacer(Modifier.height(12.dp))
            MintSectionLabel("按键")
            MintGroup {
                MintActionRow(
                    icon = Icons.Rounded.Add,
                    title = "自定义按键",
                    subtitle = if (state.customKeys.isEmpty()) {
                        "新建键盘按键 / 组合键，可拖动位置"
                    } else {
                        "${state.customKeys.size} 个自定义键 · 点击编辑绑定"
                    },
                    onClick = { state.screen = GameMenuScreen.CUSTOM },
                )
                MintGroupDivider()
                MintActionRow(
                    icon = Icons.Rounded.RestartAlt,
                    title = "重置按键布局",
                    subtitle = "默认键回到 FCL 位置，自定义键保留",
                    onClick = {
                        state.onResetControls()
                        state.buttonScale = 1f
                        state.buttonAlpha = 1f
                    },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "外接键鼠时隐藏按键",
                    subtitle = if (state.externalInputAttached) {
                        "已接入键盘 / 鼠标，触摸按键已自动收起"
                    } else {
                        "接上键盘或鼠标后自动收起触摸按键，断开恢复"
                    },
                    checked = state.tweaks.autoHideControlsOnPhysicalInput,
                    onCheckedChange = {
                        state.setTweaks(
                            state.tweaks.copy(autoHideControlsOnPhysicalInput = it),
                        )
                    },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "锁定悬浮球",
                    subtitle = "防止拖动时误碰",
                    checked = state.ballLocked,
                    onCheckedChange = {
                        state.ballLocked = it
                        state.onBallLocked(it)
                    },
                )
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun FunctionPanel(state: GameMenuState, modifier: Modifier = Modifier) {
    MintPanel(modifier) {
        PanelHeader(
            state.versionLabel,
            "功能 · ${state.rendererLabel}",
            state.onClose,
        )
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
        ) {
            MintSectionLabel("画面")
            MintGroup {
                MintActionRow(
                    icon = Icons.Rounded.Fullscreen,
                    title = "游戏窗口",
                    subtitle = state.display.windowLabel(),
                    onClick = { state.screen = GameMenuScreen.WINDOW },
                )
                MintGroupDivider()
                MintActionRow(
                    icon = Icons.Rounded.AspectRatio,
                    title = "渲染分辨率",
                    subtitle = state.display.modeSummary(state.screenHeightPx),
                    onClick = { state.screen = GameMenuScreen.RATIO },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "显示 FPS",
                    subtitle = "也可以在这里快速开关",
                    checked = state.showFps,
                    onCheckedChange = {
                        state.showFps = it
                        state.onShowFps(it)
                    },
                )
                MintGroupDivider()
                MintSwitchRow(
                    title = "显示内存",
                    subtitle = "FPS 下面叠一行 JVM 堆用量，诊断卡顿用",
                    checked = state.tweaks.showMemory,
                    onCheckedChange = {
                        state.setTweaks(state.tweaks.copy(showMemory = it))
                    },
                )
            }
            Spacer(Modifier.height(12.dp))
            MintSectionLabel("输入")
            MintGroup {
                MintActionRow(
                    icon = Icons.Rounded.Keyboard,
                    title = "输入文字",
                    subtitle = "发给游戏的聊天框 / 命令栏（支持英文、数字、符号）",
                    onClick = { state.screen = GameMenuScreen.INPUT },
                )
            }
            Spacer(Modifier.height(12.dp))
            MintSectionLabel("游戏")
            MintGroup {
                MintActionRow(
                    icon = Icons.Rounded.ExitToApp,
                    title = "返回启动器",
                    subtitle = "游戏留在后台继续运行",
                    onClick = state.onBackToLauncher,
                )
                MintGroupDivider()
                MintActionRow(
                    icon = Icons.Rounded.PowerSettingsNew,
                    title = "退出游戏",
                    subtitle = "结束进程后回到启动器",
                    danger = true,
                    onClick = { state.screen = GameMenuScreen.EXIT },
                )
            }
            Spacer(Modifier.height(12.dp))
            MintSectionLabel("提示")
            Text(
                "点悬浮球打开 / 关闭菜单；拖动悬浮球可以换位置，锁定后不会移动。",
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                fontSize = 10.5.sp,
                lineHeight = 15.sp,
                color = MintTextVariant,
            )
            Spacer(Modifier.height(8.dp))
        }
    }
}

/**
 * 退出确认 —— Compose 原生的 miuix 风确认卡。
 *
 * 不再用平台 [AlertDialog]：它会把对话框放在独立窗口里，沉浸全屏下再叠一层
 * 系统 scrim，和游戏菜单的玻璃卡片完全是两套语言。这里直接画在同一个 Compose
 * 树里：深色大圆角卡 + 危险色图标 + 胶囊按钮，点卡片外 / 返回键回到菜单。
 */
@Composable
private fun ExitConfirm(state: GameMenuState) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    Box(
        Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing),
        contentAlignment = Alignment.Center,
    ) {
        AnimatedVisibility(
            visible = shown,
            enter = fadeIn(tween(160)) + scaleIn(
                initialScale = 0.92f,
                animationSpec = tween(180),
            ),
            exit = fadeOut(tween(120)) + scaleOut(
                targetScale = 0.96f,
                animationSpec = tween(120),
            ),
        ) {
            Column(
                Modifier
                    .padding(horizontal = 22.dp, vertical = 16.dp)
                    .widthIn(max = 400.dp)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(28.dp))
                    .background(MintSheet)
                    .border(1.dp, MintLine, RoundedCornerShape(28.dp))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) {}
                    .padding(22.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(MintDanger.copy(alpha = 0.16f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Rounded.PowerSettingsNew,
                            contentDescription = null,
                            tint = MintDanger,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Spacer(Modifier.width(13.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "退出游戏",
                            fontSize = 20.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            state.versionLabel,
                            fontSize = 11.5.sp,
                            color = MintTextVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
                Text(
                    "游戏还在运行。直接结束会丢掉未保存的进度；也可以让它留在后台继续跑。",
                    fontSize = 13.sp,
                    lineHeight = 20.sp,
                    color = MintTextVariant,
                )
                Spacer(Modifier.height(22.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MintQuietButton(
                        text = "后台继续",
                        onClick = state.onBackToLauncher,
                        modifier = Modifier.weight(1f),
                    )
                    MintCapsuleButton(
                        text = "结束游戏",
                        onClick = state.onQuit,
                        danger = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun RatioPage(state: GameMenuState) {
    val display = state.display
    val ratio = display.ratio.coerceIn(
        GameDisplaySettings.MIN_RATIO,
        GameDisplaySettings.MAX_RATIO,
    )
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .padding(horizontal = 18.dp, vertical = 12.dp)
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .heightIn(max = 520.dp)
                .clip(RoundedCornerShape(26.dp))
                .background(MintSheet)
                .border(1.dp, MintLine, RoundedCornerShape(26.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {}
                .padding(18.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(Color(0x332C2C33))
                        .clickable { state.screen = GameMenuScreen.MENU },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Rounded.ArrowBack, null, tint = MintText, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("渲染分辨率", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        "实际画多少像素 · 当前 ${state.renderWidth}×${state.renderHeight}",
                        fontSize = 10.5.sp,
                        color = MintTextVariant,
                    )
                }
            }
            Spacer(Modifier.height(14.dp))
            Column(
                Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()),
            ) {
                Text(
                    "渲染精度",
                    modifier = Modifier.padding(horizontal = 4.dp),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MintTextVariant,
                )
                Spacer(Modifier.height(6.dp))
                MintSegment(
                    options = GameDisplaySettings.presetScales().map { it.first },
                    selected = GameDisplaySettings.presetScales()
                        .indexOfFirst { abs(display.resolutionScale - it.second) < 0.01f }
                        .coerceAtLeast(0),
                    onSelect = { index ->
                        state.setResolutionScale(
                            GameDisplaySettings.presetScales()[index].second,
                        )
                    },
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "当前 ${display.resolutionLabel(state.screenAspect, state.screenHeightPx)} · " +
                        "100% = 屏幕原生；帧率不够时先降到 75% 或 50%，比例不变、只降低清晰度",
                    modifier = Modifier.padding(horizontal = 4.dp),
                    fontSize = 10.5.sp,
                    lineHeight = 15.sp,
                    color = MintTextVariant,
                )
                Spacer(Modifier.height(12.dp))
                MintSegment(
                    options = listOf("适应屏幕", "铺满屏幕", "自定义"),
                    selected = when (display.mode) {
                        GameDisplaySettings.Mode.FIT -> 0
                        GameDisplaySettings.Mode.FILL -> 1
                        GameDisplaySettings.Mode.CUSTOM -> 2
                    },
                    onSelect = { index ->
                        when (index) {
                            0 -> state.setDisplay(GameDisplaySettings.Mode.FIT, ratio)
                            1 -> state.setDisplay(GameDisplaySettings.Mode.FILL, ratio)
                            else -> state.setDisplay(GameDisplaySettings.Mode.CUSTOM, ratio)
                        }
                    },
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    when (display.mode) {
                        GameDisplaySettings.Mode.FIT ->
                            "保持 16:9（${display.resolutionLabel(state.screenAspect, state.screenHeightPx)}）。" +
                                "屏幕更宽时左右留黑边，画面不变形。"
                        GameDisplaySettings.Mode.FILL ->
                            "按屏幕比例提高横向渲染分辨率（高度 ${display.renderHeight(state.screenHeightPx)}），铺满屏幕但不拉伸。"
                        GameDisplaySettings.Mode.CUSTOM ->
                            "按 ${GameDisplaySettings.ratioLabel(ratio)} 设定横向渲染分辨率" +
                                "（高度 ${display.renderHeight(state.screenHeightPx)}）；比手机更宽时上下留黑边，更窄时左右留黑边。"
                    },
                    modifier = Modifier.padding(horizontal = 4.dp),
                    fontSize = 10.5.sp,
                    lineHeight = 15.sp,
                    color = MintTextVariant,
                )
                if (display.mode == GameDisplaySettings.Mode.CUSTOM) {
                    Spacer(Modifier.height(10.dp))
                    MintGroup {
                        MintSliderRow(
                            label = "横向比例",
                            valueText = GameDisplaySettings.ratioLabel(ratio),
                            value = ratio,
                            valueRange = GameDisplaySettings.MIN_RATIO..GameDisplaySettings.MAX_RATIO,
                            onValueChange = {
                                state.setDisplay(
                                    GameDisplaySettings.Mode.CUSTOM,
                                    it,
                                    persist = false,
                                )
                            },
                            onValueChangeFinished = {
                                state.setDisplay(
                                    GameDisplaySettings.Mode.CUSTOM,
                                    state.display.ratio,
                                    persist = true,
                                )
                            },
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        for ((label, value) in GameDisplaySettings.presetRatios()) {
                            MintPill(
                                text = label,
                                selected = abs(ratio - value) < 0.015f,
                                onClick = {
                                    state.setDisplay(GameDisplaySettings.Mode.CUSTOM, value)
                                },
                            )
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
            Spacer(Modifier.height(12.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(Modifier.weight(1f)) {
                    MintQuietButton(
                        text = "恢复 16:9",
                        onClick = {
                            state.setDisplay(GameDisplaySettings.Mode.FIT, 16f / 9f)
                            state.screen = GameMenuScreen.MENU
                        },
                    )
                }
                Box(Modifier.weight(1f)) {
                    MintCapsuleButton(
                        text = "完成",
                        onClick = { state.screen = GameMenuScreen.MENU },
                    )
                }
            }
        }
    }
}


/**
 * 游戏窗口页：像拖桌面窗口一样改画面大小。
 *
 * 拖画面右下角的圆角标（或用左栏两条滑杆）改变画面在屏幕上占的矩形，
 * **即时生效**；矩形同时决定渲染分辨率的比例，所以画面永远等比缩放、不会
 * 变形，拉小之后四周出现黑边是正常现象。控制面板放左侧，把右下角留给角标。
 */
@Composable
private fun WindowPage(state: GameMenuState) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val panelWidth = minOf(300.dp, (maxWidth - 24.dp) / 2)
        // 画面框层不套 padding：它必须和 SurfaceView 用同一套屏幕像素坐标，
        // 否则虚线框和真实画面会错开一圈。
        run {
            val screenW = state.screenWidthPx.toFloat().coerceAtLeast(1f)
            val screenH = state.screenHeightPx.toFloat().coerceAtLeast(1f)
            // 窗口盒 = 屏幕 × 百分比；画面在盒子里按缓冲比例等比缩放。
            val boxW = screenW * state.display.windowWidth
            val boxH = screenH * state.display.windowHeight
            val aspect = state.renderWidth.toFloat() /
                state.renderHeight.coerceAtLeast(1)
            val picW = min(boxW, boxH * aspect).coerceAtLeast(1f)
            val picH = (picW / aspect).coerceAtLeast(1f)

            Canvas(Modifier.fillMaxSize()) {
                val left = (size.width - picW) / 2f
                val top = (size.height - picH) / 2f
                drawRect(
                    color = Color.White.copy(alpha = 0.55f),
                    topLeft = Offset(left, top),
                    size = Size(picW, picH),
                    style = Stroke(
                        width = 2.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(
                            floatArrayOf(14f, 10f), 0f,
                        ),
                    ),
                )
            }

            Box(
                Modifier
                    .align(Alignment.Center)
                    .size(
                        width = with(density) { picW.toDp() },
                        height = with(density) { picH.toDp() },
                    ),
            ) {
                var origin by remember { mutableStateOf(Offset.Zero) }
                var startW by remember { mutableFloatStateOf(1f) }
                var startH by remember { mutableFloatStateOf(1f) }
                Box(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .padding(4.dp)
                        .size(52.dp)
                        .pointerInput(screenW, screenH) {
                            detectDragGestures(
                                onDragStart = {
                                    origin = it
                                    startW = state.display.windowWidth
                                    startH = state.display.windowHeight
                                },
                                onDrag = { change, _ ->
                                    change.consume()
                                    // 画面居中，角上挪 dx 相当于宽度两边各挪一半。
                                    state.setWindow(
                                        startW + (change.position.x - origin.x) * 2f / screenW,
                                        startH + (change.position.y - origin.y) * 2f / screenH,
                                        persist = false,
                                    )
                                },
                                onDragEnd = {
                                    state.setWindow(
                                        state.display.windowWidth,
                                        state.display.windowHeight,
                                    )
                                },
                                onDragCancel = {
                                    state.setWindow(
                                        state.display.windowWidth,
                                        state.display.windowHeight,
                                    )
                                },
                            )
                        },
                    contentAlignment = Alignment.BottomEnd,
                ) {
                    Box(
                        Modifier
                            .size(26.dp)
                            .clip(RoundedCornerShape(9.dp))
                            .background(MintBlue),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Rounded.DragHandle,
                            null,
                            tint = Color.White,
                            modifier = Modifier.size(17.dp),
                        )
                    }
                }
            }
        }

        MintPanel(
            Modifier
                .align(Alignment.CenterStart)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 12.dp, vertical = 10.dp)
                .width(panelWidth)
                .fillMaxHeight(),
        ) {
            PanelHeader(
                title = "游戏窗口",
                subtitle = "${state.display.windowLabel()} · " +
                    "${state.renderWidth}×${state.renderHeight}",
                onClose = { state.screen = GameMenuScreen.MENU },
            )
            Column(
                Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
            ) {
                MintGroup {
                    MintSliderRow(
                        label = "横向大小",
                        valueText = "${(state.display.windowWidth * 100).roundToInt()}%",
                        value = state.display.windowWidth,
                        valueRange =
                            GameDisplaySettings.MIN_WINDOW..GameDisplaySettings.MAX_WINDOW,
                        onValueChange = {
                            state.setWindow(it, state.display.windowHeight, persist = false)
                        },
                        onValueChangeFinished = {
                            state.setWindow(state.display.windowWidth, state.display.windowHeight)
                        },
                    )
                    MintGroupDivider()
                    MintSliderRow(
                        label = "纵向大小",
                        valueText = "${(state.display.windowHeight * 100).roundToInt()}%",
                        value = state.display.windowHeight,
                        valueRange =
                            GameDisplaySettings.MIN_WINDOW..GameDisplaySettings.MAX_WINDOW,
                        onValueChange = {
                            state.setWindow(state.display.windowWidth, it, persist = false)
                        },
                        onValueChangeFinished = {
                            state.setWindow(state.display.windowWidth, state.display.windowHeight)
                        },
                    )
                }
                Spacer(Modifier.height(10.dp))
                // 面板只有 300dp 宽、手机横屏又只有 ~400dp 高：预设只留三档，
                // 一行放得下，不会把「渲染分辨率」和完成按钮挤出可视区。
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for ((label, value) in GameDisplaySettings.presetWindows()) {
                        MintPill(
                            text = label,
                            selected = abs(state.display.windowWidth - value) < 0.01f &&
                                abs(state.display.windowHeight - value) < 0.01f,
                            onClick = { state.setWindow(value, value) },
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                MintActionRow(
                    icon = Icons.Rounded.AspectRatio,
                    title = "渲染分辨率",
                    subtitle = "${state.renderWidth}×${state.renderHeight} · 跟随窗口比例",
                    onClick = { state.screen = GameMenuScreen.RATIO },
                )
            }
            Spacer(Modifier.height(6.dp))
            MintCapsuleButton(
                text = "完成",
                onClick = { state.screen = GameMenuScreen.MENU },
            )
        }
    }
}


/**
 * 文字输入页（FCL TouchCharInput 的简化版思路，GPL-3.0）。
 *
 * FCL 是在游戏画面上叠一个隐藏 EditText 做实时差量注入；Mint 用系统 IME
 * 在菜单里直接编完整串，确认后逐字符 sendChar + 回车一次性发出去 —— 差量
 * 逻辑容易在 IME 组合词（拼音联想）上出错，整串发送语义更可控。
 */
@Composable
private fun InputPage(state: GameMenuState) {
    var text by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .padding(horizontal = 18.dp, vertical = 12.dp)
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(26.dp))
                .background(MintSheet)
                .border(1.dp, MintLine, RoundedCornerShape(26.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {}
                .padding(18.dp),
        ) {
            Text("输入文字", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(
                "先在游戏里打开聊天框（按 T），再从这里发送。仅支持英文、数字与符号。",
                fontSize = 10.5.sp,
                lineHeight = 15.sp,
                color = MintTextVariant,
            )
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focusRequester),
                singleLine = true,
                placeholder = { Text("/gamemode creative", fontSize = 12.5.sp) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(
                    onSend = {
                        if (text.isNotEmpty()) {
                            state.onSendText(text)
                            state.screen = GameMenuScreen.MENU
                        }
                    },
                ),
            )
            Spacer(Modifier.height(14.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(Modifier.weight(1f)) {
                    MintQuietButton(
                        text = "取消",
                        onClick = { state.screen = GameMenuScreen.MENU },
                    )
                }
                Box(Modifier.weight(1f)) {
                    MintCapsuleButton(
                        text = "发送",
                        enabled = text.isNotEmpty(),
                        onClick = {
                            state.onSendText(text)
                            state.screen = GameMenuScreen.MENU
                        },
                    )
                }
            }
        }
    }
}

/**
 * 自定义按键页：列表 + 绑定编辑器。
 *
 * 绑定用键位网格而不是系统键盘：F1–F12、方向键、Insert/Delete 这些在软键盘上
 * 根本没有，网格还能直接多选做组合键。长按任意键位会把该键临时按下再松开，
 * 不用先保存就能在游戏里试效果。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CustomKeysPage(state: GameMenuState) {
    var creating by remember { mutableStateOf(false) }
    var editingId by remember { mutableStateOf<String?>(null) }
    var draftKeys by remember { mutableStateOf<List<Int>>(emptyList()) }
    var tab by remember { mutableIntStateOf(0) }
    var confirmDelete by remember { mutableStateOf<String?>(null) }

    val editing = editingId?.let { id -> state.customKeys.firstOrNull { it.id == id } }
    val inEditor = creating || editing != null
    val orderedDraft = GameKeyCatalog.ordered(draftKeys)

    fun resetDraft() {
        creating = false
        editingId = null
        draftKeys = emptyList()
        tab = 0
    }

    fun toggleKey(code: Int) {
        draftKeys = when {
            code in draftKeys -> draftKeys.filterNot { it == code }
            draftKeys.size >= GameKeyCatalog.MAX_KEYS -> draftKeys
            else -> draftKeys + code
        }
    }

    Box(
        Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .padding(horizontal = 18.dp, vertical = 12.dp)
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .heightIn(max = 560.dp)
                .clip(RoundedCornerShape(26.dp))
                .background(MintSheet)
                .border(1.dp, MintLine, RoundedCornerShape(26.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {}
                .padding(18.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(Color(0x332C2C33))
                        .clickable {
                            if (inEditor) resetDraft() else state.screen = GameMenuScreen.MENU
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.ArrowBack,
                        null,
                        tint = MintText,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        when {
                            creating -> "新建按键"
                            editing != null -> "编辑按键"
                            else -> "自定义按键"
                        },
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        if (inEditor) {
                            "${orderedDraft.size}/${GameKeyCatalog.MAX_KEYS} 个键 · " +
                                "修饰键自动排到最前"
                        } else {
                            "键盘 / 功能键 / 组合键 · 长按键位可试按"
                        },
                        fontSize = 10.5.sp,
                        color = MintTextVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.height(14.dp))

            if (!inEditor) {
                Column(
                    Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()),
                ) {
                    if (state.customKeys.isEmpty()) {
                        Column(
                            Modifier.fillMaxWidth().padding(vertical = 34.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Icon(
                                Icons.Rounded.Keyboard,
                                null,
                                tint = MintTextVariant,
                                modifier = Modifier.size(34.dp),
                            )
                            Spacer(Modifier.height(10.dp))
                            Text("还没有自定义按键", fontSize = 14.sp, color = MintText)
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "可以绑定单个键，也可以把 CTRL / SHIFT 和一个键绑成组合键。",
                                fontSize = 10.5.sp,
                                lineHeight = 15.sp,
                                color = MintTextVariant,
                            )
                        }
                    } else {
                        for (info in state.customKeys) {
                            CustomKeyRow(
                                info = info,
                                confirming = confirmDelete == info.id,
                                onEdit = {
                                    creating = false
                                    editingId = info.id
                                    draftKeys = info.keys
                                    tab = 0
                                    confirmDelete = null
                                },
                                onAskDelete = { confirmDelete = info.id },
                                onCancelDelete = { confirmDelete = null },
                                onDelete = {
                                    state.onDeleteCustomKey(info.id)
                                    confirmDelete = null
                                },
                            )
                            Spacer(Modifier.height(8.dp))
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                }
                Spacer(Modifier.height(12.dp))
                MintCapsuleButton(
                    text = "新建按键",
                    onClick = {
                        creating = true
                        editingId = null
                        draftKeys = emptyList()
                        tab = 0
                        confirmDelete = null
                    },
                )
            } else {
                Row(Modifier.fillMaxWidth().weight(1f)) {
                    Column(Modifier.width(172.dp).fillMaxHeight()) {
                        Text(
                            "已选键位",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MintTextVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                        Column(
                            Modifier.weight(1f).verticalScroll(rememberScrollState()),
                        ) {
                            if (orderedDraft.isEmpty()) {
                                Text(
                                    "点选右侧键位，先选哪个都行；修饰键会自动排到最前。",
                                    fontSize = 10.5.sp,
                                    lineHeight = 15.sp,
                                    color = MintTextVariant,
                                )
                            } else {
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    for (code in orderedDraft) {
                                        SelectedKeyChip(
                                            label = GameKeyCatalog.labelOf(code),
                                            onRemove = {
                                                draftKeys = draftKeys.filterNot { it == code }
                                            },
                                        )
                                    }
                                }
                            }
                        }
                        if (orderedDraft.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                MintPill(
                                    text = "试按组合",
                                    selected = false,
                                    onClick = { state.onTestKeys(orderedDraft) },
                                )
                                MintPill(
                                    text = "清空",
                                    selected = false,
                                    onClick = { draftKeys = emptyList() },
                                )
                            }
                        }
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f).fillMaxHeight()) {
                        MintSegment(
                            options = listOf("字母", "数字", "功能", "修饰", "符号"),
                            selected = tab,
                            onSelect = { tab = it },
                        )
                        Spacer(Modifier.height(10.dp))
                        Column(
                            Modifier.weight(1f).verticalScroll(rememberScrollState()),
                        ) {
                            val keys = when (tab) {
                                0 -> GameKeyCatalog.letters
                                1 -> GameKeyCatalog.digits
                                2 -> GameKeyCatalog.function
                                3 -> GameKeyCatalog.modifiers
                                else -> GameKeyCatalog.symbols
                            }
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                for (key in keys) {
                                    GameKeyChip(
                                        label = key.label,
                                        selected = key.code in draftKeys,
                                        onToggle = { toggleKey(key.code) },
                                        onTest = { state.onTestKeys(listOf(key.code)) },
                                    )
                                }
                            }
                            Spacer(Modifier.height(10.dp))
                            Text(
                                "长按任意键位 = 立即临时按下该键，松开由系统自动补；" +
                                    "组合键保存后，按住虚拟按键会同时按下。",
                                fontSize = 10.5.sp,
                                lineHeight = 15.sp,
                                color = MintTextVariant,
                            )
                            Spacer(Modifier.height(4.dp))
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(Modifier.weight(1f)) {
                        MintQuietButton(text = "取消", onClick = { resetDraft() })
                    }
                    Box(Modifier.weight(1f)) {
                        MintCapsuleButton(
                            text = if (creating) "添加" else "保存",
                            enabled = draftKeys.isNotEmpty(),
                            onClick = {
                                val ordered = GameKeyCatalog.ordered(draftKeys)
                                val label = GameKeyCatalog.comboLabel(ordered)
                                if (creating) {
                                    state.onAddCustomKey(label, ordered)
                                } else {
                                    editingId?.let {
                                        state.onUpdateCustomKey(it, label, ordered)
                                    }
                                }
                                resetDraft()
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CustomKeyRow(
    info: CustomKeyInfo,
    confirming: Boolean,
    onEdit: () -> Unit,
    onAskDelete: () -> Unit,
    onCancelDelete: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MintCard)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(info.label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(2.dp))
            Text(
                info.keys.joinToString(" + ") { GameKeyCatalog.labelOf(it) },
                fontSize = 10.5.sp,
                color = MintTextVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (confirming) {
            Box(
                Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onCancelDelete)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            ) {
                Text("取消", fontSize = 11.5.sp, color = MintTextVariant)
            }
            Box(
                Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onDelete)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            ) {
                Text("删除", fontSize = 11.5.sp, color = MintDanger)
            }
        } else {
            Box(
                Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onEdit),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.Edit,
                    contentDescription = "编辑",
                    tint = MintTextVariant,
                    modifier = Modifier.size(17.dp),
                )
            }
            Box(
                Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onAskDelete),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.DeleteOutline,
                    contentDescription = "删除",
                    tint = MintTextVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun SelectedKeyChip(label: String, onRemove: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MintBlue.copy(alpha = 0.22f))
            .border(1.dp, MintBlue.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
            .clickable(onClick = onRemove)
            .padding(horizontal = 11.dp, vertical = 8.dp),
    ) {
        Text("$label ×", fontSize = 12.sp, color = MintText)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GameKeyChip(
    label: String,
    selected: Boolean,
    onToggle: () -> Unit,
    onTest: () -> Unit,
) {
    Box(
        Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) MintBlue else Color(0xFF2A2A30))
            .border(
                1.dp,
                if (selected) Color.Transparent else MintLine,
                RoundedCornerShape(12.dp),
            )
            .combinedClickable(onClick = onToggle, onLongClick = onTest)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Text(
            label,
            fontSize = 12.5.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Color.White else MintText,
        )
    }
}
