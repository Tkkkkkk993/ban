# ============================================================
#  organizer.gd —— 组织者端主逻辑
# ------------------------------------------------------------
#  收 30 份群友导出的 vote_*.json，合并出最终 Top N。
#
#  流程：
#    1. 拖拽 / 选文件 / 选文件夹 导入
#    2. VoteImporter 校验格式 → 同一 voter_id 取最新 → 合并统计（同人重复只算一次）
#    3. 展示：参与人数、每人 Ban 了几个、总 Ban 次数、坏文件与重复投票提醒
#    4. 导出 final_result.json / final_result.png / final_result.txt
#
#  进入方式：玩家端「组织者模式」（要口令）或命令行 --organizer
# ============================================================
class_name OrganizerApp
extends Control

const UITheme := preload("res://scripts/ui_theme.gd")
const VoteImporter := preload("res://scripts/vote_importer.gd")

const PLAYER_SCENE := "res://scenes/Main.tscn"
const EXPORT_DIR := "user://exports"
const TOP_GRID_LIMIT := 60          # 网格最多画多少个，避免一次性画几百个
const TABLE_MAX_ROWS := 120         # 明细表最多多少行
const CELL_W := 150
const CELL_H := 190
const RESULT_PNG_WIDTH := 1024

@onready var _player_btn: Button = $Root/VBox/HeaderBox/HeaderRow/PlayerModeBtn
@onready var _toolbar: HBoxContainer = $Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar
@onready var _summary_label: Label = $Root/VBox/SummaryWrap/SummaryBox/SummaryVBox/SummaryLabel
@onready var _detail_label: Label = $Root/VBox/SummaryWrap/SummaryBox/SummaryVBox/DetailLabel
@onready var _body_box: VBoxContainer = $Root/VBox/Body/BodyBox
@onready var _body_margin: MarginContainer = $Root/VBox/Body/BodyBox/BodyMargin
@onready var _top_grid: GridContainer = $Root/VBox/Body/BodyBox/BodyMargin/TopGrid
@onready var _status_label: Label = $Root/VBox/StatusBarWrap/StatusLabel

var _file_dialog: FileDialog
var _dir_dialog: FileDialog
var _import_btn: Button
var _folder_btn: Button
var _clear_btn: Button
var _json_btn: Button
var _png_btn: Button
var _txt_btn: Button
var _top_spin: SpinBox
var _refresh_btn: Button
var _loaded_label: Label

var _stats: Dictionary = {}
var _loaded_files: Array = []        # 已导入的文件路径
var _table_box: VBoxContainer = null
var _exporting := false


func _ready() -> void:
	_build_toolbar()
	_build_file_dialogs()

	_player_btn.pressed.connect(_on_back_to_player)
	UITheme.apply_button(_player_btn)
	get_window().files_dropped.connect(_on_files_dropped)
	get_window().title = "Naruto Ban Picker - 组织者模式"

	# 组织者端也要头像，用来在排名里显示
	_status_label.text = "正在扫描头像目录…"
	ImageLoader.scan_directory()
	ImageLoader.batch_loaded.connect(_on_batch_loaded)
	ImageLoader.scan_finished.connect(_on_scan_finished)

	_render()


# ============================================================
#  工具栏
# ============================================================
func _build_toolbar() -> void:
	_import_btn = Button.new()
	_import_btn.name = "ImportFilesBtn"
	_import_btn.text = "导入文件"
	_import_btn.tooltip_text = "选择一个或多个 vote_*.json（可按住 Ctrl 多选）"
	UITheme.apply_button_primary(_import_btn)
	_import_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_import_btn.pressed.connect(func() -> void: _file_dialog.popup_centered(Vector2i(860, 600)))
	_toolbar.add_child(_import_btn)

	_folder_btn = Button.new()
	_folder_btn.name = "ImportFolderBtn"
	_folder_btn.text = "导入文件夹"
	_folder_btn.tooltip_text = "选一个文件夹，把这个文件夹里的所有 json 都导进来"
	UITheme.apply_button(_folder_btn)
	_folder_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_folder_btn.pressed.connect(func() -> void: _dir_dialog.popup_centered(Vector2i(860, 600)))
	_toolbar.add_child(_folder_btn)

	_clear_btn = Button.new()
	_clear_btn.name = "ClearBtn"
	_clear_btn.text = "清空已导入"
	UITheme.apply_button_danger(_clear_btn)
	_clear_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_clear_btn.pressed.connect(_on_clear_pressed)
	_toolbar.add_child(_clear_btn)

	_toolbar.add_child(VSeparator.new())

	var top_hint := Label.new()
	top_hint.text = "取前"
	UITheme.style_label(top_hint, 11, UITheme.TEXT_MUTED)
	top_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(top_hint)

	_top_spin = SpinBox.new()
	_top_spin.name = "TopSpin"
	_top_spin.min_value = 1
	_top_spin.max_value = 999
	_top_spin.step = 1
	_top_spin.value = 5
	_top_spin.custom_minimum_size = Vector2(86, 32)
	_top_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top_spin.tooltip_text = "网格里显示前多少名（明细里始终是全部）"
	UITheme.apply_input(_top_spin)
	_toolbar.add_child(_top_spin)

	var top_hint2 := Label.new()
	top_hint2.text = "名（999 = 全部）"
	UITheme.style_label(top_hint2, 11, UITheme.TEXT_MUTED)
	top_hint2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(top_hint2)

	_refresh_btn = Button.new()
	_refresh_btn.name = "RefreshBtn"
	_refresh_btn.text = "刷新视图"
	UITheme.apply_button(_refresh_btn)
	_refresh_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_refresh_btn.pressed.connect(_render)
	_toolbar.add_child(_refresh_btn)

	_toolbar.add_child(VSeparator.new())

	_json_btn = Button.new()
	_json_btn.name = "ExportJsonBtn"
	_json_btn.text = "导出汇总 JSON"
	UITheme.apply_button(_json_btn)
	_json_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_json_btn.pressed.connect(_on_export_json)
	_toolbar.add_child(_json_btn)

	_png_btn = Button.new()
	_png_btn.name = "ExportPngBtn"
	_png_btn.text = "导出汇总 PNG"
	UITheme.apply_button(_png_btn)
	_png_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_png_btn.pressed.connect(_on_export_png)
	_toolbar.add_child(_png_btn)

	_txt_btn = Button.new()
	_txt_btn.name = "ExportTxtBtn"
	_txt_btn.text = "导出汇总 TXT"
	UITheme.apply_button(_txt_btn)
	_txt_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_txt_btn.pressed.connect(_on_export_txt)
	_toolbar.add_child(_txt_btn)

	_toolbar.add_child(VSeparator.new())

	_loaded_label = Label.new()
	_loaded_label.name = "LoadedLabel"
	_loaded_label.text = "已导入 0 个文件"
	UITheme.style_label(_loaded_label, 11, UITheme.TEXT_MUTED)
	_loaded_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(_loaded_label)


func _build_file_dialogs() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.name = "FilePicker"
	_file_dialog.title = "选择群友发来的投票 json（可多选）"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.add_filter("*.json", "投票 json")
	_file_dialog.files_selected.connect(_on_files_selected)
	add_child(_file_dialog)

	_dir_dialog = FileDialog.new()
	_dir_dialog.name = "DirPicker"
	_dir_dialog.title = "选择装着投票 json 的文件夹"
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dialog.use_native_dialog = true
	_dir_dialog.dir_selected.connect(_on_dir_selected)
	add_child(_dir_dialog)


# ============================================================
#  导入
# ============================================================
func _on_files_selected(paths: PackedStringArray) -> void:
	var list: Array = []
	for p in paths:
		list.append(String(p))
	_do_import(list)


func _on_dir_selected(path: String) -> void:
	_do_import([path])


func _on_files_dropped(files: PackedStringArray) -> void:
	var list: Array = []
	for f in files:
		var s := String(f)
		# 目录也能拖进来
		if DirAccess.dir_exists_absolute(s):
			list.append(s)
		elif s.get_extension().to_lower() == "json":
			list.append(s)
		else:
			_status_label.text = "已忽略非 json 文件：%s" % s.get_file()
	if list.is_empty():
		if files.size() > 0:
			_status_label.text = "拖进来的东西里没有 json 文件。"
		return
	_do_import(list)


func _do_import(paths: Array) -> void:
	_status_label.text = "正在导入 %d 项…" % paths.size()
	# 过滤掉已经导入过的，避免重复拖同一个文件
	var fresh: Array = []
	var skipped := 0
	for p in paths:
		var s := String(p)
		if _loaded_files.has(s):
			skipped += 1
			continue
		fresh.append(s)
		_loaded_files.append(s)
	if fresh.is_empty():
		_status_label.text = "这些文件之前已经导入过了（跳过 %d 项）。" % skipped
		return

	var st: Dictionary = VoteImporter.import_paths(fresh)
	# 把之前导入的结果一起算进去：直接把累计文件列表重新统计一次最稳妥
	if _loaded_files.size() > fresh.size():
		st = VoteImporter.import_paths(_loaded_files)
	_stats = st
	_render()
	var errs: Array = st.get("errors", [])
	var dups: Array = st.get("duplicates", [])
	_status_label.text = "导入完成：本次 %d 项，累计 %d 个文件，有效 %d 人；坏文件 %d，重复投票 %d。" % [
		fresh.size(), _loaded_files.size(), int(st.get("voter_count", 0)),
		errs.size(), dups.size()]


func _on_clear_pressed() -> void:
	_loaded_files.clear()
	_stats = {}
	_render()
	_status_label.text = "已清空导入记录。"


# ============================================================
#  渲染
# ============================================================
func _on_scan_finished(_found: bool, _items: Array) -> void:
	# 头像目录扫描完，重新画一次（这样排名里就有图了）
	_render_top_grid()


func _on_batch_loaded(_items: Array) -> void:
	if _top_grid.get_child_count() > 0:
		_render_top_grid()


func _render() -> void:
	_update_loaded_label()
	_render_summary()
	_render_top_grid()
	_render_table()
	_update_button_state()


func _update_loaded_label() -> void:
	if _loaded_label != null:
		_loaded_label.text = "已导入 %d 个文件" % _loaded_files.size()


func _render_summary() -> void:
	if _stats.is_empty():
		_summary_label.text = "还没有导入任何投票文件。\n把群友发来的 vote_*.json 拖进这个窗口，或点上面的「导入文件 / 导入文件夹」。"
		_detail_label.text = ""
		return

	var vc := int(_stats.get("voter_count", 0))
	var ranking: Array = _stats.get("ranking", [])
	var errs: Array = _stats.get("errors", [])
	var dups: Array = _stats.get("duplicates", [])
	var parts: Array[String] = []
	parts.append("参与 %d 人" % vc)
	parts.append("被 Ban 过的忍者 %d 个" % ranking.size())
	var total_marks := 0
	for r in ranking:
		total_marks += int((r as Dictionary).get("count", 0))
	parts.append("总 Ban 次数 %d" % total_marks)
	parts.append("文件 %d 个" % int(_stats.get("file_count", 0)))
	if not dups.is_empty():
		parts.append("⚠ 重复投票 %d 位" % dups.size())
	if not errs.is_empty():
		parts.append("⚠ 坏文件 %d 个" % errs.size())
	_summary_label.text = "  |  ".join(parts)

	# 明细：每人 Ban 了几个
	var lines: Array[String] = []
	var voters: Array = _stats.get("voters", [])
	var names: Array[String] = []
	for v in voters:
		var d: Dictionary = v
		names.append("%s(%d)" % [String(d.get("voter_name", "?")), int(d.get("count", 0))])
	if not names.is_empty():
		lines.append("每人 Ban 数：" + "、".join(names))
	for d in dups:
		var dd: Dictionary = d
		lines.append("重复投票：%s 交了多份，已用最新一份（%s），丢弃（%s）" % [
			String(dd.get("voter_name", "?")),
			String(dd.get("kept_file", "")).get_file(),
			String(dd.get("dropped_file", "")).get_file()])
	for e in errs:
		var ee: Dictionary = e
		lines.append("已跳过：%s（%s）" % [
			String(ee.get("file", "")).get_file(), String(ee.get("reason", ""))])
	_detail_label.text = "\n".join(lines)


func _top_n() -> int:
	if _stats.is_empty():
		return 0
	var ranking: Array = _stats.get("ranking", [])
	var n := int(_top_spin.value) if _top_spin != null else 5
	if n >= 999 or n >= ranking.size():
		return ranking.size()
	return n


func _render_top_grid() -> void:
	if _top_grid == null:
		return
	for c in _top_grid.get_children():
		c.queue_free()
	if _stats.is_empty():
		return

	var ranking: Array = _stats.get("ranking", [])
	var n: int = mini(_top_n(), TOP_GRID_LIMIT)
	var cols: int = clampi(n, 1, 5)
	_top_grid.columns = cols
	for i in range(n):
		_top_grid.add_child(_make_cell(i + 1, ranking[i] as Dictionary))


func _make_cell(rank: int, rec: Dictionary) -> Control:
	var photo := String(rec.get("file", ""))
	var count := int(rec.get("count", 0))
	var voters: Array = rec.get("voters", [])
	var disp := ImageLoader.get_display_name(photo)

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

	var rank_lbl := Label.new()
	rank_lbl.text = "第 %d 名" % rank
	rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(rank_lbl, 11, UITheme.ACCENT if rank <= 3 else UITheme.TEXT_MUTED)
	vbox.add_child(rank_lbl)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(96, 96)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.add_theme_stylebox_override("panel",
		UITheme.make_style(Color("1f1f1f"), 8, Color(0, 0, 0, 0), UITheme.BORDER, 1))
	vbox.add_child(frame)

	var center := CenterContainer.new()
	frame.add_child(center)

	var tex := ImageLoader.resolve_texture(photo)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(96, 96)
		center.add_child(tr)
	else:
		var ph := Label.new()
		ph.text = "无图"
		ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UITheme.style_label(ph, 12, Color("666666"))
		frame.add_child(ph)

	var name_lbl := Label.new()
	name_lbl.text = disp
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name_lbl.max_lines_visible = 2
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.tooltip_text = "%s\n文件：%s" % [disp, photo]
	UITheme.style_label(name_lbl, 12, UITheme.TEXT)
	vbox.add_child(name_lbl)

	var count_lbl := Label.new()
	count_lbl.text = "%d 票" % count
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(count_lbl, 13, UITheme.ACCENT)
	vbox.add_child(count_lbl)

	var voter_lbl := Label.new()
	voter_lbl.text = "、".join(voters) if not voters.is_empty() else "—"
	voter_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voter_lbl.max_lines_visible = 1
	voter_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	voter_lbl.tooltip_text = "、".join(voters) if not voters.is_empty() else "没有人 Ban"
	UITheme.style_label(voter_lbl, 10, UITheme.TEXT_MUTED)
	vbox.add_child(voter_lbl)

	return card


## 明细表：每行一个忍者，列出票数和投它的人
func _render_table() -> void:
	if _table_box != null and is_instance_valid(_table_box):
		_table_box.queue_free()
		_table_box = null
	if _stats.is_empty():
		return

	var ranking: Array = _stats.get("ranking", [])
	if ranking.is_empty():
		return

	_table_box = VBoxContainer.new()
	_table_box.name = "DetailTable"
	_table_box.add_theme_constant_override("separation", 3)
	_body_box.add_child(_table_box)

	var title := Label.new()
	title.text = "排序明细（共 %d 个被 Ban 过的忍者%s）" % [
		ranking.size(),
		"，只显示前 %d 行" % TABLE_MAX_ROWS if ranking.size() > TABLE_MAX_ROWS else ""]
	UITheme.style_label(title, 13, UITheme.ACCENT)
	_table_box.add_child(title)

	var rows: int = mini(ranking.size(), TABLE_MAX_ROWS)
	for i in range(rows):
		var rec: Dictionary = ranking[i]
		var photo := String(rec.get("file", ""))
		var disp := ImageLoader.get_display_name(photo)
		var voters: Array = rec.get("voters", [])

		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel",
			UITheme.make_style(Color("1b1b1b") if i % 2 == 0 else Color("202020"),
				UITheme.RADIUS_SM))
		_table_box.add_child(row)

		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 8)
		m.add_theme_constant_override("margin_right", 8)
		m.add_theme_constant_override("margin_top", 3)
		m.add_theme_constant_override("margin_bottom", 3)
		row.add_child(m)

		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		m.add_child(hb)

		var idx_lbl := Label.new()
		idx_lbl.text = "%d" % (i + 1)
		idx_lbl.custom_minimum_size = Vector2(32, 0)
		idx_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		UITheme.style_label(idx_lbl, 12, UITheme.TEXT_MUTED)
		hb.add_child(idx_lbl)

		var name_lbl := Label.new()
		name_lbl.text = disp
		name_lbl.custom_minimum_size = Vector2(200, 0)
		name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UITheme.style_label(name_lbl, 12, UITheme.TEXT)
		hb.add_child(name_lbl)

		var cnt_lbl := Label.new()
		cnt_lbl.text = "%d 票" % int(rec.get("count", 0))
		cnt_lbl.custom_minimum_size = Vector2(60, 0)
		UITheme.style_label(cnt_lbl, 12, UITheme.ACCENT)
		hb.add_child(cnt_lbl)

		var voters_lbl := Label.new()
		voters_lbl.text = "、".join(voters) if not voters.is_empty() else "—"
		voters_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		voters_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		voters_lbl.tooltip_text = "、".join(voters)
		UITheme.style_label(voters_lbl, 11, UITheme.TEXT_MUTED)
		hb.add_child(voters_lbl)


func _update_button_state() -> void:
	var has := not _stats.is_empty()
	for b in [_json_btn, _png_btn, _txt_btn, _clear_btn, _refresh_btn]:
		if b != null:
			(b as Button).disabled = not has


# ============================================================
#  导出
# ============================================================
func _export_paths() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(EXPORT_DIR)
	var ts := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	return {
		"json": EXPORT_DIR.path_join("final_result.json"),
		"png": EXPORT_DIR.path_join("final_result.png"),
		"txt": EXPORT_DIR.path_join("final_result.txt"),
		"stamped_json": EXPORT_DIR.path_join("final_result_%s.json" % ts),
		"stamped_png": EXPORT_DIR.path_join("final_result_%s.png" % ts),
		"stamped_txt": EXPORT_DIR.path_join("final_result_%s.txt" % ts),
	}


func _on_export_json() -> void:
	if _stats.is_empty():
		return
	var paths := _export_paths()
	var payload: Dictionary = VoteImporter.build_final_result(_stats, _name_resolver())
	var ok := _write_json(String(paths["json"]), payload)
	# 再存一份带时间戳的，便于留档对比
	_write_json(String(paths["stamped_json"]), payload)
	if ok:
		_status_label.text = "已导出汇总 JSON：%s" % ProjectSettings.globalize_path(String(paths["json"]))
	else:
		_status_label.text = "导出汇总 JSON 失败。"


func _write_json(path: String, payload: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[Organizer] 写入失败：%s (err=%d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


func _on_export_txt() -> void:
	if _stats.is_empty():
		return
	var paths := _export_paths()
	var text: String = VoteImporter.build_text_result(_stats, _top_n(), _name_resolver())
	var f := FileAccess.open(String(paths["txt"]), FileAccess.WRITE)
	if f == null:
		_status_label.text = "导出汇总 TXT 失败。"
		return
	f.store_string(text)
	f.close()
	var f2 := FileAccess.open(String(paths["stamped_txt"]), FileAccess.WRITE)
	if f2 != null:
		f2.store_string(text)
		f2.close()
	_status_label.text = "已导出汇总 TXT：%s" % ProjectSettings.globalize_path(String(paths["txt"]))


func _on_export_png() -> void:
	if _stats.is_empty() or _exporting:
		return
	_exporting = true
	_png_btn.disabled = true
	_status_label.text = "正在渲染汇总 PNG…"
	var paths := _export_paths()
	var ok: bool = await _render_png(String(paths["png"]))
	await _render_png(String(paths["stamped_png"]))
	_exporting = false
	_png_btn.disabled = false
	if ok:
		_status_label.text = "已导出汇总 PNG：%s" % ProjectSettings.globalize_path(String(paths["png"]))
	else:
		_status_label.text = "导出汇总 PNG 失败（可能一张头像都没有？）"


## 用 SubViewport 离屏渲染 Top N 网格
func _render_png(path: String) -> bool:
	# headless（dummy 渲染器）根本没有纹理可读，get_image() 会返回 null，
	# 这里提前挡掉并说明原因，而不是静默失败。
	if DisplayServer.get_name() == "headless":
		push_warning("[Organizer] 当前是 headless 模式（无渲染器），无法导出 PNG。请在带窗口的环境运行。")
		return false

	var ranking: Array = _stats.get("ranking", [])
	var n: int = mini(_top_n(), TOP_GRID_LIMIT)
	if n <= 0:
		return false

	var cols: int = mini(5, n)
	var rows: int = int(ceil(float(n) / float(cols)))
	var pad := 16
	var gap := 10
	var grid_w: int = cols * CELL_W + (cols - 1) * gap
	var grid_h: int = rows * CELL_H + (rows - 1) * gap
	var out_w := maxi(RESULT_PNG_WIDTH, grid_w + pad * 2)
	var out_h: int = grid_h + pad * 2 + 44      # 顶部留一条标题

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

	var title := Label.new()
	title.text = "火影忍者 公共 Ban 选结果 · Top %d · 参与 %d 人 · %s" % [
		n, int(_stats.get("voter_count", 0)),
		Time.get_datetime_string_from_system().replace("T", " ")]
	title.position = Vector2(pad, 12)
	title.size = Vector2(grid_w, 24)
	UITheme.style_label(title, 14, UITheme.ACCENT)
	sv.add_child(title)

	var holder := Control.new()
	holder.position = Vector2(pad, 40)
	holder.size = Vector2(grid_w, grid_h)
	sv.add_child(holder)

	var grid := GridContainer.new()
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", gap)
	grid.add_theme_constant_override("v_separation", gap)
	grid.position = Vector2.ZERO
	holder.add_child(grid)

	for i in range(n):
		grid.add_child(_make_cell(i + 1, ranking[i] as Dictionary))

	# 等渲染完。注意：headless（dummy 渲染器）不会发 frame_post_draw，
	# 直接 await 那个信号会永久挂住，所以只能用帧数 + 超时兜底。
	await _wait_frames(4)

	var img := sv.get_texture().get_image()
	sv.queue_free()
	if img == null or img.is_empty():
		return false
	var err: int = img.save_png(path)
	if err != OK:
		push_warning("[Organizer] PNG 写盘失败：%s (err=%d)" % [path, err])
		return false
	return true


## 等渲染完成。
## 注意：headless（dummy 渲染器）不会发 frame_post_draw，
## 直接 await 那个信号会永久挂住，所以这里「信号 + 超时」二选一。
func _wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame
	await _wait_post_draw(0.4)


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


## 把照片 ID 转成显示名（交给 ImageLoader 查 characters.json）
func _name_resolver() -> Callable:
	return func(photo: String) -> String:
		return ImageLoader.get_display_name(photo)


# ============================================================
#  其他
# ============================================================
func _on_back_to_player() -> void:
	var err := get_tree().change_scene_to_file(PLAYER_SCENE)
	if err != OK:
		_status_label.text = "无法返回玩家模式（err=%d）" % err
