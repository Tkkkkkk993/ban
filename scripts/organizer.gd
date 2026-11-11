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
const UIFilePicker := preload("res://scripts/ui_file_picker.gd")

const PLAYER_SCENE := "res://scenes/Main.tscn"
const EXPORT_DIR := "user://exports"
const TOP_GRID_LIMIT := 60          # 网格最多画多少个，避免一次性画几百个
const TABLE_MAX_ROWS := 120         # 明细表最多多少行
const CELL_W := 150
const CELL_H := 190
const RESULT_PNG_WIDTH := 1024
## 做过手动调整时，界面和导出里都要出现的警告语
const _MANUAL_WARNING := "组织者对统计结果做了更改，请其他用户验证是否公平公正"

@onready var _player_btn: Button = $Root/VBox/HeaderBox/HeaderRow/PlayerModeBtn
@onready var _toolbar: HBoxContainer = $Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar
@onready var _summary_label: Label = $Root/VBox/SummaryWrap/SummaryBox/SummaryVBox/SummaryLabel
@onready var _detail_label: Label = $Root/VBox/SummaryWrap/SummaryBox/SummaryVBox/DetailLabel
@onready var _body_box: VBoxContainer = $Root/VBox/Body/BodyBox
@onready var _body_margin: MarginContainer = $Root/VBox/Body/BodyBox/BodyMargin
@onready var _top_grid: GridContainer = $Root/VBox/Body/BodyBox/BodyMargin/TopGrid
@onready var _status_label: Label = $Root/VBox/StatusBarWrap/StatusLabel

var _manual: Dictionary = {}        # 照片ID -> 累计手动增减（可为负）
var _stats_raw: Dictionary = {}     # 导入得到的原始统计（不被手动调整污染）
var _manual_warn: Label             # 顶部红色警告条
var _manual_clear_btn: Button       # 「清除手动调整」

var _file_dialog: FileDialog
var _dir_dialog: FileDialog
var _import_btn: Button
var _folder_btn: Button
var _clear_btn: Button
var _json_btn: Button
var _png_btn: Button
var _txt_btn: Button
var _top_spin: SpinBox
var _limit_spin: SpinBox
var _refresh_btn: Button
var _loaded_label: Label

var _stats: Dictionary = {}
var _loaded_files: Array = []        # 已导入的文件路径
var _table_box: VBoxContainer = null
var _exporting := false


func _ready() -> void:
	_build_toolbar()
	_build_manual_warn()
	_build_file_dialogs()

	_player_btn.pressed.connect(_on_back_to_player)
	UITheme.apply_button(_player_btn)
	get_window().files_dropped.connect(_on_files_dropped)
	get_window().title = "Naruto Ban Picker - 组织者模式"
	# 窗口变宽变窄时，重算一行放几个格子
	get_window().size_changed.connect(_render_top_grid)

	# 组织者端也要头像，用来在排名里显示
	_status_label.text = "正在扫描头像目录…"
	ImageLoader.scan_directory()
	ImageLoader.batch_loaded.connect(_on_batch_loaded)
	ImageLoader.scan_finished.connect(_on_scan_finished)

	_render()


## 顶部那条红色警告条（只有做过手动调整时才显示）
func _build_manual_warn() -> void:
	var vb: VBoxContainer = $Root/VBox/SummaryWrap/SummaryBox/SummaryVBox
	_manual_warn = Label.new()
	_manual_warn.name = "ManualWarn"
	_manual_warn.visible = false
	_manual_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_manual_warn.add_theme_font_size_override("font_size", 14)
	_manual_warn.add_theme_color_override("font_color", Color("ffb3b3"))
	var sb: StyleBoxFlat = UITheme.make_style(
		Color(0.42, 0.06, 0.06, 0.92), UITheme.RADIUS_SM,
		Color(0, 0, 0, 0.35), Color("ff3b3b"), 2, 8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_manual_warn.add_theme_stylebox_override("normal", sb)
	vb.add_child(_manual_warn)
	vb.move_child(_manual_warn, 0)


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
	# 改了立刻重画，不用再点「刷新视图」
	_top_spin.value_changed.connect(func(_v: float) -> void: _render_top_grid())
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

	# 只有在做过手动调整时才显示
	_manual_clear_btn = Button.new()
	_manual_clear_btn.name = "ClearManualBtn"
	_manual_clear_btn.text = "撤销手动调整"
	_manual_clear_btn.tooltip_text = "把手动增减全部清掉，回到原始统计"
	_manual_clear_btn.visible = false
	UITheme.apply_button(_manual_clear_btn)
	_manual_clear_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_manual_clear_btn.pressed.connect(_on_clear_manual)
	_toolbar.add_child(_manual_clear_btn)

	# ---- 每人上限检查 ----
	var lim_hint := Label.new()
	lim_hint.text = "每人上限"
	UITheme.style_label(lim_hint, 11, UITheme.TEXT_MUTED)
	lim_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(lim_hint)

	_limit_spin = SpinBox.new()
	_limit_spin.name = "LimitSpin"
	_limit_spin.min_value = 0
	_limit_spin.max_value = 99
	_limit_spin.step = 1
	_limit_spin.value = 0
	_limit_spin.custom_minimum_size = Vector2(80, 32)
	_limit_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_limit_spin.tooltip_text = "填 0 = 不检查；填 5 = 检查谁 Ban 超过 5 个"
	UITheme.apply_input(_limit_spin)
	_limit_spin.value_changed.connect(func(_v: float) -> void: _render_summary())
	_toolbar.add_child(_limit_spin)

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
	_file_dialog.title = "选择投票文件（json 或 txt，可多选）"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.add_filter("*.json, *.txt", "投票文件（json / txt）")
	_file_dialog.add_filter("*.json", "只有 json")
	_file_dialog.add_filter("*.txt", "只有 txt")
	_file_dialog.files_selected.connect(_on_files_selected)
	add_child(_file_dialog)

	_dir_dialog = FileDialog.new()
	_dir_dialog.name = "DirPicker"
	_dir_dialog.title = "选择装着投票文件的文件夹"
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
		elif s.get_extension().to_lower() in ["json", "txt"]:
			list.append(s)
		else:
			_status_label.text = "已忽略非 json / txt 文件：%s" % s.get_file()
	if list.is_empty():
		if files.size() > 0:
			_status_label.text = "拖进来的东西里没有 json 或 txt 文件。"
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
	_stats_raw = st
	# 重新导入 = 回到原始数据，手动调整清空（避免调整错位到新数据上）
	_manual.clear()
	_rebuild_stats()
	_render()
	var errs: Array = st.get("errors", [])
	var dups: Array = st.get("duplicates", [])
	var warns: Array = st.get("warnings", [])
	_status_label.text = "导入完成：本次 %d 项，累计 %d 个文件，有效 %d 人；坏文件 %d，重复投票 %d，提醒 %d。" % [
		fresh.size(), _loaded_files.size(), int(st.get("voter_count", 0)),
		errs.size(), dups.size(), warns.size()]


# ============================================================
#  手动增减票数（防呆：有人少投了一张，不必让他重开程序）
# ------------------------------------------------------------
#  设计原则：
#    · 只改「内存里的展示结果」，**不动导入的原始投票文件**
#    · 重新导入 / 清空 / 关程序 → 手动调整全部消失（所以叫"临时"）
#    · 一旦有任何调整，界面顶部就挂一条红色警告，且导出的
#      json / txt / png 里也都会写明，保证别人能复核
# ============================================================

## 加一票
func _bump(photo: String, delta: int) -> void:
	if photo == "":
		return
	var cur := int(_manual.get(photo, 0)) + delta
	if cur == 0:
		_manual.erase(photo)
	else:
		_manual[photo] = cur
	_rebuild_stats()
	_render()
	_refresh_manual_warn()


## 把原始统计 + 手动增减合成为「用于展示和导出」的统计
func _rebuild_stats() -> void:
	if _stats_raw.is_empty():
		_stats = {}
		return
	if _manual.is_empty():
		_stats = _stats_raw
		return

	var st: Dictionary = _stats_raw.duplicate(true)
	var ranking: Array = []
	for r in (_stats_raw.get("ranking", []) as Array):
		var d: Dictionary = (r as Dictionary).duplicate(true)
		var photo := String(d.get("file", ""))
		var raw := int(d.get("count", 0))
		var delta := int(_manual.get(photo, 0))
		if delta == 0:
			ranking.append(d)
			continue
		var adj := raw + delta
		if adj <= 0:
			continue          # 被减到 0 的就从排名里拿掉
		d["raw_count"] = raw
		d["manual_delta"] = delta
		d["count"] = adj
		ranking.append(d)
	# 调整后名次会变，必须重排
	VoteImporter.sort_ranking(ranking)

	var total := 0
	for r in ranking:
		total += int((r as Dictionary).get("count", 0))
	st["ranking"] = ranking
	st["total_bans"] = ranking.size()
	st["manual_adjusted"] = true
	_stats = st


## 有没有做过手动调整
func has_manual_adjustment() -> bool:
	return not _manual.is_empty()


## 全部撤销
func _on_clear_manual() -> void:
	if _manual.is_empty():
		return
	_manual.clear()
	_rebuild_stats()
	_render()
	_refresh_manual_warn()
	_status_label.text = "已撤销全部手动调整，回到原始统计。"


## 刷新顶部那条红色警告
func _refresh_manual_warn() -> void:
	if _manual_warn == null or not is_instance_valid(_manual_warn):
		return
	var on := has_manual_adjustment()
	_manual_warn.visible = on
	if on:
		var n := _manual.size()
		var total := 0
		for k in _manual.keys():
			total += int(_manual[k])
		_manual_warn.text = ("⚠ 组织者对统计结果做了手动调整（%d 处，净 %+d 票），"
			+ "本结果已不是原始投票数据，请其他用户验证是否公平公正") % [n, total]
	if _manual_clear_btn != null and is_instance_valid(_manual_clear_btn):
		_manual_clear_btn.visible = on



func _on_clear_pressed() -> void:
	_loaded_files.clear()
	_stats = {}
	_stats_raw = {}
	_manual.clear()
	_render()
	_refresh_manual_warn()
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
		_summary_label.text = "还没有导入任何投票文件。\n把群友发来的 vote_*.json **或者攒好的 txt 文字** 拖进这个窗口，或点上面的「导入文件 / 导入文件夹」。"
		_detail_label.text = ""
		return

	var vc := int(_stats.get("voter_count", 0))
	var ranking: Array = _stats.get("ranking", [])
	var errs: Array = _stats.get("errors", [])
	var dups: Array = _stats.get("duplicates", [])
	var warns: Array = _stats.get("warnings", [])
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
	if not warns.is_empty():
		parts.append("⚠ 提醒 %d 条" % warns.size())
	# 上限检查
	var limit := 0
	if _limit_spin != null:
		limit = int(_limit_spin.value)
	var over: Array = VoteImporter.find_limit_violations(_stats, limit)
	if limit > 0:
		if over.is_empty():
			parts.append("✅ 都在上限 %d 个以内" % limit)
		else:
			parts.append("❌ 超上限 %d 人" % over.size())
	_summary_label.text = "  |  ".join(parts)

	# 明细：每人 Ban 了几个
	var lines: Array[String] = []
	var voters: Array = _stats.get("voters", [])
	var names: Array[String] = []
	for v in voters:
		var d: Dictionary = v
		var tag := ""
		if String(d.get("source_kind", "json")) == "text":
			tag = "·文字"
		names.append("%s(%d)%s" % [String(d.get("voter_name", "?")), int(d.get("count", 0)), tag])
	if not names.is_empty():
		lines.append("每人 Ban 数：" + "、".join(names))

	# 超上限的人单独列出来，方便人工核对
	if limit > 0 and not over.is_empty():
		lines.append("")
		lines.append("【超过每人上限 %d 个的】" % limit)
		for o in over:
			var od: Dictionary = o
			lines.append("  ❌ %s 投了 %d 个（上限 %d）" % [
				String(od.get("voter_name", "?")),
				int(od.get("count", 0)),
				limit])

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
	for w in warns:
		var ww: Dictionary = w
		lines.append("提醒：%s" % String(ww.get("reason", "")))
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
	var cols: int = clampi(_fit_columns(), 1, maxi(1, n))
	_top_grid.columns = cols
	for i in range(n):
		_top_grid.add_child(_make_cell(i + 1, ranking[i] as Dictionary))


## 按当前可用宽度算一行能放几个格子。
## 写死 5 列时，窗口一窄第 5 个就会被挤出屏幕外。
func _fit_columns() -> int:
	var avail := 0.0
	var body := get_node_or_null("Root/VBox/Body")
	if body != null and (body as Control).size.x > 0.0:
		avail = (body as Control).size.x - 24.0    # 扣掉左右 margin
	if avail <= 0.0:
		return 5
	var gap := 10.0
	var c := int(floor((avail + gap) / (float(CELL_W) + gap)))
	return clampi(c, 1, 5)


func _make_cell(rank: int, rec: Dictionary) -> Control:
	var photo := String(rec.get("file", ""))
	var count := int(rec.get("count", 0))
	var voters: Array = rec.get("voters", [])
	var disp := ImageLoader.get_display_name(photo)

	var card := PanelContainer.new()
	card.name = "Cell_%s" % photo
	card.custom_minimum_size = Vector2(CELL_W, CELL_H)
	# 网格里显示的每一张（Top N）都统一用橙红描边；
	# 之前只给前 3 名上色是早期遗留，和「可以自定义显示前 N 名」冲突，已统一
	card.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.CARD_BG, UITheme.RADIUS_MD, Color(0, 0, 0, 0.4),
			UITheme.ACCENT, 2, 4))

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
	UITheme.style_label(rank_lbl, 11, UITheme.ACCENT)
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
		var delta := int(rec.get("manual_delta", 0))
		var raw_cnt := int(rec.get("raw_count", rec.get("count", 0)))
		var now_cnt := int(rec.get("count", 0))
		if delta != 0:
			cnt_lbl.text = "%d 票（原 %d，%+d）" % [now_cnt, raw_cnt, delta]
			cnt_lbl.add_theme_color_override("font_color", Color("ff6b6b"))
		else:
			cnt_lbl.text = "%d 票" % now_cnt
		cnt_lbl.custom_minimum_size = Vector2(140, 0)
		UITheme.style_label(cnt_lbl, 12, UITheme.ACCENT)
		hb.add_child(cnt_lbl)

		# ---- 手动增减（防呆：有人少投了一张） ----
		var minus := Button.new()
		minus.name = "Minus"
		minus.text = "−"
		minus.tooltip_text = "手动减 1 票（临时，只影响本次展示和导出，不改原始投票文件）"
		minus.custom_minimum_size = Vector2(26, 22)
		minus.focus_mode = Control.FOCUS_NONE
		UITheme.apply_button(minus)
		minus.pressed.connect(func() -> void: _bump(photo, -1))
		hb.add_child(minus)

		var plus := Button.new()
		plus.name = "Plus"
		plus.text = "＋"
		plus.tooltip_text = "手动加 1 票（用于补上漏投的那一票，临时，只影响本次展示和导出）"
		plus.custom_minimum_size = Vector2(26, 22)
		plus.focus_mode = Control.FOCUS_NONE
		UITheme.apply_button(plus)
		plus.pressed.connect(func() -> void: _bump(photo, 1))
		hb.add_child(plus)

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
# ------------------------------------------------------------
#  三个导出按钮都先让用户**选一个文件夹**，再写到那里。
#  不再默认塞到 AppData 里（那个位置用户根本找不到）。
# ============================================================

## 统一入口：先选目录，再调对应的 _export_*_to()
func _ask_dir_then(title: String, handler: Callable) -> void:
	if _stats.is_empty():
		return
	UIFilePicker.pick_folder(self, title, DataManager.effective_export_dir(), handler)


func _on_export_json() -> void:
	_ask_dir_then("选择「汇总 JSON」保存到哪个文件夹",
		func(dir: String) -> void: _export_json_to(dir))


func _export_json_to(dir: String) -> void:
	DataManager.set_export_dir(dir)      # 记住，下次选择器从这里开始
	var path := dir.path_join("final_result.json")
	var payload: Dictionary = VoteImporter.build_final_result(_stats, _name_resolver())
	if has_manual_adjustment():
		payload["manual_adjustment"] = _manual_payload()
	if _write_json(path, payload):
		_status_label.text = "已导出汇总 JSON：%s" % path
	else:
		_status_label.text = "导出汇总 JSON 失败（目录可能不可写）：%s" % path


## 手动调整的明细（写进 json / txt，供别人复核）
func _manual_payload() -> Dictionary:
	var items: Array = []
	for photo in _manual.keys():
		var delta := int(_manual[photo])
		if delta == 0:
			continue
		items.append({
			"photo": String(photo),
			"name": ImageLoader.get_display_name(String(photo)),
			"delta": delta,
		})
	items.sort_custom(func(a, b) -> bool: return String(a["name"]) < String(b["name"]))
	return {
		"adjusted": true,
		"item_count": items.size(),
		"items": items,
		"warning": _MANUAL_WARNING,
	}


## 给人看的多行文字版
func _manual_report_lines() -> Array[String]:
	var out: Array[String] = []
	if not has_manual_adjustment():
		return out
	out.append("⚠ " + _MANUAL_WARNING)
	out.append("（以下是本次手动增减明细，原始投票文件中并没有这些改动）")
	for photo in _manual.keys():
		var delta := int(_manual[photo])
		if delta == 0:
			continue
		out.append("  · %s  票数 %+d" % [ImageLoader.get_display_name(String(photo)), delta])
	return out


func _write_json(path: String, payload: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[Organizer] 写入失败：%s (err=%d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


func _on_export_txt() -> void:
	_ask_dir_then("选择「汇总 TXT」保存到哪个文件夹",
		func(dir: String) -> void: _export_txt_to(dir))


func _export_txt_to(dir: String) -> void:
	DataManager.set_export_dir(dir)
	var path := dir.path_join("final_result.txt")
	var text: String = VoteImporter.build_text_result(_stats, _top_n(), _name_resolver())
	if has_manual_adjustment():
		var lines := _manual_report_lines()
		text = "\n".join(lines) + "\n\n" + text + "\n\n" + "\n".join(lines)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status_label.text = "导出汇总 TXT 失败（目录可能不可写）：%s" % path
		return
	f.store_string(text)
	f.close()
	_status_label.text = "已导出汇总 TXT：%s" % path


func _on_export_png() -> void:
	if _exporting:
		return
	_ask_dir_then("选择「汇总 PNG」保存到哪个文件夹",
		func(dir: String) -> void: _on_png_dir_picked(dir))


## PNG 渲染是异步的，所以单独抽一个可直接 await 的方法
func _on_png_dir_picked(dir: String) -> void:
	await _export_png_to(dir)


func _export_png_to(dir: String) -> void:
	if _stats.is_empty() or _exporting:
		return
	DataManager.set_export_dir(dir)
	_exporting = true
	_png_btn.disabled = true
	_status_label.text = "正在渲染汇总 PNG…"
	var path := dir.path_join("final_result.png")
	var ok: bool = await _render_png(path)
	_exporting = false
	_png_btn.disabled = false
	if ok:
		_status_label.text = "已导出汇总 PNG：%s" % path
	else:
		_status_label.text = "导出汇总 PNG 失败（可能一张头像都没有，或在 headless 环境）"


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
	# 做过手动调整时，顶部多留一条红色警告的高度
	var warn_h: int = 34 if has_manual_adjustment() else 0
	var out_h: int = grid_h + pad * 2 + 44 + warn_h

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

	# 手动调整过 → 图片上也必须写明，不能只靠界面提醒
	if warn_h > 0:
		var warn := Label.new()
		warn.text = "⚠ 组织者对统计结果做了手动调整，请其他用户验证是否公平公正"
		warn.position = Vector2(pad, 36)
		warn.size = Vector2(out_w - pad * 2, 24)
		warn.add_theme_font_size_override("font_size", 13)
		warn.add_theme_color_override("font_color", Color("ffb3b3"))
		var wsb: StyleBoxFlat = UITheme.make_style(
			Color(0.42, 0.06, 0.06, 0.95), UITheme.RADIUS_SM,
			Color(0, 0, 0, 0.35), Color("ff3b3b"), 2, 6)
		wsb.content_margin_left = 10
		wsb.content_margin_top = 3
		warn.add_theme_stylebox_override("normal", wsb)
		sv.add_child(warn)

	var holder := Control.new()
	holder.position = Vector2(pad, 40 + warn_h)
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
