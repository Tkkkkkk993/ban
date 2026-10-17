# ============================================================
#  main.gd —— 玩家端主逻辑（分布式投票改造后）
# ------------------------------------------------------------
#  玩家端只做三件事：
#    1. 知道「我是谁」（首次启动问名字，存 user://voter_name.txt）
#    2. 让我 Ban 掉若干忍者（本地单人名单，点卡片切换）
#    3. 把我的名单导出成 json 发给组织者
#
#  界面结构见 Main.tscn；工具栏控件在运行时创建。
#
#  信号流：
#    卡片 vote_toggled → DataManager.toggle_ban → data_changed → _refresh_all()
#    ImageLoader.batch_loaded → 建卡片
# ============================================================
class_name MainApp
extends Control

const UITheme := preload("res://scripts/ui_theme.gd")
const VoteExporter := preload("res://scripts/vote_exporter.gd")

const CARD_SCENE := preload("res://scenes/CharacterCard.tscn")
const ORGANIZER_SCENE := "res://scenes/Organizer.tscn"

## 组织者模式的进入口令（硬编码，只为防止群友误入，不是安全机制）
const ORGANIZER_PASSWORD := "naruto2026"
## 通过口令后记一个标记文件，之后不再问
const ORGANIZER_UNLOCK_PATH := "user://organizer_unlocked.txt"
## 「查看大图」预览方框边长（像素）。大图缩小到这个框内，避免弹窗被撑爆。
const PREVIEW_BOX := 420
## 右侧 Ban 名单面板宽度
const BAN_PANEL_WIDTH := 280

# ============================================================
#  场景里已有的节点引用（见 Main.tscn）
# ============================================================
@onready var _mode_label: Label = $Root/VBox/HeaderBox/HeaderRow/ModeLabel
@onready var _name_label: Label = $Root/VBox/HeaderBox/HeaderRow/NameLabel
@onready var _organizer_btn: Button = $Root/VBox/HeaderBox/HeaderRow/OrganizerBtn
@onready var _toolbar: HBoxContainer = $Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar
@onready var _card_area: MarginContainer = $Root/VBox/Body/CardArea
@onready var _scroll: ScrollContainer = $Root/VBox/Body/CardArea/CardScroll
@onready var _flow: FlowContainer = $Root/VBox/Body/CardArea/CardScroll/CardFlow
@onready var _ban_panel: BanListPanel = $Root/VBox/Body/BanPanelWrap/BanListPanel
@onready var _status_label: Label = $Root/VBox/StatusBarWrap/StatusLabel

# ============================================================
#  运行时创建的控件
# ============================================================
var _search_edit: LineEdit
var _group_option: OptionButton
var _import_spin: SpinBox
var _import_btn: Button
var _load_all_btn: Button
var _clear_btn: Button
var _export_btn: Button
var _rename_btn: Button
var _export_dir_btn: Button
var _rescan_btn: Button
var _help_btn: Button

var _name_dialog: AcceptDialog
var _name_edit: LineEdit
var _empty_state: CenterContainer
var _empty_label: Label

# 数据
var _cards: Array[CharacterCard] = []
var _card_by_photo: Dictionary = {}
var _total_count := 0
var _loaded_count := 0
var _filtered_count := 0
var _loading := false
var _known_photo_set: Dictionary = {}
var _search_timer := -1.0
var _name_prompt_done := false


func _ready() -> void:
	# 命令行 --organizer：直达组织者模式（免口令，给组织者自己用）
	if _has_cmdline_flag("--organizer"):
		# 等一帧再切场景，避免在 _ready 里换掉正在初始化的场景
		_go_organizer.call_deferred()
		return

	_build_toolbar()
	_build_empty_state()
	_build_name_dialog()
	_connect_globals()

	_organizer_btn.pressed.connect(_on_organizer_pressed)
	UITheme.apply_button(_organizer_btn)
	UITheme.apply_scroll(_scroll)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_mode_label.text = "玩家模式"

	# 右侧 Ban 名单面板
	_ban_panel.unban_requested.connect(_on_unban_requested)
	_ban_panel.row_clicked.connect(_on_ban_row_clicked)

	_apply_name_ui()

	# 名字优先级：命令行参数 > 已存文件 > 弹窗问
	var from_cmd := _name_from_cmdline()
	if from_cmd != "" and not DataManager.has_name():
		DataManager.set_voter_name(from_cmd)
	_apply_name_ui()

	# 首次启动就得先知道是谁在投
	if not DataManager.has_name():
		call_deferred("_prompt_for_name", true)
	else:
		_start_scan()


func _exit_tree() -> void:
	DataManager.save()


# ============================================================
#  名字
# ============================================================
func _apply_name_ui() -> void:
	var nm := DataManager.voter_name
	if nm == "":
		_name_label.text = "玩家：未命名"
		get_window().title = "Naruto Ban Picker"
	else:
		_name_label.text = "玩家：%s" % nm
		get_window().title = "Naruto Ban Picker - %s" % nm


## 支持命令行预置名字：
##   --voter-name=张三     或     -- --voter-name 张三
func _name_from_cmdline() -> String:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for i in range(args.size()):
		var a := String(args[i])
		if a.begins_with("--voter-name="):
			return DataManager.sanitize_name(a.substr("--voter-name=".length()))
		if a == "--voter-name" and i + 1 < args.size():
			return DataManager.sanitize_name(String(args[i + 1]))
	var env := OS.get_environment("NARUTO_VOTER_NAME")
	if env != "":
		return DataManager.sanitize_name(env)
	return ""


## 命令行里有没有某个开关（形如 --organizer）
func _has_cmdline_flag(flag: String) -> bool:
	if OS.get_cmdline_args().has(flag) or OS.get_cmdline_user_args().has(flag):
		return true
	return false


func _build_name_dialog() -> void:
	_name_dialog = AcceptDialog.new()
	_name_dialog.name = "NameDialog"
	_name_dialog.title = "欢迎"
	_name_dialog.ok_button_text = "确定"
	_name_dialog.min_size = Vector2i(420, 190)
	_name_dialog.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(_name_dialog)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_name_dialog.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var tip := Label.new()
	tip.text = "请输入你的名字："
	UITheme.style_label(tip, 15, UITheme.TEXT)
	vbox.add_child(tip)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "例如：张三"
	_name_edit.max_length = DataManager.MAX_NAME_LEN
	_name_edit.custom_minimum_size = Vector2(380, 34)
	UITheme.apply_input(_name_edit)
	vbox.add_child(_name_edit)

	var hint := Label.new()
	hint.text = "这个名字会显示在导出的投票文件名和内容里，方便组织者认人。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, 11, UITheme.TEXT_MUTED)
	vbox.add_child(hint)

	_name_dialog.confirmed.connect(_on_name_confirmed)
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		_on_name_confirmed())


## required=true 表示没名字就不让继续用（首次启动）
func _prompt_for_name(required: bool) -> void:
	_name_prompt_done = true
	_name_edit.text = DataManager.voter_name
	_name_dialog.dialog_text = ""
	_name_dialog.title = "欢迎使用 Naruto Ban Picker" if required else "改名"
	_name_dialog.popup_centered(Vector2i(430, 200))
	_name_edit.grab_focus()
	_name_edit.select_all()


func _on_name_confirmed() -> void:
	var ok := DataManager.set_voter_name(_name_edit.text)
	if not ok:
		# 名字不合法就再问一次，不允许空名字
		_status_label.text = "名字不能为空，请重新输入。"
		call_deferred("_prompt_for_name", not DataManager.has_name())
		return
	_apply_name_ui()
	DataManager.save()
	_status_label.text = "你好，%s！点卡片把忍者加入你的 Ban 名单。" % DataManager.voter_name
	if _total_count == 0 and not _loading:
		_start_scan()


# ============================================================
#  工具栏
# ============================================================
func _build_toolbar() -> void:
	_search_edit = LineEdit.new()
	_search_edit.name = "SearchEdit"
	_search_edit.placeholder_text = "搜索忍者..."
	_search_edit.clear_button_enabled = true
	_search_edit.custom_minimum_size = Vector2(150, 32)
	_search_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_search_edit.tooltip_text = "按忍者名或照片 ID 搜索（Ctrl+F 聚焦）"
	UITheme.apply_input(_search_edit)
	_search_edit.text_changed.connect(_on_search_changed)
	_toolbar.add_child(_search_edit)

	_group_option = OptionButton.new()
	_group_option.name = "GroupOption"
	_group_option.custom_minimum_size = Vector2(96, 32)
	_group_option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_group_option.tooltip_text = "按 characters.json 里的 group 字段筛选（没写 group 时自动隐藏）"
	UITheme.apply_input(_group_option)
	_group_option.item_selected.connect(_on_group_selected)
	_toolbar.add_child(_group_option)

	_toolbar.add_child(VSeparator.new())

	var import_hint := Label.new()
	import_hint.name = "ImportHint"
	import_hint.text = "导入张数"
	UITheme.style_label(import_hint, 11, UITheme.TEXT_MUTED)
	import_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toolbar.add_child(import_hint)

	_import_spin = SpinBox.new()
	_import_spin.name = "ImportSpin"
	_import_spin.min_value = 1
	_import_spin.max_value = 9999
	_import_spin.step = 1
	# 默认不限：数量由头像目录里实际有几张决定
	_import_spin.value = mini(ImageLoader.max_load_count, 9999)
	_import_spin.custom_minimum_size = Vector2(90, 32)
	_import_spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_import_spin.tooltip_text = "启动时载入多少张头像；默认 9999 表示不限（调试时可以改小）"
	UITheme.apply_input(_import_spin)
	_toolbar.add_child(_import_spin)

	_import_btn = Button.new()
	_import_btn.name = "ImportBtn"
	_import_btn.text = "导入"
	_import_btn.tooltip_text = "按上面的张数加载头像（增量加载，不影响已 Ban 的卡片）"
	UITheme.apply_button(_import_btn)
	_import_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_import_btn.pressed.connect(_on_import_pressed)
	_toolbar.add_child(_import_btn)

	_load_all_btn = Button.new()
	_load_all_btn.name = "LoadAllBtn"
	_load_all_btn.text = "全部加载"
	_load_all_btn.tooltip_text = "一次性把头像目录里的图全部载入"
	UITheme.apply_button(_load_all_btn)
	_load_all_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_load_all_btn.pressed.connect(_on_load_all_pressed)
	_toolbar.add_child(_load_all_btn)

	_toolbar.add_child(VSeparator.new())

	_clear_btn = Button.new()
	_clear_btn.name = "ClearBtn"
	_clear_btn.text = "清空我的投票"
	_clear_btn.tooltip_text = "清空我自己的 Ban 名单（Ctrl+Delete）"
	UITheme.apply_button_danger(_clear_btn)
	_clear_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_clear_btn.pressed.connect(_on_clear_pressed)
	_toolbar.add_child(_clear_btn)

	_export_btn = Button.new()
	_export_btn.name = "ExportBtn"
	_export_btn.text = "导出我的投票"
	_export_btn.tooltip_text = "生成投票 json 和 txt 文件，发给组织者（Ctrl+E）"
	UITheme.apply_button_primary(_export_btn)
	_export_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_export_btn.pressed.connect(_on_export_pressed)
	_toolbar.add_child(_export_btn)

	_rename_btn = Button.new()
	_rename_btn.name = "RenameBtn"
	_rename_btn.text = "改名"
	_rename_btn.tooltip_text = "修改我的名字（voter_id 不变）"
	UITheme.apply_button(_rename_btn)
	_rename_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rename_btn.pressed.connect(func() -> void: _prompt_for_name(false))
	_toolbar.add_child(_rename_btn)

	_export_dir_btn = Button.new()
	_export_dir_btn.name = "ExportDirBtn"
	_export_dir_btn.text = "导出目录"
	_export_dir_btn.tooltip_text = "选择投票 json/txt 导出到哪里（会记住）"
	UITheme.apply_button(_export_dir_btn)
	_export_dir_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_export_dir_btn.pressed.connect(_on_pick_export_dir)
	_toolbar.add_child(_export_dir_btn)

	_rescan_btn = Button.new()
	_rescan_btn.name = "RescanBtn"
	_rescan_btn.text = "重新扫描"
	_rescan_btn.tooltip_text = "重新扫描头像目录，新增头像不用重启"
	UITheme.apply_button(_rescan_btn)
	_rescan_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rescan_btn.pressed.connect(_on_rescan_pressed)
	_toolbar.add_child(_rescan_btn)

	_help_btn = Button.new()
	_help_btn.name = "HelpBtn"
	_help_btn.text = "说明"
	UITheme.apply_button(_help_btn)
	_help_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_help_btn.pressed.connect(_on_help_pressed)
	_toolbar.add_child(_help_btn)


func _build_empty_state() -> void:
	_empty_state = CenterContainer.new()
	_empty_state.name = "EmptyState"
	_empty_state.visible = false
	_empty_state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_state.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_card_area.add_child(_empty_state)

	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = ImageLoader.get_missing_dir_hint()
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.custom_minimum_size = Vector2(520, 0)
	UITheme.style_label(_empty_label, 14, UITheme.TEXT_MUTED)
	_empty_state.add_child(_empty_label)


func _connect_globals() -> void:
	ImageLoader.batch_loaded.connect(_on_batch_loaded)
	ImageLoader.all_loaded.connect(_on_all_loaded)
	ImageLoader.scan_finished.connect(_on_scan_finished)
	ImageLoader.image_failed.connect(_on_image_failed)
	DataManager.data_changed.connect(_refresh_all)
	DataManager.name_changed.connect(_on_name_changed)


func _on_name_changed(_n: String) -> void:
	_apply_name_ui()


# ============================================================
#  扫描 / 导入
# ============================================================
func _start_scan() -> void:
	_status_label.text = "正在扫描头像目录…"
	ImageLoader.scan_directory()


func _on_scan_finished(found: bool, items: Array) -> void:
	_total_count = items.size()
	if not found or _total_count == 0:
		_empty_state.visible = true
		_empty_label.text = ImageLoader.get_missing_dir_hint()
		_status_label.text = "没有找到头像目录 · 已 Ban %d 个" % DataManager.get_ban_count()
		_update_buttons()
		return

	_empty_state.visible = false
	_populate_groups()
	_import_spin.max_value = maxi(_total_count, 1)
	# 没设置过张数就用「全部」，符合「数量由目录内容决定」
	if _import_spin.value > _total_count:
		_import_spin.value = _total_count

	var new_indexes: Array = []
	for i in range(items.size()):
		var photo := String(items[i]["photo"])
		if not _known_photo_set.has(photo):
			new_indexes.append(i)
			_known_photo_set[photo] = true

	if _cards.is_empty():
		var want: int = clampi(int(_import_spin.value), 1, _total_count)
		ImageLoader.load_batch(0, want)
	else:
		if new_indexes.is_empty():
			_status_label.text = "没有发现新头像，当前共 %d 张。" % _total_count
		else:
			_status_label.text = "发现 %d 张新头像，正在加载…" % new_indexes.size()
			for idx in new_indexes:
				ImageLoader.load_batch(idx, 1)
	_update_status()
	_update_buttons()


func _populate_groups() -> void:
	_group_option.clear()
	_group_option.add_item("全部")
	var groups := ImageLoader.groups
	if groups.is_empty():
		_group_option.visible = false
		return
	_group_option.visible = true
	for g in groups:
		_group_option.add_item(g)
	_group_option.select(0)


func _on_import_pressed() -> void:
	if _loading:
		return
	if _total_count == 0:
		_start_scan()
		return
	var want: int = clampi(int(_import_spin.value), 1, maxi(_total_count, 1))
	var need: int = want - _loaded_count
	if need <= 0:
		_status_label.text = "已加载 %d 张；想重新开始请点「重新扫描」。" % _loaded_count
		return
	ImageLoader.load_batch(_loaded_count, need)
	_update_status()


func _on_load_all_pressed() -> void:
	if _loading or _total_count == 0:
		return
	ImageLoader.load_all()
	_update_status()


func _on_rescan_pressed() -> void:
	_status_label.text = "正在重新扫描头像目录…"
	ImageLoader.scan_directory()


# ============================================================
#  卡片
# ============================================================
func _on_batch_loaded(items: Array) -> void:
	for it in items:
		var photo := String(it.get("photo", ""))
		var tex: Texture2D = it.get("texture", null)
		var existing: CharacterCard = _card_by_photo.get(photo, null)
		if existing != null:
			existing.set_texture(tex)
			continue
		_make_card(photo, tex)
	_loaded_count = ImageLoader.get_finished_count()
	_apply_filter()
	_update_status()
	_update_buttons()


func _make_card(photo: String, tex: Texture2D) -> CharacterCard:
	var meta := ImageLoader.find_photo(photo)
	if meta.is_empty():
		return null
	var card := CARD_SCENE.instantiate() as CharacterCard
	if card == null:
		return null
	card.setup(String(meta["name"]), photo, String(meta["group"]))
	card.set_texture(tex)
	card.vote_toggled.connect(_on_card_vote_toggled)
	card.preview_requested.connect(_on_card_preview_requested)
	_flow.add_child(card)
	_cards.append(card)
	_card_by_photo[photo] = card
	_refresh_card(card)
	return card


func _on_all_loaded() -> void:
	_loading = false
	_loaded_count = ImageLoader.get_finished_count()
	_apply_filter()
	_update_status()
	_update_buttons()


func _on_image_failed(photo: String, reason: String) -> void:
	_status_label.text = "已跳过损坏图片：%s（%s）" % [photo, reason]


# ============================================================
#  投票
# ============================================================
func _on_card_vote_toggled(photo: String, _voted: bool) -> void:
	# 卡片传来的 voted 只是它自己的猜测，以 DataManager 的实际状态为准
	DataManager.toggle_ban(photo)


func _refresh_all() -> void:
	for card in _cards:
		_refresh_card(card)
	_refresh_ban_panel()
	_update_status()
	_update_buttons()


func _refresh_card(card: CharacterCard) -> void:
	card.set_vote_state(DataManager.is_banned(card.photo), "", _ban_summary())


## 卡片底部那行小字：我的名单摘要（如「我的 Ban：鸣人、佐助、小樱」）
func _ban_summary() -> String:
	var bans := DataManager.get_bans()
	if bans.is_empty():
		return ""
	var names: Array[String] = []
	for i in range(mini(3, bans.size())):
		names.append(ImageLoader.get_display_name(bans[i]))
	var s := "我的 Ban：" + "、".join(names)
	if bans.size() > 3:
		s += " +%d" % (bans.size() - 3)
	return s


## 刷新右侧「我的 Ban 名单」
func _refresh_ban_panel() -> void:
	if _ban_panel == null:
		return
	var entries: Array = []
	for photo in DataManager.get_bans():
		entries.append([photo, ImageLoader.get_display_name(photo)])
	_ban_panel.refresh(entries)


## 右侧列表里点了「移除」
func _on_unban_requested(photo: String) -> void:
	DataManager.set_ban(photo, false)
	_status_label.text = "已把「%s」移出你的 Ban 名单。" % ImageLoader.get_display_name(photo)


## 右侧列表里点了整行 → 滚动定位到对应卡片
func _on_ban_row_clicked(photo: String) -> void:
	var card: CharacterCard = _card_by_photo.get(photo, null)
	if card == null:
		_status_label.text = "「%s」的卡片还没加载出来，可以先点「全部加载」。" % ImageLoader.get_display_name(photo)
		return
	_scroll.ensure_control_visible(card)
	_status_label.text = "已定位到「%s」" % card.character_name


# ============================================================
#  导出
# ============================================================
func _on_export_pressed() -> void:
	if not DataManager.has_name():
		_prompt_for_name(true)
		return
	var bans := DataManager.get_bans()
	var vid := DataManager.ensure_voter_id()
	var out_dir := DataManager.effective_export_dir()

	var r: Dictionary = VoteExporter.save_vote_file(
		DataManager.voter_name, vid, bans, out_dir)
	if not bool(r["ok"]):
		_show_message("导出失败", "导出投票失败：\n%s" % String(r["error"]))
		return
	var tr: Dictionary = VoteExporter.save_vote_text_file(
		DataManager.voter_name, bans, out_dir)
	_show_export_dialog(String(r["path"]), String(tr.get("path", "")), bans.size())


## 导出完成弹窗：可改「下次导出到哪里」，选择会记住
func _show_export_dialog(json_path: String, txt_path: String, count: int) -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "ExportDoneDialog"
	dlg.title = "导出完成"
	dlg.ok_button_text = "关闭"
	dlg.min_size = Vector2i(660, 400)
	dlg.max_size = Vector2i(900, 700)
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "已导出 %d 个 Ban 名额" % count
	UITheme.style_label(title, 16, Color("7ddc7d"))
	vbox.add_child(title)

	var tip := Label.new()
	tip.text = "请把这个 json 文件发给组织者："
	UITheme.style_label(tip, 12, UITheme.TEXT)
	vbox.add_child(tip)

	var path_edit := LineEdit.new()
	path_edit.name = "JsonPathEdit"
	path_edit.text = ProjectSettings.globalize_path(json_path)
	path_edit.editable = false
	path_edit.custom_minimum_size = Vector2(600, 32)
	UITheme.apply_input(path_edit)
	vbox.add_child(path_edit)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var copy_btn := Button.new()
	copy_btn.text = "复制路径到剪贴板"
	UITheme.apply_button_primary(copy_btn)
	copy_btn.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(ProjectSettings.globalize_path(json_path))
		copy_btn.text = "✓ 已复制"
		_status_label.text = "路径已复制到剪贴板")
	btn_row.add_child(copy_btn)

	var open_btn := Button.new()
	open_btn.text = "打开所在文件夹"
	UITheme.apply_button(open_btn)
	open_btn.pressed.connect(func() -> void:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(json_path)))
	btn_row.add_child(open_btn)

	if txt_path != "":
		var txt_hint := Label.new()
		txt_hint.text = "同时导出了文本版（可直接粘到群里）：\n%s" % ProjectSettings.globalize_path(txt_path)
		txt_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(txt_hint, 10, UITheme.TEXT_MUTED)
		vbox.add_child(txt_hint)

	# ---- 下次导出到哪里（可改，会记住）----
	vbox.add_child(UITheme.separator())

	var dir_label := Label.new()
	dir_label.text = "下次导出到（会记住这个选择）："
	UITheme.style_label(dir_label, 12, UITheme.TEXT)
	vbox.add_child(dir_label)

	var dir_row := HBoxContainer.new()
	dir_row.add_theme_constant_override("separation", 8)
	vbox.add_child(dir_row)

	var dir_edit := LineEdit.new()
	dir_edit.name = "ExportDirEdit"
	dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
	dir_edit.editable = false
	dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dir_edit.custom_minimum_size = Vector2(360, 32)
	UITheme.apply_input(dir_edit)
	dir_row.add_child(dir_edit)

	var pick_btn := Button.new()
	pick_btn.name = "PickDirBtn"
	pick_btn.text = "选择文件夹…"
	UITheme.apply_button(pick_btn)
	dir_row.add_child(pick_btn)

	var reset_btn := Button.new()
	reset_btn.name = "ResetDirBtn"
	reset_btn.text = "恢复默认"
	reset_btn.tooltip_text = "恢复成程序自己的目录（user://exports/）"
	UITheme.apply_button(reset_btn)
	dir_row.add_child(reset_btn)

	# 目录选择器（原生对话框）
	var picker := FileDialog.new()
	picker.name = "DirPicker"
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.use_native_dialog = true
	picker.title = "选择导出目录"
	picker.dir_selected.connect(func(picked: String) -> void:
		if DataManager.set_export_dir(picked):
			dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
			_status_label.text = "下次会导出到：%s" % dir_edit.text
		else:
			_show_message("无法使用该目录", "这个目录创建不了或不能写入：\n%s" % picked))
	dlg.add_child(picker)
	pick_btn.pressed.connect(func() -> void:
		picker.current_dir = DataManager.effective_export_dir()
		picker.popup_centered(Vector2i(860, 600)))
	reset_btn.pressed.connect(func() -> void:
		DataManager.reset_export_dir()
		dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
		_status_label.text = "已恢复默认导出目录")

	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(680, 430))
	_status_label.text = "已导出：%s" % ProjectSettings.globalize_path(json_path)


func _show_message(title: String, msg: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.dialog_text = msg
	dlg.ok_button_text = "知道了"
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)
	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(460, 190))


## 工具栏「导出目录」：直接选目录，不用先导出一次
func _on_pick_export_dir() -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "ExportDirDialog"
	dlg.title = "导出目录"
	dlg.ok_button_text = "关闭"
	dlg.min_size = Vector2i(640, 230)
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var tip := Label.new()
	tip.text = "「导出我的投票」生成的 json / txt 会放到这里："
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(tip, 12, UITheme.TEXT)
	vbox.add_child(tip)

	var dir_edit := LineEdit.new()
	dir_edit.name = "ExportDirEdit"
	dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
	dir_edit.editable = false
	dir_edit.custom_minimum_size = Vector2(580, 32)
	UITheme.apply_input(dir_edit)
	vbox.add_child(dir_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var picker := FileDialog.new()
	picker.name = "DirPicker"
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.use_native_dialog = true
	picker.title = "选择导出目录"
	picker.dir_selected.connect(func(picked: String) -> void:
		if DataManager.set_export_dir(picked):
			dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
			_status_label.text = "已设置导出目录：%s" % dir_edit.text
			_update_status()
		else:
			_show_message("无法使用该目录", "这个目录创建不了或不能写入：\n%s" % picked))
	dlg.add_child(picker)

	var pick_btn := Button.new()
	pick_btn.text = "选择文件夹…"
	UITheme.apply_button_primary(pick_btn)
	pick_btn.pressed.connect(func() -> void:
		picker.current_dir = DataManager.effective_export_dir()
		picker.popup_centered(Vector2i(860, 600)))
	row.add_child(pick_btn)

	var open_btn := Button.new()
	open_btn.text = "打开这个目录"
	UITheme.apply_button(open_btn)
	open_btn.pressed.connect(func() -> void:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(DataManager.effective_export_dir())))
	row.add_child(open_btn)

	var reset_btn := Button.new()
	reset_btn.text = "恢复默认"
	reset_btn.tooltip_text = "恢复成程序自己的目录（user://exports/）"
	UITheme.apply_button(reset_btn)
	reset_btn.pressed.connect(func() -> void:
		DataManager.reset_export_dir()
		dir_edit.text = ProjectSettings.globalize_path(DataManager.effective_export_dir())
		_status_label.text = "已恢复默认导出目录"
		_update_status())
	row.add_child(reset_btn)

	var hint := Label.new()
	hint.text = "选择会记住，下次启动还在（存在 votes.json 里）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, 10, UITheme.TEXT_MUTED)
	vbox.add_child(hint)

	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(660, 250))


# ============================================================
#  组织者模式入口
# ============================================================
func _on_organizer_pressed() -> void:
	if FileAccess.file_exists(ORGANIZER_UNLOCK_PATH):
		_go_organizer()
		return
	var dlg := AcceptDialog.new()
	dlg.name = "PasswordDialog"
	dlg.title = "组织者模式"
	dlg.ok_button_text = "进入"
	dlg.min_size = Vector2i(400, 180)
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	dlg.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var tip := Label.new()
	tip.text = "请输入组织者口令："
	UITheme.style_label(tip, 14, UITheme.TEXT)
	vbox.add_child(tip)

	var edit := LineEdit.new()
	edit.secret = true
	edit.placeholder_text = "口令"
	edit.custom_minimum_size = Vector2(340, 32)
	UITheme.apply_input(edit)
	vbox.add_child(edit)

	var hint := Label.new()
	hint.text = "这是防止群友误入的简易口令，不是安全措施。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(hint, 10, UITheme.TEXT_MUTED)
	vbox.add_child(hint)

	var try_once := func() -> void:
		if edit.text == ORGANIZER_PASSWORD:
			var f := FileAccess.open(ORGANIZER_UNLOCK_PATH, FileAccess.WRITE)
			if f != null:
				f.store_string("unlocked\n")
				f.close()
			dlg.queue_free()
			_go_organizer()
		else:
			edit.text = ""
			tip.text = "口令不对，请重试："
			tip.add_theme_color_override("font_color", UITheme.DANGER)
	dlg.confirmed.connect(try_once)
	edit.text_submitted.connect(func(_t: String) -> void: try_once.call())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(420, 200))
	edit.grab_focus()


func _go_organizer() -> void:
	DataManager.save()
	var err := get_tree().change_scene_to_file(ORGANIZER_SCENE)
	if err != OK:
		_show_message("无法进入组织者模式", "加载 %s 失败（err=%d）" % [ORGANIZER_SCENE, err])


# ============================================================
#  清空 / 搜索 / 筛选
# ============================================================
func _on_clear_pressed() -> void:
	if DataManager.get_ban_count() == 0:
		_status_label.text = "你的 Ban 名单已经是空的。"
		return
	var dlg := ConfirmationDialog.new()
	dlg.name = "ClearConfirm"
	dlg.title = "清空我的投票"
	dlg.dialog_text = "确定清空你自己的 Ban 名单吗？\n（我的名字和 voter_id 不受影响）\n此操作不可撤销。"
	dlg.ok_button_text = "确定清空"
	dlg.cancel_button_text = "取消"
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		DataManager.clear_all()
		_status_label.text = "已清空你的 Ban 名单。"
		dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(420, 180))


func _on_search_changed(_t: String) -> void:
	_search_timer = 0.0


func _on_group_selected(_idx: int) -> void:
	_apply_filter()


func _process(delta: float) -> void:
	if _search_timer >= 0.0:
		_search_timer += delta
		if _search_timer >= 0.25:
			_search_timer = -1.0
			_apply_filter()


func _apply_filter() -> void:
	var kw := ""
	if _search_edit != null:
		kw = _search_edit.text.strip_edges()
	var group := ""
	if _group_option != null and _group_option.visible and _group_option.selected > 0:
		group = _group_option.get_item_text(_group_option.selected)

	var shown := 0
	for card in _cards:
		var vis := true
		if kw != "":
			vis = card.character_name.contains(kw) or card.photo.contains(kw)
		if vis and group != "":
			vis = card.group == group
		card.visible = vis
		if vis:
			shown += 1
	_filtered_count = shown
	_flow.queue_sort()
	_update_status()


# ============================================================
#  右键看大图 / 说明
# ============================================================
## 右键看大图。
## 【坑】AcceptDialog 会按内容自动撑大自己。如果把原图直接塞进一个
## SIZE_EXPAND_FILL 的 TextureRect，弹窗会被撑到接近图片的原始像素高度
## （实测 480x2300），远超屏幕，结果只看得到底部文字、完全看不到图。
## 所以这里三件事都要做：
##   ① 先把图按方框等比缩好   ② 图片框用 SHRINK_CENTER   ③ 给弹窗设 max_size
func _on_card_preview_requested(photo: String) -> void:
	var meta := ImageLoader.find_photo(photo)
	if meta.is_empty():
		return
	var path := String(meta["path"])
	var img := ImageLoader.load_full_image(photo)
	if img == null or img.is_empty():
		_status_label.text = "无法读取该图片（文件可能已损坏）：%s" % photo
		return

	var box := PREVIEW_BOX
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		_status_label.text = "这张图尺寸异常：%s" % photo
		return

	# 等比缩放进方框：大图只缩不放，小图最多放大 3 倍
	var k: float = minf(float(box) / float(w), float(box) / float(h))
	if w > box or h > box:
		k = minf(k, 1.0)
	else:
		k = minf(k, 3.0)
	var tw: int = maxi(1, int(round(w * k)))
	var th: int = maxi(1, int(round(h * k)))
	var shown := img
	if tw != w or th != h:
		shown = img.duplicate() as Image
		shown.resize(tw, th, Image.INTERPOLATE_LANCZOS)

	_show_preview(ImageTexture.create_from_image(shown), String(meta["name"]),
		photo, w, h, path, Vector2(tw, th))


func _show_preview(tex: Texture2D, disp: String, photo: String,
		w: int, h: int, path: String, shown_size: Vector2) -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "PreviewDialog"
	dlg.title = "%s · 查看大图" % disp
	dlg.ok_button_text = "关闭"
	dlg.min_size = Vector2i(420, 300)
	# 关键：给上限，否则会被内容撑到屏幕外
	dlg.max_size = Vector2i(PREVIEW_BOX + 140, PREVIEW_BOX + 220)
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	dlg.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# 用 CenterContainer 包住，避免 TextureRect 去撑满可用空间
	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	center.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(center)

	var tr := TextureRect.new()
	tr.name = "PreviewImage"
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = shown_size
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center.add_child(tr)

	var info := Label.new()
	info.text = "%s\n照片ID：%s\n原图尺寸：%d × %d（当前显示 %d × %d）\n文件：%s" % [
		disp, photo, w, h, int(shown_size.x), int(shown_size.y), path]
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_label(info, 11, UITheme.TEXT_MUTED)
	vbox.add_child(info)

	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	# 显式给尺寸，不让弹窗按内容自由膨胀到屏幕外
	dlg.popup_centered(Vector2i(
		clampi(int(shown_size.x) + 70, 420, PREVIEW_BOX + 140),
		clampi(int(shown_size.y) + 160, 300, PREVIEW_BOX + 220)))


func _on_help_pressed() -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "HelpDialog"
	dlg.title = "使用说明"
	dlg.ok_button_text = "知道了"
	dlg.min_size = Vector2i(660, 520)
	dlg.add_theme_stylebox_override("panel",
		UITheme.make_style(UITheme.BG, UITheme.RADIUS_LG, Color(0, 0, 0, 0.6),
			UITheme.BORDER, 1, 14))
	add_child(dlg)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	dlg.add_child(margin)

	var scroll := ScrollContainer.new()
	UITheme.apply_scroll(scroll)
	margin.add_child(scroll)

	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.scroll_active = false
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(600, 420)
	lbl.add_theme_font_size_override("normal_font_size", 12)
	lbl.add_theme_color_override("default_color", UITheme.TEXT)
	lbl.text = _help_text()
	scroll.add_child(lbl)

	dlg.confirmed.connect(func() -> void: dlg.queue_free())
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	dlg.popup_centered(Vector2i(680, 540))


func _help_text() -> String:
	var nm := DataManager.voter_name if DataManager.voter_name != "" else "（未命名）"
	var vid := DataManager.voter_id if DataManager.voter_id != "" else "（未生成）"
	return """[b][color=#FF6B00]火影忍者公共 Ban 选投票器 —— 玩家端[/color][/b]

[b]你的信息[/b]
· 名字：[b]%s[/b]
· 唯一 ID：[code]%s[/code]（改名也不会变，组织者靠它区分谁是谁）

[b]怎么投票[/b]
1. 点卡片 = 把这个忍者加入你的 Ban 名单（橙色边框 + 右上角出现徽章）
   再点一次 = 取消
2. 右上角可以搜索、按分组筛选
3. 鼠标悬停在卡片上可以看到完整名字与照片 ID；[b]右键[/b]看大图

[b]怎么交票（重要）[/b]
投完后点工具栏的 [b]「导出我的投票」[/b]，会生成两个文件：
· [code]vote_<你的名字>_<时间>.json[/code] —— [b]把这个发给组织者[/b]
· [code]vote_<你的名字>_<时间>.txt[/code] —— 文本版，可以直接粘到群里
弹窗里可以「复制路径到剪贴板」或「打开所在文件夹」。每个忍者只算一票，
重复 Ban 同一个不会多算。

[b]快捷键[/b]
· Ctrl+F      聚焦搜索框
· Ctrl+E      导出我的投票
· Ctrl+Delete 清空我的投票
· 右键点卡片   查看大图

[b]数据在哪[/b]
· 我的投票：[code]user://votes.json[/code]
· 我的名字：[code]user://voter_name.txt[/code]
· 我的 ID：[code]user://voter_id.txt[/code]
· 导出目录：[code]user://exports/[/code]

[b]其他[/b]
· 「导入张数」默认 9999（不限），也可以点「全部加载」
· 往头像目录里丢新图后，点「重新扫描」即可生效，不用重启
· 右上角「组织者模式」是收票汇总用的，普通玩家用不到（需要口令）""" % [nm, vid]


# ============================================================
#  状态栏 / 按钮
# ============================================================
func _update_status() -> void:
	if _status_label == null:
		return
	var parts: Array[String] = []
	if _total_count == 0:
		parts.append("未找到头像目录")
	else:
		parts.append("已加载 %d / 共 %d 张" % [_loaded_count, _total_count])
		parts.append("显示 %d" % _filtered_count)
	var bans := DataManager.get_bans()
	# Ban 名单的明细现在在右侧面板里，状态栏只留一个计数
	parts.append("已 Ban %d 个" % bans.size())
	if DataManager.has_custom_export_dir():
		parts.append("导出到 %s" % DataManager.export_dir.get_file())
	if _loading:
		parts.append("加载中…")
	_status_label.text = "  |  ".join(parts)


func _update_buttons() -> void:
	if _load_all_btn == null:
		return
	_load_all_btn.disabled = _loading or _loaded_count >= _total_count
	_import_btn.disabled = _loading or _total_count == 0
	_export_btn.disabled = DataManager.get_ban_count() == 0


# ============================================================
#  快捷键
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("focus_search"):
		_search_edit.grab_focus()
		_search_edit.select_all()
		accept_event()
	elif event.is_action_pressed("export_result"):
		_on_export_pressed()
		accept_event()
	elif event.is_action_pressed("clear_all_votes"):
		_on_clear_pressed()
		accept_event()
