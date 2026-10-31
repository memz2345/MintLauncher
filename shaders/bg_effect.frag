// Local2API - 关于页「效果背景」着色器。
// 移植自 InstallerX-Revived 的 OS3BgFrag.kt（AGSL，源自 compose-miuix-ui/miuix
// example 的效果背景）：4 个彩色光斑在归一化坐标里按 sin/cos 游走，Perlin 噪声
// 对混出的颜色做去饱和 + 提亮，最后叠一层梯度噪声抖动防色带。
//
// 与 AGSL 原版的差异（Flutter FragmentShader 的限制）：
// - uniform 数组不受支持，uPoints[4]/uPointsAnim[4]/uColors[4] 摊平成
//   uPoint0..3 / uPointsAnim0..3 / uColor0..3，下标连续无 padding；
// - 入口走 runtime_effect.glsl 的 FlutterFragCoord()，坐标语义与 AGSL 一致
//   （原点左上、y 向下），uv 的 1-y 翻转照搬。
//
// ⚠️ 必须声明 highp：AGSL 原版跑在设备 RuntimeShader 上，SkSL 默认给到
// highp 语义；Flutter 侧声明 mediump 会被编成 fp16，gradientNoise 里
// fract(52.98 * fract(dot(uv, …))) 的自变量超过 fp16 的 11 位尾数精度
// （uv≈1000px 时量化步长 0.5px），抖动噪点退化成周期性横纹；rgb2hsv 的
// 1e-10 除法保护在 fp16 下直接下溢成 0，近灰色像素的色相爆掉 —— 动画
// 过程里的彩色断层就是它。highp 在所有 GLES3 / Vulkan / Metal 设备上都可用。
// SPDX-License-Identifier: Apache-2.0
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// ---- uniform 顺序即 setFloat 下标（见 bg_effect_background.dart 的布局常量）----
uniform vec2 uResolution;       // 0  绘制区域尺寸（物理像素）
uniform float uAnimTime;        // 2  动画时间（秒）
uniform vec4 uBound;            // 3  渐变映射区 (x, y, w, h)，UV 空间
uniform float uTranslateY;      // 7  整体纵向平移（原版固定 0）
uniform vec3 uPoint0;           // 8  光斑 x, y, 半径（归一化 bound 空间）
uniform vec3 uPoint1;           // 11
uniform vec3 uPoint2;           // 14
uniform vec3 uPoint3;           // 17
uniform vec2 uPointsAnim0;      // 20 本帧动画位置（宿主每帧按 sin/cos 算好传入）
uniform vec2 uPointsAnim1;      // 22
uniform vec2 uPointsAnim2;      // 24
uniform vec2 uPointsAnim3;      // 26
uniform vec4 uColor0;           // 28 本帧光斑颜色（宿主按颜色循环插值好传入）
uniform vec4 uColor1;           // 32
uniform vec4 uColor2;           // 36
uniform vec4 uColor3;           // 40
uniform float uAlphaMulti;      // 44 整体 alpha 乘子（滚动淡出用）
uniform float uNoiseScale;      // 45 Perlin 噪声频率
uniform float uPointRadiusMulti;// 46 光斑半径乘子
uniform float uSaturateOffset;  // 47 噪声去饱和强度
uniform float uLightOffset;     // 48 噪声提亮强度
uniform float uDpr;             // 49 设备像素比（抖动噪声换算物理像素网格用）

out vec4 fragColor;

vec3 rgb2hsv(vec3 c) {
  vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
  vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
  float d = q.x - min(q.w, q.y);
  float e = 1.0e-10;
  return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
  vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
  vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
  return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.13);
  p3 += dot(p3, p3.yzx + 3.333);
  return fract((p3.x + p3.y) * p3.z);
}

float perlin(vec2 x) {
  vec2 i = floor(x);
  vec2 f = fract(x);

  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));

  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float gradientNoise(in vec2 uv) {
  return fract(52.9829189 * fract(dot(uv, vec2(0.06711056, 0.00583715))));
}

// 一个光斑叠进 color：距离越近越偏向 pointColor（AGSL 循环体的展开）。
vec4 applyPoint(vec4 color, vec4 pointColor, vec2 point, float rad, vec2 uv) {
  pointColor.rgb *= pointColor.a;
  float d = distance(uv, point);
  float pct = smoothstep(rad, 0.0, d);
  color.rgb = mix(color.rgb, pointColor.rgb, pct);
  color.a = mix(color.a, pointColor.a, pct);
  return color;
}

vec4 shaderMain(vec2 fragCoord) {
  vec2 vUv = fragCoord / uResolution;
  vUv.y = 1.0 - vUv.y;
  vec2 uv = vUv;
  uv -= vec2(0.0, uTranslateY);
  uv.xy -= uBound.xy;
  uv.xy /= uBound.zw;

  vec4 color = vec4(0.0);
  float noiseValue = perlin(vUv * uNoiseScale + vec2(-uAnimTime, -uAnimTime));

  color = applyPoint(color, uColor0, uPointsAnim0, uPoint0.z * uPointRadiusMulti, uv);
  color = applyPoint(color, uColor1, uPointsAnim1, uPoint1.z * uPointRadiusMulti, uv);
  color = applyPoint(color, uColor2, uPointsAnim2, uPoint2.z * uPointRadiusMulti, uv);
  color = applyPoint(color, uColor3, uPointsAnim3, uPoint3.z * uPointRadiusMulti, uv);

  float oppositeNoise = smoothstep(0.0, 1.0, noiseValue);
  color.rgb /= color.a;
  vec3 hsv = rgb2hsv(color.rgb);
  hsv.y = mix(hsv.y, 0.0, oppositeNoise * uSaturateOffset);
  color.rgb = hsv2rgb(hsv);
  color.rgb += oppositeNoise * uLightOffset;

  color.a = clamp(color.a, 0.0, 1.0);
  color.a *= uAlphaMulti;

  // 抖动噪声必须落在**物理像素**网格上：AGSL 原版的 fragCoord 就是物理
  // 像素（Compose drawRect 的 surface 分辨率），而 Flutter 的
  // FlutterFragCoord() 是逻辑坐标 —— 直接拿去算 IGN，噪声会变成
  // dpr×dpr 物理像素一块的色块网格，与非整数缩放的采样栅格拍频出
  // 45° 斜纹（截图放大后是斜向锯齿）。乘回 uDpr 即与原版逐物理像素
  // 的细密噪声一致。
  color += (10.0 / 255.0) * gradientNoise(fragCoord.xy * uDpr) - (5.0 / 255.0);
  return vec4(color.rgb * color.a, color.a);
}

void main() {
  fragColor = shaderMain(FlutterFragCoord().xy);
}
