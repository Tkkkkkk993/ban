# ============================================================
#  ranking_row.gd —— 排名面板里的单行
# ------------------------------------------------------------
#  结构：PanelContainer(本脚本)
#          └ Margin > HBox
#              ├ RankLabel   名次（前 3 名用金银铜配色）
#              ├ AvatarFrame > Center > Avatar(TextureRect 32x32) / Placeholder
#              ├ NameLabel   忍者名
#              └ CountLabel  票数
#
#  点击整行会发 row_clicked，由 RankingPanel 转给 Main 去滚动定位到对应卡片。
# ============================================================
class_name RankingRow
extends PanelContainer

# UITheme 用 preload 引用（不依赖全局 class_name 注册，任何运行方式下都可用）
const UITheme := preload("res://scripts/ui_theme.gd")

## 点击整行：请求把左侧列表滚动到该卡片
signal row_clicked(photo: String)

const AVATAR_SIZE := 32
const COLOR_ROW := Color("202020")
const COLOR_ROW_ALT := Color("242424")
const COLOR_ROW_HOVER := Color("303030")
const COLOR_ACCENT := Color("FF6B00")
const COLOR_TEXT := Color("e8e8e8")
const COLOR_MUTED := Color("9a9a9a")

const MEDALS := [Color("ffd54a"), Color("cfd8dc"), Color("d08a4a")]   # 金 银 铜

var photo := ""                       # 照片 ID
var rank := 1
var ban_count := 0
var voter_names: Array = []

var _rank_label: Label
var _avatar: TextureRect
var _avatar_fallback: Label
var _name_label: Label
var _count_label: Label
var _style_normal: StyleBoxFlat
var _style_hover: StyleBoxFlat
var _style_alt: StyleBoxFlat
var _hovered := false
var _odd := false
var _pulse: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	refresh()


# ============================================================
#  构建界面
# ============================================================
func _build_ui() -> void:
	_style_normal = UITheme.make_style(COLOR_ROW, UITheme.RADIUS_SM)
	_style_alt = UITheme.make_style(COLOR_ROW_ALT, UITheme.RADIUS_SM)
	_style_hover = UITheme.make_style(COLOR_ROW_HOVER, UITheme.RADIUS_SM, Color(0, 0, 0, 0), COLOR_ACCENT, 1)
	add_theme_stylebox_override("panel", _style_normal)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", 6)
	margin.add_child(hbox)

	# 名次
	_rank_label = Label.new()
	_rank_label.name = "RankLabel"
	_rank_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rank_label.custom_minimum_size = Vector2(20, 0)
	_rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rank_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(_rank_label, 13, COLOR_MUTED)
	hbox.add_child(_rank_label)

	# 头像小图
	var frame := PanelContainer.new()
	frame.name = "AvatarFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("1a1a1a"), 5, Color(0, 0, 0, 0), Color("3a3a3a"), 1))
	hbox.add_child(frame)

	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(center)

	_avatar = TextureRect.new()
	_avatar.name = "Avatar"
	_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	center.add_child(_avatar)

	_avatar_fallback = Label.new()
	_avatar_fallback.name = "Placeholder"
	_avatar_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_fallback.text = "?"
	_avatar_fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_avatar_fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(_avatar_fallback, 14, Color("555555"))
	frame.add_child(_avatar_fallback)

	# 名字
	_name_label = Label.new()
	_name_label.name = "NameLabel"
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UITheme.style_label(_name_label, 12, COLOR_TEXT)
	hbox.add_child(_name_label)

	# 票数
	_count_label = Label.new()
	_count_label.name = "CountLabel"
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.custom_minimum_size = Vector2(34, 0)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(_count_label, 13, COLOR_ACCENT)
	hbox.add_child(_count_label)


# ============================================================
#  对外设置
# ============================================================

## 一次性设置整行内容
func setup(p_rank: int, p_photo: String, p_name: String, p_count: int,
		p_voter_names: Array = [], p_odd: bool = false) -> void:
	rank = p_rank
	photo = p_photo
	ban_count = p_count
	voter_names = p_voter_names
	_odd = p_odd
	if _name_label != null:
		_name_label.text = p_name if p_name != "" else p_photo
	if _count_label != null:
		_count_label.text = str(p_count)
	refresh()


## 只更新名次与票数（重排时用，避免整行重建）
func update_stats(p_rank: int, p_count: int, p_voter_names: Array = []) -> void:
	rank = p_rank
	ban_count = p_count
	if not p_voter_names.is_empty() or voter_names.is_empty():
		voter_names = p_voter_names
	refresh()


func set_texture(tex: Texture2D) -> void:
	if _avatar == null:
		return
	_avatar.texture = tex
	_avatar_fallback.visible = (tex == null)


## 刷新名次配色、票数、提示
func refresh() -> void:
	if _rank_label == null:
		return
	_rank_label.text = str(rank)
	# 前 3 名用金银铜，其余灰色
	var col := COLOR_MUTED
	if rank >= 1 and rank <= 3:
		col = MEDALS[rank - 1]
	UITheme.style_label(_rank_label, 15 if rank <= 3 else 13, col)

	if _count_label != null:
		_count_label.text = str(ban_count)

	add_theme_stylebox_override("panel", _style_hover if _hovered else (_style_alt if _odd else _style_normal))

	var tip := "照片ID：%s\n被 Ban %d 次" % [photo, ban_count]
	if not voter_names.is_empty():
		tip += "\n投票人：%s" % "、".join(voter_names)
	tooltip_text = tip


## 名次变化时闪一下，让重排看得见
func pulse() -> void:
	if _pulse != null and _pulse.is_valid():
		_pulse.kill()
	modulate = Color(1.35, 1.2, 1.0, 1.0)
	_pulse = create_tween()
	_pulse.tween_property(self, "modulate", Color.WHITE, 0.45)


# ============================================================
#  交互
# ============================================================
func _on_enter() -> void:
	_hovered = true
	refresh()


func _on_exit() -> void:
	_hovered = false
	refresh()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			row_clicked.emit(photo)
