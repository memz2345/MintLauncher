package dev.mint.mint

import android.app.LocaleManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.LocaleList
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import kotlin.math.max
import kotlin.math.min

/**
 * 启动器（Flutter 宿主）。跑在默认进程里。
 *
 * 游戏在 `:game` 独立进程（见 [GameActivity]），两边只通过广播 + pid 文件
 * 通信 —— 这样「启动器结束游戏」不会把自己一起杀掉。
 */
class MainActivity : FlutterActivity() {
    /** 启动 26.x 时临时把启动器转横屏，游戏退出后恢复自动旋转。 */
    private var forcedLandscapeForLaunch = false

    override fun onResume() {
        super.onResume()
        if (forcedLandscapeForLaunch && GameActivity.gamePid(applicationContext) <= 0) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            forcedLandscapeForLaunch = false
        }
    }

    companion object {
        private const val CHANNEL = "mint/fcl"

        @Volatile
        private var channel: MethodChannel? = null

        /**
         * SplashScreen 的 keep-on-screen 开关：Dart 侧第一帧画完前一直挂着
         * 品牌闪屏，避免「闪屏收了、Flutter 还在读设置」时露出一帧空白。
         *
         * 进程级静态：Activity 因配置变化重建时不会重新闪一次。
         */
        @Volatile
        private var splashDismissed = false

        /** 游戏进程退出（广播转过来的）；崩溃时附带 exitCode / 日志摘要。 */
        fun notifyGameExit(info: Map<String, Any?>? = null) {
            Handler(Looper.getMainLooper()).post {
                channel?.invokeMethod("onGameExit", info)
            }
        }
    }

    private val exitReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == GameActivity.ACTION_EXIT) {
                val extras = intent.extras
                val info: Map<String, Any?>? = if (extras == null) {
                    null
                } else {
                    val map = HashMap<String, Any?>()
                    if (extras.getBoolean("abnormal", false)) {
                        map["abnormal"] = true
                        map["exitCode"] = extras.getInt("exitCode", 0)
                        map["message"] = extras.getString("message").orEmpty()
                        map["logPath"] = extras.getString("logPath").orEmpty()
                        map["logTail"] = extras.getString("logTail").orEmpty()
                        map["version"] = extras.getString("version").orEmpty()
                        map["dialogShown"] = extras.getBoolean("dialogShown", false)
                    }
                    map
                }
                notifyGameExit(info)
            }
        }
    }

    private var receiverRegistered = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // 必须在 super.onCreate 之前装：FlutterActivity 会在里面创建视图并
        // 开始首帧绘制。
        val splash = installSplashScreen()
        splash.setKeepOnScreenCondition { !splashDismissed }
        // 尽早让系统创建应用专属外部目录，避免 Dart 侧先于 Channel
        // 注册时硬编码 mkdir /Android/data/<pkg> 被 scoped storage 拒绝。
        try {
            getExternalFilesDir(null)?.mkdirs()
        } catch (_: Throwable) {
        }
        super.onCreate(savedInstanceState)
        // Dart 侧异常 / 初始化卡住时的兜底：8 秒后强制收起，别把人锁在闪屏。
        Handler(Looper.getMainLooper()).postDelayed({
            splashDismissed = true
        }, 8_000L)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 某些设备/构建组合下 Flutter 的自动插件注册没有生效（实测
        // shared_preferences 报 MissingPluginException），这里显式补一次；
        // 已注册过的插件重复 add 会被 FlutterEngine 忽略/替换。
        try {
            GeneratedPluginRegistrant.registerWith(flutterEngine)
        } catch (t: Throwable) {
            android.util.Log.w("Mint", "GeneratedPluginRegistrant 手动注册失败", t)
        }
        registerExitReceiver()
        // 原生平台通道（与 local2api 同一套）：底座 tooltip / 系统 Toast /
        // Android 13+ per-app 语言。
        NativeTooltipHost.install(this, flutterEngine.dartExecutor.binaryMessenger)
        NativeToastHost.install(this, flutterEngine.dartExecutor.binaryMessenger)
        LiquidGlassBarHost.install(this, flutterEngine.dartExecutor.binaryMessenger)
        VolumeBarHost.install(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.mint.mint/locale",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppLocales" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val lm = getSystemService(LocaleManager::class.java)
                        val locales = lm.applicationLocales
                        val tags = (0 until locales.size()).map {
                            locales.get(it).toLanguageTag()
                        }
                        result.success(tags)
                    } else {
                        result.success(emptyList<String>())
                    }
                }
                "setAppLocale" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val tag = call.argument<String>("tag")
                        val lm = getSystemService(LocaleManager::class.java)
                        lm.applicationLocales = if (tag.isNullOrEmpty()) {
                            LocaleList.getEmptyLocaleList()
                        } else {
                            LocaleList.forLanguageTags(tag)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        )
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                /** Flutter 首帧已绘制：收起品牌闪屏。 */
                "ready" -> {
                    splashDismissed = true
                    result.success(true)
                }

                "prepare" -> Thread {
                    try {
                        val legacyAwt = call.argument<Boolean>("legacyAwt") ?: false
                        val bootAnimationDir =
                            call.argument<String>("bootAnimationDir").orEmpty()
                        val requiredJavaMajor =
                            (call.argument<Int>("requiredJavaMajor") ?: 8)
                        val lwjglVersion =
                            call.argument<String>("lwjglVersion") ?: "3.3.3"
                        val paths = FclRuntime.prepare(
                            applicationContext, legacyAwt, requiredJavaMajor, lwjglVersion,
                        )
                        val map = mapOf(
                            "javaHome" to paths.javaHome,
                            "lwjglDir" to paths.lwjglDir,
                            "wrapperJar" to paths.wrapperJar,
                            "legacyBootstrapJar" to paths.legacyBootstrapJar,
                            "nativeLibDir" to paths.nativeLibDir,
                            "logDir" to paths.logDir,
                            "cacheDir" to paths.cacheDir,
                            "runtimeDir" to paths.runtimeDir,
                            "abi" to paths.abi,
                            "javaMajor" to paths.javaMajor,
                            "cacio8Jars" to paths.cacio8Jars,
                            "cacio17Jars" to paths.cacio17Jars,
                            "cacioAgentJar" to paths.cacioAgentJar,
                        )
                        runOnUiThread { result.success(map) }
                    } catch (t: Throwable) {
                        runOnUiThread { result.error("prepare_failed", t.message, t.stackTraceToString()) }
                    }
                }.start()

                "launch" -> {
                    try {
                        @Suppress("UNCHECKED_CAST")
                        val args = (call.argument<List<String>>("args") ?: emptyList()).toTypedArray()
                        val workingDir = call.argument<String>("workingDir").orEmpty()
                        val logDir = call.argument<String>("logDir").orEmpty()
                        val javaHome = call.argument<String>("javaHome").orEmpty()
                        val renderer = call.argument<String>("renderer").orEmpty().ifEmpty { "gl4es" }
                        val showFps = call.argument<Boolean>("showFps") ?: true
                        val versionName = call.argument<String>("versionName").orEmpty()
                        val lwjglVersion =
                            call.argument<String>("lwjglVersion") ?: "3.3.3"
                        val useInputStackQueue =
                            call.argument<Boolean>("useInputStackQueue") ?: false
                        val javaMajor = (call.argument<Int>("javaMajor") ?: 8)
                        val legacyAwt = call.argument<Boolean>("legacyAwt") ?: false
                        val bootAnimationDir =
                            call.argument<String>("bootAnimationDir").orEmpty()
                        val sdl3 = call.argument<Boolean>("sdl3") ?: false
                        if (args.isEmpty() || workingDir.isEmpty() || javaHome.isEmpty()) {
                            result.error("bad_args", "启动参数为空", null)
                        } else {
                            val gameIntent =
                                Intent(this, GameActivity::class.java).apply {
                                    putExtra("args", args)
                                    putExtra("workingDir", workingDir)
                                    putExtra("logDir", logDir)
                                    putExtra("javaHome", javaHome)
                                    putExtra("renderer", renderer)
                                    putExtra("showFps", showFps)
                                    putExtra("versionName", versionName)
                                    putExtra("lwjglVersion", lwjglVersion)
                                    putExtra("useInputStackQueue", useInputStackQueue)
                                    putExtra("javaMajor", javaMajor)
                                    putExtra("legacyAwt", legacyAwt)
                                    putExtra("bootAnimationDir", bootAnimationDir)
                                    putExtra("sdl3", sdl3)
                                }
                            // 26.x 的 SDL3 窗口会跟着“启动时”的屏幕朝向走：
                            // 启动器还竖着就直接开 GameActivity，Surface 是在
                            // 旋转动画里创建的，SDK 拿到竖屏 buffer，游戏里整个
                            // UI 会转 90°。先让启动器切横屏，等显示方向落定再
                            // 开游戏，GameActivity 就能直接以横屏 Surface 启动。
                            if (sdl3) {
                                forcedLandscapeForLaunch = true
                                requestedOrientation =
                                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                                window.decorView.postDelayed({
                                    if (!isFinishing && !isDestroyed) {
                                        startActivity(gameIntent)
                                    }
                                }, 350L)
                            } else {
                                startActivity(gameIntent)
                            }
                            result.success(true)
                        }
                    } catch (t: Throwable) {
                        result.error("launch_failed", t.message, t.stackTraceToString())
                    }
                }

                /** 游戏还在不在跑（pid 文件 + /proc 复核）。 */
                "gameRunning" -> result.success(GameActivity.gamePid(applicationContext) > 0)

                /** 结束游戏：先广播让它自己退，600ms 还没走就硬杀。 */
                "stopGame" -> {
                    val pid = GameActivity.gamePid(applicationContext)
                    if (pid <= 0) {
                        result.success(false)
                    } else {
                        sendBroadcast(Intent(GameActivity.ACTION_STOP).setPackage(packageName))
                        Handler(Looper.getMainLooper()).postDelayed({
                            val alive = GameActivity.gamePid(applicationContext)
                            if (alive > 0) android.os.Process.killProcess(alive)
                        }, 600)
                        result.success(true)
                    }
                }

                /**
                 * 强制结束：跳过「先广播、再兜底」的软退出，直接 SIGKILL。
                 * 卡死在游戏里（广播收不动、画面回不来）时的最后手段。
                 */
                "game.forceStop" -> {
                    val pid = GameActivity.gamePid(applicationContext)
                    if (pid <= 0) {
                        result.success(false)
                    } else {
                        android.os.Process.killProcess(pid)
                        result.success(true)
                    }
                }

                /**
                 * 把游戏窗口调回前台：游戏 task 被启动器 / 别的应用盖住、
                 * 又不想杀掉重进时用。GameActivity 是 singleTask + 独立 task，
                 * REORDER_TO_FRONT 只挪 task 不重建实例。
                 */
                "game.foreground" -> {
                    val pid = GameActivity.gamePid(applicationContext)
                    if (pid <= 0) {
                        result.success(false)
                    } else {
                        try {
                            startActivity(
                                Intent(this, GameActivity::class.java)
                                    .addFlags(
                                        Intent.FLAG_ACTIVITY_NEW_TASK or
                                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                                    )
                                    // 万一 Activity 真没了（进程活着），重建的
                                    // 实例凭这个标记静默退出而不是报参数缺失。
                                    .putExtra("restoreToFront", true),
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("foreground_failed", t.message, null)
                        }
                    }
                }

                "supported" -> {
                    val nativeDir = applicationInfo.nativeLibraryDir.orEmpty()
                    val abi = when {
                        nativeDir.contains("arm64") -> "arm64-v8a"
                        nativeDir.contains("x86_64") -> "x86_64"
                        else -> Build.SUPPORTED_ABIS.firstOrNull {
                            it == "arm64-v8a" || it == "x86_64"
                        }
                    }
                    result.success(abi != null)
                }

                // 应用专属数据目录。实测 vivo Android 16 连自己的外部
                // Android/data/<pkg> 都拒绝应用进程访问（run-as 可以，
                // untrusted_app 被 SELinux 拦），直接用内部 filesDir，
                // 和 FCL 默认路径一致，保证游戏目录可读写。
                "dataDir" -> {
                    filesDir.mkdirs()
                    result.success(filesDir.absolutePath)
                }

                /** 启动器里的「游戏窗口 / 画面比例」页：与游戏内菜单共用同一个 JSON。 */
                "display.get" -> {
                    val settings = GameDisplaySettings.load(applicationContext)
                    val dm = resources.displayMetrics
                    val long = max(dm.widthPixels, dm.heightPixels)
                    val short = min(dm.widthPixels, dm.heightPixels).coerceAtLeast(1)
                    result.success(
                        mapOf(
                            "mode" to settings.mode.id,
                            "ratio" to settings.ratio,
                            "windowWidth" to settings.windowWidth,
                            "windowHeight" to settings.windowHeight,
                            "resolutionScale" to settings.resolutionScale,
                            "screenAspect" to long.toFloat() / short,
                            // 100% 精度的基准（横屏原生像素）。
                            "screenWidth" to long,
                            "screenHeight" to short,
                        ),
                    )
                }

                "display.set" -> {
                    try {
                        val settings = GameDisplaySettings(
                            mode = GameDisplaySettings.Mode.fromId(
                                call.argument<String>("mode"),
                            ),
                            ratio = (call.argument<Double>("ratio")
                                ?: (16.0 / 9.0)).toFloat().coerceIn(
                                GameDisplaySettings.MIN_RATIO,
                                GameDisplaySettings.MAX_RATIO,
                            ),
                            windowWidth = GameDisplaySettings.clampWindow(
                                (call.argument<Double>("windowWidth") ?: 1.0).toFloat(),
                            ),
                            windowHeight = GameDisplaySettings.clampWindow(
                                (call.argument<Double>("windowHeight") ?: 1.0).toFloat(),
                            ),
                            resolutionScale = (call.argument<Double>("resolutionScale")
                                ?: 1.0).toFloat().coerceIn(
                                GameDisplaySettings.MIN_SCALE,
                                GameDisplaySettings.MAX_SCALE,
                            ),
                        )
                        GameDisplaySettings.save(applicationContext, settings)
                        // 游戏在后台跑着也让它立刻套用（GameActivity 收广播重读）。
                        sendBroadcast(
                            Intent(GameActivity.ACTION_DISPLAY)
                                .setPackage(packageName),
                        )
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("display_failed", t.message, null)
                    }
                }

                /** 启动器设置页读体验微调（灵敏度 / 陀螺仪 / 高刷 / 内存叠层）。 */
                "tweaks.get" -> {
                    val t = GameTweaksSettings.load(applicationContext)
                    val hasGyro = (getSystemService(SENSOR_SERVICE) as? android.hardware.SensorManager)
                        ?.getDefaultSensor(android.hardware.Sensor.TYPE_GYROSCOPE) != null
                    result.success(
                        t.toMap() + mapOf("gyroscopeAvailable" to hasGyro),
                    )
                }

                /** 部分更新体验微调：传入的键覆盖，其余保持；改完广播游戏重读。 */
                "tweaks.set" -> {
                    try {
                        val current = GameTweaksSettings.load(applicationContext)
                        val next = current.withArguments(call.arguments)
                        GameTweaksSettings.save(applicationContext, next)
                        sendBroadcast(
                            Intent(GameActivity.ACTION_TWEAKS)
                                .setPackage(packageName),
                        )
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("tweaks_failed", t.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // Java 运行时：状态 / 按需下载（从 FCL 发布 APK 里 Range 取 JRE）。
        // 独立通道，避免和 mint/fcl 的单 handler（游戏退出回调）互相覆盖。
        val jreChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mint/jre",
        )
        jreChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(FclRuntime.status(applicationContext))

                "download" -> {
                    val major = call.argument<Int>("major") ?: 0
                    Thread {
                        try {
                            val info = JreDownloader.downloadAndInstall(
                                applicationContext, major,
                            ) { p ->
                                runOnUiThread {
                                    runCatching {
                                        jreChannel.invokeMethod(
                                            "progress",
                                            mapOf(
                                                "major" to major,
                                                "phase" to p.phase,
                                                "fraction" to p.fraction,
                                                "detail" to p.detail,
                                            ),
                                        )
                                    }
                                }
                            }
                            runOnUiThread { result.success(info) }
                        } catch (t: Throwable) {
                            runOnUiThread {
                                result.error(
                                    if (t is JreDownloader.CancelledException) {
                                        "cancelled"
                                    } else {
                                        "download_failed"
                                    },
                                    t.message,
                                    t.stackTraceToString(),
                                )
                            }
                        }
                    }.start()
                }

                "cancel" -> {
                    JreDownloader.cancel()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun registerExitReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(GameActivity.ACTION_EXIT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(exitReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(exitReceiver, filter)
        }
        receiverRegistered = true
    }

    override fun onDestroy() {
        if (receiverRegistered) {
            try {
                unregisterReceiver(exitReceiver)
            } catch (_: Throwable) {
            }
            receiverRegistered = false
        }
        if (channel != null) channel = null
        NativeTooltipHost.dispose()
        NativeToastHost.dispose()
        LiquidGlassBarHost.dispose()
        VolumeBarHost.dispose()
        super.onDestroy()
    }
}
