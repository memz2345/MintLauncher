#include "native_tooltip.h"

#include <cmath>
#include <cstring>

#include <gtk/gtk.h>

// GtkTooltip 的样式来自 CSS 节点名 `tooltip`（不是 style class）：
// gtk_widget_class_set_css_name(widget_class, "tooltip")。普通 GtkWindow
// 的节点名固定是 `window`，只挂 style class 的话主题规则
// `tooltip.background { ... }` 匹配不上，弹出来就是一块白底方框。
// 这里照 GtkTooltipWindow 的做法定义一个 CSS 名为 tooltip 的窗口子类。
struct MintTooltipWindow {
  GtkWindow parent_instance;
};

struct MintTooltipWindowClass {
  GtkWindowClass parent_class;
};

G_DEFINE_TYPE(MintTooltipWindow, mint_tooltip_window, GTK_TYPE_WINDOW)

static void mint_tooltip_window_class_init(MintTooltipWindowClass* klass) {
  gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(klass), "tooltip");
}

static void mint_tooltip_window_init(MintTooltipWindow* self) { (void)self; }

namespace {

// 复用同一个窗口：tooltip 连续切换（最小化 → 最大化 → 关闭）时不重建，
// GTK 主题（Adwaita / Breeze / Yaru）的 tooltip 样式直接生效。
GtkWidget* g_tooltip_window = nullptr;
GtkWidget* g_tooltip_label = nullptr;
GtkWindow* g_parent_window = nullptr;

void ensure_tooltip_window() {
  if (g_tooltip_window != nullptr) return;

  GtkWidget* window = GTK_WIDGET(
      g_object_new(mint_tooltip_window_get_type(), "type", GTK_WINDOW_POPUP,
                   nullptr));
  gtk_window_set_type_hint(GTK_WINDOW(window), GDK_WINDOW_TYPE_HINT_TOOLTIP);
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_accept_focus(GTK_WINDOW(window), FALSE);
  gtk_window_set_focus_on_map(GTK_WINDOW(window), FALSE);
  gtk_window_set_modal(GTK_WINDOW(window), FALSE);
  gtk_widget_set_name(window, "gtk-tooltip");
  // 主题里配色规则挂在 `tooltip.background` 上。
  gtk_style_context_add_class(gtk_widget_get_style_context(window),
                              GTK_STYLE_CLASS_BACKGROUND);

  GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_widget_set_margin_top(box, 6);
  gtk_widget_set_margin_bottom(box, 6);
  gtk_widget_set_margin_start(box, 6);
  gtk_widget_set_margin_end(box, 6);
  gtk_container_add(GTK_CONTAINER(window), box);

  GtkWidget* label = gtk_label_new(nullptr);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  gtk_label_set_yalign(GTK_LABEL(label), 0.5);
  gtk_label_set_single_line_mode(GTK_LABEL(label), TRUE);
  gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);

  g_tooltip_window = window;
  g_tooltip_label = label;

  if (g_parent_window != nullptr) {
    // 父窗口销毁时一并收掉弹出层，避免 GtkWindow 泄漏到进程退出。
    g_signal_connect_swapped(g_parent_window, "destroy",
                             G_CALLBACK(gtk_widget_destroy),
                             g_tooltip_window);
  }
}

double arg_double(FlValue* args, const char* key, double fallback) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_FLOAT) {
    return fallback;
  }
  return fl_value_get_float(value);
}

int to_pixels(GtkWidget* widget, double logical, double scale) {
  return static_cast<int>(std::lround(logical * scale));
}

void hide_tooltip() {
  if (g_tooltip_window != nullptr) {
    gtk_widget_hide(g_tooltip_window);
  }
}

void show_tooltip(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return;
  FlValue* text_value = fl_value_lookup_string(args, "text");
  if (text_value == nullptr ||
      fl_value_get_type(text_value) != FL_VALUE_TYPE_STRING) {
    return;
  }
  const gchar* text = fl_value_get_string(text_value);
  if (text == nullptr || text[0] == '\0') return;

  ensure_tooltip_window();
  gtk_label_set_text(GTK_LABEL(g_tooltip_label), text);

  // 取 tooltip 的自然尺寸（还没 show，GTK 也能算）。
  GtkRequisition natural = {0, 0};
  gtk_widget_get_preferred_size(g_tooltip_window, nullptr, &natural);
  if (natural.width <= 0 || natural.height <= 0) return;

  GtkWidget* parent_widget =
      g_parent_window != nullptr ? GTK_WIDGET(g_parent_window) : nullptr;
  const int scale = parent_widget != nullptr
                        ? gtk_widget_get_scale_factor(parent_widget)
                        : 1;
  const int safe_scale = scale > 0 ? scale : 1;

  int window_x = 0;
  int window_y = 0;
  if (g_parent_window != nullptr) {
    gtk_window_get_position(g_parent_window, &window_x, &window_y);
  }

  // Dart 给的 anchor 是 Flutter 逻辑像素（相对客户区左上角）。
  const int anchor_x =
      window_x + to_pixels(parent_widget, arg_double(args, "x", 0), safe_scale);
  const int anchor_y =
      window_y + to_pixels(parent_widget, arg_double(args, "y", 0), safe_scale);
  const int anchor_w =
      to_pixels(parent_widget, arg_double(args, "w", 0), safe_scale);
  const int anchor_h =
      to_pixels(parent_widget, arg_double(args, "h", 0), safe_scale);

  const int gap = 6 * safe_scale;
  const int margin = 6 * safe_scale;

  int x = anchor_x + anchor_w / 2 - natural.width / 2;
  int y = anchor_y - natural.height - gap;
  if (y < margin) {
    // 标题栏按钮贴着窗口顶边，上面放不下就落到按钮下方。
    y = anchor_y + anchor_h + gap;
  }

  // 用父窗口所在显示器的 workarea 夹一下，避免弹出到屏幕外。
  GdkWindow* parent_gdk = parent_widget != nullptr
                              ? gtk_widget_get_window(parent_widget)
                              : nullptr;
  GdkDisplay* display = gtk_widget_get_display(
      parent_widget != nullptr ? parent_widget : g_tooltip_window);
  if (parent_gdk != nullptr && display != nullptr) {
    GdkMonitor* monitor = gdk_display_get_monitor_at_window(display, parent_gdk);
    if (monitor != nullptr) {
      GdkRectangle workarea = {0, 0, 0, 0};
      gdk_monitor_get_workarea(monitor, &workarea);
      const int right = workarea.x + workarea.width - natural.width - margin;
      const int bottom = workarea.y + workarea.height - natural.height - margin;
      if (x < workarea.x + margin) x = workarea.x + margin;
      if (right >= workarea.x + margin && x > right) x = right;
      if (y < workarea.y + margin) y = workarea.y + margin;
      if (bottom >= workarea.y + margin && y > bottom) y = bottom;
    }
  }

  gtk_window_move(GTK_WINDOW(g_tooltip_window), x, y);
  gtk_widget_show_all(g_tooltip_window);
  gtk_window_move(GTK_WINDOW(g_tooltip_window), x, y);
  GdkWindow* tooltip_gdk = gtk_widget_get_window(g_tooltip_window);
  if (tooltip_gdk != nullptr) gdk_window_raise(tooltip_gdk);
}

void tooltip_method_call(FlMethodChannel* channel,
                         FlMethodCall* method_call,
                         gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "show") == 0) {
    show_tooltip(fl_method_call_get_args(method_call));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "hide") == 0) {
    hide_tooltip();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void mint_native_tooltip_register(FlView* view) {
  g_parent_window =
      GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "MintNativeTooltip");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, "dev.mint.mint/tooltip", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, tooltip_method_call,
                                            nullptr, nullptr);
}
