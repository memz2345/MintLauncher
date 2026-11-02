#ifndef RUNNER_GPU_HOST_H_
#define RUNNER_GPU_HOST_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace mint {

// Handles `mint/gpu` platform channel calls:
//   · listAdapters  — DXGI 物理显卡枚举（名称 / VEN&DEV&SUBSYS）
//   · getPreference — 读某个 exe 当前的每应用显卡偏好
//   · setPreference — 写（或删）该偏好，即「指定游戏用哪块 GPU 渲染」
// Unknown methods are answered with NotImplemented.
void HandleGpuMethod(
    HWND hwnd,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

}  // namespace mint

#endif  // RUNNER_GPU_HOST_H_
