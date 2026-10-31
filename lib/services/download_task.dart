/// 下载任务状态。与 PCL2「下载」页的任务队列一致：跑着 / 完成 / 失败 / 取消。
enum DownloadStatus {
  running,
  completed,
  failed,
  cancelled;

  bool get isActive => this == DownloadStatus.running;

  String get label => switch (this) {
    DownloadStatus.running => '下载中',
    DownloadStatus.completed => '已完成',
    DownloadStatus.failed => '失败',
    DownloadStatus.cancelled => '已取消',
  };
}

/// 一条下载任务（一次安装 / 一次运行时下载 / 一个模组文件）。
///
/// **纯 Dart、不依赖 Flutter**：downloader.dart 要被 `dart run` 的无头
/// 工具（tool/e2e_*）直接编译，Flutter 侧的队列 / 节流通知在
/// `download_center.dart`（它 re-export 本文件，旧 import 不用改）。
///
/// 数据是可变对象 + 中心化节流通知：真正的高频数字（字节数）每秒会跳几十
/// 次，逐次通知会把整棵树标脏，所以写入只改字段，由
/// [onNotify]（DownloadCenter 注入）统一按 100ms 节流通知。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    this.detail = '',
    void Function()? onCancel,
  }) : _onCancel = onCancel;

  final String id;

  /// 任务标题（「安装 1.20.4」「下载 JRE 21」）。
  String title;

  /// 当前阶段 / 当前文件。
  String detail;

  DownloadStatus status = DownloadStatus.running;

  /// 字节级进度（并发下载器按文件累加的分片大小）。
  int doneBytes = 0;
  int totalBytes = 0;

  /// 文件级进度（字节总数未知时兜底）。
  int doneFiles = 0;
  int totalFiles = 0;

  /// 失败的下载项数量。
  ///
  /// 关键：**失败也算「这一个跑完了」**（否则一条 64 并发里挂一个就把整批
  /// 卡死），但绝不能因此把整条任务显示成「已完成」—— 「显示已下载、实际还
  /// 有一大堆依赖没搞完」就是这么来的。调用方按这个数决定成功还是报错。
  int failedFiles = 0;

  /// 安装阶段的粗粒度进度（0..1）。非空时优先于字节进度 ——
  /// 版本安装大部分时间花在解压 / 校验，字节数不增长但阶段在推进。
  double? phaseProgress;

  /// 瞬时速度（字节/秒），按 1 秒滑窗算。
  double bytesPerSecond = 0;

  /// 取消回调：置下载器的 cancelled 标记（VoidCallback 的纯 Dart 写法）。
  void Function()? _onCancel;

  /// 取消回调（控制器把下载器的取消接上来时赋值）。
  set onCancel(void Function()? cb) => _onCancel = cb;

  /// 节流通知钩子：由 DownloadCenter 注入，headless 工具里为 null（静默）。
  void Function(DownloadTask task)? onNotify;

  String? error;

  final DateTime createdAt = DateTime.now();
  DateTime? finishedAt;

  DateTime _speedWindowStart = DateTime.now();
  int _speedWindowBytes = 0;

  bool get isActive => status.isActive;

  bool get cancelRequested => _cancelRequested;
  bool _cancelRequested = false;

  /// 0..1。未知总量时返回 null（进度条走 indeterminate）。
  double? get progress {
    final phase = phaseProgress;
    if (phase != null) return phase.clamp(0.0, 1.0);
    if (totalBytes > 0) return (doneBytes / totalBytes).clamp(0.0, 1.0);
    if (totalFiles > 0) return (doneFiles / totalFiles).clamp(0.0, 1.0);
    return null;
  }

  Duration? get remaining {
    final total = totalBytes;
    final p = progress;
    if (total <= 0 || p == null || bytesPerSecond <= 1) return null;
    final left = total * (1 - p);
    if (left <= 0) return null;
    final seconds = left / bytesPerSecond;
    if (seconds.isNaN || seconds.isInfinite || seconds > 86400) return null;
    return Duration(seconds: seconds.round());
  }

  /// 下载器铺好总量（一条任务的**第一批**）。之后每批用 [addPlan] 累加。
  void plan({required int files, required int bytes}) {
    totalFiles = files;
    totalBytes = bytes;
    doneFiles = 0;
    doneBytes = 0;
    failedFiles = 0;
    phaseProgress = null;
  }

  /// 又发现一批要下的东西（assets 索引解析完才知道有几万个文件、加载器装完
  /// 还要再补一批库）：**累加**总量而不是覆盖。
  ///
  /// 覆盖会让进度条在每一批开始时显示成 100%，然后又开始下一轮 —— 这就是
  /// 「幽灵下载」：看起来早下完了，实际依赖还排着队。
  void addPlan({required int files, required int bytes}) {
    if (files <= 0 && bytes <= 0) return;
    totalFiles += files;
    totalBytes += bytes;
    // 阶段进度不能把新增的下载量「吃掉」：清掉它，让字节/文件数说话。
    phaseProgress = null;
    notify();
  }

  /// 开始下一个文件。
  void startFile(String name, {int? size}) {
    detail = name;
    // 单文件下载（Modrinth 直装）不走 runBatch，没有 plan()：
    // 用文件大小兜一下总量，进度条才有确定值。
    if (totalBytes == 0 && size != null && size > 0) totalBytes = size;
    notify();
  }

  void addBytes(int delta) {
    if (delta <= 0) return;
    doneBytes += delta;
    _speedWindowBytes += delta;
    final now = DateTime.now();
    final elapsed = now.difference(_speedWindowStart);
    if (elapsed >= const Duration(milliseconds: 600)) {
      bytesPerSecond = _speedWindowBytes / (elapsed.inMilliseconds / 1000.0);
      _speedWindowBytes = 0;
      _speedWindowStart = now;
    }
    notify();
  }

  /// 回滚一次失败尝试已计入的字节（重试的分片不算第二遍下载量）。
  void undoBytes(int delta) {
    if (delta <= 0) return;
    doneBytes -= delta;
    if (doneBytes < 0) doneBytes = 0;
    _speedWindowBytes -= delta;
    if (_speedWindowBytes < 0) _speedWindowBytes = 0;
    notify();
  }

  void fileDone(String name) {
    doneFiles++;
    detail = name;
    notify();
  }

  /// 某一项失败：计数与 [fileDone] 分开，进度照走，但「已完成」不成立。
  void fileFailed(String name) {
    doneFiles++;
    failedFiles++;
    detail = name;
    notify();
  }

  /// 安装阶段的进度（来自 VersionInstaller 的 InstallProgress）。
  ///
  /// 只许前进不许后退：阶段切换时（assetIndex 0.1 → natives 0.2）如果直接
  /// 覆盖，进度条会突然往回跳，看起来像「下完了又重下」。
  void setPhase(double fraction, String label) {
    final previous = phaseProgress;
    phaseProgress = previous == null
        ? fraction
        : (fraction > previous ? fraction : previous);
    if (label.isNotEmpty) detail = label;
    notify();
  }

  void complete({String? detail}) {
    if (!isActive) return;
    // 有失败项就按失败收尾：以前无条件置 completed，UI 于是打绿勾。
    if (failedFiles > 0) {
      fail(Exception('$failedFiles 个文件下载失败'));
      return;
    }
    status = DownloadStatus.completed;
    if (detail != null) this.detail = detail;
    phaseProgress = 1;
    finishedAt = DateTime.now();
    bytesPerSecond = 0;
    notify();
  }

  void fail(Object error) {
    if (!isActive) return;
    status = DownloadStatus.failed;
    this.error = '$error';
    finishedAt = DateTime.now();
    bytesPerSecond = 0;
    notify();
  }

  void cancel() {
    if (!isActive) return;
    _cancelRequested = true;
    _onCancel?.call();
    status = DownloadStatus.cancelled;
    finishedAt = DateTime.now();
    bytesPerSecond = 0;
    notify();
  }

  /// 通知中心（无中心时静默 —— headless 工具用）。
  void notify() => onNotify?.call(this);
}
