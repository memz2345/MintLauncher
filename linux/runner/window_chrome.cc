#include "window_chrome.h"

#include <string.h>

#include <gdk/gdk.h>

namespace {

// 三大金刚图标名：先找 symbolic（主题会按上下文着色），找不到退普通名。
// Adwaita / Breeze / Yaru / Papirus 等主流主题都带这一组。
struct CaptionIcon {
  const char* key;
  const char* symbolic;
  const char* plain;
};
constexpr CaptionIcon kCaptionIcons[] = {
    {"minimize", "window-minimize-symbolic", "window-minimize"},
    {"maximize", "window-maximize-symbolic", "window-maximize"},
    {"restore", "window-restore-symbolic", "window-restore"},
    {"close", "window-close-symbolic", "window-close"},
};

guint32 argb_from_args(FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 0xFF000000;
  }
  FlValue* v = fl_value_lookup_string(args, "fg");
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_INT) {
    return 0xFF000000;
  }
  return static_cast<guint32>(fl_value_get_int(v));
}

GdkRGBA rgba_from_argb(guint32 argb) {
  return GdkRGBA{static_cast<double>((argb >> 16) & 0xFF) / 255.0,
                 static_cast<double>((argb >> 8) & 0xFF) / 255.0,
                 static_cast<double>(argb & 0xFF) / 255.0,
                 static_cast<double>((argb >> 24) & 0xFF) / 255.0};
}

// 按前景色渲染一枚图标成 PNG 字节；主题里没有就返回 null。
guchar* render_icon_png(const gchar* symbolic,
                        const gchar* plain,
                        const GdkRGBA* fg,
                        gsize* out_len) {
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  const GtkIconLookupFlags flags = GTK_ICON_LOOKUP_FORCE_SIZE;
  GtkIconInfo* info = gtk_icon_theme_lookup_icon(theme, symbolic, 32, flags);
  if (!info) {
    info = gtk_icon_theme_lookup_icon(theme, plain, 32, flags);
  }
  if (!info) {
    return nullptr;
  }
  // load_symbolic 会按 fg 重着色 symbolic 图标；普通彩图标原样返回。
  const GdkRGBA success = {0.26, 0.69, 0.28, 1.0};
  const GdkRGBA warning = {0.96, 0.75, 0.14, 1.0};
  const GdkRGBA error = {0.88, 0.26, 0.21, 1.0};
  gboolean was_symbolic = FALSE;
  GError* err = nullptr;
  GdkPixbuf* pixbuf =
      gtk_icon_info_load_symbolic(info, fg, &success, &warning, &error,
                                  &was_symbolic, &err);
  g_object_unref(info);
  if (err) {
    g_error_free(err);
  }
  if (!pixbuf) {
    return nullptr;
  }
  gchar* png = nullptr;
  gsize len = 0;
  gdk_pixbuf_save_to_bufferv(pixbuf, &png, &len, "png", nullptr, nullptr,
                             nullptr);
  g_object_unref(pixbuf);
  *out_len = len;
  return reinterpret_cast<guchar*>(png);
}

void chrome_method_call(FlMethodChannel* channel,
                        FlMethodCall* method_call,
                        gpointer user_data) {
  (void)channel;
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  GtkWindow* window = GTK_WINDOW(user_data);

  if (strcmp(method, "setCustomFrame") == 0) {
    gboolean on = TRUE;
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* v = fl_value_lookup_string(args, "on");
      if (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) {
        on = fl_value_get_bool(v) ? TRUE : FALSE;
      }
    }
    // 摘掉 / 恢复 GTK 原生装饰（标题栏 + 边框）。真实化之前调用就不会闪。
    gtk_window_set_decorated(window, !on);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "getWindowIcons") == 0) {
    const guint32 fg = argb_from_args(args);
    const GdkRGBA fg_rgba = rgba_from_argb(fg);
    g_autoptr(FlValue) result = fl_value_new_map();
    for (const auto& icon : kCaptionIcons) {
      gsize len = 0;
      guchar* png = render_icon_png(icon.symbolic, icon.plain, &fg_rgba, &len);
      if (png) {
        fl_value_set_string_take(
            result, icon.key, fl_value_new_uint8_list(png, len));
        g_free(png);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void mint_window_chrome_register(FlView* view) {
  GtkWindow* window = GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "MintWindowChrome");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, "mint/window_chrome", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, chrome_method_call,
                                            window, nullptr);
}
