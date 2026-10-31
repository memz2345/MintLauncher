cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "window_effects.cc"
  "window_chrome.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# X11（窗口模糊的 _KDE_NET_WM_BLUR_BEHIND_REGION 原子要调 Xlib）。
# gtk+-3.0.pc 只把 x11 放在 Requires.private，默认不带出链接，要显式找。
pkg_check_modules(X11 IMPORTED_TARGET x11)
if(TARGET PkgConfig::X11)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11)
endif()

# 窗口模糊（Wayland 侧）：用 wayland-scanner 从协议 XML 生成客户端代码。
# X11 侧只需要 Xlib（GTK3 已带），任何环境都能编；缺 wayland-scanner /
# libwayland-client 的环境自动降级为纯 X11 实现。
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT IMPORTED_TARGET wayland-client)
find_program(WAYLAND_SCANNER wayland-scanner)
if(WAYLAND_CLIENT_FOUND AND WAYLAND_SCANNER)
  set(MINT_PROTOCOLS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/protocols")
  set(MINT_PROTOCOL_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/protocols")
  file(MAKE_DIRECTORY "${MINT_PROTOCOL_GEN_DIR}")
  set(MINT_PROTOCOL_SOURCES "")
  foreach(proto org-kde-kwin-blur ext-background-effect-v1)
    set(MINT_XML "${MINT_PROTOCOLS_DIR}/${proto}.xml")
    set(MINT_HDR "${MINT_PROTOCOL_GEN_DIR}/${proto}-client-protocol.h")
    set(MINT_SRC "${MINT_PROTOCOL_GEN_DIR}/${proto}-client-protocol.c")
    add_custom_command(
      OUTPUT "${MINT_HDR}" "${MINT_SRC}"
      COMMAND "${WAYLAND_SCANNER}" client-header "${MINT_XML}" "${MINT_HDR}"
      COMMAND "${WAYLAND_SCANNER}" private-code "${MINT_XML}" "${MINT_SRC}"
      DEPENDS "${MINT_XML}"
      COMMENT "Generating Wayland client code for ${proto}"
      VERBATIM
    )
    list(APPEND MINT_PROTOCOL_SOURCES "${MINT_SRC}")
    # 生成的代码不保证零警告，runner 是 -Wall -Werror，单独关掉。
    set_source_files_properties("${MINT_SRC}" PROPERTIES COMPILE_OPTIONS "-w")
  endforeach()
  target_sources(${BINARY_NAME} PRIVATE ${MINT_PROTOCOL_SOURCES})
  target_include_directories(${BINARY_NAME} PRIVATE "${MINT_PROTOCOL_GEN_DIR}")
  target_compile_definitions(${BINARY_NAME} PRIVATE MINT_HAS_WAYLAND_BLUR=1)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::WAYLAND_CLIENT)
else()
  message(STATUS "wayland-scanner or libwayland-client not found: "
                 "Wayland blur disabled (X11/KDE blur atom still available)")
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
