package dev.mint.mint

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.content.pm.ActivityInfo
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.graphics.SurfaceTexture
import android.view.TextureView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import dev.mint.mint.compose.ComposeOverlayHost
import dev.mint.mint.compose.CustomKeyInfo
import dev.mint.mint.compose.GameCrashOverlay
import dev.mint.mint.compose.GameLoadingOverlay
import dev.mint.mint.compose.GameMenuOverlay
import dev.mint.mint.compose.GameMenuScreen
import dev.mint.mint.compose.GameMenuState
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 游戏宿主窗口。
 *
 * 跑在独立进程 `:game` 里（见 AndroidManifest）：这样「启动器结束游戏」只要
 * 杀掉游戏进程就够，启动器自己不受牵连。
 *
 * 与启动器的通信全部走广播 + pid 文件（跨进程）：
 *  - `ACTION_STOP`（启动器 / 通知栏「结束」）→ 杀本进程；
 *  - `ACTION_EXIT`（游戏自己退出）→ 启动器把状态从「运行中」切回空闲；
 *  - `filesDir/game.pid` → 启动器随时能判断游戏还在不在。
 *
 * 游戏内 UI 全部交给 Compose（[GameMenuOverlay]）；悬浮球是 FCL 同款
 * 可拖动 ImageView。画面比例读 [GameDisplaySettings]（拉取器设置页和
 * 游戏内菜单共用同一个 JSON）。
 */
class GameActivity : Activity(), TextureView.SurfaceTextureListener {
    companion object {
        private const val TAG = "MintFcl"
        private const val GAME_W = 1280
        private const val GAME_H = 720
        /** GLFW KEY_ENTER（输入屏发送聊天 / 命令用）。 */
        private const val KEY_ENTER = 257

        /** GLFW 窗口属性（与 lwjgl3 GLFW_FOCUSED / GLFW_HOVERED 同值）。 */
        private const val GLFW_FOCUSED = 0x00020001
        private const val GLFW_HOVERED = 0x0002000B
        private const val GLFW_KEY_ESCAPE = 256

        /** 启动器 / 通知栏要求结束游戏。 */
        const val ACTION_STOP = "dev.mint.mint.action.STOP_GAME"

        /** 游戏进程自己退出（JVM 结束 / 用户点退出）。 */
        const val ACTION_EXIT = "dev.mint.mint.action.GAME_EXIT"

        /** 启动器改了画面比例：游戏在后台也立刻重读。 */
        const val ACTION_DISPLAY = "dev.mint.mint.action.DISPLAY_CHANGED"

        /**
         * 启动器改了体验微调（灵敏度 / 陀螺仪 / 内存叠层等）：游戏在后台
         * 也立刻重读。画面比例走 ACTION_DISPLAY，这里只管其余的。
         */
        const val ACTION_TWEAKS = "dev.mint.mint.action.TWEAKS_CHANGED"

        fun gamePid(context: Context): Int {
            val f = File(context.filesDir, "game.pid")
            val pid = try {
                f.readText().trim().toInt()
            } catch (_: Throwable) {
                return -1
            }
            if (pid <= 0) return -1
            val cmdline = try {
                File("/proc/$pid/cmdline").readText()
            } catch (_: Throwable) {
                return -1
            }
            val pkg = context.packageName
            if (!cmdline.contains(pkg)) {
                f.delete()
                return -1
            }
            return pid
        }

        fun pidFile(context: Context): File = File(context.filesDir, "game.pid")

        /** 崩溃判定用的关键词（FCL 的 findFatalErrorLogPath 思路）。 */
        private val CRASH_MARKERS = listOf(
            "---- Minecraft Crash Report ----",
            "A fatal error has been detected by the Java Runtime Environment",
            "Exception in thread",
            "Caused by:",
            "java.lang.reflect.InvocationTargetException",
            "java.lang.ExceptionInInitializerError",
            "java.lang.NoClassDefFoundError",
            "java.lang.NoSuchMethodError",
            "java.lang.UnsatisfiedLinkError",
            "java.lang.OutOfMemoryError",
            "Error: Could not find or load main class",
            "Could not find or load main class",
            "FATAL ERROR",
        )
    }

    private lateinit var root: FrameLayout
    private lateinit var textureView: TextureView

    /**
     * 游戏画面的 SurfaceTexture 与其 Surface（FCL JVMActivity 同款）。
     *
     * 用 **TextureView** 而不是 SurfaceView 有两个硬理由：
     *  1. display 旋转的 transform 由 TextureView 自己吸收（它内部按
     *     SurfaceTexture 的 transform 矩阵反向旋转后再合成）；SurfaceView 是
     *     直通图层，transform 直接透传给 SurfaceFlinger —— RenderPearl 的
     *     Vulkan swapchain 不做 pre-rotate，26.3 就整个转 90°。
     *  2. [SurfaceTexture.setDefaultBufferSize] 是「默认值」，生产者提交的
     *     buffer 不会被固定尺寸拒单；SurfaceView 的 `setFixedSize` 会把
     *     BufferQueue 锁死 —— Zink 的 swapchain 按初始化时的几何拿 buffer，
     *     与固定尺寸不符时整个 swapchain 被 kill（26.2 黑屏有声的根因）。
     */
    private var surfaceTexture: SurfaceTexture? = null
    private var gameSurface: Surface? = null

    private lateinit var inputView: GameInputView
    private lateinit var fpsLabel: TextView
    private lateinit var memLabel: TextView
    private lateinit var editHint: TextView
    private lateinit var menuBall: MenuBallView
    private lateinit var overlayHost: ComposeOverlayHost
    private var loadingOverlay: GameLoadingOverlay? = null
    private var loadingDone = false
    private var gameStartAt = 0L

    /** 本次启动的 GL 缓冲尺寸（高固定 720，宽度按画面比例算）。 */
    private var gameWidth = GAME_W
    private var gameHeight = GAME_H

    private var menuState: GameMenuState? = null
    private var bridge: Any? = null
    private var started = false
    private var showFps = true

    /**
     * 「跳转游戏」重建出的无参实例：finish 时不要删 pid 文件、不要给启动器
     * 发退出广播 —— 游戏进程还在跑，启动器的「运行中」状态必须保住。
     */
    private var restoreOnly = false

    private var displaySettings = GameDisplaySettings()
    private var tweaks = GameTweaksSettings()
    private var gyroscope: GameGyroscope? = null
    private var versionName = ""
    private var rendererName = "GL4ES"

    /** 物理键鼠 → FCL 输入的路由器（在 dispatch 阶段拦事件，早于 View 树）。 */
    private lateinit var hardwareInput: GameHardwareInput

    /** 外接键鼠的在线状态（拔插即时回调，用来自动收起触摸按键）。 */
    private var physicalInput: PhysicalInputWatcher? = null

    /** 1.13+（结构化参数）要开 GLFW 的 input stack queue，否则键盘输入会丢。 */
    private var useInputStackQueue = false

    /** 26.3+ 的 RenderPearl 走 SDL3：Surface 要先注册给 FCL 的 SdlBridge。 */
    private var sdl3 = false

    /**
     * SDL 窗口刚创建时游戏还没收到我们同步的尺寸，`syncResolution` 又要等
     * `sdlEnabled=true`（游戏 SDL_Init 触发 notifyLauncher）才生效，结果游戏
     * 按初始几何建窗口、SDL 窗口与 Surface buffer 不一致。等 SdlBridge 真正
     * 接管后再同步一次，并补一次窗口稳定后的同步。
     */
    private val sdlSyncHandler = Handler(Looper.getMainLooper())
    private var sdlSyncAttempts = 0

    // ── 崩溃日志 / 报告 ──
    /** FCLBridge.onLog 的滚动缓冲（约 800 行），JVM 挂了也能拿出来看。 */
    private val runtimeLog = ArrayDeque<String>()
    private var crashOverlay: GameCrashOverlay? = null
    private var crashShown = false
    private var exitBroadcastSent = false
    private var crashSummary = ""
    private var crashDetail = ""
    private var crashTail = ""
    private lateinit var workingDirPath: String

    private val handler = Handler(Looper.getMainLooper())
    private var backCallback: OnBackInvokedCallback? = null

    /**
     * FPS 采样窗口。
     *
     * FCL 的 `CallbackBridge.getFps()` 是**读并清零**（native 侧 swpal 0），
     * 返回的是「上次调用以来画了多少帧」，不是每秒帧数。以前每 500ms 直接
     * 把它当 FPS 显示，60fps 会被读成 30fps —— 这是「720p 只有 30 帧」的
     * 真正来源。这里按实际经过时间换算成每秒帧数。
     */
    private var lastFpsSampleAt = 0L
    private var lastFps = 0
    private val fpsTick = object : Runnable {
        override fun run() {
            updateFps()
            handler.postDelayed(this, 500)
        }
    }

    /**
     * 首帧检测：FCL 的 native FPS 计数一涨就说明游戏真的画出了第一帧，
     * 这时再收加载层；60 秒还没动静就兜底收起（渲染器异常时别把玩家永久
     * 挡在加载层后面）。
     */
    private val loadingTick = object : Runnable {
        override fun run() {
            if (loadingDone) return
            if (FclRuntime.getFps(bridge) > 0 ||
                SystemClock.elapsedRealtime() - gameStartAt > 60_000L
            ) {
                finishLoading()
                return
            }
            handler.postDelayed(this, 250)
        }
    }

    private val tweaksReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_TWEAKS) {
                applyTweaks(GameTweaksSettings.load(this@GameActivity))
            }
        }
    }

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP) {
                Log.i(TAG, "收到结束指令，杀游戏进程")
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }

    private val displayReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_DISPLAY) return
            // 启动器改了设置：窗口大小立刻重排，渲染分辨率也立刻下发给游戏。
            applyDisplay(GameDisplaySettings.load(this@GameActivity))
        }
    }

    /**
     * 套用一份画面设置。
     *
     *  - **窗口大小**只是 TextureView 的布局参数，改完立刻重排；
     *  - **渲染分辨率**要换 GL 缓冲尺寸：`SurfaceTexture.setDefaultBufferSize` +
     *    给 GLFW 发 framebuffer-size 事件（FCL 切「强制分辨率」就是这条链路），
     *    游戏会按新比例重新布局，不需要重启。
     *
     * [commitResolution] = false 用在滑杆/拖角的过程中：每帧换缓冲会让
     * compositor 反复重分配，所以拖动中只重排矩形（画面短暂拉伸），松手
     * 那一刻才真正下发新分辨率。JVM 还没起来时同样只记尺寸，
     * [startIfReady] 会按最新值启动。
     */
    private fun applyDisplay(next: GameDisplaySettings, commitResolution: Boolean = true) {
        displaySettings = next
        if (!::textureView.isInitialized) return
        if (commitResolution) {
            val (w, h) = next.renderSize(screenAspect(), screenHeightPx())
            if (w != gameWidth || h != gameHeight) {
                gameWidth = w
                gameHeight = h
                // buffer（渲染分辨率）、SDL 窗口、GLFW 窗口三者保持一致：
                // FCL 用 TextureView.setDefaultBufferSize 维持同一条不变式。
                // TextureView 的默认 buffer 尺寸不锁队列，运行中的游戏按新
                // 尺寸重新 dequeue 即可，不会像 setFixedSize 那样把 Zink 的
                // swapchain 逼死；SDL 几何由 syncSdlResolution 跟进。
                surfaceTexture?.setDefaultBufferSize(w, h)
                if (::inputView.isInitialized) inputView.setGameSize(w, h)
                if (sdl3) FclRuntime.syncSdlResolution(w, h)
                if (started) {
                    FclRuntime.updateWindowSize(applicationContext, bridge, w, h)
                    Log.i(TAG, "渲染分辨率实时切换 ${w}x$h")
                } else {
                    Log.i(TAG, "渲染分辨率待应用 ${w}x$h（JVM 尚未启动）")
                }
                // 菜单开着的话把新尺寸回灌，标签 / 虚线框才不会停在旧比例。
                menuState?.let {
                    it.renderWidth = w
                    it.renderHeight = h
                }
            }
        }
        applyGameBounds()
        // 换缓冲后 Surface 可能换了，重新投一次高刷票。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            display?.let { voteSurfaceRefreshRate(targetRefreshRate(it)) }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val args = intent.getStringArrayExtra("args")
        val workingDir = intent.getStringExtra("workingDir").orEmpty()
        val logDir = intent.getStringExtra("logDir").orEmpty()
        val javaHome = intent.getStringExtra("javaHome").orEmpty()
        val renderer = intent.getStringExtra("renderer").orEmpty().ifEmpty { "gl4es" }
        val lwjglVersion = intent.getStringExtra("lwjglVersion") ?: "3.3.3"
        val javaMajor = intent.getIntExtra("javaMajor", 8)
        showFps = intent.getBooleanExtra("showFps", true)
        versionName = intent.getStringExtra("versionName").orEmpty()
        workingDirPath = workingDir
        rendererName = rendererLabel(renderer)
        useInputStackQueue = intent.getBooleanExtra("useInputStackQueue", false)
        sdl3 = intent.getBooleanExtra("sdl3", false)
        InputDebug.init(this)
        val legacyAwt = intent.getBooleanExtra("legacyAwt", false)
        InputDebug.log(
            "启动参数：renderer=$renderer 远古版=$legacyAwt lwjgl=$lwjglVersion",
        )
        // 诊断开关：`<外部files>/input_queue` 写 0 / 1 可临时覆盖队列开关。
        InputDebug.queueOverride(this)?.let {
            useInputStackQueue = it
            InputDebug.log("输入队列被 input_queue 文件覆盖为 $useInputStackQueue")
        }
        if (workingDir.isNotEmpty()) {
            // 清掉上一局的实时日志，避免硬崩溃兜底读到旧内容。
            try {
                val logs = File(workingDir, "logs").apply { mkdirs() }
                File(logs, "mint-runtime.log").writeText("")
            } catch (_: Throwable) {
            }
        }
        displaySettings = GameDisplaySettings.load(this)
        displaySettings.renderSize(screenAspect(), screenHeightPx()).let { (w, h) ->
            gameWidth = w
            gameHeight = h
        }
        // FCL/Pojav 的 AWT stub：远古版（alpha/beta/1.5）会 new Frame，
        // 这套 JRE 用 AWTSTUB_WIDTH/HEIGHT 画到内存位图；不设的话
        // Java 会因为没有 X11 DISPLAY 直接 HeadlessException。
        try {
            android.system.Os.setenv("AWTSTUB_WIDTH", gameWidth.toString(), true)
            android.system.Os.setenv("AWTSTUB_HEIGHT", gameHeight.toString(), true)
        } catch (_: Throwable) {
        }
        Log.i(
            TAG,
            "渲染分辨率 ${gameWidth}x$gameHeight（${displaySettings.mode.id} " +
                "${(displaySettings.resolutionScale * 100).toInt()}%，" +
                "窗口 ${displaySettings.windowLabel()}，" +
                "屏幕原生高 ${screenHeightPx()}px，" +
                "屏幕 ${"%.2f".format(screenAspect())}:1）",
        )
        tweaks = GameTweaksSettings.load(this)
        if (args == null || args.isEmpty() || workingDir.isEmpty() || javaHome.isEmpty()) {
            // 「更多 → 跳转游戏」只是把已有 task 提回前台；若进程还活着但
            // Activity 已被销毁，这次重建的实例拿不到参数 —— 静默退场，别把
            // 正在跑的游戏误报成「启动参数不完整」。
            if (intent.getBooleanExtra("restoreToFront", false)) {
                restoreOnly = true
                finish()
                return
            }
            // 参数缺失以前是静默 finish()，表现成「点了启动但什么都没发生」；
            // 现在把缺的东西写进崩溃页与日志，玩家和排查的人都看得见。
            Log.e(TAG, "启动参数不完整，无法拉起游戏")
            reportCrash(
                title = "启动参数不完整",
                summary = "没有收到 JVM 启动参数或游戏目录，游戏进程没有起来",
                detail = "args=${args?.size ?: 0} 项，workingDir=$workingDir，javaHome=$javaHome",
                exitCode = -2,
            )
            return
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        writePid()
        registerStopReceiver()
        registerDisplayReceiver()
        registerTweaksReceiver()
        applyMaxRefreshRatePolicy()
        (getSystemService(DISPLAY_SERVICE) as? DisplayManager)
            ?.registerDisplayListener(displayListener, handler)
        GameKeepAliveService.start(this, "")

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        textureView = TextureView(this).apply {
            surfaceTextureListener = this@GameActivity
            // 不透明度保持 1f：玻璃浮层 backdrop 抓的是这一层的绘制内容。
            isOpaque = true
        }
        root.addView(textureView, FrameLayout.LayoutParams(-1, -1))
        inputView = GameInputView(this)
        root.addView(inputView, FrameLayout.LayoutParams(-1, -1))
        FclRuntime.onCursorModeChanged = {
            if (!FclRuntime.cursorGrabbed) inputView.resetInput()
            inputView.invalidate()
        }
        FclRuntime.onGameLog = { line -> appendRuntimeLog(line) }
        FclRuntime.onGameExit = { code -> handleGameExit(code) }

        fpsLabel = TextView(this).apply {
            textSize = 11.5f
            typeface = Typeface.MONOSPACE
            setTextColor(0xF2FFFFFF.toInt())
            setShadowLayer(3f, 0f, 1f, Color.BLACK)
            visibility = if (showFps) View.VISIBLE else View.GONE
        }
        root.addView(
            fpsLabel,
            FrameLayout.LayoutParams(-2, -2).apply {
                gravity = Gravity.TOP or Gravity.START
                leftMargin = dp(14)
                topMargin = dp(10)
            },
        )

        // 内存叠层（FCL showMemory 对应物）：跟 FPS 同一列，诊断卡顿用。
        memLabel = TextView(this).apply {
            textSize = 11.5f
            typeface = Typeface.MONOSPACE
            setTextColor(0xF2FFFFFF.toInt())
            setShadowLayer(3f, 0f, 1f, Color.BLACK)
            visibility = if (tweaks.showMemory) View.VISIBLE else View.GONE
        }
        root.addView(
            memLabel,
            FrameLayout.LayoutParams(-2, -2).apply {
                gravity = Gravity.TOP or Gravity.START
                leftMargin = dp(14)
                topMargin = dp(24)
            },
        )

        editHint = TextView(this).apply {
            text = "编辑模式 · 拖动按键调整位置，点悬浮球完成"
            textSize = 12f
            setTextColor(0xF2FFFFFF.toInt())
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(7), dp(14), dp(7))
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(0xCC141417.toInt())
                setStroke(dp(1), 0x33FFFFFF)
            }
            visibility = View.GONE
            isClickable = false
            isFocusable = false
        }
        root.addView(
            editHint,
            FrameLayout.LayoutParams(-2, -2).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(16)
            },
        )

        menuBall = MenuBallView(this).apply {
            locked = GameMenuPrefs.locked(this@GameActivity)
            onTap = { openMenu() }
            // 首帧出来之前不显示，加载层收起时再亮出来。
            visibility = View.INVISIBLE
        }
        root.addView(
            menuBall,
            FrameLayout.LayoutParams(dp(46), dp(46)),
        )

        overlayHost = ComposeOverlayHost(this, root, textureView)

        hardwareInput = GameHardwareInput(
            applicationContext,
            surface = { if (::textureView.isInitialized) textureView else null },
            gameSize = { gameWidth to gameHeight },
            grabbed = { FclRuntime.cursorGrabbed },
        )
        physicalInput = PhysicalInputWatcher(this) { _, _ ->
            applyOsdVisibility()
        }.also { it.start() }

        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
            if (r - l != or - ol || b - t != ob - ot) {
                applyGameBounds()
                menuBall.restorePosition()
            }
        }

        setContentView(root)
        // decorView 在 setContentView 之后才保证存在。
        hideSystemUi()
        loadingOverlay = GameLoadingOverlay(this).also {
            it.show(
                versionName,
                intent.getStringExtra("bootAnimationDir").orEmpty(),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // manifest 开了 enableOnBackInvokedCallback：API 33+ 返回键走
            // dispatcher，不会再回调 onBackPressed。
            val callback = OnBackInvokedCallback { handleBack() }
            backCallback = callback
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                callback,
            )
        }

        try {
            gameStartAt = SystemClock.elapsedRealtime()
            // 远古版只认 GL4ES：VirGL/Zink 在 AWT + LWJGL2 上会只清出灰屏
            // （实测 a1.0.15：VirGL 灰屏 100fps，GL4ES 直接出主菜单）。
            val effectiveRenderer = if (legacyAwt) "gl4es" else renderer
            bridge = FclRuntime.launch(
                applicationContext, args, workingDir, logDir, javaHome,
                effectiveRenderer, lwjglVersion, javaMajor,
            )
            textureView.post {
                applyGameBounds()
                menuBall.restorePosition()
                startIfReady(gameSurface)
            }
            handler.post(loadingTick)
        } catch (t: Throwable) {
            Log.e(TAG, "启动 JVM 失败", t)
            reportCrash(
                title = "启动失败",
                summary = t.message ?: t.javaClass.simpleName,
                detail = "JVM / FCL 运行时没有成功启动。下面是异常堆栈：\n$t",
                exitCode = -1,
            )
        }
        gyroscope = GameGyroscope(
            applicationContext,
            tweaksProvider = { tweaks },
            isCaptured = { FclRuntime.cursorGrabbed },
        ).also { if (tweaks.enableGyroscope) it.start() }
        inputView.setLookSensitivity(tweaks.lookSensitivity)
        handler.post(fpsTick)
    }

    /**
     * SDL（RenderPearl，26.3+）建窗口时会按窗口宽高请求方向
     * （SDLActivity.setOrientation：宽<高 → sensorPortrait，直接调
     * `activity.setRequestedOrientation`）。Activity 一旦被转成竖屏，Surface、
     * SDL 窗口、游戏渲染全部跟着竖排 —— 这就是 26.3「画面竖躺拉伸」的根因。
     * FCL 的 JVMActivity 同款兜底：无论 SDL 请求什么都锁横屏（跟随传感器），
     * 保证游戏画面方向恒定，几何一致性由 [applyDisplay] 的固定缓冲维持。
     */
    override fun setRequestedOrientation(requestedOrientation: Int) {
        super.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE)
    }

    private fun rendererLabel(id: String): String = when (id) {
        "gl4es" -> "Holy GL4ES"
        "nggl4es" -> "NG GL4ES"
        "virgl" -> "VirGL"
        "vgpu" -> "VGPU"
        "zink" -> "Zink"
        "freedreno" -> "Freedreno"
        else -> id
    }

    // ───────────────────────── 画面比例 ─────────────────────────

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    /** 横屏屏幕宽高比。resources 的宽高会随方向互换，用 max/min 消除依赖。 */
    private fun screenAspect(): Float {
        val dm = resources.displayMetrics
        val long = max(dm.widthPixels, dm.heightPixels).toFloat()
        val short = min(dm.widthPixels, dm.heightPixels).coerceAtLeast(1).toFloat()
        return if (short > 0f) long / short else 16f / 9f
    }

    /** 屏幕原生高度（横屏短边）：渲染精度 100% 的基准。 */
    private fun screenHeightPx(): Int {
        val dm = resources.displayMetrics
        return min(dm.widthPixels, dm.heightPixels).coerceAtLeast(240)
    }

    /**
     * 按**窗口大小 × 渲染缓冲比例**排 TextureView：
     *  1. 先在屏幕上取出「窗口」矩形（屏幕宽高各乘 [GameDisplaySettings.windowWidth] /
     *     [GameDisplaySettings.windowHeight]），游戏画面只占这一块，剩下的都是黑边；
     *  2. 缓冲已经按渲染分辨率生成（setDefaultBufferSize），在这块矩形里
     *     **等比**塞进去，所以任何模式下合成器都只做等比缩放，画面不变形。
     *
     * 只改布局参数，不动渲染 buffer —— 拖动窗口即时生效，不会丢 GL 上下文。
     */
    private fun applyGameBounds() {
        if (!::root.isInitialized || !::textureView.isInitialized) return
        val screenW = root.width
        val screenH = root.height
        if (screenW <= 0 || screenH <= 0) return
        val boxW = (screenW * displaySettings.windowWidth).toInt().coerceAtLeast(1)
        val boxH = (screenH * displaySettings.windowHeight).toInt().coerceAtLeast(1)
        val aspect = gameWidth.toFloat() / gameHeight.coerceAtLeast(1)
        val targetW = min(boxW, (boxH * aspect).toInt()).coerceAtLeast(1)
        val targetH = (targetW / aspect).toInt().coerceAtLeast(1)
        val current = textureView.layoutParams
        if (current.width == targetW && current.height == targetH) return
        textureView.layoutParams = FrameLayout.LayoutParams(
            targetW, targetH, Gravity.CENTER,
        )
        inputView.layoutParams = FrameLayout.LayoutParams(
            targetW, targetH, Gravity.CENTER,
        )
    }

    // ───────────────────────── 体验微调（灵敏度/陀螺仪/内存叠层/高刷） ─────────────────────────

    /**
     * 重读体验微调设置并应用到各处。启动器改设置（tweaks.set）或游戏内菜单
     * 改设置后都走这里，保证两个入口改完立刻生效。
     */
    private fun applyTweaks(next: GameTweaksSettings) {
        val old = tweaks
        tweaks = next
        memLabel.visibility = if (next.showMemory) View.VISIBLE else View.GONE
        inputView.setLookSensitivity(next.lookSensitivity)
        // 开关本身的变化也要立刻反映到按键层（关掉「自动隐藏」应马上放回）。
        applyOsdVisibility()
        val g = gyroscope ?: return
        when {
            next.enableGyroscope && !old.enableGyroscope -> g.start()
            !next.enableGyroscope && old.enableGyroscope -> g.stop()
        }
    }

    /**
     * 目标刷新率 = 当前模式 + 它的 `alternativeRefreshRates` 里最高的一档。
     *
     * **不能**直接挑设备支持的最高档（这台机器是 144Hz）：120 → 144 不是无缝
     * 倍率，SurfaceFlinger 要做整屏 modeset（画面黑一下），而系统又会按内容把
     * 模式调回 120 —— 两边每秒抢一次，游戏里就是「动一下就卡一下」。
     * 只在同一无缝组内提档：60Hz 可无缝升到 120Hz，120Hz 就停在 120Hz；
     * 系统本来就在 144Hz 时才保留 144。
     */
    private fun targetRefreshRate(display: Display): Float {
        val current = display.mode
        var target = current.refreshRate
        for (rate in current.alternativeRefreshRates) {
            if (rate <= target + 0.1f) continue
            val supported = display.supportedModes.any {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight &&
                    abs(it.refreshRate - rate) < 0.1f
            }
            if (supported) target = rate
        }
        return target
    }

    private fun targetRefreshMode(display: Display, rate: Float): Display.Mode? {
        val current = display.mode
        return display.supportedModes.firstOrNull {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight &&
                abs(it.refreshRate - rate) < 0.1f
        }
    }

    /**
     * 高刷请求（FCL JVMActivity.applyMaxRefreshRatePolicy 思路）：
     * 避免高刷屏被系统限制在 60Hz 自适应档。只换同分辨率、且在当前模式
     * 无缝档位里的模式，不在 120/144 之间反复 modeset。
     *
     * 除了窗口级 preferredDisplayModeId，还要在 Surface 上投票
     * （CHANGE_FRAME_RATE_ALWAYS）：部分 ROM 只认 surface 级请求，缺了它
     * 游戏会被按「非游戏应用」压到低帧率档。
     */
    private fun applyMaxRefreshRatePolicy() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val display: Display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display ?: return
        } else {
            @Suppress("DEPRECATION")
            (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay ?: return
        }
        if (!tweaks.requestMaxRefreshRate) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = 0 }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                gameSurface != null
            ) {
                runCatching {
                    gameSurface?.setFrameRate(
                        0f,
                        Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                    )
                }
            }
            return
        }
        val targetRate = targetRefreshRate(display)
        if (targetRate > display.mode.refreshRate + 0.1f) {
            val target = targetRefreshMode(display, targetRate)
            if (target != null && target.modeId != display.mode.modeId) {
                Log.i(
                    TAG,
                    "刷新率 ${display.mode.refreshRate} → ${targetRate} Hz（无缝档）",
                )
                window.attributes = window.attributes.apply {
                    preferredDisplayModeId = target.modeId
                }
            }
        }
        voteSurfaceRefreshRate(targetRate)
    }

    /** Surface 级高刷投票（FCL `voteMaxDisplayRefreshRate` 对应物）。 */
    private fun voteSurfaceRefreshRate(refreshRate: Float) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (!tweaks.requestMaxRefreshRate || refreshRate <= 0f) return
        val s = gameSurface ?: return
        if (!s.isValid) return
        runCatching {
            s.setFrameRate(
                refreshRate,
                Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                Surface.CHANGE_FRAME_RATE_ALWAYS,
            )
        }.onFailure { Log.w(TAG, "surface.setFrameRate($refreshRate) 失败", it) }
    }

    /**
     * 系统中途降档（智能刷新率 / 省电策略）后重新发起请求。
     * 只在**当前模式还能无缝提档**时才重发（60 → 120）；120 不会去抢 144，
     * 避免和系统的自适应策略互相打架。5 秒冷却，防止 ROM 回调把窗口刷爆。
     */
    private val displayListener = object : DisplayManager.DisplayListener {
        private var lastRequestAt = 0L

        override fun onDisplayAdded(displayId: Int) {}

        override fun onDisplayRemoved(displayId: Int) {}

        override fun onDisplayChanged(displayId: Int) {
            if (!tweaks.requestMaxRefreshRate) return
            if (SystemClock.uptimeMillis() - lastRequestAt < 5_000L) return
            val d = (getSystemService(DISPLAY_SERVICE) as? DisplayManager)
                ?.getDisplay(displayId) ?: return
            if (d.mode.refreshRate >= targetRefreshRate(d) - 0.1f) return
            lastRequestAt = SystemClock.uptimeMillis()
            applyMaxRefreshRatePolicy()
        }
    }

    private fun registerTweaksReceiver() {
        val filter = IntentFilter(ACTION_TWEAKS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(tweaksReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(tweaksReceiver, filter)
        }
    }

    // ───────────────────────── 游戏内菜单 ─────────────────────────

    private fun openMenu() {
        if (crashShown || overlayHost.visible || !loadingDone) {
            InputDebug.log(
                "openMenu 被拒绝 crash=$crashShown overlay=${overlayHost.visible} loadingDone=$loadingDone",
            )
            return
        }
        InputDebug.log("打开游戏内菜单")
        inputView.resetInput()
        // FCL 打开菜单时会把虚拟按键层收起，避免按键压在面板上。
        inputView.visibility = View.INVISIBLE
        menuBall.visibility = View.INVISIBLE
        val state = GameMenuState(
            versionLabel = versionName.ifEmpty { "Minecraft" },
            rendererLabel = rendererName,
            editMode = inputView.editMode,
            showFps = showFps,
            buttonScale = ControlLayout.scale,
            buttonAlpha = ControlLayout.alpha,
            ballLocked = menuBall.locked,
            display = displaySettings,
            tweaks = tweaks,
            gyroscopeAvailable = gyroscope?.isAvailable() ?: false,
            externalInputAttached = physicalInput?.hasAny ?: false,
            renderWidth = gameWidth,
            renderHeight = gameHeight,
            screenAspect = screenAspect(),
            screenWidthPx = root.width,
            screenHeightPx = root.height,
            initialCustomKeys = inputView.customButtons().map {
                CustomKeyInfo(it.id, it.label, it.keys.toList())
            },
        )
        state.onEditMode = { on ->
            inputView.editMode = on
            editHint.visibility = if (on) View.VISIBLE else View.GONE
            if (on) {
                // 面板会挡住拖动，开启编辑就收起；点悬浮球能回来关。
                root.postDelayed({
                    closeMenu()
                }, 140L)
            }
        }
        state.onShowFps = { on ->
            showFps = on
            fpsLabel.visibility = if (on) View.VISIBLE else View.GONE
            if (on) {
                resetFpsWindow()
                updateFps()
            }
        }
        state.onButtonScale = { value, finished ->
            ControlLayout.scale = value
            inputView.refreshAppearance()
            if (finished) {
                ControlLayout.saveAppearance(this, ControlLayout.scale, ControlLayout.alpha)
            }
        }
        state.onButtonAlpha = { value, finished ->
            ControlLayout.alpha = value
            inputView.refreshAppearance()
            if (finished) {
                ControlLayout.saveAppearance(this, ControlLayout.scale, ControlLayout.alpha)
            }
        }
        state.onBallLocked = { locked ->
            menuBall.locked = locked
            GameMenuPrefs.setLocked(this, locked)
        }
        state.onResetControls = {
            inputView.resetToDefault()
            inputView.editMode = false
            editHint.visibility = View.GONE
        }
        state.onAddCustomKey = { label, keys ->
            inputView.addCustomButton(label, keys)?.let { button ->
                state.customKeys.add(
                    CustomKeyInfo(button.id, button.label, button.keys.toList()),
                )
            }
        }
        state.onUpdateCustomKey = { id, label, keys ->
            if (inputView.updateCustomButton(id, label, keys)) {
                val index = state.customKeys.indexOfFirst { it.id == id }
                if (index >= 0) {
                    state.customKeys[index] = CustomKeyInfo(id, label, keys)
                }
            }
        }
        state.onDeleteCustomKey = { id ->
            inputView.removeCustomButton(id)
            state.customKeys.removeAll { it.id == id }
        }
        state.onTestKeys = { keys -> inputView.tapKeys(keys) }
        state.onDisplay = { next, persist ->
            // persist=false = 用户还在拖：先只重排矩形，别每帧换 GL 缓冲。
            if (persist) GameDisplaySettings.save(this, next)
            applyDisplay(next, commitResolution = persist)
        }
        state.onTweaks = { next, persist ->
            if (persist) GameTweaksSettings.save(this, next)
            applyTweaks(next)
        }
        state.onBackToLauncher = {
            closeMenu()
            backToLauncher()
        }
        state.onQuit = {
            // 主动退出：先告诉启动器「正常结束」，避免它把这次 kill 当成崩溃。
            notifyLauncherExit(abnormal = false)
            android.os.Process.killProcess(android.os.Process.myPid())
        }
        state.onSendText = { text ->
            closeMenu()
            // 整串逐字符发送（FCL TouchCharInput 简化版），末尾回车确认。
            // 字符间留几毫秒，避免太快被输入队列丢帧。
            Thread {
                for (ch in text) {
                    FclRuntime.sendChar(applicationContext, ch)
                    Thread.sleep(6)
                }
                FclRuntime.sendKey(applicationContext, KEY_ENTER, true)
                FclRuntime.sendKey(applicationContext, KEY_ENTER, false)
            }.start()
        }
        state.onClose = { closeMenu() }
        menuState = state
        overlayHost.show { GameMenuOverlay(state) }
    }

    private fun closeMenu() {
        overlayHost.dismiss()
        menuState = null
        if (::menuBall.isInitialized) menuBall.visibility = View.VISIBLE
        // 菜单打开时整层被收起了，这里先放回来，再由 OSD 规则决定画不画按键
        // （接了键鼠就只放层、不画按钮）。
        if (::inputView.isInitialized && loadingDone) {
            inputView.visibility = View.VISIBLE
        }
        applyOsdVisibility()
    }

    /** 丢弃首帧检测/暂停期间攒下的计数，从当前时刻重新开窗。 */
    private fun resetFpsWindow() {
        lastFpsSampleAt = SystemClock.elapsedRealtime()
        lastFps = 0
        runCatching { FclRuntime.getFps(bridge) }
    }

    private fun updateFps() {
        val now = SystemClock.elapsedRealtime()
        val frames = FclRuntime.getFps(bridge)
        val elapsed = now - lastFpsSampleAt
        if (lastFpsSampleAt > 0 && elapsed in 100..5_000) {
            lastFps = ((frames * 1000.0) / elapsed).roundToInt()
            // 个位数帧只可能是整段渲染停了（GC / 系统调度 / 服务端卡死），
            // 留一条日志方便和 logcat、游戏日志对齐时间点。
            if (showFps && lastFps in 1..9) {
                Log.w(TAG, "FPS 掉到 ${lastFps}：frames=$frames elapsed=${elapsed}ms")
            }
        }
        lastFpsSampleAt = now
        if (showFps) {
            fpsLabel.text = if (lastFps > 0) "FPS $lastFps" else "FPS --"
        }
        if (tweaks.showMemory) {
            // FCL showMemory 同思路：JVM 堆的已用 / 已分配，谷值说明 GC 状态健康。
            val runtime = Runtime.getRuntime()
            val used = (runtime.totalMemory() - runtime.freeMemory()) shr 20
            val total = runtime.totalMemory() shr 20
            memLabel.text = "MEM ${used}M / ${total}M"
        }
    }

    /** 首帧已出现（或兜底超时）：收起加载层，亮出悬浮球与 FPS。 */
    private fun finishLoading() {
        if (loadingDone) return
        loadingDone = true
        handler.removeCallbacks(loadingTick)
        resetFpsWindow()
        loadingOverlay?.dismiss()
        loadingOverlay = null
        if (::menuBall.isInitialized) menuBall.visibility = View.VISIBLE
        // 首帧出来才决定按键层要不要显示（外接键鼠时直接不放出来）。
        applyOsdVisibility()
        Log.i(TAG, "首帧已渲染，收起加载层")
    }

    // ───────────────────────── 崩溃日志 / 弹窗 ─────────────────────────

    private var crashFilePath = ""
    private var crashExitCode = 0
    private var flushScheduled = false
    private val flushRuntimeLog = Runnable {
        flushScheduled = false
        val text = logSnapshot()
        if (text.isBlank()) return@Runnable
        Thread {
            try {
                val dir = File(workingDirPath, "logs").apply { mkdirs() }
                File(dir, "mint-runtime.log").writeText(text)
            } catch (_: Throwable) {
            }
        }.start()
    }

    private fun appendRuntimeLog(chunk: String) {
        if (chunk.isEmpty()) return
        synchronized(runtimeLog) {
            for (line in chunk.split('\n')) {
                runtimeLog.addLast(line)
            }
            while (runtimeLog.size > 900) runtimeLog.removeFirst()
        }
        // 外部目录镜像：真机 logcat 会被系统吞掉，排查远古版 / AWT 渲染
        // 只能靠这份文件（launcher 内部目录 adb 进不去）。
        runCatching {
            getExternalFilesDir(null)?.let { base ->
                File(base, "logs").mkdirs()
                File(base, "logs/mint-runtime.log").appendText(chunk)
            }
        }
        // 硬崩溃（JVM abort / SIGSEGV）来不及走 onExit，这里定期把最后
        // 900 行落盘；启动器下次对状态时能据此识别崩溃并弹日志。
        if (!flushScheduled) {
            flushScheduled = true
            handler.postDelayed(flushRuntimeLog, 1200)
        }
    }

    private fun logSnapshot(): String = synchronized(runtimeLog) {
        runtimeLog.joinToString("\n")
    }

    private fun latestCrashReport(): Pair<String, String>? {
        val dir = File(workingDirPath, "crash-reports")
        val file = dir.listFiles { f -> f.isFile && f.name.endsWith(".txt") }
            ?.maxByOrNull { it.lastModified() } ?: return null
        val text = readTail(file, 160_000) ?: return null
        return "crash-reports/${file.name}" to text
    }

    private fun readTail(file: File, maxBytes: Int): String? {
        return try {
            if (!file.isFile) return null
            val len = file.length()
            val start = max(0L, len - maxBytes)
            java.io.RandomAccessFile(file, "r").use { raf ->
                raf.seek(start)
                val bytes = ByteArray((len - start).toInt())
                raf.readFully(bytes)
                bytes.toString(Charsets.UTF_8)
            }
        } catch (_: Throwable) {
            null
        }
    }

    /** 拼出给用户看的完整日志：运行时输出 + 游戏 latest.log + crash-reports。 */
    private fun buildCrashLog(extra: String): String {
        val parts = mutableListOf<String>()
        val runtime = logSnapshot()
        if (runtime.isNotBlank()) parts += runtime
        val latest = readTail(File(workingDirPath, "logs/latest.log"), 200_000)
        if (!latest.isNullOrBlank() &&
            (runtime.isBlank() || !runtime.contains(latest.trimEnd().takeLast(400)))
        ) {
            parts += "\n===== logs/latest.log =====\n$latest"
        }
        latestCrashReport()?.let { (name, text) ->
            parts += "\n===== $name =====\n$text"
        }
        if (extra.isNotBlank()) parts += "\n===== 启动器附加信息 =====\n$extra"
        val joined = parts.joinToString("\n")
        return if (joined.length > 240_000) joined.takeLast(240_000) else joined
    }

    private fun detectCrashSummary(log: String, code: Int): String {
        if (log.contains("X11GraphicsEnvironment") ||
            log.contains("No X11 DISPLAY") ||
            log.contains("java.awt.HeadlessException")
        ) {
            return "远古版需要 AWT 桌面窗口；当前 Android 运行时没有 X11 图形环境，" +
                "alpha / beta / 1.5.2 及以下版本暂时启动不了"
        }
        for (marker in CRASH_MARKERS) {
            val idx = log.indexOf(marker, ignoreCase = true)
            if (idx < 0) continue
            val line = log.substring(
                log.lastIndexOf('\n', idx).let { if (it < 0) 0 else it + 1 },
            ).lineSequence().firstOrNull().orEmpty().trim()
            if (line.isNotEmpty()) {
                return if (line.length > 220) line.take(220) + "…" else line
            }
        }
        return "游戏进程异常退出（exitCode=$code）"
    }

    /** JVM 正常退出还是崩溃，全在这里分流。 */
    private fun handleGameExit(code: Int) {
        if (exitBroadcastSent || crashShown) return
        val log = logSnapshot()
        val crashed = code != 0 ||
            CRASH_MARKERS.any { log.contains(it, ignoreCase = true) }
        if (!crashed) {
            Log.i(TAG, "JVM 正常退出（exitCode=$code）")
            notifyLauncherExit(abnormal = false)
            finish()
            return
        }
        crashExitCode = code
        reportCrash(
            title = "游戏崩溃",
            summary = detectCrashSummary(log, code),
            detail = "游戏进程已退出（exitCode=$code）。" +
                "完整日志已保存到游戏目录 logs/ 下，也可以直接复制下面的内容发出去。",
            exitCode = code,
        )
    }

    private fun reportCrash(
        title: String,
        summary: String,
        detail: String,
        exitCode: Int,
    ) {
        if (crashShown) return
        crashShown = true
        crashExitCode = exitCode
        crashSummary = summary
        crashDetail = detail
        val log = buildCrashLog("exitCode=$exitCode，版本=$versionName，渲染器=$rendererName")
        crashTail = if (log.length > 16_000) log.takeLast(16_000) else log
        crashFilePath = writeCrashFile(title, summary, detail, log)
        Log.e(TAG, "$title：$summary（exitCode=$exitCode，日志 $crashFilePath）")

        // 收起加载层 / 按键层，避免盖住崩溃页。
        loadingDone = true
        handler.removeCallbacks(loadingTick)
        loadingOverlay?.dismiss()
        loadingOverlay = null
        if (::overlayHost.isInitialized && overlayHost.visible) closeMenu()
        if (::inputView.isInitialized) {
            inputView.resetInput()
            inputView.visibility = View.INVISIBLE
        }
        if (::menuBall.isInitialized) menuBall.visibility = View.INVISIBLE

        val overlay = crashOverlay ?: GameCrashOverlay(
            this,
            onBackToLauncher = {
                notifyLauncherExit(abnormal = true)
                backToLauncher()
                finish()
            },
            onExit = {
                notifyLauncherExit(abnormal = true)
                android.os.Process.killProcess(android.os.Process.myPid())
            },
        ).also { crashOverlay = it }
        overlay.show(
            title = title,
            versionLabel = versionName.ifEmpty { "Minecraft" },
            summary = summary,
            detail = detail,
            log = log,
        )
    }

    private fun writeCrashFile(
        title: String,
        summary: String,
        detail: String,
        log: String,
    ): String {
        return try {
            val dir = File(workingDirPath, "logs")
            dir.mkdirs()
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
            val path = File(dir, "mint-crash-$stamp.txt")
            path.writeText(
                buildString {
                    append("Mint Launcher 崩溃报告\n")
                    append("时间：${Date()}\n")
                    append("版本：$versionName\n")
                    append("渲染器：$rendererName\n")
                    append("$title：$summary\n")
                    append("$detail\n\n")
                    append(log)
                },
            )
            path.absolutePath
        } catch (t: Throwable) {
            Log.w(TAG, "写崩溃报告失败", t)
            ""
        }
    }

    /** 通知启动器游戏已退出；崩溃时把日志一起带回去（Dart 侧弹窗 / 写日志页）。 */
    private fun notifyLauncherExit(abnormal: Boolean) {
        if (exitBroadcastSent) return
        exitBroadcastSent = true
        try {
            val intent = Intent(ACTION_EXIT).setPackage(packageName)
            if (abnormal) {
                intent.putExtra("abnormal", true)
                intent.putExtra("exitCode", crashExitCode)
                intent.putExtra("message", crashSummary)
                intent.putExtra("logPath", crashFilePath)
                intent.putExtra("logTail", crashTail)
                intent.putExtra("version", versionName)
                intent.putExtra("dialogShown", crashShown)
            }
            sendBroadcast(intent)
        } catch (t: Throwable) {
            Log.w(TAG, "发送退出广播失败", t)
        }
    }

    // ───────────────────────── 生命周期 ─────────────────────────

    private fun writePid() {
        try {
            pidFile(this).writeText(android.os.Process.myPid().toString())
        } catch (t: Throwable) {
            Log.w(TAG, "写 pid 文件失败", t)
        }
    }

    private fun registerStopReceiver() {
        val filter = IntentFilter(ACTION_STOP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stopReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(stopReceiver, filter)
        }
    }

    private fun registerDisplayReceiver() {
        val filter = IntentFilter(ACTION_DISPLAY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(displayReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(displayReceiver, filter)
        }
    }

    private fun hideSystemUi() {
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

    private fun startIfReady(surface: Surface?) {
        val b = bridge ?: return
        val s = surface ?: return
        if (!s.isValid) return
        if (started) {
            setSurfaceDestroyed(false)
            // 这是**重建出来的** surface（切后台回来）：必须重绑 native 窗口
            // 并强制游戏重画，否则画面永久黑着（详见 restoreAfterSurfaceRecreate）。
            restoreAfterSurfaceRecreate(s)
            return
        }
        started = true
        try {
            inputView.setGameSize(gameWidth, gameHeight)
            if (sdl3) {
                Log.i(
                    TAG,
                    "SDL surface view=${textureView.width}x${textureView.height} " +
                        "buffer=${gameWidth}x$gameHeight",
                )
                // 必须先注册 SDL Surface 再 execute（FCL JVMActivity 同顺序）。
                FclRuntime.prepareSdlSurface(this, s, root)
                FclRuntime.forceSyncSdlResolution(gameWidth, gameHeight)
            }
            FclRuntime.execute(
                applicationContext, this, b, s, gameWidth, gameHeight,
                useInputStackQueue, surfaceTexture,
            )
            if (sdl3) {
                FclRuntime.syncSdlResolution(gameWidth, gameHeight)
                scheduleSdlResolutionSync()
            }
            // onResume 可能早于 FCL dex 加载；JVM 起来后再补一次焦点状态。
            val focused = if (hasWindowFocus()) 1 else 0
            FclRuntime.setWindowAttrib(GLFW_FOCUSED, focused)
            FclRuntime.setWindowAttrib(GLFW_HOVERED, focused)
            (getSystemService(DISPLAY_SERVICE) as? DisplayManager)?.let { dm ->
                dm.getDisplay(Display.DEFAULT_DISPLAY)?.let {
                    voteSurfaceRefreshRate(targetRefreshRate(it))
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "JVM 启动失败", t)
            reportCrash(
                title = "启动失败",
                summary = t.message ?: t.javaClass.simpleName,
                detail = "游戏窗口已创建，但 JVM 执行失败。下面是异常堆栈：\n$t",
                exitCode = -1,
            )
        }
    }

    private fun setSurfaceDestroyed(destroyed: Boolean) {
        val b = bridge ?: return
        try {
            b.javaClass
                .getMethod("setSurfaceDestroyed", Boolean::class.javaPrimitiveType)
                .invoke(b, destroyed)
        } catch (t: Throwable) {
            Log.w(TAG, "标记 surface 状态失败", t)
        }
    }

    // ───────────────────────── TextureView 生命周期 ─────────────────────────

    /**
     * SurfaceTexture 就绪：把缓冲设成渲染分辨率、包一层 Surface 交给
     * [startIfReady]。SurfaceTexture 在 Activity 进后台 / 视图重挂时会被销毁
     * 重造，重建后走 [restoreAfterSurfaceRecreate] 重绑 native 窗口。
     */
    override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
        surfaceTexture = st
        st.setDefaultBufferSize(gameWidth, gameHeight)
        val surface = Surface(st)
        gameSurface = surface
        startIfReady(surface)
    }

    /** 视图尺寸变化（拖角标 / 分屏）：缓冲跟渲染分辨率走，几何由各链路重发。 */
    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {
        surfaceTexture = st
        st.setDefaultBufferSize(gameWidth, gameHeight)
        if (started) {
            if (sdl3) FclRuntime.syncSdlResolution(gameWidth, gameHeight)
            FclRuntime.updateWindowSize(
                applicationContext, bridge, gameWidth, gameHeight,
            )
        }
    }

    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
        setSurfaceDestroyed(true)
        if (sdl3) FclRuntime.destroySdlSurface()
        FclRuntime.beginSurfaceDestroy(applicationContext, gameSurface)
        if (::hardwareInput.isInitialized) hardwareInput.reset()
        gameSurface = null
        surfaceTexture = null
        // true = 允许销毁 SurfaceTexture，回来时 onSurfaceTextureAvailable 重建。
        return true
    }

    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {
        // 首帧检测走 FCL 的 FPS 计数器（[loadingTick]），这里无需处理。
    }

    /**
     * 切后台回来：把重建的 surface 重新交给 native，并逼游戏重画一帧。
     *
     * 安卓在 Activity 进后台时会回收 SurfaceView 的 surface，回前台给的是**新
     * 的** ANativeWindow。native 侧若仍指向旧窗口，`eglSwapBuffers` 会一路
     * `EGL_BAD_NATIVE_WINDOW`、EGL 上下文随之丢失 —— 表现就是「游戏还在跑、
     * 声音还在、画面全黑」。所以这里除了恢复渲染标记，还必须：
     *  1. 重新绑定桥接窗口 / 重新注册 SDL surface；
     *  2. 补发屏幕尺寸 + GLFW window/framebuffer 事件，把 Minecraft 从
     *     「窗口不可见」的分支里拽回来重绘。
     *
     * 全部走反射 + 容错：FCL 某个版本没有对应入口时只是少一步，不会把原本
     * 能跑的链路搞坏。
     */
    private fun scheduleSdlResolutionSync() {
        sdlSyncHandler.removeCallbacksAndMessages(null)
        sdlSyncAttempts = 0
        val poll = object : Runnable {
            override fun run() {
                if (!started || isFinishing || isDestroyed) return
                // 每次轮询都先强制同步 geometry，SDL 通知到达前窗口也不会拿竖屏尺寸。
                FclRuntime.forceSyncSdlResolution(gameWidth, gameHeight)
                if (FclRuntime.isSdlEnabled()) {
                    FclRuntime.syncSdlResolution(gameWidth, gameHeight)
                    // 游戏主窗口创建后 SDL 可能再按旧尺寸重置一次，补一刀。
                    sdlSyncHandler.postDelayed({
                        if (started && !isFinishing && !isDestroyed) {
                            FclRuntime.syncSdlResolution(gameWidth, gameHeight)
                        }
                    }, 1500L)
                    return
                }
                if (sdlSyncAttempts++ < 120) {
                    sdlSyncHandler.postDelayed(this, 250L)
                }
            }
        }
        sdlSyncHandler.postDelayed(poll, 250L)
    }

    private fun restoreAfterSurfaceRecreate(surface: Surface?) {
        if (!::root.isInitialized || surface == null) return
        if (sdl3) {
            Log.i(TAG, "SDL 重建 surface，buffer=${gameWidth}x$gameHeight")
            FclRuntime.prepareSdlSurface(this, surface, root)
            FclRuntime.forceSyncSdlResolution(gameWidth, gameHeight)
            FclRuntime.syncSdlResolution(gameWidth, gameHeight)
        }
        val rebound = FclRuntime.rebindSurface(applicationContext, this, root, surface)
        // 重绑后稍等一帧再发尺寸事件：native 换窗口是异步的，同一帧内既换
        // window 又改尺寸，部分渲染器会直接把 context 判废。
        val refresh = Runnable {
            FclRuntime.forceRefresh(applicationContext, bridge, gameWidth, gameHeight)
        }
        if (rebound) textureView.postDelayed(refresh, 60L) else textureView.post(refresh)
        Log.i(TAG, "surface 已重建：${gameWidth}x$gameHeight 重绑窗口并强制刷新")
    }

    /**
     * 触摸按键（OSD）的显隐。
     *
     * 外接键鼠在线时收起按键：外设有自己的按键和指针，虚拟按钮只挡画面。
     * 收的只是**绘制**（[GameInputView.controlsVisible]），这层视图照旧接收
     * 触摸并当触摸板用，所以接了键盘也能用手指操作菜单。
     *
     * 断开外设、关掉开关或菜单收起后恢复。菜单打开期间保持隐藏（那是菜单
     * 自己收的，不能被这里放回来）。
     */
    private fun applyOsdVisibility() {
        if (!::inputView.isInitialized || !loadingDone || crashShown) return
        if (::overlayHost.isInitialized && overlayHost.visible) return
        val hide = tweaks.autoHideControlsOnPhysicalInput &&
            (physicalInput?.hasAny == true)
        if (inputView.controlsVisible == !hide) return
        inputView.controlsVisible = !hide
        if (hide) inputView.resetInput()
        InputDebug.log(
            if (hide) "检测到外接键鼠，收起触摸按键（物理键鼠在线）" else "恢复触摸按键",
        )
    }

    /**
     * 回到启动器，游戏留在后台继续跑。
     *
     * 用 ACTION_MAIN + CATEGORY_LAUNCHER 交给系统恢复已有的启动器 task：
     * NEW_TASK 裸启动 MainActivity 会按 affinity 落进游戏自己的 task。
     */
    private fun backToLauncher() {
        try {
            startActivity(
                Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .setClassName(packageName, MainActivity::class.java.name)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
                    ),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "回启动器失败", t)
            moveTaskToBack(true)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        handleBack()
    }

    private fun handleBack() {
        // 崩溃页必须走它自己的按钮（返回启动器 / 退出），避免误触把日志弄丢。
        if (crashShown) return
        val state = menuState
        if (overlayHost.visible && state != null) {
            if (state.screen != GameMenuScreen.MENU) {
                state.screen = GameMenuScreen.MENU
            } else {
                closeMenu()
            }
            return
        }
        // 还没进游戏（加载页）时返回键仍用于脱身，避免卡在加载页。
        if (!loadingDone) {
            backToLauncher()
            return
        }
        // 进游戏后返回键默认映射为 ESC（FCL 同款）：菜单 / 背包 / 聊天都靠它，
        // 不会误把游戏切到后台。回启动器走悬浮球菜单里的入口。
        sendEscape()
    }

    /** 发一次 ESC 按下 + 松开（FCL `dispatchKeyEvent` 的 KEYCODE_BACK 分支）。 */
    private fun sendEscape() {
        FclRuntime.sendKey(applicationContext, GLFW_KEY_ESCAPE, true)
        handler.postDelayed(
            { FclRuntime.sendKey(applicationContext, GLFW_KEY_ESCAPE, false) },
            60L,
        )
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        FclRuntime.setWindowAttrib(GLFW_FOCUSED, if (hasFocus) 1 else 0)
        FclRuntime.setWindowAttrib(GLFW_HOVERED, if (hasFocus) 1 else 0)
        if (hasFocus) {
            hideSystemUi()
            // 部分系统会在切后台后把刷新率降回自适应档，回前台重放一次。
            applyMaxRefreshRatePolicy()
        }
    }

    override fun onResume() {
        super.onResume()
        FclRuntime.setWindowAttrib(GLFW_FOCUSED, 1)
        FclRuntime.setWindowAttrib(GLFW_HOVERED, 1)
        if (started) {
            // 回前台补一次强制刷新：surface 可能还没重建（此时这里是空转，
            // 真正的重绑在 surfaceCreated 里做），也可能已经重建但 Minecraft
            // 仍停在「窗口不可见」分支不渲染。两帧后再发一次更稳。
            textureView.postDelayed({
                if (started) {
                    FclRuntime.forceRefresh(applicationContext, bridge, gameWidth, gameHeight)
                }
            }, 120L)
        }
        applyOsdVisibility()
    }

    override fun onPause() {
        if (::inputView.isInitialized) inputView.resetInput()
        if (::hardwareInput.isInitialized) hardwareInput.reset()
        FclRuntime.setWindowAttrib(GLFW_FOCUSED, 0)
        FclRuntime.setWindowAttrib(GLFW_HOVERED, 0)
        FclRuntime.resetNativeInput(applicationContext)
        super.onPause()
    }

    // ───────────────────────── 物理键鼠 ─────────────────────────

    /**
     * 游戏内浮层（菜单 / 崩溃页）打开时，键鼠交给 Compose 自己处理：
     * 这时候玩家要点按钮、要在输入框里打字，不该被游戏吃掉。
     */
    private fun hardwareInputEnabled(): Boolean {
        if (!::hardwareInput.isInitialized || !loadingDone || crashShown) return false
        return !(::overlayHost.isInitialized && overlayHost.visible)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (hardwareInputEnabled() && hardwareInput.onKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (hardwareInputEnabled() && hardwareInput.onGenericMotion(event)) return true
        return super.dispatchGenericMotionEvent(event)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (hardwareInputEnabled() && hardwareInput.onTouch(event)) {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                InputDebug.log(
                    "触摸被物理键鼠路由器消费 source=${event.source} device=${event.deviceId}",
                )
            }
            return true
        }
        val handled = super.dispatchTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            val dev = InputDevice.getDevice(event.deviceId)
            InputDebug.log(
                "触摸下发 source=${event.source} device=${event.deviceId} " +
                    "devKeyboardType=${dev?.keyboardType} devSources=${dev?.sources} " +
                    "handled=$handled",
            )
        }
        return handled
    }

    override fun onDestroy() {
        handler.removeCallbacks(fpsTick)
        handler.removeCallbacks(loadingTick)
        sdlSyncHandler.removeCallbacksAndMessages(null)
        physicalInput?.stop()
        physicalInput = null
        gyroscope?.stop()
        gyroscope = null
        FclRuntime.onCursorModeChanged = null
        FclRuntime.onGameLog = null
        FclRuntime.onGameExit = null
        if (sdl3) FclRuntime.resetSdlBridge()
        crashOverlay?.dismiss()
        crashOverlay = null
        if (::overlayHost.isInitialized) overlayHost.dismiss()
        loadingOverlay?.dismiss()
        loadingOverlay = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                backCallback?.let {
                    onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)
                }
            } catch (_: Throwable) {
            }
        }
        try {
            unregisterReceiver(stopReceiver)
        } catch (_: Throwable) {
        }
        try {
            unregisterReceiver(displayReceiver)
        } catch (_: Throwable) {
        }
        try {
            unregisterReceiver(tweaksReceiver)
        } catch (_: Throwable) {
        }
        try {
            (getSystemService(DISPLAY_SERVICE) as? DisplayManager)
                ?.unregisterDisplayListener(displayListener)
        } catch (_: Throwable) {
        }
        if (restoreOnly) return
        pidFile(this).delete()
        notifyLauncherExit(abnormal = crashShown)
        GameKeepAliveService.stop(this)
        super.onDestroy()
    }
}
