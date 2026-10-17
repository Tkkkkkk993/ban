# ============================================================
#  ranking_panel.gd —— 实时排名面板
# ------------------------------------------------------------
#  结构：PanelContainer(本脚本)
#          └ Margin > VBox
#              ├ Header[TitleLabel / CountLabel]
#              ├ Separator
#              ├ ScrollContainer > ListBox   ← 动态生成 RankingRow
#              └ FooterLabel
#
#  只显示票数 > 0 的条目，按票数降序。
#  行节点做了池化复用：行数不变时只更新文字，不重建节点；
#  名次发生变化的行会闪一下，方便看出重排。
#
#  头像不在这里读 DataManager，而是向 ImageLoader 要缩略图；
#  内存里没有就只显示占位方块，等 ImageLoader.batch_loaded 再补上。
# ============================================================
class_name RankingPanel
extends PanelContainer

# UITheme 用 preload 引用（不依赖全局 class_name 注册，任何运行方式下都可用）
const UITheme := preload("res://scripts/ui_theme.gd")

## 点击某一行，请求把左侧列表滚动到该忍者
signal row_clicked(photo: String)

const AVATAR_SYNC_BUDGET := 8            # 每次刷新最多同步补多少张头像

@onready var _title_label: Label = $Margin/VBox/Header/HeaderMargin/HeaderBox/TitleLabel
@onready var _count_label: Label = $Margin/VBox/Header/HeaderMargin/HeaderBox/CountLabel
@onready var _list_box: VBoxContainer = $Margin/VBox/ScrollContainer/ListBox
@onready var _scroll: ScrollContainer = $Margin/VBox/ScrollContainer
@onready var _footer_label: Label = $Margin/VBox/FooterLabel

@export var empty_hint: String = "还没有人投票\n点击左侧卡片把他加入你的 Ban 名单"
@export var max_rows: int = 200
@export var compact: bool = false

var _rows: Array[RankingRow] = []
var _built := false
var _last_order: Array[String] = []
var _pending_textures: Array = []


func _ready() -> void:
	UITheme.apply_scroll(_scroll)
	_ensure_built()
	# 头像晚一点加载好时，把还没出图的行补上
	if not ImageLoader.batch_loaded.is_connected(_on_batch_loaded):
		ImageLoader.batch_loaded.connect(_on_batch_loaded)


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_list_box.add_child(_make_empty_hint())


func _make_empty_hint() -> Control:
	var box := MarginContainer.new()
	box.name = "EmptyHint"
	box.add_theme_constant_override("margin_top", 16)
	box.add_theme_constant_override("margin_left", 6)
	box.add_theme_constant_override("margin_right", 6)
	var lbl := Label.new()
	lbl.text = empty_hint
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.style_label(lbl, 12, Color("7a7a7a"))
	box.add_child(lbl)
	return box


# ============================================================
#  对外接口
# ============================================================

## 刷新排名。
## ranking: [[照片ID, 票数, 显示名, [投票人显示名...]], ...]，已按票数降序。
func refresh(ranking: Array) -> void:
	_ensure_built()

	if ranking.is_empty():
		_clear_rows()
		_set_empty_hint_visible(true)
		_count_label.text = "0 项"
		_footer_label.text = "还没有任何 Ban 记录"
		return

	_set_empty_hint_visible(false)
	var total := ranking.size()
	var shown: int = mini(total, maxi(1, max_rows))
	_count_label.text = "%d 项" % total
	if total <= shown:
		_footer_label.text = "仅显示票数 > 0 的条目"
	else:
		_footer_label.text = "共 %d 项，仅显示前 %d 项" % [total, shown]

	# 行数与池子不一致时补齐/裁剪
	while _rows.size() < shown:
		var row := RankingRow.new()
		row.name = "Row%d" % _rows.size()
		row.row_clicked.connect(_on_row_clicked)
		_list_box.add_child(row)
		_rows.append(row)
	while _rows.size() > shown:
		var dead: RankingRow = _rows.pop_back()
		dead.queue_free()

	var order: Array[String] = []
	var need_texture: Array = []
	var texture_budget := AVATAR_SYNC_BUDGET

	for i in range(shown):
		var item: Array = ranking[i]
		var photo := String(item[0])
		var count := int(item[1])
		var disp := String(item[2]) if item.size() > 2 else photo
		var voters: Array = item[3] if item.size() > 3 else []
		var row: RankingRow = _rows[i]
		order.append(photo)

		var prev_idx := _last_order.find(photo)
		var rank_changed := prev_idx != -1 and prev_idx != i
		row.setup(i + 1, photo, disp, count, voters, (i % 2) == 1)

		# 头像：内存里已有就直接用，否则本次最多同步补几张，剩下的等异步通知
		var tex: Texture2D = null
		if ImageLoader.has_texture(photo):
			tex = ImageLoader.get_thumbnail(photo)
		elif texture_budget > 0:
			tex = ImageLoader.get_thumbnail(photo)
			if tex != null:
				texture_budget -= 1
		if tex != null:
			row.set_texture(tex)
		elif not need_texture.has(photo):
			need_texture.append(photo)

		if rank_changed and i < 8:
			row.pulse()

	_last_order = order
	_request_missing_textures(need_texture)


## 清空显示（例如清空投票后）
func clear() -> void:
	refresh([])


# ============================================================
#  内部
# ============================================================
func _clear_rows() -> void:
	for row in _rows:
		row.queue_free()
	_rows.clear()
	_last_order.clear()


func _set_empty_hint_visible(v: bool) -> void:
	var hint := _list_box.get_node_or_null("EmptyHint")
	if hint != null:
		(hint as Control).visible = v


## 把排名里还没出图的头像补上。
## 排名面板一般只有几十行，同步补图代价很小（128x128 的 Image 已在内存里）。
## 剩下没轮到的，等 ImageLoader.batch_loaded 通知时再补。
func _request_missing_textures(photos: Array) -> void:
	if photos.is_empty():
		_pending_textures.clear()
		return
	for p in photos:
		if not _pending_textures.has(p):
			_pending_textures.append(p)
	var budget := AVATAR_SYNC_BUDGET
	while budget > 0 and not _pending_textures.is_empty():
		var photo := String(_pending_textures.pop_front())
		var tex := ImageLoader.get_thumbnail(photo)
		if tex != null:
			_apply_texture(photo, tex)
		budget -= 1


func _apply_texture(photo: String, tex: Texture2D) -> void:
	for row in _rows:
		if row.photo == photo:
			row.set_texture(tex)
			return


func _on_batch_loaded(items: Array) -> void:
	for it in items:
		var photo := String(it.get("photo", ""))
		var tex: Texture2D = it.get("texture", null)
		if tex == null:
			continue
		_pending_textures.erase(photo)
		_apply_texture(photo, tex)
	# 还有没出图的，下一帧继续补
	if not _pending_textures.is_empty():
		var leftover := _pending_textures.duplicate()
		_pending_textures.clear()
		_request_missing_textures(leftover)


func _on_row_clicked(photo: String) -> void:
	row_clicked.emit(photo)
