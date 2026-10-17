# ============================================================
#  result_dialog.gd —— Ban 选结果弹窗
# ------------------------------------------------------------
#  继承 AcceptDialog（本身就是一个 Window），内容全部代码构建。
#
#  结构：
#      ResultDialog (AcceptDialog)
#        └ Root (MarginContainer)
#            └ VBox
#                ├ HeaderBox : TitleLabel + SubtitleLabel
#                ├ CtrlBox   : "取前 N 名" + SpinBox + 刷新预览
#                ├ ScrollContainer
#                │    └ ResultGrid (GridContainer)   ← 头像 + 名字 + 票数
#                ├ NotifyLabel   （复制/导出结果提示）
#                └ FooterBox  : 复制文本 / 导出JSON / 导出PNG
#
#  导出 PNG 走 SubViewport 离屏渲染，不受弹窗大小和窗口遮挡影响。
# ============================================================
class_name ResultDialog
extends AcceptDialog

# UITheme 用 preload 引用（不依赖全局 class_name 注册，任何运行方式下都可用）
const UITheme := preload("res://scripts/ui_theme.gd")

signal export_finished(kind: String, ok: bool, path: String)

const GRID_COLUMNS := 5
const CELL_AVATAR := 96
const CELL_W := 150
const CELL_H := 190             # 名字两行 + 票数 + 一行投票人，留够高度免得被裁
const RESULT_PNG_WIDTH := 1024        # 导出 PNG 的目标宽度
const DEF_TOP_N := 5

@onready var _root: MarginContainer = $Root
@onready var _vbox: VBoxContainer = $Root/VBox
@onready var _title_label: Label = $Root/VBox/HeaderBox/TitleLabel
@onready var _subtitle_label: Label = $Root/VBox/HeaderBox/SubtitleLabel
@onready var _spin: SpinBox = $Root/VBox/CtrlBox/Spin
@onready var _refresh_btn: Button = $Root/VBox/CtrlBox/RefreshBtn
@onready var _scroll: ScrollContainer = $Root/VBox/ScrollContainer
@onready var _grid: GridContainer = $Root/VBox/ScrollContainer/ResultGrid
@onready var _notify: Label = $Root/VBox/NotifyLabel
@onready var _copy_btn: Button = $Root/VBox/FooterBox/CopyBtn
@onready var _json_btn: Button = $Root/VBox/FooterBox/JsonBtn
@onready var _png_btn: Button = $Root/VBox/FooterBox/PngBtn

## 当前展示的数据：[[照片ID, 票数, 显示名, [投票人...]], ...]
var _data: Array = []
var _timestamp := ""
var _exporting := false


func _ready() -> void:
	_setup_window()
	_setup_controls()
	_wire_signals()
	_notify.text = ""


# ============================================================
#  初始化
# ============================================================
func _setup_window() -> void:
	title = "公共 Ban 选结果"
	# 去掉默认的 OK 按钮，底部换成我们自己的三个按钮
	var ok := get_ok_button()
	if ok != null:
		ok.visible = false
	exclusive = false
	transient = true
	unresizable = false
	min_size = Vector2i(720, 560)
	add_theme_stylebox_override("panel", UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG,
		Color(0, 0, 0, 0.6), UITheme.BORDER, 1, 14))
	_root.add_theme_constant_override("margin_left", 16)
	_root.add_theme_constant_override("margin_right", 16)
	_root.add_theme_constant_override("margin_top", 10)
	_root.add_theme_constant_override("margin_bottom", 10)
	_vbox.add_theme_constant_override("separation", 8)
	_scroll.add_theme_stylebox_override("panel", UITheme.make_style(Color("151515"), UITheme.RADIUS_MD))
	UITheme.apply_scroll(_scroll)


func _setup_controls() -> void:
	UITheme.style_label(_title_label, 20, UITheme.TEXT)
	UITheme.style_label(_subtitle_label, 11, UITheme.TEXT_MUTED)
	UITheme.style_label(_notify, 11, UITheme.ACCENT)

	_spin.min_value = 1
	_spin.max_value = 99
	_spin.step = 1
	_spin.value = DEF_TOP_N
	_spin.select_all_on_focus = true
	UITheme.apply_input(_spin)
	var line := _spin.get_line_edit()
	if line != null:
		UITheme.apply_input(line)

	UITheme.apply_button(_refresh_btn)
	UITheme.apply_button(_copy_btn)
	UITheme.apply_button(_json_btn)
	UITheme.apply_button_primary(_png_btn)
	_refresh_btn.text = "刷新预览"
	_copy_btn.text = "复制文本"
	_json_btn.text = "导出 JSON"
	_png_btn.text = "导出 PNG"

	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)


func _wire_signals() -> void:
	_spin.value_changed.connect(_on_spin_changed)
	_refresh_btn.pressed.connect(_rebuild_grid)
	_copy_btn.pressed.connect(_on_copy)
	_json_btn.pressed.connect(_on_export_json)
	_png_btn.pressed.connect(_on_export_png)
	confirmed.connect(_on_confirmed)


# ============================================================
#  对外接口
# ============================================================

## 显示结果。ranking 为 [[照片ID, 票数, 显示名, [投票人...]], ...]
func show_result(ranking: Array) -> void:
	_data = ranking.duplicate()
	_timestamp = _make_timestamp()
	_notify.text = ""
	if ranking.is_empty():
		_title_label.text = "还没有任何 Ban 记录"
		_subtitle_label.text = "先在主界面给忍者投票，再来生成结果"
		_clear_grid()
	else:
		_rebuild_grid()
	popup_centered(Vector2i(860, 640))


func get_timestamp() -> String:
	if _timestamp == "":
		_timestamp = _make_timestamp()
	return _timestamp


func _make_timestamp() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")


## 复制的纯文本格式
func build_text() -> String:
	var n: int = mini(int(_spin.value), _data.size())
	var lines: Array[String] = []
	lines.append("公共Ban选（Top %d）：" % n)
	if _data.is_empty():
		lines.append("（暂无投票记录）")
	else:
		for i in range(n):
			var it: Array = _data[i]
			var disp := String(it[2]) if it.size() > 2 else String(it[0])
			lines.append("%d. %s - %d票" % [i + 1, disp, int(it[1])])
			var voters: Array = it[3] if it.size() > 3 else []
			if not voters.is_empty():
				lines.append("   （被 %s Ban）" % "、".join(voters))
	lines.append("")
	lines.append("生成时间：%s" % Time.get_datetime_string_from_system())
	return "\n".join(lines)


## JSON 结构
func build_json_dict() -> Dictionary:
	var n: int = mini(int(_spin.value), _data.size())
	var picks: Array = []
	for i in range(n):
		var it: Array = _data[i]
		picks.append({
			"rank": i + 1,
			"photo": String(it[0]),
			"name": String(it[2]) if it.size() > 2 else String(it[0]),
			"ban_count": int(it[1]),
			"voters": it[3] if it.size() > 3 else [],
		})
	return {
		"title": "公共Ban选",
		"top_n": n,
		"generated_at": Time.get_datetime_string_from_system(),
		"generated_unix": int(Time.get_unix_time_from_system()),
		"total_voters": DataManager.get_voter_count(),
		"total_ban_marks": DataManager.get_total_ban_marks(),
		"total_characters": ImageLoader.photos.size(),
		"ban_limit_enabled": DataManager.ban_limit_enabled,
		"ban_limit": DataManager.ban_limit,
		"picks": picks,
	}


# ============================================================
#  结果区
# ============================================================
func _clear_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()


func _rebuild_grid() -> void:
	_clear_grid()
	var n: int = mini(int(_spin.value), _data.size())
	_title_label.text = "公共 Ban 选 · Top %d" % n
	_subtitle_label.text = "共 %d 项有效投票 · 生成于 %s" % [
		_data.size(), Time.get_datetime_string_from_system()]
	for i in range(n):
		_grid.add_child(_make_cell(i + 1, _data[i]))


func _make_cell(rank: int, item: Array) -> Control:
	var photo := String(item[0])
	var count := int(item[1])
	var disp := String(item[2]) if item.size() > 2 else photo
	var voters: Array = item[3] if item.size() > 3 else []

	var card := PanelContainer.new()
	card.name = "Cell_%s" % photo
	card.custom_minimum_size = Vector2(CELL_W, CELL_H)
	card.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.CARD_BG, UITheme.RADIUS_MD, Color(0, 0, 0, 0.4),
			UITheme.ACCENT if rank <= 3 else UITheme.BORDER, 2 if rank <= 3 else 1, 4))

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 6)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	margin.add_child(vbox)

	# 名次
	var rank_lbl := Label.new()
	rank_lbl.text = "第 %d 名" % rank
	rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(rank_lbl, 11, UITheme.ACCENT if rank <= 3 else UITheme.TEXT_MUTED)
	vbox.add_child(rank_lbl)

	# 头像
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(CELL_AVATAR, CELL_AVATAR)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("1f1f1f"), 8, Color(0, 0, 0, 0), UITheme.BORDER, 1))
	vbox.add_child(frame)

	var center := CenterContainer.new()
	frame.add_child(center)

	var tex := ImageLoader.get_thumbnail(photo)
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(CELL_AVATAR, CELL_AVATAR)
	tr.texture = tex
	center.add_child(tr)
	if tex == null:
		var ph := Label.new()
		ph.text = "无图"
		ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UITheme.style_label(ph, 12, Color("666666"))
		frame.add_child(ph)

	# 名字
	var name_lbl := Label.new()
	name_lbl.text = disp
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.max_lines_visible = 2
	name_lbl.tooltip_text = "%s\n照片ID：%s" % [disp, photo]
	UITheme.style_label(name_lbl, 12, UITheme.TEXT)
	vbox.add_child(name_lbl)

	# 票数
	var count_lbl := Label.new()
	count_lbl.text = "%d 票" % count
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(count_lbl, 13, UITheme.ACCENT)
	vbox.add_child(count_lbl)

	# 被谁 Ban（只留一行，用省略号截断，避免把格子和导出图撑变形）
	var voter_lbl := Label.new()
	voter_lbl.text = "、".join(voters) if not voters.is_empty() else "—"
	voter_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voter_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	voter_lbl.max_lines_visible = 1
	voter_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	voter_lbl.tooltip_text = "、".join(voters) if not voters.is_empty() else "没有人 Ban"
	UITheme.style_label(voter_lbl, 10, UITheme.TEXT_MUTED)
	vbox.add_child(voter_lbl)

	return card


# ============================================================
#  三个导出动作
# ============================================================
func _on_spin_changed(_v: float) -> void:
	if is_visible():
		_rebuild_grid()


func _on_confirmed() -> void:
	hide()


func _on_copy() -> void:
	var text := build_text()
	DisplayServer.clipboard_set(text)
	_notify.text = "已复制到剪贴板（%d 行）" % text.split("\n").size()
	_notify.add_theme_color_override("font_color", UITheme.ACCENT)


func _on_export_json() -> void:
	var path := "user://ban_result_%s.json" % get_timestamp()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("JSON 写入失败 (err=%d)" % FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(build_json_dict(), "\t"))
	f.close()
	_succeed("已导出 JSON", path, "json")


func _on_export_png() -> void:
	if _exporting:
		return
	_exporting = true
	_png_btn.disabled = true
	_notify.text = "正在渲染 PNG..."
	var path := "user://ban_result_%s.png" % get_timestamp()
	var ok: bool = await _render_grid_to_png(path)
	_exporting = false
	_png_btn.disabled = false
	if ok:
		_succeed("已导出 PNG", path, "png")
	else:
		_fail("PNG 渲染失败，请重试")


## 用 SubViewport 离屏渲染结果网格并写盘
func _render_grid_to_png(path: String) -> bool:
	# headless（dummy 渲染器）没有纹理可读，直接说明原因而不是静默失败
	if DisplayServer.get_name() == "headless":
		push_warning("[ResultDialog] 当前是 headless 模式（无渲染器），无法导出 PNG。")
		return false

	var card_count: int = mini(int(_spin.value), _data.size())
	if card_count <= 0:
		return false

	var cols: int = mini(GRID_COLUMNS, card_count)
	var rows: int = int(ceil(float(card_count) / float(cols)))
	var pad := 16
	var gap := 10
	var grid_w: int = cols * CELL_W + (cols - 1) * gap
	var grid_h: int = rows * CELL_H + (rows - 1) * gap
	var out_w := maxi(RESULT_PNG_WIDTH, grid_w + pad * 2)
	var out_h := grid_h + pad * 2

	var sv := SubViewport.new()
	sv.name = "ExportViewport"
	sv.size = Vector2i(out_w, out_h)
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.disable_3d = true
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.position = Vector2.ZERO
	bg.size = Vector2(out_w, out_h)
	sv.add_child(bg)

	var holder := Control.new()
	holder.position = Vector2(pad, pad)
	holder.size = Vector2(grid_w, grid_h)
	sv.add_child(holder)

	var grid := GridContainer.new()
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", gap)
	grid.add_theme_constant_override("v_separation", gap)
	grid.position = Vector2.ZERO
	holder.add_child(grid)

	for i in range(card_count):
		grid.add_child(_make_cell(i + 1, _data[i]))

	# 等渲染完。headless（dummy 渲染器）不会发 frame_post_draw，
	# 直接 await 那个信号会永久挂住，所以「信号 + 超时」二选一。
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait_post_draw(0.4)

	var img := sv.get_texture().get_image()
	sv.queue_free()
	if img == null or img.is_empty():
		return false
	var err: int = img.save_png(path)
	if err != OK:
		push_warning("[ResultDialog] PNG 写盘失败：%s (err=%d)" % [path, err])
		return false
	return true


## 等一次绘制完成，但最多等 timeout_sec 秒（没渲染时靠超时兜底，不永久挂住）
func _wait_post_draw(timeout_sec: float) -> void:
	var flag := {"done": false}
	var mark := func() -> void: flag["done"] = true
	RenderingServer.frame_post_draw.connect(mark, CONNECT_ONE_SHOT)
	var elapsed := 0.0
	while elapsed < timeout_sec and not bool(flag["done"]):
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	if not bool(flag["done"]) and RenderingServer.frame_post_draw.is_connected(mark):
		RenderingServer.frame_post_draw.disconnect(mark)


func _succeed(msg: String, path: String, kind: String) -> void:
	_notify.text = "%s → %s" % [msg, ProjectSettings.globalize_path(path)]
	_notify.add_theme_color_override("font_color", Color("7ddc7d"))
	export_finished.emit(kind, true, path)


func _fail(msg: String) -> void:
	_notify.text = msg
	_notify.add_theme_color_override("font_color", UITheme.DANGER)
	export_finished.emit("", false, "")
