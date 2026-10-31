import 'downloader.dart';

/// 官方版本清单（piston-meta / BMCLAPI 镜像同构）。
class VersionManifest {
  VersionManifest({required this.latest, required this.versions});

  final Latest latest;
  final List<ManifestVersion> versions;

  static Future<VersionManifest> fetch(Downloader dl) async {
    // BMCLAPI 有自己的清单端点（内容与官方同构，但里面的 version url 也指向镜像）
    final url = switch (dl.mirror) {
      Mirror.official => kOfficialManifestUrl,
      _ => kBmclManifestUrl,
    };
    try {
      final json = await dl.getJson(url);
      return _parse(json);
    } catch (_) {
      if (dl.mirror == Mirror.auto) {
        // auto：清单本体也回退官方
        return _parse(await dl.getJson(kOfficialManifestUrl));
      }
      rethrow;
    }
  }

  static const kOfficialManifestUrl =
      'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
  static const kBmclManifestUrl =
      'https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json';

  static VersionManifest _parse(Map<String, dynamic> json) => VersionManifest(
    latest: Latest(
      release: (json['latest']?['release'] as String?) ?? '',
      snapshot: (json['latest']?['snapshot'] as String?) ?? '',
    ),
    versions: [
      for (final v in (json['versions'] as List? ?? const []))
        ManifestVersion(
          id: (v['id'] as String?) ?? '',
          url: (v['url'] as String?) ?? '',
          type: (v['type'] as String?) ?? 'release',
          releaseTime: (v['releaseTime'] as String?) ?? '',
          sha1: v['sha1'] as String?,
        ),
    ],
  );

  ManifestVersion? find(String id) {
    for (final v in versions) {
      if (v.id == id) return v;
    }
    return null;
  }
}

class Latest {
  const Latest({required this.release, required this.snapshot});
  final String release;
  final String snapshot;
}

class ManifestVersion {
  const ManifestVersion({
    required this.id,
    required this.url,
    required this.type,
    required this.releaseTime,
    this.sha1,
  });

  final String id;
  final String url;
  final String type; // release / snapshot / old_beta / old_alpha
  final String releaseTime;
  final String? sha1;

  bool get isRelease => type == 'release';
  bool get isSnapshot => type == 'snapshot';
  bool get isOld => type == 'old_beta' || type == 'old_alpha';
}
