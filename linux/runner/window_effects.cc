#include "window_effects.h"

#include <stdint.h>
#include <string.h>

#include <cairo/cairo.h>
#include <gdk/gdk.h>

#ifdef GDK_WINDOWING_X11
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#endif

#if defined(MINT_HAS_WAYLAND_BLUR) && defined(GDK_WINDOWING_WAYLAND)
#define MINT_WAYLAND_BLUR_ENABLED 1
#include "ext-background-effect-v1-client-protocol.h"
#include "org-kde-kwin-blur-client-protocol.h"
#endif

namespace {

#ifdef GDK_WINDOWING_X11
// `_KDE_NET_WM_BLUR_BEHIND_REGION`：KWin 读到的 cardinal 数为 0 或 1 时
// 表示「整窗模糊」（kwin src/plugins/blur/blur.cpp updateBlurRegion 同款），
// 所以不用跟着 DPI / 窗口尺寸重算矩形。
constexpr char kKdeBlurAtom[] = "_KDE_NET_WM_BLUR_BEHIND_REGION";
#endif

#if defined(MINT_WAYLAND_BLUR_ENABLED)

// 整窗模糊用的超大矩形（合成器会裁到表面尺寸）。与 KWindowSystem
// （src/platforms/wayland/windoweffects.cpp installBlur）一致，窗口
// 改尺寸也不用重新提交。
constexpr int32_t kFullRegionX = INT32_MIN / 2;
constexpr int32_t kFullRegionY = INT32_MIN / 2;
constexpr int32_t kFullRegionW = INT32_MAX;
constexpr int32_t kFullRegionH = INT32_MAX;

struct WaylandState {
  bool initialized = false;
  bool failed = false;
  wl_display* display = nullptr;
  wl_registry* registry = nullptr;
  wl_compositor* compositor = nullptr;
  // KWin 6.3+ 的标准协议（wayland-protocols staging）。
  ext_background_effect_manager_v1* ext_manager = nullptr;
  uint32_t ext_capabilities = 0;
  // 老 Plasma / KWin 的 KDE 私有协议。
  org_kde_kwin_blur_manager* blur_manager = nullptr;
  // 已创建的效果对象（disable 时释放）。
  ext_background_effect_surface_v1* ext_effect = nullptr;
  org_kde_kwin_blur* blur = nullptr;
};
WaylandState g_wayland;

void ext_manager_capabilities(void* data,
                              ext_background_effect_manager_v1* manager,
                              uint32_t flags) {
  (void)manager;
  auto* state = static_cast<WaylandState*>(data);
  state->ext_capabilities = flags;
}

const struct ext_background_effect_manager_v1_listener kExtManagerListener = {
    ext_manager_capabilities,
};

void registry_handle_global(void* data,
                            struct wl_registry* registry,
                            uint32_t name,
                            const char* interface,
                            uint32_t version) {
  auto* state = static_cast<WaylandState*>(data);
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    state->compositor =
        static_cast<struct wl_compositor*>(wl_registry_bind(
            registry, name, &wl_compositor_interface, version < 4 ? version : 4));
  } else if (strcmp(interface, ext_background_effect_manager_v1_interface.name) ==
             0) {
    state->ext_manager =
        static_cast<ext_background_effect_manager_v1*>(wl_registry_bind(
            registry, name, &ext_background_effect_manager_v1_interface, 1));
    ext_background_effect_manager_v1_add_listener(state->ext_manager,
                                                  &kExtManagerListener, state);
  } else if (strcmp(interface, org_kde_kwin_blur_manager_interface.name) == 0) {
    state->blur_manager =
        static_cast<org_kde_kwin_blur_manager*>(wl_registry_bind(
            registry, name, &org_kde_kwin_blur_manager_interface, 1));
  }
}

void registry_handle_global_remove(void* data,
                                   struct wl_registry* registry,
                                   uint32_t name) {
  // 全局消失时旧代理会变 inert，libwayland 自己兜底，这里无需处理。
  (void)data;
  (void)registry;
  (void)name;
}

const struct wl_registry_listener kRegistryListener = {
    registry_handle_global,
    registry_handle_global_remove,
};

bool wayland_init() {
  if (g_wayland.failed) {
    return false;
  }
  if (g_wayland.initialized) {
    return true;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (!gdk_display || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    g_wayland.failed = true;
    return false;
  }
  g_wayland.display = gdk_wayland_display_get_wl_display(gdk_display);
  if (!g_wayland.display) {
    g_wayland.failed = true;
    return false;
  }
  g_wayland.registry = wl_display_get_registry(g_wayland.display);
  wl_registry_add_listener(g_wayland.registry, &kRegistryListener, &g_wayland);
  // 第一趟拿 globals；绑了 ext manager 再补一趟收 capabilities 事件。
  wl_display_roundtrip(g_wayland.display);
  if (g_wayland.ext_manager) {
    wl_display_roundtrip(g_wayland.display);
  }
  g_wayland.initialized = true;
  return true;
}

struct wl_region* wayland_full_region() {
  struct wl_region* region = wl_compositor_create_region(g_wayland.compositor);
  if (!region) {
    return nullptr;
  }
  wl_region_add(region, kFullRegionX, kFullRegionY, kFullRegionW, kFullRegionH);
  return region;
}

// 返回 true = 走通了对应的协议（不管当前是不是启用状态）。
bool wayland_apply_blur(struct wl_surface* surface, bool enable) {
  if (!wayland_init() || !surface) {
    return false;
  }
  if (g_wayland.ext_manager &&
      (g_wayland.ext_capabilities &
       EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR)) {
    if (!enable) {
      if (g_wayland.ext_effect) {
        // NULL region = 移除效果（协议描述原文），随下一次 surface
        // commit 生效。
        ext_background_effect_surface_v1_set_blur_region(g_wayland.ext_effect,
                                                         nullptr);
        wl_surface_commit(surface);
        ext_background_effect_surface_v1_destroy(g_wayland.ext_effect);
        g_wayland.ext_effect = nullptr;
      }
      return true;
    }
    if (!g_wayland.compositor) {
      return false;
    }
    if (!g_wayland.ext_effect) {
      g_wayland.ext_effect =
          ext_background_effect_manager_v1_get_background_effect(
              g_wayland.ext_manager, surface);
      if (!g_wayland.ext_effect) {
        return false;
      }
    }
    struct wl_region* region = wayland_full_region();
    if (!region) {
      return false;
    }
    ext_background_effect_surface_v1_set_blur_region(g_wayland.ext_effect,
                                                     region);
    wl_region_destroy(region);
    // 双缓冲状态：随下一次 wl_surface.commit 应用。
    wl_surface_commit(surface);
    return true;
  }
  if (g_wayland.blur_manager) {
    if (!enable) {
      if (g_wayland.blur) {
        org_kde_kwin_blur_manager_unset(g_wayland.blur_manager, surface);
        org_kde_kwin_blur_release(g_wayland.blur);
        g_wayland.blur = nullptr;
      }
      return true;
    }
    if (!g_wayland.compositor) {
      return false;
    }
    if (g_wayland.blur) {
      return true;
    }
    g_wayland.blur =
        org_kde_kwin_blur_manager_create(g_wayland.blur_manager, surface);
    if (!g_wayland.blur) {
      return false;
    }
    struct wl_region* region = wayland_full_region();
    if (!region) {
      org_kde_kwin_blur_release(g_wayland.blur);
      g_wayland.blur = nullptr;
      return false;
    }
    org_kde_kwin_blur_set_region(g_wayland.blur, region);
    wl_region_destroy(region);
    org_kde_kwin_blur_commit(g_wayland.blur);
    return true;
  }
  return false;
}

bool wayland_blur_available() {
  if (!wayland_init()) {
    return false;
  }
  if (g_wayland.ext_manager) {
    return (g_wayland.ext_capabilities &
            EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR) != 0;
  }
  return g_wayland.blur_manager != nullptr;
}

#endif  // MINT_WAYLAND_BLUR_ENABLED

bool x11_apply_blur(GdkWindow* gdk_window, bool enable) {
#ifdef GDK_WINDOWING_X11
  if (!GDK_IS_X11_WINDOW(gdk_window)) {
    return false;
  }
  Display* dpy = gdk_x11_window_get_xdisplay(gdk_window);
  Window xid = gdk_x11_window_get_xid(gdk_window);
  if (!dpy || !xid) {
    return false;
  }
  Atom atom = XInternAtom(dpy, kKdeBlurAtom, False);
  if (enable) {
    uint32_t whole_window = 0;  // 0/1 个 cardinal = 整窗模糊
    XChangeProperty(dpy, xid, atom, XA_CARDINAL, 32, PropModeReplace,
                    reinterpret_cast<const unsigned char*>(&whole_window), 1);
  } else {
    XDeleteProperty(dpy, xid, atom);
  }
  XFlush(dpy);
  return true;
#else
  (void)gdk_window;
  (void)enable;
  return false;
#endif
}

bool x11_blur_available(GdkWindow* gdk_window) {
#ifdef GDK_WINDOWING_X11
  if (!GDK_IS_X11_WINDOW(gdk_window)) {
    return false;
  }
  GdkScreen* screen = gdk_window_get_screen(gdk_window);
  if (!screen) {
    return false;
  }
  const gchar* wm = gdk_x11_screen_get_window_manager_name(screen);
  // 只有 KWin 消费这个原子（picom / mutter / muffin 都不看它）。
  return wm && strcmp(wm, "KWin") == 0;
#else
  (void)gdk_window;
  return false;
#endif
}

// XDG_CURRENT_DESKTOP 是冒号分隔列表（如 "KDE" / "ubuntu:GNOME"），取第一段。
gchar* detect_desktop_name(GdkWindow* gdk_window) {
  const gchar* env = g_getenv("XDG_CURRENT_DESKTOP");
  if (env && *env) {
    const gchar* colon = strchr(env, ':');
    gsize len = colon ? static_cast<gsize>(colon - env) : strlen(env);
    gchar* name = static_cast<gchar*>(g_malloc(len + 1));
    memcpy(name, env, len);
    name[len] = '\0';
    return name;
  }
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_WINDOW(gdk_window)) {
    GdkScreen* screen = gdk_window_get_screen(gdk_window);
    const gchar* wm =
        screen ? gdk_x11_screen_get_window_manager_name(screen) : nullptr;
    if (wm) {
      return g_strdup(wm);
    }
  }
#endif
  return g_strdup("unknown");
}

gboolean mint_window_draw(GtkWidget* widget, cairo_t* cr, gpointer user_data) {
  (void)widget;
  (void)user_data;
  cairo_save(cr);
  cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.0);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint(cr);
  cairo_restore(cr);
  return FALSE;
}

void backdrop_method_call(FlMethodChannel* channel,
                          FlMethodCall* method_call,
                          gpointer user_data) {
  (void)channel;
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  GdkWindow* gdk_window = static_cast<GdkWindow*>(user_data);

  if (strcmp(method, "getCapabilities") == 0) {
    const gchar* session = "unknown";
    bool blur = false;
#ifdef GDK_WINDOWING_WAYLAND
    if (GDK_IS_WAYLAND_WINDOW(gdk_window)) {
      session = "wayland";
#if defined(MINT_WAYLAND_BLUR_ENABLED)
      blur = wayland_blur_available();
#endif
    }
#endif
#ifdef GDK_WINDOWING_X11
    if (GDK_IS_X11_WINDOW(gdk_window)) {
      session = "x11";
      blur = x11_blur_available(gdk_window);
    }
#endif
    g_autofree gchar* de = detect_desktop_name(gdk_window);
    g_autoptr(FlValue) caps = fl_value_new_map();
    fl_value_set_string_take(caps, "supported", fl_value_new_bool(blur));
    fl_value_set_string_take(caps, "blur", fl_value_new_bool(blur));
    fl_value_set_string_take(caps, "de", fl_value_new_string(de));
    fl_value_set_string_take(caps, "session", fl_value_new_string(session));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(caps));
  } else if (strcmp(method, "setBackdrop") == 0 ||
             strcmp(method, "reset") == 0) {
    const gchar* mode = "off";
    if (strcmp(method, "setBackdrop") == 0 &&
        fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* mode_value = fl_value_lookup_string(args, "mode");
      if (mode_value && fl_value_get_type(mode_value) == FL_VALUE_TYPE_STRING) {
        mode = fl_value_get_string(mode_value);
      }
    }
    bool enable = strcmp(mode, "off") != 0;
    bool applied = false;
    if (enable) {
#ifdef GDK_WINDOWING_X11
      applied = x11_apply_blur(gdk_window, true);
#endif
#if defined(MINT_WAYLAND_BLUR_ENABLED)
      if (!applied && GDK_IS_WAYLAND_WINDOW(gdk_window)) {
        struct wl_surface* surface =
            gdk_wayland_window_get_wl_surface(gdk_window);
        applied = wayland_apply_blur(surface, true);
      }
#endif
    } else {
      // 关闭：把两边都清干净（同一时刻只有一边是真窗口类型）。
#ifdef GDK_WINDOWING_X11
      if (GDK_IS_X11_WINDOW(gdk_window)) {
        x11_apply_blur(gdk_window, false);
      }
#endif
#if defined(MINT_WAYLAND_BLUR_ENABLED)
      if (GDK_IS_WAYLAND_WINDOW(gdk_window)) {
        struct wl_surface* surface =
            gdk_wayland_window_get_wl_surface(gdk_window);
        wayland_apply_blur(surface, false);
      }
#endif
      applied = true;  // 关闭总是成功的
    }
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(
        result, "applied", fl_value_new_string(enable && applied ? mode : "off"));
    fl_value_set_string_take(result, "fallback", fl_value_new_bool(false));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "hideCaption") == 0) {
    // Windows 专属（DWM caption 兜底），Linux 无操作。
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void mint_backdrop_configure_window(GtkWindow* window, FlView* view) {
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window));
  if (!screen) {
    return;
  }
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (!visual || !gdk_screen_is_composited(screen)) {
    // 没有混成（Xvfb / 关闭混成的 X11）：保持黑色不透明底。
    return;
  }
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  gtk_widget_set_visual(GTK_WIDGET(window), visual);
  g_signal_connect(G_OBJECT(window), "draw", G_CALLBACK(mint_window_draw),
                   nullptr);
  GdkRGBA transparent;
  gdk_rgba_parse(&transparent, "#00000000");
  fl_view_set_background_color(view, &transparent);
}

void mint_backdrop_register(FlView* view) {
  GtkWindow* window = GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  FlBinaryMessenger* messenger = fl_view_get_binary_messenger(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, "mint/backdrop", FL_METHOD_CODEC(codec));
  // user_data 存顶层 GdkWindow（capabilities / setBackdrop 都要用）；
  // handler 由 messenger 按通道名持有，channel 对象销毁不影响回调。
  GdkWindow* gdk_window = gtk_widget_get_realized(GTK_WIDGET(window))
                              ? gtk_widget_get_window(GTK_WIDGET(window))
                              : nullptr;
  fl_method_channel_set_method_call_handler(channel, backdrop_method_call,
                                            gdk_window, nullptr);
}
