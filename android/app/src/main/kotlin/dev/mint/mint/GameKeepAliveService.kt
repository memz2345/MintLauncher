package dev.mint.mint

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 游戏后台保活的常驻通知。
 *
 * 跑在 `:game` 进程里，跟游戏 JVM 同生共死：它的唯一职责是让系统知道
 * 「这个进程还在干活」，别在用户切回启动器 / 桌面时把整局游戏回收掉。
 *
 * 通知上的「结束」直接发 [GameActivity.ACTION_STOP] 广播 —— 由游戏进程自己
 * 杀自己，比从外面 kill 可靠（不用猜 pid，也不受进程复活影响）。
 */
class GameKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "mint.game"
        private const val NOTIFICATION_ID = 0x4D43

        fun start(context: Context, subtitle: String) {
            val intent = Intent(context, GameKeepAliveService::class.java)
                .putExtra("subtitle", subtitle)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // 前台服务被系统拒绝（少见）也不该拖垮游戏启动。
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, GameKeepAliveService::class.java))
            } catch (_: Throwable) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val subtitle = intent?.getStringExtra("subtitle").orEmpty()
        startForeground(NOTIFICATION_ID, buildNotification(subtitle))
        // 不被系统「低内存时顺手杀掉」优先：START_STICKY 会在被杀后重建，
        // 但游戏进程本身没了就没意义，这里只用 NOT_STICKY 的语义反而更干净。
        return START_NOT_STICKY
    }

    private fun buildNotification(subtitle: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "游戏运行状态",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Minecraft 在后台运行时常驻显示"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, GameActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getBroadcast(
            this,
            1,
            Intent(GameActivity.ACTION_STOP).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Minecraft 正在运行")
            .setContentText(
                if (subtitle.isEmpty()) "点按返回游戏 · 可在此结束" else "$subtitle · 点按返回游戏",
            )
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setContentIntent(open)
            // 用旧的 addAction(int, ...) 而不是 Action.Builder(Icon?, ...)：
            // 后者传 null 图标在部分 ROM 上会 NPE。
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "结束游戏",
                stop,
            )
            .build()
    }
}
