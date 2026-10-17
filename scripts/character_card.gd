# ============================================================
#  character_card.gd —— 单张忍者卡片
# ------------------------------------------------------------
#  结构：Control(本脚本)
#          └ card_panel   : PanelContainer  外层，负责橙色选中描边
#              └ bg_panel : PanelContainer  内层，卡片底色 + 圆角阴影
#                  └ Margin > VBox
#                      ├ image_frame : PanelContainer > Center > avatar(TextureRect)
#                      ├ name_label  : Label
#                      └ voters_label: Label（被谁 Ban）
#          └ badge_holder: MarginContainer > badge(Label)  右上角票数徽章
#
#  交互：
#    · hover   → 变亮 + 1.05 倍缩放（Tween）
#    · 左键    → toggle 当前投票人对该忍者的 Ban 状态
#    · 右键    → 查看大图
#
#  与 Main 解耦：卡片不直接读写 DataManager，只发信号，由 Main 决定数据怎么变。
# ============================================================
class_name CharacterCard
extends Control

# UITheme 用 preload 引用（不依赖全局 class_name 注册，任何运行方式下都可用）
const UITheme := preload("res://scripts/ui_theme.gd")

## 左键点击：请求把该忍者加入/移出当前投票人的 Ban 名单
signal vote_toggled(photo: String, voted: bool)
## 右键：请求查看大图
signal preview_requested(photo: String)

const CARD_SIZE := Vector2(140, 206)
const IMAGE_SIZE := 112
const HOVER_SCALE := 1.05
const TWEEN_TIME := 0.12
const LIFT := 3.0                       # hover 时向上浮起的像素

const COLOR_BG := Color("2a2a2a")
const COLOR_BG_HOVER := Color("363636")
const COLOR_BORDER := Color("3a3a3a")
const COLOR_ACCENT := Color("FF6B00")
const COLOR_TEXT := Color("e8e8e8")
const COLOR_MUTED := Color("9a9a9a")

var photo := ""                          # 照片 ID（文件名去扩展名），也是票数 key
var character_name := ""                 # 显示用的忍者名
var group := ""                          # 分组（来自 characters.json）
var banned := false                      # 当前投票人是否 Ban 了它
var vote_count := 0                      # 被 Ban 总次数

# ---- 节点引用（全部来自 CharacterCard.tscn，脚本只改属性，不再新建节点）----
@onready var _card_panel: PanelContainer = $CardPanel
@onready var _bg_panel: PanelContainer = $CardPanel/BgPanel
@onready var _margin: MarginContainer = $CardPanel/BgPanel/Margin
@onready var _vbox: VBoxContainer = $CardPanel/BgPanel/Margin/VBox
@onready var _image_frame: PanelContainer = $CardPanel/BgPanel/Margin/VBox/ImageFrame
@onready var _avatar: TextureRect = $CardPanel/BgPanel/Margin/VBox/ImageFrame/Center/Avatar
@onready var _avatar_fallback: Label = $CardPanel/BgPanel/Margin/VBox/ImageFrame/Placeholder
@onready var _name_label: Label = $CardPanel/BgPanel/Margin/VBox/NameLabel
@onready var _voters_label: Label = $CardPanel/BgPanel/Margin/VBox/VotersLabel
@onready var _badge_holder: MarginContainer = $BadgeHolder
@onready var _badge: Label = $BadgeHolder/Badge

# _ready() 之前调用的 setup()/set_texture() 先把值存这里，等 _ready 再套用
var _pending_name := ""
var _pending_texture: Texture2D = null

var _thumb: Texture2D = null
var _hovered := false

var _style_bg: StyleBoxFlat
var _style_bg_hover: StyleBoxFlat
var _style_outline: StyleBoxFlat
var _tween: Tween


func _ready() -> void:
	custom_minimum_size = CARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP   # 由本节点统一接收鼠标事件
	clip_contents = false
	_apply_styles()

	# 统一从本节点的 mouse_entered/exited 驱动 hover，
	# 子节点全设 IGNORE，避免鼠标划过子控件时反复触发。
	mouse_entered.connect(_on_mouse_enter)
	mouse_exited.connect(_on_mouse_exit)
	resized.connect(_update_pivot)

	# 补上 _ready 之前传进来的内容（Main 是在 add_child 之前就 setup 的）
	if _pending_name != "":
		_apply_name(_pending_name)
	if _pending_texture != null:
		_apply_texture(_pending_texture)

	_update_pivot()
	_apply_visual()


## 样式统一在这里套用（圆角/阴影/强调色都在 GDScript 里，方便调）
func _apply_styles() -> void:
	_style_outline = UITheme.make_style(UITheme.CARD_BG, 11, Color(0, 0, 0, 0), COLOR_ACCENT, 2)
	_style_bg = UITheme.make_style(COLOR_BG, 10, Color(0, 0, 0, 0.45), Color(0, 0, 0, 0), 0, 6)
	_style_bg_hover = UITheme.make_style(COLOR_BG_HOVER, 10, Color(0, 0, 0, 0.55), COLOR_BORDER, 1, 6)
	_card_panel.add_theme_stylebox_override("panel", _style_outline)
	_bg_panel.add_theme_stylebox_override("panel", _style_bg)
	_image_frame.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("1f1f1f"), 8, Color(0, 0, 0, 0.35), Color("3d3d3d"), 1, 3))

	_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar.custom_minimum_size = Vector2(IMAGE_SIZE, IMAGE_SIZE)

	UITheme.style_label(_name_label, 13, COLOR_TEXT)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY   # 中文按字换行
	# 名字最多两行，再长就省略号截断 —— 否则超长名字会把卡片撑高、参差不齐
	_name_label.max_lines_visible = 2
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.text = "—"

	UITheme.style_label(_voters_label, 10, COLOR_MUTED)
	_voters_label.text = ""
	# 名单摘要一行放不下就省略号（完整内容在 tooltip 与右侧面板里）
	_voters_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

	UITheme.style_label(_badge, 12, Color.WHITE)
	_badge.custom_minimum_size = Vector2(24, 24)
	_badge.text = "0"


# ============================================================
#  对外设置接口
# ============================================================

## 设定这张卡片代表哪个忍者（在 _ready 之前调用也安全）
func setup(p_name: String, p_photo: String, p_group: String = "") -> void:
	character_name = p_name
	photo = p_photo
	group = p_group
	if _name_label == null:
		_pending_name = p_name        # _ready 还没跑，先存着
		return
	_apply_name(p_name)


func _apply_name(p_name: String) -> void:
	_name_label.text = p_name if p_name != "" else photo
	var tip := "%s\n照片ID：%s" % [_name_label.text, photo]
	if group != "":
		tip += "\n分组：%s" % group
	tooltip_text = tip


## 设置头像纹理（在 _ready 之前调用也安全；传 null 显示占位符）
func set_texture(tex: Texture2D) -> void:
	_thumb = tex
	if _avatar == null:
		_pending_texture = tex        # _ready 还没跑，先存着
		return
	_apply_texture(tex)


func _apply_texture(tex: Texture2D) -> void:
	_avatar.texture = tex
	_avatar_fallback.visible = (tex == null)
	# 非正方形图片按比例收缩，避免被拉变形
	if tex != null:
		var ts := tex.get_size()
		if ts.x > 0.0 and ts.y > 0.0 and not is_equal_approx(ts.x, ts.y):
			var k: float = float(IMAGE_SIZE) / maxf(ts.x, ts.y)
			_avatar.custom_minimum_size = Vector2(round(ts.x * k), round(ts.y * k))
		else:
			_avatar.custom_minimum_size = Vector2(IMAGE_SIZE, IMAGE_SIZE)
	else:
		_avatar.custom_minimum_size = Vector2(IMAGE_SIZE, IMAGE_SIZE)


func get_texture() -> Texture2D:
	return _thumb


## 刷新 Ban 状态显示（由 Main 在数据变化后调用）
##
## 单人模式说明：这里不再显示「票数」。因为分布式投票下每台电脑只代表一位玩家，
## 自己 Ban 了某个忍者就是 1 票，把「1」画成角标没有信息量还会误导。
## 现在徽章只表示「已加入我的 Ban 名单」，文字行给出名单摘要。
##
## list_text 传非空时显示在底部（例如「我的名单：鸣人、佐助 +3」）
func set_vote_state(p_banned: bool, count_text: String = "", list_text: String = "") -> void:
	banned = p_banned
	vote_count = 1 if p_banned else 0
	if _badge == null:
		return

	# 徽章：已 Ban 才显示，默认只显示一个勾，避免误读成票数
	_badge_holder.visible = p_banned
	_badge.text = count_text if count_text != "" else "✓"

	# 底部文字：优先用调用方给的名单摘要，否则退化成「已 Ban」
	var base := "%s\n照片ID：%s" % [character_name, photo]
	if group != "":
		base += "\n分组：%s" % group
	if p_banned:
		_voters_label.text = list_text if list_text != "" else "已 Ban"
		_voters_label.tooltip_text = list_text
		tooltip_text = "%s\n\n已在你的 Ban 名单里（再点一次取消）" % base
	else:
		_voters_label.text = ""
		_voters_label.tooltip_text = ""
		tooltip_text = base

	_apply_visual()


# ============================================================
#  交互
# ============================================================
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			_play_press()
			# 只发信号，票数怎么变由 Main 决定
			vote_toggled.emit(photo, not banned)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			accept_event()
			preview_requested.emit(photo)


func _on_mouse_enter() -> void:
	_hovered = true
	_apply_visual()
	_tween_scale(Vector2(HOVER_SCALE, HOVER_SCALE), Vector2(0, -LIFT))


func _on_mouse_exit() -> void:
	_hovered = false
	_apply_visual()
	_tween_scale(Vector2.ONE, Vector2.ZERO)


# ============================================================
#  视觉
# ============================================================
func _apply_visual() -> void:
	if _bg_panel == null:
		return
	_bg_panel.add_theme_stylebox_override("panel", _style_bg_hover if _hovered else _style_bg)
	# 选中时整体提亮一点，未选中略压暗
	if banned:
		modulate = Color(1.06, 1.06, 1.06, 1.0)
	elif _hovered:
		modulate = Color(1.0, 1.0, 1.0, 1.0)
	else:
		modulate = Color(0.94, 0.94, 0.94, 1.0)


func _tween_scale(target: Vector2, offset: Vector2) -> void:
	if _card_panel == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_update_pivot()
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card_panel, "scale", target, TWEEN_TIME)
	_tween.tween_property(_card_panel, "position", offset, TWEEN_TIME)


func _play_press() -> void:
	if _card_panel == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var target := Vector2(HOVER_SCALE, HOVER_SCALE) if _hovered else Vector2.ONE
	var off := Vector2(0, -LIFT) if _hovered else Vector2.ZERO
	_card_panel.scale = Vector2(0.95, 0.95)
	_card_panel.position = off
	_update_pivot()
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card_panel, "scale", target, 0.18)
	_tween.tween_property(_card_panel, "position", off, 0.18)


## 缩放中心固定在卡片正中，并抵消 hover 时的位移
func _update_pivot() -> void:
	if _card_panel == null:
		return
	var half := size * 0.5
	if _card_panel.scale.is_equal_approx(Vector2.ONE) and _card_panel.position.is_zero_approx():
		_card_panel.pivot_offset = half
	else:
		_card_panel.pivot_offset = half - _card_panel.position
