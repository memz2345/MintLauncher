package dev.mint.mint

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.Inflater

/**
 * 按需从 FCL 的发布 APK 里取一份 JRE（默认 Java 25），不整包下载。
 *
 * 背景：Mint 随包只带 jre8/17/21；Minecraft 26.x 的版本 JSON 已经要求
 * Java 25，直接启动会被 JRE 选择器挡下。让用户为了一个 JRE 去下 300MB
 * 的 FCL APK 太蠢，所以这里用 HTTP Range：
 *
 *  1. 取 APK 尾部 EOCD → 中央目录（几 MB）；
 *  2. 在中央目录里找到 `assets/app_runtime/java/jreN/...` 三个 entry；
 *  3. 只 Range 下载这几个 entry 的压缩数据并解压成 tar.xz；
 *  4. 交给 [FclRuntime.installJreFromArchives] 解压 + patchJava。
 *
 * 只信任 GitHub Releases 的 HTTPS；下载内容与 FCL 官方 APK 一致（GPL-3.0，
 * 见 assets/fcl/NOTICE.txt）。
 */
object JreDownloader {
    private const val TAG = "MintJre"

    /** 与随包 FCL 运行时同版本；新版 FCL 的 APK 结构一致，换 URL 即可。 */
    private const val APK_URL =
        "https://github.com/FCL-Team/FoldCraftLauncher/releases/download/" +
            "1.3.4.3/FCL-release-1.3.4.3-all.apk"

    private const val EOCD_SIG = 0x06054b50
    private const val CD_SIG = 0x02014b50
    private const val LOCAL_SIG = 0x04034b50
    private const val ZIP64_EOCD_SIG = 0x06064b50
    private const val ZIP64_LOCATOR_SIG = 0x07064b50

    private const val EOCD_MAX = 22 + 0xFFFF
    private const val MAX_CENTRAL_DIR = 32 * 1024 * 1024

    data class Progress(val phase: String, val fraction: Double, val detail: String)

    class CancelledException : IOException("已取消")

    @Volatile private var cancelled = false
    @Volatile private var running = false
    @Volatile private var activeConnection: HttpURLConnection? = null

    fun cancel() {
        cancelled = true
        runCatching { activeConnection?.disconnect() }
    }

    fun isRunning(): Boolean = running

    /**
     * 下载并安装 [major]。进度回调在调用线程（后台线程）触发，宿主自己
     * 切主线程再发 MethodChannel。
     */
    fun downloadAndInstall(
        context: Context,
        major: Int,
        onProgress: (Progress) -> Unit,
    ): Map<String, Any?> {
        synchronized(this) {
            if (running) throw IllegalStateException("已有 Java 下载任务在运行")
            running = true
        }
        cancelled = false
        val tempDir = File(context.cacheDir, "jre-download/jre$major")
        try {
            require(major in FclRuntime.JAVA_MAJORS) { "不支持的 Java 大版本：$major" }
            val abi = FclRuntime.deviceAbi(context)
            val arch = if (abi == "arm64-v8a") "arm64" else "x86_64"
            val prefix = "assets/app_runtime/java/jre$major"
            val wanted = listOf(
                "$prefix/bin-$arch.tar.xz",
                "$prefix/universal.tar.xz",
                "$prefix/version",
            )

            onProgress(Progress("index", 0.01, "读取 FCL 发布包目录"))
            val apkSize = remoteSize()
            checkCancelled()
            val entries = readCentralDirectory(apkSize, wanted)
            val totalBytes = entries.sumOf { it.compressedSize }.coerceAtLeast(1L)

            tempDir.deleteRecursively()
            tempDir.mkdirs()
            var done = 0L
            val files = mutableListOf<File>()
            for (entry in entries) {
                checkCancelled()
                val name = entry.name.substringAfterLast('/')
                val out = File(tempDir, name)
                downloadEntry(entry, out) { delta ->
                    done += delta
                    val fraction = 0.05 + 0.85 * (done.toDouble() / totalBytes)
                    onProgress(Progress("download", fraction, "下载 $name"))
                }
                files += out
            }
            checkCancelled()
            onProgress(Progress("extract", 0.92, "解压 Java $major"))
            val home = FclRuntime.installJreFromArchives(
                context = context,
                major = major,
                binTarXz = files[0],
                universalTarXz = files[1],
                versionFile = files[2],
            ) { phase -> onProgress(Progress("extract", 0.94, phase)) }
            tempDir.deleteRecursively()
            onProgress(Progress("done", 1.0, "Java $major 已安装"))
            return mapOf("major" to major, "home" to home)
        } catch (t: Throwable) {
            runCatching { tempDir.deleteRecursively() }
            if (cancelled) throw CancelledException()
            throw t
        } finally {
            running = false
            activeConnection = null
        }
    }

    // ───────────────────────── HTTP Range ─────────────────────────

    private fun openRange(start: Long, endInclusive: Long): InputStream {
        checkCancelled()
        val conn = (URL(APK_URL).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 45_000
            instanceFollowRedirects = true
            setRequestProperty("Accept-Encoding", "identity")
            setRequestProperty("Range", "bytes=$start-$endInclusive")
        }
        activeConnection = conn
        val code = conn.responseCode
        if (code != HttpURLConnection.HTTP_OK && code != 206) {
            runCatching { conn.disconnect() }
            throw IOException("HTTP $code（$start-$endInclusive）")
        }
        if (code == HttpURLConnection.HTTP_OK && endInclusive - start + 1 < contentLengthOf(conn)) {
            // 服务器忽略了 Range，会把整个 APK 灌过来 —— 不能要。
            runCatching { conn.disconnect() }
            throw IOException("服务器不支持 Range（HTTP 200）")
        }
        return conn.inputStream
    }

    private fun contentLengthOf(conn: HttpURLConnection): Long =
        conn.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L

    private fun remoteSize(): Long {
        val conn = (URL(APK_URL).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 20_000
            instanceFollowRedirects = true
            setRequestProperty("Accept-Encoding", "identity")
            setRequestProperty("Range", "bytes=0-0")
        }
        activeConnection = conn
        try {
            val code = conn.responseCode
            if (code !in listOf(HttpURLConnection.HTTP_OK, 206)) {
                throw IOException("HTTP $code")
            }
            val range = conn.getHeaderField("Content-Range")
            range?.substringAfterLast('/')?.toLongOrNull()?.let { if (it > 0) return it }
            val length = contentLengthOf(conn)
            if (length > 0) return length
            throw IOException("无法确定 APK 大小")
        } finally {
            runCatching { conn.disconnect() }
            activeConnection = null
        }
    }

    private fun fetchRange(start: Long, endInclusive: Long): ByteArray {
        if (endInclusive < start) return ByteArray(0)
        val size = (endInclusive - start + 1)
        require(size <= MAX_CENTRAL_DIR) { "Range 过大：$size" }
        val out = ByteArray(size.toInt())
        openRange(start, endInclusive).use { input ->
            var read = 0
            while (read < out.size) {
                checkCancelled()
                val n = input.read(out, read, out.size - read)
                if (n < 0) break
                read += n
            }
            if (read != out.size) throw IOException("Range 读取不完整：$read/${out.size}")
        }
        return out
    }

    // ───────────────────────── ZIP 解析 ─────────────────────────

    private data class ZipEntryInfo(
        val name: String,
        val method: Int,
        val compressedSize: Long,
        val uncompressedSize: Long,
        val localHeaderOffset: Long,
    )

    private fun readCentralDirectory(apkSize: Long, wanted: List<String>): List<ZipEntryInfo> {
        val tailLen = minOf(apkSize, EOCD_MAX.toLong())
        val tailStart = apkSize - tailLen
        val tail = fetchRange(tailStart, apkSize - 1)
        var eocd = -1
        var i = tail.size - 22
        while (i >= 0) {
            if (u32(tail, i) == EOCD_SIG.toLong()) {
                eocd = i
                break
            }
            i--
        }
        if (eocd < 0) throw IOException("APK 里找不到 EOCD")
        var entries = u16(tail, eocd + 10).toLong()
        var cdSize = u32(tail, eocd + 12)
        var cdOffset = u32(tail, eocd + 16)

        if (entries == 0xFFFFL || cdSize == 0xFFFFFFFFL || cdOffset == 0xFFFFFFFFL) {
            val eocdAbs = tailStart + eocd
            if (eocdAbs >= 20) {
                val locator = fetchRange(eocdAbs - 20, eocdAbs - 1)
                if (u32(locator, 0) == ZIP64_LOCATOR_SIG.toLong()) {
                    val z64Offset = u64(locator, 8)
                    val z64 = fetchRange(z64Offset, z64Offset + 55)
                    if (u32(z64, 0) == ZIP64_EOCD_SIG.toLong()) {
                        entries = u64(z64, 32)
                        cdSize = u64(z64, 40)
                        cdOffset = u64(z64, 48)
                    }
                }
            }
        }
        if (cdSize <= 0 || cdSize > MAX_CENTRAL_DIR) {
            throw IOException("中央目录大小异常：$cdSize")
        }
        val cd = fetchRange(cdOffset, cdOffset + cdSize - 1)
        val found = mutableMapOf<String, ZipEntryInfo>()
        var pos = 0
        val maxEntries = entries.coerceAtMost(500_000L).toInt()
        for (index in 0 until maxEntries) {
            if (pos + 46 > cd.size) break
            if (u32(cd, pos) != CD_SIG.toLong()) break
            val method = u16(cd, pos + 10)
            var compressed = u32(cd, pos + 20)
            var uncompressed = u32(cd, pos + 24)
            val nameLen = u16(cd, pos + 28)
            val extraLen = u16(cd, pos + 30)
            val commentLen = u16(cd, pos + 32)
            var localOffset = u32(cd, pos + 42)
            val name = String(cd, pos + 46, nameLen, Charsets.UTF_8)
            if (name in wanted) {
                // ZIP64 扩展字段：顺序是 uncompressed / compressed / offset，
                // 只有对应基础字段是 0xFFFFFFFF 时才出现。
                if (compressed == 0xFFFFFFFFL || uncompressed == 0xFFFFFFFFL ||
                    localOffset == 0xFFFFFFFFL
                ) {
                    var e = pos + 46 + nameLen
                    val extraEnd = e + extraLen
                    while (e + 4 <= extraEnd) {
                        val id = u16(cd, e)
                        val len = u16(cd, e + 2)
                        if (id == 0x0001) {
                            var p = e + 4
                            if (uncompressed == 0xFFFFFFFFL) {
                                uncompressed = u64(cd, p); p += 8
                            }
                            if (compressed == 0xFFFFFFFFL) {
                                compressed = u64(cd, p); p += 8
                            }
                            if (localOffset == 0xFFFFFFFFL) {
                                localOffset = u64(cd, p)
                            }
                        }
                        e += 4 + len
                    }
                }
                found[name] = ZipEntryInfo(
                    name = name,
                    method = method,
                    compressedSize = compressed,
                    uncompressedSize = uncompressed,
                    localHeaderOffset = localOffset,
                )
            }
            pos += 46 + nameLen + extraLen + commentLen
            if (found.size == wanted.size) break
        }
        return wanted.map { name ->
            found[name] ?: throw IOException("FCL 包里没有 $name")
        }
    }

    private fun downloadEntry(
        entry: ZipEntryInfo,
        outFile: File,
        onBytes: (Long) -> Unit,
    ) {
        val header = fetchRange(entry.localHeaderOffset, entry.localHeaderOffset + 29)
        if (u32(header, 0) != LOCAL_SIG.toLong()) throw IOException("本地文件头损坏：${entry.name}")
        val nameLen = u16(header, 26)
        val extraLen = u16(header, 28)
        val dataStart = entry.localHeaderOffset + 30 + nameLen + extraLen
        if (entry.compressedSize <= 0) {
            outFile.writeBytes(ByteArray(0))
            return
        }
        val dataEnd = dataStart + entry.compressedSize - 1
        openRange(dataStart, dataEnd).use { input ->
            when (entry.method) {
                0 -> outFile.outputStream().buffered().use { output ->
                    copyStream(input, output) { delta -> onBytes(delta) }
                }
                8 -> inflateRaw(input, outFile) { delta -> onBytes(delta) }
                else -> throw IOException("不支持的压缩方式 ${entry.method}：${entry.name}")
            }
        }
        if (entry.uncompressedSize > 0 && outFile.length() != entry.uncompressedSize) {
            throw IOException(
                "解压大小不符：${entry.name} ${outFile.length()}/${entry.uncompressedSize}",
            )
        }
    }

    private fun copyStream(
        input: InputStream,
        output: java.io.OutputStream,
        onBytes: (Long) -> Unit,
    ) {
        val buf = ByteArray(256 * 1024)
        while (true) {
            checkCancelled()
            val n = input.read(buf)
            if (n < 0) break
            output.write(buf, 0, n)
            onBytes(n.toLong())
        }
    }

    private fun inflateRaw(input: InputStream, outFile: File, onBytes: (Long) -> Unit) {
        val inflater = Inflater(true)
        val inBuf = ByteArray(256 * 1024)
        val outBuf = ByteArray(256 * 1024)
        var finished = false
        try {
            outFile.outputStream().buffered().use { output ->
                while (true) {
                    checkCancelled()
                    if (inflater.needsInput()) {
                        val n = input.read(inBuf)
                        if (n < 0) break
                        inflater.setInput(inBuf, 0, n)
                        onBytes(n.toLong())
                    }
                    val produced = inflater.inflate(outBuf)
                    if (produced > 0) output.write(outBuf, 0, produced)
                    if (inflater.finished()) {
                        finished = true
                        break
                    }
                    if (produced == 0 && inflater.needsDictionary()) {
                        throw IOException("deflate 需要字典")
                    }
                }
            }
        } finally {
            inflater.end()
        }
        if (!finished) throw IOException("deflate 数据不完整")
    }

    // ───────────────────────── 小端读取 ─────────────────────────

    private fun u16(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)

    private fun u32(b: ByteArray, off: Int): Long =
        (b[off].toLong() and 0xFF) or
            ((b[off + 1].toLong() and 0xFF) shl 8) or
            ((b[off + 2].toLong() and 0xFF) shl 16) or
            ((b[off + 3].toLong() and 0xFF) shl 24)

    private fun u64(b: ByteArray, off: Int): Long {
        var value = 0L
        for (i in 7 downTo 0) {
            value = (value shl 8) or (b[off + i].toLong() and 0xFF)
        }
        return value
    }

    private fun checkCancelled() {
        if (cancelled) throw CancelledException()
    }
}
