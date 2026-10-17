# ============================================================
#  ui_theme.gd —— 深色主题工具（纯静态函数，不挂节点）
# ------------------------------------------------------------
#  按需求要求，圆角 / 阴影全部用 StyleBoxFlat 在代码里动态创建，
#  不依赖任何 .tres 资源文件，方便直接改颜色改圆角就生效。
#
#  用法：var sb := UITheme.panel_style(UITheme.CARD_BG, 12)
# ============================================================
class_name UITheme
extends RefCounted

# ---------- 配色 ----------
const BG := Color("1a1a1a")            # 主背景
const BG_PANEL := Color("212121")      # 分区面板
const CARD_BG := Color("2a2a2a")       # 卡片
const ACCENT := Color("FF6B00")        # 强调色 / 选中描边
const ACCENT_DIM := Color("8a3a00")    # 弱化强调色
const TEXT := Color("e8e8e8")
const TEXT_MUTED := Color("9a9a9a")
const BORDER := Color("3a3a3a")
const DANGER := Color("e74c3c")

const RADIUS_SM := 6
const RADIUS_MD := 10
const RADIUS_LG := 14


## 生成一个 StyleBoxFlat。
## bg        底色
## radius    圆角
## shadow    阴影颜色（传 Color(0,0,0,0) 表示不要阴影）
## border    边框颜色（传 Color(0,0,0,0) 表示不要边框）
## border_w  边框宽度
## shadow_sz 阴影大小
static func make_style(bg: Color, radius: int = RADIUS_MD, shadow: Color = Color(0, 0, 0, 0),
		border: Color = Color(0, 0, 0, 0), border_w: int = 0, shadow_sz: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.anti_aliasing = true
	if shadow.a > 0.0 and shadow_sz > 0:
		sb.shadow_color = shadow
		sb.shadow_size = shadow_sz
		sb.shadow_offset = Vector2(0, 2)
	if border.a > 0.0 and border_w > 0:
		sb.border_color = border
		sb.set_border_width_all(border_w)
	return sb


## 常用：面板 / 卡片 / 输入框
static func panel_style(bg: Color = BG_PANEL, radius: int = RADIUS_MD) -> StyleBoxFlat:
	return make_style(bg, radius)


## 常用：带内边距的面板
static func padded_panel(bg: Color, radius: int, pad_h: int, pad_v: int) -> StyleBoxFlat:
	var sb := make_style(bg, radius)
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


static func accent_style(radius: int = RADIUS_SM) -> StyleBoxFlat:
	return make_style(ACCENT, radius)


static func danger_style(radius: int = RADIUS_SM) -> StyleBoxFlat:
	return make_style(DANGER, radius)


## 给一个 Button 套上深色按钮皮肤（normal / hover / pressed / disabled）
static func apply_button(btn: Button, radius: int = RADIUS_SM) -> void:
	btn.add_theme_stylebox_override("normal", make_style(Color("333333"), radius))
	btn.add_theme_stylebox_override("hover", make_style(Color("454545"), radius))
	btn.add_theme_stylebox_override("pressed", make_style(Color("2b2b2b"), radius))
	btn.add_theme_stylebox_override("disabled", make_style(Color("262626"), radius))
	btn.add_theme_stylebox_override("focus", make_style(Color(0, 0, 0, 0), radius, Color(0, 0, 0, 0), ACCENT, 1))
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", ACCENT)


## 主按钮（橙色实心）
static func apply_button_primary(btn: Button, radius: int = RADIUS_SM) -> void:
	btn.add_theme_stylebox_override("normal", make_style(ACCENT, radius))
	btn.add_theme_stylebox_override("hover", make_style(Color("ff8636"), radius))
	btn.add_theme_stylebox_override("pressed", make_style(Color("d95a00"), radius))
	btn.add_theme_stylebox_override("disabled", make_style(Color("5a3a20"), radius))
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)


## 危险按钮（红）
static func apply_button_danger(btn: Button, radius: int = RADIUS_SM) -> void:
	btn.add_theme_stylebox_override("normal", make_style(Color("3a2222"), radius, Color(0, 0, 0, 0), DANGER, 1))
	btn.add_theme_stylebox_override("hover", make_style(Color("5a2a2a"), radius, Color(0, 0, 0, 0), DANGER, 1))
	btn.add_theme_stylebox_override("pressed", make_style(Color("2a1818"), radius))
	btn.add_theme_color_override("font_color", Color("ffb3b3"))
	btn.add_theme_color_override("font_hover_color", Color.WHITE)


## 输入框 / 下拉框皮肤
static func apply_input(ctrl: Control, radius: int = RADIUS_SM) -> void:
	var normal := padded_panel(Color("252525"), radius, 8, 4)
	normal.border_color = BORDER
	normal.set_border_width_all(1)
	var focus := padded_panel(Color("2c2c2c"), radius, 8, 4)
	focus.border_color = ACCENT
	focus.set_border_width_all(1)
	for slot in ["normal", "focus", "read_only"]:
		ctrl.add_theme_stylebox_override(slot, normal if slot != "focus" else focus)
	for slot2 in ["hover", "pressed"]:
		ctrl.add_theme_stylebox_override(slot2, focus)
	ctrl.add_theme_color_override("font_color", TEXT)
	ctrl.add_theme_color_override("font_placeholder_color", Color("6a6a6a"))
	ctrl.add_theme_color_override("font_selected_color", Color.WHITE)
	ctrl.add_theme_color_override("caret_color", ACCENT)


## 给 Label 统一字号与颜色
static func style_label(lbl: Label, font_size: int = 14, color: Color = TEXT) -> void:
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)


## ScrollContainer 的滚动条皮肤
static func apply_scroll(sc: ScrollContainer) -> void:
	var vbar := sc.get_v_scroll_bar()
	if vbar != null:
		vbar.custom_minimum_size = Vector2(10, 0)
		vbar.add_theme_stylebox_override("scroll", make_style(Color("242424"), 5))
		vbar.add_theme_stylebox_override("grabber", make_style(Color("4a4a4a"), 5))
		vbar.add_theme_stylebox_override("grabber_highlight", make_style(ACCENT, 5))
		vbar.add_theme_stylebox_override("grabber_pressed", make_style(Color("ff8636"), 5))
	var hbar := sc.get_h_scroll_bar()
	if hbar != null:
		hbar.custom_minimum_size = Vector2(0, 10)
		hbar.add_theme_stylebox_override("scroll", make_style(Color("242424"), 5))
		hbar.add_theme_stylebox_override("grabber", make_style(Color("4a4a4a"), 5))
		hbar.add_theme_stylebox_override("grabber_highlight", make_style(ACCENT, 5))


## 分隔线
static func separator() -> HSeparator:
	var sep := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BORDER
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	sep.add_theme_stylebox_override("separator", sb)
	return sep


## 生成「颜色 → #RRGGBB」文本（导出/调试用）
static func to_hex(c: Color) -> String:
	return "#" + c.to_html(false).to_upper()
