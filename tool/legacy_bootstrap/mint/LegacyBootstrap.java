package mint;

import java.io.File;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.List;

/**
 * 让 launchwrapper 1.5（远古版 a/b/1.5 用的 wrapper）能在 Java 9+ 上启动。
 *
 * launchwrapper 的 `Launch` 构造函数会把「自己的」ClassLoader 强转成
 * URLClassLoader；JDK 9+ 的系统 ClassLoader 是 AppClassLoader，不是
 * URLClassLoader，于是直接 ClassCastException（Android 上 JRE17 必现）。
 *
 * 这里把 launchwrapper.Launch 装进一个自建的 URLClassLoader（URL 来自
 * java.class.path），它的 classloader 就是 URLClassLoader，强转通过。
 */
public final class LegacyBootstrap {
    private LegacyBootstrap() {
    }

    public static void main(String[] args) throws Exception {
        String mainClass = args.length > 0
                ? args[0]
                : "net.minecraft.launchwrapper.Launch";
        String[] gameArgs = new String[Math.max(0, args.length - 1)];
        if (args.length > 1) {
            System.arraycopy(args, 1, gameArgs, 0, args.length - 1);
        }

        String classpath = System.getProperty("java.class.path", "");
        List<URL> urls = new ArrayList<URL>();
        for (String entry : classpath.split(File.pathSeparator)) {
            if (entry.isEmpty()) continue;
            try {
                urls.add(new File(entry).toURI().toURL());
            } catch (Exception ignored) {
                // 无效条目直接跳过
            }
        }
        // 父加载器用平台加载器（不是 AppClassLoader），避免 Launch 再次
        // 走系统类加载器；JDK 8 上 getParent() 也可能是 null，URLClassLoader
        // 接受 null 作为 bootstrap parent。
        ClassLoader platform = ClassLoader.getSystemClassLoader().getParent();
        URLClassLoader loader = new URLClassLoader(
                urls.toArray(new URL[0]), platform);
        Thread.currentThread().setContextClassLoader(loader);
        Class<?> clazz = Class.forName(mainClass, true, loader);
        Method main = clazz.getDeclaredMethod("main", String[].class);
        main.setAccessible(true);
        main.invoke(null, (Object) gameArgs);
    }
}
