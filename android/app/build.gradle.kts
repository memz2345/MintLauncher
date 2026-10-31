plugins {
    id("com.android.application")
    // 游戏内悬浮窗 / 弹窗都是 Compose；版本必须与 settings.gradle.kts 的 Kotlin 一致。
    id("org.jetbrains.kotlin.plugin.compose")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/**
 * 要打进包的 ABI。默认双 ABI（真机 arm64 + 模拟器 x86_64）。
 *
 * 想要**纯 arm64 包**时用环境变量覆盖：
 *   MINT_ABIS=arm64-v8a flutter build apk --target-platform android-arm64
 *
 * 光给 flutter 传 `--target-platform` 不够：那只决定 Flutter 引擎自己的
 * `libflutter.so` / `libapp.so`，本项目 jniLibs 里那批 FCL / 渲染器 / JNA 的
 * so（x86_64 有 37 个，百兆级）照样会被打进去，AAR 带的 armeabi-v7a 也是。
 */
fun mintAbis(): List<String> =
    System.getenv("MINT_ABIS")
        ?.split(',', ' ')
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?: listOf("arm64-v8a", "x86_64")

android {
    namespace = "dev.mint.mint"
    // targetSdk 37（用户要求）；compileSdk 需 >= targetSdk
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    defaultConfig {
        applicationId = "dev.mint.mint"
        // FCL 运行时（JRE8 / LWJGL3）要求 26+
        minSdk = 26
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // 模拟器 x86_64 + 真机 arm64（FCL 运行时资源按 ABI 分目录提取）。
            // 单个 ABI 时用 MINT_ABIS 覆盖，见 [mintAbis]。
            abiFilters += mintAbis()
        }
    }

    packaging {
        jniLibs {
            // JRE8 的 libunpack200.so 需要作为可执行文件解出来（FCL 同款）。
            useLegacyPackaging = true
            // 多个 AAR 都带 libc++_shared.so，得 pickFirst 消冲突。
            // 注意别写成 `**/libc++_shared.so`：pickFirst 优先于 excludes，
            // 那个通配会把下面要排除的 ABI 也捞回来（实测漏掉
            // lib/x86_64/libc++_shared.so）。所以按保留的 ABI 逐个写死。
            mintAbis().forEach { pickFirsts += "lib/$it/libc++_shared.so" }
            // ndk.abiFilters 管不到 jniLibs / AAR 里其它 ABI 的 so（实测打
            // arm64 包时 x86_64 和 armeabi-v7a 仍会被塞进 APK）。这里按 APK
            // 内的路径再显式排除一次，才是真正的「纯 arm64」。
            val keep = mintAbis()
            listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64", "mips", "mips64")
                .filter { it !in keep }
                .forEach { excludes += "lib/$it/**" }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // FCL 运行时是外置 dex（InMemoryDexClassLoader）+ 大量反射，
            // R8 会把 kotlinx.coroutines 之类「本工程没直接引用」的依赖裁掉，
            // 启动游戏时 PluginManager 直接 NoClassDefFoundError。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 与 local2api 同一套（Compose 1.12.1 / Kotlin 2.4.10），Gradle 缓存已热。
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    // M3E（Material 3 Expressive）的 LoadingIndicator：BOM 2026.09.00 里的
    // material3 1.4 还只有 token，没有这个 composable，显式抬到 1.5 beta。
    // 只影响游戏内 Compose 浮层，Flutter 侧不参与。
    implementation("androidx.compose.material3:material3:1.5.0-beta02")
    implementation("androidx.compose.material:material-icons-extended")

    // 原生液态玻璃底栏（local2api 同款 kyant Backdrop）：Compose 1.12 的
    // 实时背景抓取 / 折射 / 高光。
    implementation("io.github.kyant0:backdrop:2.0.1")
    implementation("io.github.kyant0:shapes:1.2.1")

    // ComposeView 宿主在 FlutterActivity 的视图树上没有 Lifecycle/SavedState owner。
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.savedstate:savedstate-ktx:1.2.1")

    // Android 12+ 原生 SplashScreen（旧版本由兼容库回填）。
    implementation("androidx.core:core-splashscreen:1.0.1")
}

flutter {
    source = "../.."
}
