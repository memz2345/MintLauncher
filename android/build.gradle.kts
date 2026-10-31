allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 部分插件（desktop_drop 等）模板里的 compileSdk 还是 33，会被 AndroidX
// 的新依赖校验拦下；统一抬到 36，避免逐个改 pub cache 里的插件工程。
// 必须在 evaluationDependsOn(":app") 之前注册 afterEvaluate，否则工程
// 已经被提前求值，注册会直接抛错。
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.LibraryExtension>()?.apply {
            compileSdk = 36
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
