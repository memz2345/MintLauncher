#ifndef RUNNER_TASKBAR_PROGRESS_H_
#define RUNNER_TASKBAR_PROGRESS_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace mint {

// Handles `mint/taskbar` platform channel calls (Windows taskbar progress
// via ITaskbarList3). Unknown methods are answered with NotImplemented.
void HandleTaskbarMethod(
    HWND hwnd,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

}  // namespace mint

#endif  // RUNNER_TASKBAR_PROGRESS_H_
