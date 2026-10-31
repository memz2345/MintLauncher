// Mint「云雾前景」片元着色器。
//
// 视觉参考：Kimi（月之暗面）K3.1 Pro 博客页头的「液态云雾」——白色柔雾团里
// 带大理石漩涡等高线，缓慢漂移/形变（https://www.kimi.ai/blog/kimi-k3-1-pro，
// 其 layer-1/2/3.png 就是把云雾质感装进字形/团块剪影的几层）。Kimi 的素材
// 不能入库，这里程序化复现同款观感：
//
//  1. fbm + 两层 domain warping（IQ 的经典配方）：对 fbm 的采样坐标先做
//     两次「fbm 扭曲」，输出的等值线天然带大理石漩涡——这正是 Kimi
//     layer-1 那种「雾里藏纹」的来源；
//  2. 双层 blob 密度场当云的「形状」：远层大而慢、近层小而快，叠出视差；
//     云团水平方向 fract 回绕，跨边探进探出，永远不会「飘出画面」；
//  3. sin(v) 等值线刻纹 + 时间慢滑，让雾内部有流动的大理石纹；
//  4. 上下左右羽化 + 上半屏偏置：云雾是氛围不是主角，不给内容压暗角。
//
// 本 shader 是 **Paint 着色器**（不是 backdrop filter）：widget 侧把画面
// 光栅到半分辨率离屏图再放大绘制（云是极低频图像，肉眼无损），所以
// uSize 是「本次实际渲染的画布尺寸」而非屏幕尺寸，不需要 gles_compat 的
// 背景纹理翻转处理。

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;     // 0,1  渲染画布尺寸（px，可能是半分辨率）
uniform float uTime;    // 2    演化时间（秒；Dart 侧按速度系数累加）
uniform float uBlobs;   // 3    近层云团数量（支持小数，调密度时渐隐渐现）
uniform float uSeed;    // 4    种子（换一批云团布局）
uniform float uOpacity; // 5    总不透明度（深浅主题换算在 Dart 侧做）
uniform float uShade;   // 6    灰度深度 0..1（浅色主题要更深才在白底上显形）
uniform float uTopBias; // 7    上半屏偏置 0..1（云雾飘在上半屏为主）
uniform float uDrift;   // 8    漂移/演化速度倍率

out vec4 fragColor;

// ── hash / value noise / fbm ────────────────────────────────────────────
// hash12 是 Dave Hoskins 的 2D hash（无纹理依赖、桌面与移动一致）。

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// 平滑值噪声（quintic 太贵，smoothstep 插值对低频雾足够）。
float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 5 阶 fbm：每阶旋转矩阵避免轴对齐的格状纹理，lacunarity 2.02 破坏周期感。
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
  for (int i = 0; i < 5; i++) {
    v += a * vnoise(p);
    p = rot * p * 2.02 + vec2(7.3, 11.7);
    a *= 0.5;
  }
  return v;
}

// ── 云团密度场 ──────────────────────────────────────────────────────────
// 第 i 个云团的锚点/半径全部由 hash 确定（种子换了就换一批布局），随时间
// 水平回绕漂移 + 竖直轻微呼吸。count 支持小数：第 floor(count) 个云团以
// 小数部分做强度，设置滑杆拖密度时云团是「渐隐渐现」而不是硬蹦。
//
// 用固定 8 次的循环 + 权重清零代替 break/continue：ANGLE 的 GLSL→HLSL
// 翻译对动态循环边界更挑剔，常量循环展开最稳。
float blobField(
  vec2 uv,
  float aspect,
  float count,
  float radMin,
  float radMax,
  float speed,
  float phase
) {
  float m = 0.0;
  for (int i = 0; i < 8; i++) {
    float fi = float(i);
    float w = clamp(count - fi, 0.0, 1.0);
    float t = uTime * speed * uDrift + fi * 17.31 + phase;
    float ax = hash12(vec2(fi * 7.31 + uSeed, 1.7));
    float ay = mix(0.10, 0.86, hash12(vec2(fi * 3.97 + uSeed, 4.3)));
    float x = fract(ax + t * 0.10); // 横向慢漂，fract 回绕
    float y = ay + 0.05 * sin(t * 0.6 + fi * 2.1);
    float rad = mix(radMin, radMax, hash12(vec2(fi + uSeed, 9.9)));
    vec2 d = uv - vec2(x, y);
    d.x -= floor(d.x + 0.5); // 取「最短回绕距离」，跨边云团从另一侧探进来
    d *= vec2(aspect, 1.0);
    m += w * exp(-dot(d, d) / (rad * rad));
  }
  return m;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize; // 0..1
  float aspect = uSize.x / max(uSize.y, 1.0);

  // 噪声域：等比映射（噪声不随窗口宽高比变形）+ 慢速演化偏移。
  // t 同时喂给扭曲层与刻纹层，雾的「纹」和「形」以不同速率演化。
  vec2 p = uv * vec2(aspect, 1.0) * 3.2 + uSeed * 13.7;
  float t = uTime * uDrift;
  vec2 t1 = vec2(t * 0.050, -t * 0.031);
  vec2 t2 = vec2(-t * 0.043, t * 0.024);

  // 两层域扭曲（IQ「Domain Warping」）：q 先扭一次，r 扭第二次，
  // fbm 等值线被拧出大理石漩涡。
  vec2 q = vec2(fbm(p + t1), fbm(p + vec2(5.2, 1.3) - t1));
  vec2 r = vec2(fbm(p + 3.0 * q + t2), fbm(p + 3.0 * q + vec2(8.3, 2.8) - t2));
  float v = fbm(p + 2.2 * r);

  // 双层云团：远层多而大而慢，近层少而小而快 —— 视差就来自这两层速度差。
  // 半径刻意收小（uv 单位）：太大时高斯互相糊成一片「白床单」，
  // 就没有「一朵一朵的云」了。
  float far = blobField(uv, aspect, uBlobs + 2.0, 0.13, 0.24, 0.020, 0.0);
  float near = blobField(uv, aspect, uBlobs, 0.08, 0.16, 0.048, 37.0);
  float field = 0.78 * far + 0.60 * near;

  // 上半屏偏置（Kimi 页头的云是氛围不是主角）+ 四边羽化。
  // 阈值抬高：只留云团核心，团与团之间露出底色。
  float vbias = mix(1.0, smoothstep(1.15, 0.05, uv.y), clamp(uTopBias, 0.0, 1.0));
  float edge = smoothstep(0.0, 0.10, uv.x) * smoothstep(1.0, 0.90, uv.x) *
               smoothstep(0.0, 0.10, uv.y) * smoothstep(1.0, 0.90, uv.y);
  float mask = smoothstep(0.22, 0.70, field) * vbias * edge;

  // 雾体：用噪声在雾里「挖洞」，让边缘破碎、内部有云洞而不是实心色块。
  float body = mask * smoothstep(0.34, 0.86, v + 0.30 * field - 0.16);

  // 大理石涡纹：v（加一点密度场让纹跟云走）的等值线被 sin 刻成明暗带，
  // 随时间极慢滑动 —— 静止截图像大理石，动起来像雾在内部翻涌。
  float contour = sin((v + 0.10 * field) * 22.0 - t * 0.35);
  float marble = 1.0 - uShade * 0.22 * smoothstep(0.2, 1.0, contour);

  // 颜色：v 高处近纯白，低处按 uShade 压出灰底（浅色主题靠这点灰在白底
  // 上显形；深色主题 shade 低，雾更纯白柔和）。涡纹同时压暗颜色，
  // 层内才有「雾在翻」的层次感。
  float alpha = uOpacity * body * (0.55 + 0.45 * v) * marble;
  vec3 col = mix(vec3(1.0 - uShade * 0.09), vec3(1.0), v) -
             uShade * 0.12 * smoothstep(0.3, 1.0, contour);

  // ⚠️ Flutter 运行时效果的输出约定是**预乘 alpha**（Skia/Impeller 一致）：
  // 直接输出 (直色, alpha) 会被当成 color>alpha 的非法预乘值，雾会整片
  // 变成不透明的白（第一版就栽在这 —— probe 截图整屏纯白才定位到）。
  fragColor = vec4(col * clamp(alpha, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
}
