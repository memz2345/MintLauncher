package dev.mint.mint

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.SurfaceTexture
import android.os.Build
import android.util.Log
import android.view.Surface
import dalvik.system.InMemoryDexClassLoader
import java.io.File
import java.lang.ref.WeakReference
import java.lang.reflect.Proxy
import java.nio.ByteBuffer

/**
 * FCL 运行时桥：复用 FoldCraftLauncher 的 JRE8 / LWJGL3+lwjglx / 原生库，
 * 只保留启动所需的最小链路（Mint 自己负责 UI、下载和版本管理）。
 *
 * FCL 的 Java 代码以 dex 资产形式随 APK 打包，用 InMemoryDexClassLoader
 * 加载；原生库走 jniLibs（类名/native 方法名与 FCL 保持一致）。
 */
object FclRuntime {
    private const val TAG = "MintFcl"

    /** GLFW 窗口属性（与 lwjgl3 常量同值）。 */
    private const val GLFW_FOCUSED = 0x00020001
    private const val GLFW_ICONIFIED = 0x00020002
    private const val GLFW_VISIBLE = 0x00020004
    private const val GLFW_HOVERED = 0x0002000B
    private const val ASSET_DEX_DIR = "fcl/dex"
    private const val ASSET_JRE = "app_runtime/java/jre8"
    private const val ASSET_JRE_BASE = "app_runtime/java"
    private const val ASSET_LWJGL = "app_runtime/lwjgl"

    /** 支持的大版本（设置页 / 下载器共用）。25 用于 26.x+，不再随包。 */
    val JAVA_MAJORS = listOf(8, 17, 21, 25)

    /**
     * 解压/复制完成标记。
     *
     * 只判断「某个文件在不在」会被半截产物骗到：手机上解压到一半被系统杀掉，
     * 之后 `release` / `lwjgl.jar` 已经在，就永远不会重解，表现成「下载完成但
     * 启动缺库」。所以每次成功做完才写 marker，下次以 marker 为准。
     */
    private const val READY_MARKER = ".mint-ready"

    private var loader: ClassLoader? = null
    private var appContext: Context? = null

    /**
     * 一个渲染器的 FCL 定义（照 `com.mio.data.Renderer` 的 13 参构造）。
     *
     * 这些名字/so 名必须跟 FCL 的 `RendererManager` 逐字一致 —— native 层
     * 按 `name` 查环境变量、按 `glName`/`eglName` 去 `System.loadLibrary`。
     * Mint 的 jniLibs 已经把六套 so 全打包进来了，所以这里可以直接选。
     */
    private data class RendererSpec(
        val name: String,
        val glName: String,
        val eglName: String,
        val id: String,
        val maxMcVer: String,
    )

    private val renderers = mapOf(
        "gl4es" to RendererSpec(
            "Holy-GL4ES", "libgl4es_114.so", "libEGL.so",
            "f7e985d8-6d4c-f63c-d9f1-06074dab823a", "1.21.4",
        ),
        "nggl4es" to RendererSpec(
            "Krypton Wrapper", "libng_gl4es.so", "libEGL.so",
            "e7b90ed6-e518-4d4e-93dc-5c7133cd5b31", "26.3-snapshot-3",
        ),
        "virgl" to RendererSpec(
            "VirGLRenderer", "libOSMesa_81.so", "libEGL.so",
            "417a7a93-d9b4-98b9-ec6e-1ea400259c1f", "26.3-snapshot-3",
        ),
        "vgpu" to RendererSpec(
            "VGPU", "libvgpu.so", "libEGL.so",
            "0fb718e4-64e3-83d4-a974-8204ea1d9f9f", "1.16.5",
        ),
        "zink" to RendererSpec(
            "Zink", "libglxshim.so", "libEGL_mesa.so",
            "18d93f17-ff53-a319-fa61-58709a77bf87", "26.3-snapshot-3",
        ),
        "freedreno" to RendererSpec(
            "Freedreno", "libOSMesa_8.so", "libEGL.so",
            "8d427e6c-9d22-2d19-db0c-3b9ac2c1543f", "26.3-snapshot-3",
        ),
        // FCL 1.3.4.3 新增：MobileGlues 自带 EGL（glName == eglName），
        // Minecraft 26.3 的 RenderPearl 后端要求真正的 EGL，GL4ES/Krypton
        // 都会报「Could not retrieve EGL function eglGetDisplay」。
        "mobileglues" to RendererSpec(
            "MobileGlues", "libmobileglues.so", "libmobileglues.so",
            "acaf8100-bbaf-4d68-b30d-38bf42fcd640", "",
        ),
        "sfpew" to RendererSpec(
            "SimpleFPEWrapper", "libSimpleFPEWrapper.so", "libEGL.so",
            "f3e4280b-db2e-42e2-95eb-671640b7b0eb", "",
        ),
    )

    /** 给 Dart 侧「可用渲染器」用的列表（id → 显示名）。 */
    fun rendererNames(): Map<String, String> = renderers.mapValues { it.value.name }

    /** 游戏是否已捕获鼠标（决定右侧拖动是转视角还是移动菜单光标）。 */
    @Volatile
    var cursorGrabbed = false

    /** 捕获状态变化（进入/退出世界）时通知宿主刷新控制层。 */
    var onCursorModeChanged: (() -> Unit)? = null

    /** JVM 输出（FCLBridge.onLog）：GameActivity 用来留一份崩溃前日志。 */
    var onGameLog: ((String) -> Unit)? = null

    /** JVM 退出（带 exitCode）：GameActivity 据此决定正常退出还是弹崩溃页。 */
    var onGameExit: ((Int) -> Unit)? = null

    data class RuntimePaths(
        val javaHome: String,
        val lwjglDir: String,
        val wrapperJar: String,
        val legacyBootstrapJar: String,
        val nativeLibDir: String,
        val logDir: String,
        val cacheDir: String,
        val runtimeDir: String,
        val abi: String,
        val javaMajor: Int,
        val cacio8Jars: List<String>,
        val cacio17Jars: List<String>,
        val cacioAgentJar: String,
    )

    /**
     * 随包 JRE 的可用大版本 —— 按 APK 里实际存在的 `bin-<abi>.tar.xz` 判断。
     *
     * 之前是按 ABI 硬写死（arm64 有 8/17/21，x86_64 只有 8），高版本在模拟器上
     * 注定跑不起来；现在补了哪个包就自动支持哪个，不会再和资产脱节。
     * 缺包时 Dart 侧按 `paths.javaMajor < requiredJavaMajor` 明确报错，
     * 而不是让 JVM 起不来再猜。
     */
    private fun bundledJavaMajors(context: Context, abi: String): List<Int> {
        val jreArch = if (abi == "arm64-v8a") "arm64" else "x86_64"
        return JAVA_MAJORS.filter { major ->
            runCatching {
                context.assets.open("$ASSET_JRE_BASE/jre$major/bin-$jreArch.tar.xz").close()
            }.isSuccess
        }
    }

    /** 设备 ABI（nativeLibraryDir 在 compileSdk 37 后比 primaryCpuAbi 可靠）。 */
    fun deviceAbi(context: Context): String {
        val nativeDir = context.applicationInfo.nativeLibraryDir.orEmpty()
        return when {
            nativeDir.contains("arm64") -> "arm64-v8a"
            nativeDir.contains("x86_64") -> "x86_64"
            Build.SUPPORTED_64_BIT_ABIS.contains("arm64-v8a") -> "arm64-v8a"
            Build.SUPPORTED_64_BIT_ABIS.contains("x86_64") -> "x86_64"
            else -> throw IllegalStateException(
                "当前 Android 运行时只支持 64 位 arm64-v8a / x86_64",
            )
        }
    }

    fun jreHomePath(context: Context, major: Int): String =
        File(File(context.getDir("runtime", 0), "java"), "jre$major").absolutePath

    private fun jreLibJvm(major: Int, abi: String): String = if (major == 8) {
        if (abi == "arm64-v8a") "lib/aarch64/server/libjvm.so"
        else "lib/amd64/server/libjvm.so"
    } else {
        "lib/server/libjvm.so"
    }

    /** 已完整解压（marker + libjvm 都在）的 JRE 大版本。 */
    fun installedJavaMajors(context: Context, abi: String = deviceAbi(context)): List<Int> =
        JAVA_MAJORS.filter { major ->
            val home = File(jreHomePath(context, major))
            File(home, READY_MARKER).exists() && File(home, jreLibJvm(major, abi)).exists()
        }

    /**
     * 随包 + 已下载的可用 JRE。prepare 选版本、设置页展示状态都用它。
     *
     * Android 16 (SDK 36) arm64 上 JRE8 会崩（见 [prepare]），这里仍然返回，
     * 由调用方按 `usable` 过滤 —— 状态页要能说明「为什么这台机器不用 8」。
     */
    fun availableJavaMajors(context: Context, abi: String): List<Int> =
        (bundledJavaMajors(context, abi) + installedJavaMajors(context, abi))
            .distinct()
            .sorted()

    /** Java 8 在当前机器上是否不可用（AArch64 JIT 的 Field too big for insn）。 */
    fun jre8Broken(abi: String): Boolean =
        abi == "arm64-v8a" && Build.VERSION.SDK_INT >= 36

    fun status(context: Context): List<Map<String, Any?>> {
        val abi = deviceAbi(context)
        val bundled = bundledJavaMajors(context, abi)
        val installed = installedJavaMajors(context, abi)
        val broken8 = jre8Broken(abi)
        return JAVA_MAJORS.map { major ->
            mapOf(
                "major" to major,
                "bundled" to bundled.contains(major),
                "installed" to installed.contains(major),
                "home" to jreHomePath(context, major),
                // 这台机器上能否真的拿来跑（8 在 Android 16 arm64 上不行）。
                "usable" to !(major == 8 && broken8),
            )
        }
    }

    private fun cls(name: String): Class<*> =
        Class.forName(name, true, loader ?: error("FCL runtime not loaded"))

    fun ensureLoaded(context: Context): ClassLoader {
        loader?.let { return it }
        synchronized(this) {
            loader?.let { return it }
            val assets = context.assets
            val dexNames: List<String> =
                assets.list(ASSET_DEX_DIR)?.sorted() ?: emptyList()
            require(dexNames.isNotEmpty()) { "缺少 FCL dex 资产" }
            val buffers = dexNames.map { name ->
                val bytes = assets.open("$ASSET_DEX_DIR/$name").use { it.readBytes() }
                ByteBuffer.allocateDirect(bytes.size).put(bytes).apply { position(0) }
            }.toTypedArray()
            // librarySearchPath 必须显式给 nativeLibraryDir：FCLBridge 的
            // System.loadLibrary("fcl") 走的是这个 ClassLoader 的 native 搜索路径。
            val l = InMemoryDexClassLoader(
                buffers,
                context.applicationInfo.nativeLibraryDir,
                javaClass.classLoader,
            )
            loader = l
            appContext = context.applicationContext
            // FCLApp 的静态上下文在 attachBaseContext 里赋值；不启动 FCL 的
            // Application，就手动造一个实例只用来满足 getAppContext()。
            try {
                val appCls = Class.forName("com.tungsten.fcl.FCLApp", true, l)
                val app = appCls.getDeclaredConstructor().newInstance()
                val attach = ContextWrapper::class.java.getDeclaredMethod(
                    "attachBaseContext", Context::class.java,
                )
                attach.isAccessible = true
                attach.invoke(app, context.applicationContext)
            } catch (t: Throwable) {
                Log.w(TAG, "FCLApp 占位初始化失败（部分功能可能不可用）", t)
            }
            val pathCls = Class.forName("com.tungsten.fclauncher.utils.FCLPath", true, l)
            pathCls.getMethod("loadPaths", Context::class.java)
                .invoke(null, context.applicationContext)
            return l
        }
    }

    /** FCL 默认把 LOG_DIR 指到 /sdcard/FCL；改到应用专属目录，避免权限问题。 */
    private fun overridePaths(context: Context) {
        val pathCls = cls("com.tungsten.fclauncher.utils.FCLPath")
        val logDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs")
            .apply { mkdirs() }
        pathCls.getField("LOG_DIR").set(null, logDir.absolutePath)
        pathCls.getField("CACHE_DIR")
            .set(null, File(context.cacheDir, "fclauncher").apply { mkdirs() }.absolutePath)
        pathCls.getField("CONTROLLER_DIR")
            .set(null, File(context.filesDir, "control").apply { mkdirs() }.absolutePath)
        pathCls.getField("SHARE_DIR")
            .set(null, File(context.filesDir, "share").apply { mkdirs() }.absolutePath)
    }

    fun prepare(
        context: Context,
        legacyAwt: Boolean = false,
        requiredJavaMajor: Int = 8,
        lwjglVersion: String = "3.3.3",
    ): RuntimePaths {
        // 以 APK 实际安装的 ABI 为准（模拟器 x86_64、真机 arm64-v8a）。
        val abi = deviceAbi(context)
        // FCL 资源命名：bin-arm64.tar.xz / bin-x86_64.tar.xz；
        // JVM 动态库目录：JRE8 是 aarch64/amd64，JRE17/21 是 lib/server。
        val jreArch = if (abi == "arm64-v8a") "arm64" else "x86_64"
        // 选 JRE：按版本 JSON 要求的 Java 大版本，取随包里「正好或更高」的第一档
        // （FCL JavaManager.findExactOrNextGreater 同款）。
        // Android 16 (SDK 36) arm64 上 JRE8 的 AArch64 汇编器会崩
        // （assembler_aarch64.hpp:237 Field too big for insn，-Xint 也救不了），
        // 那种机器上 JRE8 直接不可用，1.7.10 也得跟着上 JRE17。
        // 远古版（AWT Frame）另外偏好 JRE8：JRE17 的 java.desktop 在 Android 上
        // 会走 X11GraphicsEnvironment，initDisplay 没有 native 实现 —— 但那是
        // 「更差也要选」的偏好，不能压过「这个 JRE 在这台机器上根本起不来」。
        val available = availableJavaMajors(context, abi)
        if (available.isEmpty()) {
            throw IllegalStateException(
                "APK 里没有 $abi 可用的 JRE（jre8/17/21 的 bin-$abi 包都缺失）",
            )
        }
        val broken8 = jre8Broken(abi)
        val usable = if (broken8) available.filter { it >= 17 } else available
        val wanted = if (legacyAwt) 8 else requiredJavaMajor.coerceAtLeast(8)
        val javaMajor = usable.firstOrNull { it >= wanted } ?: usable.first()
        val jreAsset = "$ASSET_JRE_BASE/jre$javaMajor"
        val jvmLib = jreLibJvm(javaMajor, abi)
        val jreBundled = bundledJavaMajors(context, abi).contains(javaMajor)
        val lwjglDirName = lwjglDirName(lwjglVersion)
        ensureLoaded(context)
        overridePaths(context)
        val pathCls = cls("com.tungsten.fclauncher.utils.FCLPath")
        fun path(name: String): String = pathCls.getField(name).get(null) as String

        val lwjglDir = File(path("LWJGL_DIR"), lwjglDirName)

        val javaHome = path(
            when (javaMajor) {
                25 -> "JAVA_25_PATH"
                21 -> "JAVA_21_PATH"
                8 -> "JAVA_8_PATH"
                else -> "JAVA_17_PATH"
            },
        )
        val pluginDir = File(path("PLUGIN_DIR")).apply { mkdirs() }
        val wrapper = File(pluginDir, "MioLaunchWrapper.jar")
        val patcher = File(pluginDir, "MioLibPatcher.jar")
        val runtimeUtils = cls("com.tungsten.fcl.util.RuntimeUtils")

        val jreMarker = File(javaHome, READY_MARKER)
        if (!jreMarker.exists() || !File(javaHome, jvmLib).exists()) {
            if (!jreBundled) {
                // 下载的运行时没装好 / 被清掉了：明确让上层去「运行环境」页装。
                throw IllegalStateException(
                    "Java $javaMajor 运行时未安装（$abi），请到「设置 → 运行环境」下载",
                )
            }
            Log.i(TAG, "解压 JRE（$jreAsset / $abi）→ $javaHome")
            File(javaHome).deleteRecursively()
            File(javaHome).mkdirs()
            val unxz = runtimeUtils.getMethod(
                "uncompressTarXZ", java.io.InputStream::class.java, File::class.java,
            )
            context.assets.open("$jreAsset/universal.tar.xz").use {
                unxz.invoke(null, it, File(javaHome))
            }
            context.assets.open("$jreAsset/bin-$jreArch.tar.xz").use {
                unxz.invoke(null, it, File(javaHome))
            }
            context.assets.open("$jreAsset/version").use {
                File(javaHome, "version").writeBytes(it.readBytes())
            }
            try {
                runtimeUtils.getMethod("patchJava", Context::class.java, String::class.java)
                    .invoke(null, context, javaHome)
            } catch (t: Throwable) {
                // JRE17/21 不需要 JRE8 的那套 patch，失败不阻断启动。
                Log.w(TAG, "patchJava 失败（$jreAsset）", t)
            }
            jreMarker.writeText(javaMajor.toString())
        }
        ensureAssetDir(
            context, "$ASSET_LWJGL/$lwjglDirName", lwjglDir, lwjglDirName, runtimeUtils,
        )
        if (!wrapper.exists()) {
            runtimeUtils.getMethod(
                "copyAssets", Context::class.java, String::class.java, String::class.java,
            ).invoke(null, context, "game/MioLaunchWrapper.jar", wrapper.absolutePath)
        }
        val legacyBootstrap = File(pluginDir, "MintLegacyBootstrap.jar")
        if (!legacyBootstrap.exists()) {
            runtimeUtils.getMethod(
                "copyAssets", Context::class.java, String::class.java, String::class.java,
            ).invoke(
                null, context, "game/MintLegacyBootstrap.jar",
                legacyBootstrap.absolutePath,
            )
        }
        if (!patcher.exists()) {
            runtimeUtils.getMethod(
                "copyAssets", Context::class.java, String::class.java, String::class.java,
            ).invoke(null, context, "game/MioLibPatcher.jar", patcher.absolutePath)
        }
        // caciocavallo（AWT 软件后端）：1.13+ 的启动图 / Forge 的 Swing 界面都要
        // Toolkit，Android 没有 X11，不挂它就直接 HeadlessException。
        val cacio8Dir = File(path("CACIOCAVALLO_8_DIR"))
        val cacio17Dir = File(path("CACIOCAVALLO_17_DIR"))
        ensureAssetDir(context, "app_runtime/caciocavallo", cacio8Dir, "8", runtimeUtils)
        ensureAssetDir(context, "app_runtime/caciocavallo17", cacio17Dir, "17", runtimeUtils)
        // JNA 原生库（1.20.5+ 与部分模组加载器会要）：FCL 按版本分目录打包。
        ensureAssetDir(
            context, "app_runtime/jna", File(path("RUNTIME_DIR"), "jna"),
            "jna", runtimeUtils,
        )

        val logDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs")
            .apply { mkdirs() }
        fun jarsIn(dir: File): List<String> =
            (dir.listFiles { f: File -> f.isFile && f.name.endsWith(".jar") }
                ?: emptyArray()).sortedBy { it.name }.map { it.absolutePath }
        val agent = File(cacio17Dir, "cacio-agent.jar")
        return RuntimePaths(
            javaHome = javaHome,
            lwjglDir = lwjglDir.absolutePath,
            wrapperJar = wrapper.absolutePath,
            legacyBootstrapJar = legacyBootstrap.absolutePath,
            nativeLibDir = context.applicationInfo.nativeLibraryDir,
            logDir = logDir.absolutePath,
            cacheDir = File(context.cacheDir, "fclauncher").apply { mkdirs() }.absolutePath,
            runtimeDir = path("RUNTIME_DIR"),
            abi = abi,
            javaMajor = javaMajor,
            cacio8Jars = jarsIn(cacio8Dir),
            cacio17Jars = jarsIn(cacio17Dir),
            cacioAgentJar = if (agent.exists()) agent.absolutePath else "",
        )
    }

    /**
     * 把游戏 Surface 注册给 FCL 的 SDL3 桥（Minecraft 26.3+ 的 RenderPearl
     * 用 SDL 建窗口，不再走 GLFW）。
     *
     * FCL `JVMActivity` 在 `onSurfaceTextureAvailable` 里先
     * `SdlBridge.prepareSurface(...)` 再 `fclBridge.execute(...)`；不注册的话
     * SDL 的隐藏窗口拿不到 ANativeWindow，报
     * `Could not fetch native window` 后静默退出。
     */
    fun prepareSdlSurface(activity: Activity, surface: Surface, layout: android.view.ViewGroup) {
        try {
            val sdlBridge = cls("com.tungsten.fcl.game.sdl.SdlBridge")
            sdlBridge.getMethod(
                "prepareSurface",
                Activity::class.java,
                Surface::class.java,
                android.view.ViewGroup::class.java,
                Any::class.java,
            ).invoke(null, activity, surface, layout, activity)
            Log.i(TAG, "SdlBridge.prepareSurface 完成")
        } catch (t: Throwable) {
            Log.w(TAG, "SdlBridge.prepareSurface 失败", t)
        }
    }

    fun syncSdlResolution(width: Int, height: Int) {
        try {
            cls("com.tungsten.fcl.game.sdl.SdlBridge").getMethod(
                "syncResolution",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            ).invoke(null, width, height)
        } catch (_: Throwable) {
        }
    }

    /**
     * 不等 SDL 通知，直接把当前 Surface 的尺寸/geometry 同步给 SDLSurface。
     *
     * 只在 SDL 桥真正接管后调用：`nativeResize` 是 `SDLActivity` 的 JNI 方法，
     * 游戏调用 `SDL_Init` 之前 `libSDL3` 还没被加载，直接调只会抛
     * `UnsatisfiedLinkError`（26.2 走 GLFW，以前被误判成 SDL 版本时每 250ms
     * 刷一次）。SDL 未接管时直接返回，等 [isSdlEnabled] 为 true 由轮询补上。
     */
    fun forceSyncSdlResolution(width: Int, height: Int) {
        if (!isSdlEnabled()) return
        try {
            val sdlActivity = cls("org.libsdl.app.SDLActivity")
            val surface = sdlActivity.getMethod("getSDLSurface").invoke(null) ?: return
            surface.javaClass.getMethod("surfaceChanged").invoke(surface)
            surface.javaClass.getMethod(
                "nativeResize",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            ).invoke(surface, width, height)
            Log.i(TAG, "SDL 强制同步尺寸 ${width}x$height")
        } catch (t: Throwable) {
            Log.w(TAG, "SDL 强制同步尺寸失败", t)
        }
    }

    /** SDL 桥是否已经真正接管（游戏发过 SDL 通知），syncResolution 只有此时生效。 */
    fun isSdlEnabled(): Boolean = try {
        cls("com.tungsten.fcl.game.sdl.SdlBridge")
            .getMethod("getSdlEnabled")
            .invoke(null) as? Boolean ?: false
    } catch (_: Throwable) {
        false
    }

    fun destroySdlSurface() {
        try {
            val sdlActivity = cls("org.libsdl.app.SDLActivity")
            val surface = sdlActivity.getMethod("getSDLSurface").invoke(null) ?: return
            surface.javaClass.getMethod("surfaceDestroyed").invoke(surface)
        } catch (_: Throwable) {
        }
    }

    fun resetSdlBridge() {
        try {
            cls("com.tungsten.fcl.game.sdl.SdlBridge").getMethod("reset").invoke(null)
        } catch (_: Throwable) {
        }
    }

    /**
     * 安装一份「下载好的」JRE：三个 tar.xz 由 [JreDownloader] 从 FCL 发布包
     * 里按需取出，这里复用 FCL 的 RuntimeUtils 解压 + patchJava，写 marker。
     *
     * 与随包 JRE 走完全相同的落盘结构，[prepare] 的下一次调用会直接认它。
     */
    fun installJreFromArchives(
        context: Context,
        major: Int,
        binTarXz: File,
        universalTarXz: File,
        versionFile: File,
        onPhase: (String) -> Unit = {},
    ): String {
        require(major in JAVA_MAJORS) { "不支持的 Java 大版本：$major" }
        require(binTarXz.isFile && universalTarXz.isFile) { "JRE 压缩包不完整" }
        val abi = deviceAbi(context)
        ensureLoaded(context)
        overridePaths(context)
        val runtimeUtils = cls("com.tungsten.fcl.util.RuntimeUtils")
        val javaHome = File(jreHomePath(context, major))
        Log.i(TAG, "安装下载的 JRE$major（$abi）→ $javaHome")
        javaHome.deleteRecursively()
        javaHome.mkdirs()
        val unxz = runtimeUtils.getMethod(
            "uncompressTarXZ", java.io.InputStream::class.java, File::class.java,
        )
        onPhase("解压 universal")
        universalTarXz.inputStream().buffered().use {
            unxz.invoke(null, it, javaHome)
        }
        onPhase("解压 bin-$abi")
        binTarXz.inputStream().buffered().use {
            unxz.invoke(null, it, javaHome)
        }
        if (versionFile.isFile) {
            versionFile.copyTo(File(javaHome, "version"), overwrite = true)
        }
        onPhase("patch Java")
        try {
            runtimeUtils.getMethod("patchJava", Context::class.java, String::class.java)
                .invoke(null, context, javaHome.absolutePath)
        } catch (t: Throwable) {
            Log.w(TAG, "patchJava 失败（jre$major）", t)
        }
        if (!File(javaHome, jreLibJvm(major, abi)).exists()) {
            throw IllegalStateException("解压后缺少 libjvm.so（jre$major）")
        }
        File(javaHome, READY_MARKER).writeText(major.toString())
        return javaHome.absolutePath
    }

    /**
     * LWJGL 运行时目录名：FCL 只随包 3.3.3 / 3.4.1。按 FCL
     * `DefaultLauncher.setLwjglVersion` 的规则，声明版本 ≥ 3.4.1（26.3 是
     * 3.4.3）用 3.4.1，其它（含走 lwjglx 的 2.x）归一到 3.3.3。
     */
    private fun lwjglDirName(version: String): String {
        val match = Regex("^(\\d+)\\.(\\d+)(?:\\.(\\d+))?").find(version.trim())
            ?: return "3.3.3"
        val major = match.groupValues[1].toIntOrNull() ?: 0
        val minor = match.groupValues[2].toIntOrNull() ?: 0
        val patch = match.groupValues.getOrNull(3)?.toIntOrNull() ?: 0
        val atLeast341 = major > 3 ||
            (major == 3 && (minor > 4 || (minor == 4 && patch >= 1)))
        return if (atLeast341) "3.4.1" else "3.3.3"
    }

    private fun path(name: String, context: Context): String {
        ensureLoaded(context)
        val pathCls = cls("com.tungsten.fclauncher.utils.FCLPath")
        return pathCls.getField(name).get(null) as String
    }

    /** 把 assets 下的目录复制到 [dest]，用 marker 判断是否已经完整做完。 */
    private fun ensureAssetDir(
        context: Context,
        assetPath: String,
        dest: File,
        stamp: String,
        runtimeUtils: Class<*>,
    ) {
        val marker = File(dest, READY_MARKER)
        if (marker.exists() && dest.isDirectory) return
        val children = runCatching { context.assets.list(assetPath) }.getOrNull()
        if (children.isNullOrEmpty()) {
            Log.w(TAG, "assets/$assetPath 不存在，跳过")
            return
        }
        Log.i(TAG, "复制 assets/$assetPath → ${dest.absolutePath}")
        dest.mkdirs()
        runtimeUtils.getMethod(
            "copyAssets", Context::class.java, String::class.java, String::class.java,
        ).invoke(null, context, assetPath, dest.absolutePath)
        marker.writeText(stamp)
    }

    /**
     * 构造 FCLBridge 并返回。真正的 JVM 由 [execute] 在 Surface 就绪后启动。
     *
     * [rendererId] 取 [renderers] 的键（gl4es / nggl4es / virgl / vgpu / zink /
     * freedreno）；未知 id 回落 Holy-GL4ES —— 那个是兼容性最好的默认档。
     *
     * [lwjglVersion] 是版本 JSON 声明的 LWJGL 版本（归一化后 3.3.3 / 3.4.1）：
     * FCL 用它决定原生库目录与 `libfcl` 的加载分支，写死 3.3.3 会让 1.21.5+
     * 那批要 3.4.1 的版本找不到符号。
     */
    fun launch(
        context: Context,
        args: Array<String>,
        workingDir: String,
        logDir: String,
        javaHome: String,
        rendererId: String = "gl4es",
        lwjglVersion: String = "3.3.3",
        javaMajor: Int = 8,
        installedModLoaders: Map<String, Boolean> = emptyMap(),
    ): Any {
        ensureLoaded(context)
        overridePaths(context)
        File(logDir).mkdirs()

        val spec = renderers[rendererId] ?: renderers.getValue("gl4es")
        val rendererCls = cls("com.mio.data.Renderer")
        val rendererCtor = rendererCls.declaredConstructors
            .first { it.parameterCount == 13 }
            .apply { isAccessible = true }
        // 13 参：(name, des, glName, eglName, path, boatEnv, pojavEnv, id,
        //        minMCver, maxMCver, pojavRendererId, source, displayMaxMCver)
        val renderer = rendererCtor.newInstance(
            spec.name, "", spec.glName, spec.eglName, "",
            null, null, spec.id, "", spec.maxMcVer, "", "", "",
        )

        val configCls = cls("com.tungsten.fclauncher.FCLConfig")
        val configCtor = configCls.declaredConstructors
            .first { it.parameterCount == 6 }
            .apply { isAccessible = true }
        val config = configCtor.newInstance(
            context.applicationContext, logDir, javaHome, workingDir, renderer, args,
        )
        val dirName = lwjglDirName(lwjglVersion)
        configCls.getMethod("setLwjglVersion", String::class.java)
            .invoke(config, dirName)
        // Zink/Freedreno 走 Vulkan：FCL 的版本设置里有「使用系统 Vulkan
        // 驱动」，默认 false 时会去用随包的 Turnip；Adreno 机器上系统驱动
        // 才是可用的（否则游戏 Vulkan 后端报 No Vulkan capable devices）。
        if (rendererId == "zink" || rendererId == "freedreno") {
            runCatching {
                configCls.getMethod(
                    "setUseVKDriverSystem", Boolean::class.javaPrimitiveType,
                ).invoke(config, true)
            }.onFailure { Log.w(TAG, "setUseVKDriverSystem 失败", it) }
        }
        // FCL 靠这个标记决定要不要给 Fabric/Forge 走特殊分支（缺省是 null，
        // 但装了加载器时不给会漏掉 bootstrap 的一些补丁）。
        if (installedModLoaders.isNotEmpty()) {
            try {
                val loadersCls = Class.forName(
                    "com.tungsten.fclauncher.FCLConfig\$InstalledModLoaders", true,
                    loader,
                )
                val ctor = loadersCls.declaredConstructors.first().apply { isAccessible = true }
                fun flag(key: String) = installedModLoaders[key] == true
                val loaders = ctor.newInstance(
                    flag("forge"), flag("cleanroom"), flag("neoforge"),
                    flag("optifine"), flag("liteloader"), flag("fabric"), flag("quilt"),
                )
                configCls.getMethod("setInstalledModLoaders", loadersCls)
                    .invoke(config, loaders)
            } catch (t: Throwable) {
                Log.w(TAG, "设置 InstalledModLoaders 失败", t)
            }
        }

        val bridge = cls("com.tungsten.fclauncher.FCLauncher")
            .getMethod("launchMinecraft", configCls)
            .invoke(null, config)
        bridge.javaClass.getMethod("setGameDir", String::class.java)
            .invoke(bridge, workingDir)
        bridge.javaClass.getMethod("setRenderer", String::class.java)
            .invoke(bridge, spec.name)
        bridge.javaClass.getMethod("setJava", String::class.java)
            .invoke(bridge, javaMajor.toString())
        Log.i(TAG, "渲染器：${spec.name}（${spec.glName} / ${spec.eglName}）LWJGL=$dirName JRE=$javaMajor")
        return bridge
    }

    /**
     * 读 FCL 的实时帧率。`FCLBridge.getFps()`（native 计数器，GL4ES 每帧 +1）
     * 是 FCL 自己游戏菜单里那个 FPS 数据源；拿不到就返回 0，UI 显示 "--"。
     */
    fun getFps(bridge: Any?): Int {
        val b = bridge ?: return 0
        return try {
            val m = fpsMethod ?: b.javaClass.getMethod("getFps").also { fpsMethod = it }
            (m.invoke(b) as? Int) ?: 0
        } catch (_: Throwable) {
            0
        }
    }

    private var fpsMethod: java.lang.reflect.Method? = null

    fun execute(
        context: Context,
        activity: Activity,
        bridge: Any,
        surface: Surface,
        width: Int,
        height: Int,
        /// 1.13+（结构化参数）必须开 input stack queue，FCL 按
        /// `version.getArguments().isPresent()` 传这个；关掉的话高版本键盘输入会被丢。
        useInputStackQueue: Boolean = false,
        /// TextureView 的 SurfaceTexture：execute 之后回灌给
        /// `FCLBridge.setSurfaceTexture`（FCL JVMActivity 同顺序），GLFW 路径
        /// 靠它在分辨率变化时驱动 TextureView 的缓冲尺寸。
        surfaceTexture: SurfaceTexture? = null,
    ) {
        ensureLoaded(context)
        overridePaths(context)
        try {
            cls("com.tungsten.fcl.FCLApp")
                .getDeclaredField("currentActivity")
                .apply { isAccessible = true }
                .set(null, WeakReference(activity))
        } catch (_: Throwable) {
        }

        val callbackCls = cls("com.tungsten.fclauncher.bridge.FCLBridgeCallback")
        val callback = Proxy.newProxyInstance(loader, arrayOf(callbackCls)) { _, method, methodArgs ->
            when (method.name) {
                "onLog" -> {
                    val line = (methodArgs?.firstOrNull() as? String).orEmpty()
                    Log.i(TAG, line)
                    try {
                        onGameLog?.invoke(line)
                    } catch (_: Throwable) {
                    }
                    null
                }
                "onCursorModeChange" -> {
                    // FCLBridge.CursorDisabled = 0，CursorEnabled = 1
                    cursorGrabbed = (methodArgs?.firstOrNull() as? Int) == 0
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        onCursorModeChanged?.invoke()
                    }
                    null
                }
                "onExit" -> {
                    val code = (methodArgs?.firstOrNull() as? Int) ?: 0
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        val handler = onGameExit
                        if (handler != null) {
                            handler(code)
                        } else {
                            MainActivity.notifyGameExit()
                            activity.finish()
                        }
                    }
                    null
                }
                else -> null
            }
        }

        val cb = cls("org.lwjgl.glfw.CallbackBridge")
        cb.getField("windowWidth").setInt(null, width)
        cb.getField("windowHeight").setInt(null, height)
        cb.getMethod("nativeSetUseInputStackQueue", Boolean::class.javaPrimitiveType)
            .invoke(null, useInputStackQueue)
        bridge.javaClass.getMethod("setSurfaceDestroyed", Boolean::class.javaPrimitiveType)
            .invoke(bridge, false)
        bridge.javaClass.getMethod(
            "pushEventWindow", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
        ).invoke(bridge, width, height)
        bridge.javaClass.getMethod("execute", Surface::class.java, callbackCls)
            .invoke(bridge, surface, callback)
        if (surfaceTexture != null) {
            runCatching {
                bridge.javaClass
                    .getMethod("setSurfaceTexture", SurfaceTexture::class.java)
                    .invoke(bridge, surfaceTexture)
            }.onFailure { Log.w(TAG, "setSurfaceTexture 失败", it) }
        }
    }

    /**
     * 运行中改渲染尺寸（FCL JVMActivity.onSurfaceTextureSizeChanged 的等价动作）：
     * 刷新 [CallbackBridge] 的窗口宽高、发 GLFW framebuffer-size 事件，再补一次
     * `pushEventWindow`。游戏侧收到的就是「窗口被拖大了」，会按新比例重新布局
     * 界面与视口，不需要重启。
     */
    fun updateWindowSize(context: Context, bridge: Any?, width: Int, height: Int) {
        ensureLoaded(context)
        try {
            val cb = cls("org.lwjgl.glfw.CallbackBridge")
            cb.getField("windowWidth").setInt(null, width)
            cb.getField("windowHeight").setInt(null, height)
            cb.getMethod(
                "sendUpdateWindowSize", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            ).invoke(null, width, height)
        } catch (t: Throwable) {
            Log.w(TAG, "sendUpdateWindowSize($width, $height) 失败", t)
        }
        try {
            bridge?.javaClass
                ?.getMethod(
                    "pushEventWindow", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                )?.invoke(bridge, width, height)
        } catch (t: Throwable) {
            Log.w(TAG, "pushEventWindow($width, $height) 失败", t)
        }
    }

    /**
     * 通知 LWJGLX/GLFW「窗口是否聚焦 / 悬停」。
     *
     * FCL 的 JVMActivity 在 onResume/onPause 里会调它；不调的话游戏认为
     * 窗口没有焦点，键盘事件会被直接丢掉（摇杆/按键全都没反应），
     * 鼠标视角也可能被忽略。
     */
    fun setWindowAttrib(attrib: Int, value: Int) {
        val ctx = appContext ?: return
        try {
            ensureLoaded(ctx)
            cls("org.lwjgl.glfw.CallbackBridge")
                .getMethod(
                    "nativeSetWindowAttrib",
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                )
                .invoke(null, attrib, value)
        } catch (t: Throwable) {
            Log.w(TAG, "setWindowAttrib($attrib, $value) 失败", t)
        }
    }

    private fun bridge(): Class<*> = cls("org.lwjgl.glfw.CallbackBridge")

    /**
     * 注入输入前确认 GLFW「聚焦 + 悬停」。
     *
     * onResume / onWindowFocusChanged 都可能早于游戏建好窗口，漏一次就
     * 表现成按键鼠标全无反应；nativeSetWindowAttrib 幂等，重复设无害。
     */
    private fun ensureFocused() {
        setWindowAttrib(GLFW_FOCUSED, 1)
        setWindowAttrib(GLFW_HOVERED, 1)
    }

    fun sendPointer(context: Context, x: Float, y: Float) {
        ensureLoaded(context)
        ensureFocused()
        cls("org.lwjgl.glfw.CallbackBridge")
            .getMethod("sendCursorPos", Float::class.javaPrimitiveType, Float::class.javaPrimitiveType)
            .invoke(null, x, y)
    }

    fun sendMouseButton(context: Context, button: Int, down: Boolean) {
        ensureLoaded(context)
        ensureFocused()
        runCatching {
            cls("org.lwjgl.glfw.CallbackBridge")
                .getMethod(
                    "sendMouseButton",
                    Int::class.javaPrimitiveType,
                    Boolean::class.javaPrimitiveType,
                ).invoke(null, button, down)
        }.onSuccess {
            InputDebug.log("mouse button=$button down=$down grabbed=$cursorGrabbed")
        }.onFailure {
            InputDebug.log("sendMouseButton($button, $down) 失败：$it")
        }
    }

    fun sendScroll(context: Context, dy: Double) {
        ensureLoaded(context)
        cls("org.lwjgl.glfw.CallbackBridge")
            .getMethod("sendScroll", Double::class.javaPrimitiveType, Double::class.javaPrimitiveType)
            .invoke(null, 0.0, dy)
    }

    fun sendCursorDelta(context: Context, dx: Float, dy: Float) {
        ensureLoaded(context)
        ensureFocused()
        cls("org.lwjgl.glfw.CallbackBridge")
            .getMethod(
                "sendCursorDelta",
                Float::class.javaPrimitiveType,
                Float::class.javaPrimitiveType,
            ).invoke(null, dx, dy)
    }

    /**
     * GLFW 键码 → FCL 键码（Linux input-event code）。
     *
     * FCL 的 CallbackBridge.sendKeycode 会先拿参数去 LwjglKeycodeMap 查表，
     * 查不到就直接 return（键盘事件静默丢弃）。悬浮按键用的是 GLFW 码，
     * 不换算的表现就是「ESC 没反应、Space 变成往右走」。
     */
    private val glfwToFclKey = mapOf(
        // 数字行
        48 to 11, 49 to 2, 50 to 3, 51 to 4, 52 to 5,
        53 to 6, 54 to 7, 55 to 8, 56 to 9, 57 to 10,
        // 字母
        65 to 30, 66 to 48, 67 to 46, 68 to 32, 69 to 18,
        70 to 33, 71 to 34, 72 to 35, 73 to 23, 74 to 36,
        75 to 37, 76 to 38, 77 to 50, 78 to 49, 79 to 24,
        80 to 25, 81 to 16, 82 to 19, 83 to 31, 84 to 20,
        85 to 22, 86 to 47, 87 to 17, 88 to 45, 89 to 21, 90 to 44,
        // 标点 + 空格
        32 to 57, 39 to 40, 44 to 51, 45 to 12, 46 to 52,
        47 to 53, 59 to 39, 61 to 13, 91 to 26, 92 to 43,
        93 to 27, 96 to 41,
        // 功能键 / 控制键
        256 to 1, 257 to 28, 258 to 15, 259 to 14, 261 to 111,
        260 to 110,
        262 to 106, 263 to 105, 264 to 108, 265 to 103,
        266 to 104, 267 to 109, 268 to 102, 269 to 107,
        280 to 58, 281 to 70, 282 to 69, 283 to 99, 284 to 119,
        290 to 59, 291 to 60, 292 to 61, 293 to 62,
        294 to 63, 295 to 64, 296 to 65, 297 to 66, 298 to 67,
        299 to 68, 300 to 87, 301 to 88,
        340 to 42, 341 to 29, 342 to 56, 343 to 125, 344 to 54,
        345 to 97, 346 to 100, 347 to 126,
    )

    fun sendKey(context: Context, keyCode: Int, down: Boolean) {
        ensureLoaded(context)
        val fclKey = glfwToFclKey[keyCode] ?: keyCode
        try {
            cls("org.lwjgl.glfw.CallbackBridge")
                .getMethod(
                    "sendKeycode",
                    Int::class.javaPrimitiveType,
                    Char::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Boolean::class.javaPrimitiveType,
                ).invoke(null, fclKey, '\u0000', 0, 0, down)
        } catch (t: Throwable) {
            Log.e(TAG, "sendKey 失败 glfw=$keyCode fcl=$fclKey down=$down", t)
        }
    }

    /**
     * 发送一个可打印字符（FCL `CallbackBridge.sendChar` 同思路，聊天 / 命令
     * 输入用）。keycode 传 0、字符走 keychar 通道，由 lwjglx 转成 GLFW
     * charMods 事件；超出 ASCII 可打印区的字符（中文等）交由游戏侧输入法
     * 支持，这里直接丢弃。
     */
    fun sendChar(context: Context, char: Char) {
        if (char.code !in 32..126) return
        ensureLoaded(context)
        cls("org.lwjgl.glfw.CallbackBridge")
            .getMethod(
                "sendChar",
                Char::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            ).invoke(null, char, 0)
    }

    // ───────────────────────── 硬输入（物理键盘 / 鼠标） ─────────────────────────

    /**
     * 发一个物理按键，同时把可打印字符带进去。
     *
     * [sendKey] 的 char 位固定传 `\u0000`，物理键盘打字时游戏输入框就收不到
     * 字符（表现为「按得出方向键，打不出字」）。这里把 [keyChar] 一起送进
     * `sendKeycode`，lwjglx 才会转成 GLFW charMods 事件。
     *
     * [glfwCode] 不存在于 [glfwToFclKey] 时原样下发（FCL 侧查不到就直接丢弃，
     * 不会崩）。
     */
    fun sendKeyWithChar(
        context: Context,
        glfwCode: Int,
        keyChar: Char,
        down: Boolean,
    ) {
        ensureLoaded(context)
        ensureFocused()
        val fclKey = glfwToFclKey[glfwCode] ?: glfwCode
        runCatching {
            cls("org.lwjgl.glfw.CallbackBridge")
                .getMethod(
                    "sendKeycode",
                    Int::class.javaPrimitiveType,
                    Char::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    Boolean::class.javaPrimitiveType,
                ).invoke(null, fclKey, keyChar, 0, 0, down)
        }.onFailure {
            Log.e(TAG, "sendKeyWithChar 失败 glfw=$glfwCode fcl=$fclKey down=$down", it)
        }
    }

    /**
     * 清空 native 侧按住的输入状态（切后台 / 拔掉键鼠时用）。
     *
     * 不做的话「按住 W 切后台」回来 W 还压着，人物一直往前走。
     */
    fun resetNativeInput(context: Context) {
        runCatching {
            ensureLoaded(context)
            val cb = cls("org.lwjgl.glfw.CallbackBridge")
            runCatching { cb.getMethod("nativeResetInputState").invoke(null) }
                .onFailure { cb.getMethod("resetInputState").invoke(null) }
        }.onFailure { Log.w(TAG, "重置输入状态失败", it) }
    }

    // ───────────────────────── 窗口绑定（切后台回来黑屏的修复入口） ─────────────────────────

    /**
     * 把**当前**的 Surface 重新交给 native 桥。
     *
     * 安卓上 Activity 一进后台，SurfaceView 的 surface 就被 SurfaceFlinger 回收；
     * 回到前台时系统给的是一个**全新的** ANativeWindow。native 侧还握着旧
     * window 的话，`eglSwapBuffers` 会一路返回 `EGL_BAD_NATIVE_WINDOW`、
     * EGL 上下文随之丢失 —— 表现就是「游戏还在跑、声音还在，但画面全黑」。
     * 只调 `setSurfaceDestroyed(false)` 恢复渲染是不够的，**必须**把新 window
     * 重新绑回去。
     *
     * 两条路径都试（失败一律忽略，不改变原有行为）：
     *  - `CallbackBridge.setupBridgeWindow`：非 SDL 渲染器走的通用桥，native 里
     *    就是 `ANativeWindow_fromSurface` 换掉桥接窗口；
     *  - `SdlBridge.registerSurface`：FCL 新版 SDL 渲染路径的重新注册入口。
     */
    fun rebindSurface(
        context: Context,
        activity: Activity?,
        parent: android.view.ViewGroup?,
        surface: Surface?,
    ): Boolean {
        val s = surface ?: return false
        if (!s.isValid) return false
        ensureLoaded(context)
        var bound = false
        runCatching {
            cls("com.tungsten.fcl.game.sdl.SdlBridge")
                .getMethod(
                    "registerSurface",
                    Activity::class.java,
                    Surface::class.java,
                    android.view.ViewGroup::class.java,
                ).invoke(null, activity, s, parent)
            bound = true
            Log.i(TAG, "SDL：surface 已重新注册")
        }.onFailure { Log.w(TAG, "SdlBridge.registerSurface 不可用", it) }
        runCatching {
            cls("org.lwjgl.glfw.CallbackBridge")
                .getMethod("setupBridgeWindow", Object::class.java)
                .invoke(null, s)
            bound = true
            Log.i(TAG, "CallbackBridge：桥接窗口已重新绑定")
        }.onFailure { Log.w(TAG, "setupBridgeWindow 不可用", it) }
        return bound
    }

    /** surface 即将被销毁：先让 SDL 侧开始收尾，再挂起渲染。 */
    fun beginSurfaceDestroy(context: Context, surface: Surface?) {
        val s = surface ?: return
        runCatching {
            ensureLoaded(context)
            cls("com.tungsten.fcl.game.sdl.SdlBridge")
                .getMethod("beginSurfaceDestroy", Object::class.java, Surface::class.java)
                .invoke(null, null, s)
        }.onFailure { Log.w(TAG, "SdlBridge.beginSurfaceDestroy 不可用", it) }
    }

    /**
     * 回前台后强制游戏重画一帧。
     *
     * 即使 window 已经重新绑定，Minecraft 仍可能停在「窗口不可见」的分支里
     * 不渲染。这里把该补的信号全补一遍：native 屏幕尺寸 → GLFW
     * framebuffer-size 事件 → GLFW window-size 事件 → 窗口可见 / 非最小化 /
     * 聚焦 / 悬停。全部幂等，重复调用无害。
     */
    fun forceRefresh(context: Context, bridge: Any?, width: Int, height: Int) {
        ensureLoaded(context)
        // nativeSendScreenSize 在 FCL dex 里是跨 ABI 的 @CriticalNative 私有方法，
        // getMethod（只查 public）找不到，必须走 declared + isAccessible。
        runCatching {
            cls("org.lwjgl.glfw.CallbackBridge")
                .getDeclaredMethod(
                    "nativeSendScreenSize",
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                ).apply { isAccessible = true }
                .invoke(null, width, height)
        }.onFailure { Log.w(TAG, "nativeSendScreenSize 失败", it) }
        updateWindowSize(context, bridge, width, height)
        setWindowAttrib(GLFW_VISIBLE, 1)
        setWindowAttrib(GLFW_ICONIFIED, 0)
        setWindowAttrib(GLFW_FOCUSED, 1)
        setWindowAttrib(GLFW_HOVERED, 1)
    }
}
