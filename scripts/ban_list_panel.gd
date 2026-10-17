# ============================================================
#  ban_list_panel.gd —— 右侧「我的 Ban 名单」面板
# ------------------------------------------------------------
#  分布式单人投票版的右侧栏：只显示我自己 Ban 掉的忍者（不是跨人票数）。
#
#  结构：
#      BanListPanel (PanelContainer)            宽 280
#        └ Margin > VBox
#            ├ Header (PanelContainer) > HBox
#            │    ├ TitleLabel  "我的 Ban 名单"
#            │    └ CountLabel  "0 个"
#            ├ Separator
#            ├ ScrollContainer
#            │    └ ListBox (VBoxContainer)   ← 每行一个 BanRow（运行时创建）
#            └ EmptyHint (Label)             名单为空时的提示
#
#  每一行：名次 | 小头像 | 名字 | [移除]
#    · 点「移除」→ 发 unban_requested(photo)，由 Main 调 DataManager 取消
#    · 点整行   → 发 row_clicked(photo)，由 Main 滚动定位到对应卡片
# ============================================================
class_name BanListPanel
extends PanelContainer

const UITheme := preload("res://scripts/ui_theme.gd")

## 点了某一行的「移除」
signal unban_requested(photo: String)
## 点了整行，希望滚动定位到卡片
signal row_clicked(photo: String)

const AVATAR_SIZE := 30
const ROW_HEIGHT := 42
const MAX_ROWS := 400

@onready var _title_label: Label = $Margin/VBox/Header/HeaderMargin/HeaderBox/TitleLabel
@onready var _count_label: Label = $Margin/VBox/Header/HeaderMargin/HeaderBox/CountLabel
@onready var _scroll: ScrollContainer = $Margin/VBox/ScrollContainer
@onready var _list_box: VBoxContainer = $Margin/VBox/ScrollContainer/ListBox
@onready var _empty_hint: Label = $Margin/VBox/EmptyHint

var _rows: Array[Control] = []
## _ready 之前 refresh() 传进来的数据，等 _ready 再补上
var _pending: Array = []


func _ready() -> void:
	UITheme.apply_scroll(_scroll)
	# 面板整体皮肤
	add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG_PANEL, UITheme.RADIUS_MD, Color(0, 0, 0, 0.35),
			UITheme.BORDER, 1, 4))
	UITheme.style_label(_title_label, 14, UITheme.TEXT)
	UITheme.style_label(_count_label, 11, UITheme.TEXT_MUTED)
	UITheme.style_label(_empty_hint, 12, Color("7a7a7a"))
	# 补上 _ready 之前来的数据
	if not _pending.is_empty():
		var p := _pending
		_pending = []
		refresh(p)


## 刷新列表。
## entries: [[photo, 显示名], ...]（顺序就是 Ban 的顺序）
## name_resolver: 可选，Callable(photo) -> 显示名
func refresh(entries: Array) -> void:
	# _ready 之前被调用时（@onready 变量还是 null）先记下来，等 _ready 再补
	if _list_box == null:
		_pending = entries
		return
	var n := entries.size()
	_count_label.text = "%d 个" % n
	_empty_hint.visible = (n == 0)
	_scroll.visible = (n > 0)

	# 行数对齐（复用已有行，避免每次重建）
	while _rows.size() < mini(n, MAX_ROWS):
		var row := _make_row()
		_list_box.add_child(row)
		_rows.append(row)
	while _rows.size() > mini(n, MAX_ROWS):
		var dead: Control = _rows.pop_back()
		dead.queue_free()

	for i in range(mini(n, MAX_ROWS)):
		_fill_row(_rows[i], i + 1, entries[i])


func _make_row() -> Control:
	# 【坑】Container 会自动给孩子起名（MarginContainer 的孩子默认叫 "Box"），
	# 如果我自己再设 hb.name="Box"，Godot 会改名成 "@HBoxContainer@123"，
	# 之后所有 get_node("Box/...") 全部找不到。
	# 所以这里**每个节点都显式命名**，并且避开 Godot 的默认类名。
	var root := PanelContainer.new()
	root.name = "BanRow"
	root.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("232323"), UITheme.RADIUS_SM))

	var m := MarginContainer.new()
	m.name = "RowMargin"
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_theme_constant_override("margin_left", 5)
	m.add_theme_constant_override("margin_right", 4)
	m.add_theme_constant_override("margin_top", 3)
	m.add_theme_constant_override("margin_bottom", 3)
	root.add_child(m)

	var hb := HBoxContainer.new()
	hb.name = "RowBox"
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 5)
	m.add_child(hb)

	var idx := Label.new()
	idx.name = "Index"
	idx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idx.custom_minimum_size = Vector2(18, 0)
	idx.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	idx.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(idx, 11, UITheme.TEXT_MUTED)
	hb.add_child(idx)

	var frame := PanelContainer.new()
	frame.name = "AvatarFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("161616"), 4, Color(0, 0, 0, 0), UITheme.BORDER, 1))
	hb.add_child(frame)

	var center := CenterContainer.new()
	center.name = "AvatarCenter"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(center)

	var tex := TextureRect.new()
	tex.name = "Avatar"
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	center.add_child(tex)

	var ph := Label.new()
	ph.name = "Placeholder"
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ph.text = "?"
	ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(ph, 12, Color("555555"))
	frame.add_child(ph)

	var name_lbl := Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UITheme.style_label(name_lbl, 12, UITheme.TEXT)
	hb.add_child(name_lbl)

	var btn := Button.new()
	btn.name = "RemoveBtn"
	btn.text = "移除"
	btn.tooltip_text = "把这个忍者从我的 Ban 名单里去掉"
	btn.custom_minimum_size = Vector2(44, 26)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UITheme.apply_button_danger(btn)
	hb.add_child(btn)

	return root


func _fill_row(row: Control, index: int, entry: Array) -> void:
	var photo := String(entry[0]) if entry.size() > 0 else ""
	var disp := String(entry[1]) if entry.size() > 1 else photo

	# 用完整的真实路径取节点（RowMargin/RowBox），找不到就跳过而不是崩
	var box := row.get_node_or_null("RowMargin/RowBox")
	if box == null:
		push_warning("[BanListPanel] 行结构异常，找不到 RowBox")
		return
	var idx_lbl := box.get_node_or_null("Index") as Label
	if idx_lbl != null:
		idx_lbl.text = str(index)
	var name_lbl := box.get_node_or_null("NameLabel") as Label
	if name_lbl != null:
		name_lbl.text = disp
	row.tooltip_text = "%s\n照片ID：%s\n（点这一行可定位到卡片）" % [disp, photo]

	# 头像：内存里没有就先显示占位
	var tex_rect := box.get_node_or_null("AvatarFrame/AvatarCenter/Avatar") as TextureRect
	var ph := box.get_node_or_null("AvatarFrame/Placeholder") as Label
	if tex_rect != null:
		var tex: Texture2D = ImageLoader.resolve_texture(photo)
		if tex != null:
			tex_rect.texture = tex
			if ph != null:
				ph.visible = false
		else:
			tex_rect.texture = null
			if ph != null:
				ph.visible = true

	# 信号：先断开旧的，避免复用行时重复连接
	var btn := box.get_node_or_null("RemoveBtn") as Button
	if btn != null:
		for c in btn.pressed.get_connections():
			btn.pressed.disconnect(c["callable"])
		btn.pressed.connect(func() -> void: unban_requested.emit(photo))

	for c2 in row.gui_input.get_connections():
		row.gui_input.disconnect(c2["callable"])
	row.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				row.accept_event()
				row_clicked.emit(photo))
