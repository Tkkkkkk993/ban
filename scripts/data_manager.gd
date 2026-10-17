# ============================================================
#  data_manager.gd —— Autoload「DataManager」
# ------------------------------------------------------------
#  分布式投票改造后的「玩家端本地数据」：只关心我自己是谁、我 Ban 了哪些。
#
#  数据模型：
#    voter_name : 我的名字（"张三"），存 user://voter_name.txt
#    voter_id   : 我的唯一 ID（"v_xxx"），存 user://voter_id.txt，改名不变
#    bans       : 我 Ban 掉的照片 ID 列表，保证唯一、有顺序
#
#  落盘 user://votes.json：
#    { "version": 3, "voter_name": "张三", "voter_id": "v_xxx",
#      "bans": ["90001_headshot", ...] }
#
#  为什么 voter_id 要单独存文件、而不是只放 votes.json：
#    需求要求「改名后 id 不变」，而且 votes.json 可能被用户清掉，
#    id 单独持久化更稳。两个文件互相独立，谁缺了就补谁。
#
#  旧数据兼容：读到旧的多人格式（含 voters / bans 字典）时，
#    把所有人的 Ban 名单并成一个集合保留下来，然后提示「检测到旧版本数据，已重置为单人模式」。
# ============================================================
extends Node

## 某个照片的 Ban 状态发生变化（我 Ban / 取消 Ban 时发）
signal ban_changed(photo: String, banned: bool)
## 我的 Ban 名单整体变化（清空、批量导入等）
signal bans_changed()
## 名字发生变化
signal name_changed(new_name: String)
## 每次改动后都会发一次（UI 可统一刷新）
signal data_changed()
## 读到了旧格式数据并已完成迁移（Main 收到后可以弹提示）
signal legacy_migrated(kept_count: int, dropped_voters: int)

## 至少要有几个字才算有效名字
const MIN_NAME_LEN := 1
const MAX_NAME_LEN := 24

const SAVE_PATH := "user://votes.json"
const NAME_PATH := "user://voter_name.txt"
const ID_PATH := "user://voter_id.txt"
const SAVE_DEBOUNCE_MS := 500
const SAVE_VERSION := 3

var voter_name := ""
var voter_id := ""
var bans: Array[String] = []

## 导出目录（用户自选，留空表示用默认的 user://exports/）。
## 存进 votes.json，下次启动还在。
var export_dir := ""

var _dirty := false
var _dirty_ms := 0
var _loaded := false


func _ready() -> void:
	read_from_disk()
	set_process(true)


func _process(delta: float) -> void:
	# debounce 落盘
	if not _dirty:
		return
	_dirty_ms += int(delta * 1000.0)
	if _dirty_ms >= SAVE_DEBOUNCE_MS:
		save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _dirty:
			save()


func _exit_tree() -> void:
	if _dirty:
		save()


# ============================================================
#  名字
# ============================================================

## 是否已经设置过名字（没设置就要弹窗问）
func has_name() -> bool:
	return voter_name.strip_edges().length() >= MIN_NAME_LEN


## 清洗名字：去首尾空白、压掉换行、限长
func sanitize_name(raw: String) -> String:
	var n := raw.strip_edges()
	n = n.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	while n.contains("  "):
		n = n.replace("  ", " ")
	if n.length() > MAX_NAME_LEN:
		n = n.substr(0, MAX_NAME_LEN)
	return n


## 设置名字（会同步写 user://voter_name.txt）
func set_voter_name(raw: String) -> bool:
	var n := sanitize_name(raw)
	if n.length() < MIN_NAME_LEN:
		return false
	var changed := n != voter_name
	voter_name = n
	_write_text(NAME_PATH, n)
	# 名字变了但还没有 id，就补一个
	if voter_id == "":
		ensure_voter_id()
	if changed:
		name_changed.emit(voter_name)
		data_changed.emit()
	_mark_dirty()
	return true


# ============================================================
#  voter_id（UUID）
# ============================================================

## 保证有 voter_id；没有就生成一个并持久化
func ensure_voter_id() -> String:
	if voter_id != "":
		return voter_id
	if FileAccess.file_exists(ID_PATH):
		var saved := _read_text(ID_PATH).strip_edges()
		if saved != "":
			voter_id = saved
			return voter_id
	voter_id = "v_" + _make_uuid()
	_write_text(ID_PATH, voter_id)
	_mark_dirty()
	return voter_id


## 生成一个 UUID v4 风格的字符串（32 位十六进制，带连字符）
func _make_uuid() -> String:
	var hex := "0123456789abcdef"
	var out := ""
	for i in range(32):
		if i == 8 or i == 12 or i == 16 or i == 20:
			out += "-"
		out += hex[randi() % 16]
	return out


# ============================================================
#  Ban 名单
# ============================================================

## 我是否 Ban 了这个忍者
func is_banned(photo: String) -> bool:
	return bans.has(photo)


## 我 Ban 了多少个
func get_ban_count() -> int:
	return bans.size()


## 我的全部 Ban 名单（副本）
func get_bans() -> Array[String]:
	return bans.duplicate()


## 切换某个忍者的 Ban 状态，返回切换后是否处于「已 Ban」
func toggle_ban(photo: String) -> bool:
	if photo == "":
		return false
	if bans.has(photo):
		bans.erase(photo)
		ban_changed.emit(photo, false)
		bans_changed.emit()
		data_changed.emit()
		_mark_dirty()
		return false
	bans.append(photo)
	ban_changed.emit(photo, true)
	bans_changed.emit()
	data_changed.emit()
	_mark_dirty()
	return true


## 明确设置某个忍者的 Ban 状态
func set_ban(photo: String, banned: bool) -> void:
	if photo == "":
		return
	if banned and not bans.has(photo):
		bans.append(photo)
		ban_changed.emit(photo, true)
		bans_changed.emit()
		data_changed.emit()
		_mark_dirty()
	elif not banned and bans.has(photo):
		bans.erase(photo)
		ban_changed.emit(photo, false)
		bans_changed.emit()
		data_changed.emit()
		_mark_dirty()


## 直接用一份名单覆盖（导入组织者给的结果时用）
func replace_bans(list: Array, silent: bool = false) -> void:
	var seen := {}
	var out: Array[String] = []
	for p in list:
		var s := String(p)
		if s == "" or seen.has(s):
			continue
		seen[s] = true
		out.append(s)
	bans = out
	if not silent:
		bans_changed.emit()
		data_changed.emit()
	_mark_dirty()


## 清空我自己的 Ban 名单（名字和 id 不动）
func clear_all() -> void:
	if bans.is_empty():
		return
	bans.clear()
	bans_changed.emit()
	data_changed.emit()
	_mark_dirty()


# ============================================================
#  导出目录
# ============================================================

## 默认导出目录
func default_export_dir() -> String:
	return "user://exports"


## 当前生效的导出目录（用户没选过就是默认的），并确保它存在
func effective_export_dir() -> String:
	var d := export_dir.strip_edges()
	if d == "":
		d = default_export_dir()
	DirAccess.make_dir_recursive_absolute(d)
	return d


## 设置导出目录；传空串表示恢复默认。返回是否设置成功。
func set_export_dir(dir: String) -> bool:
	var d := dir.strip_edges()
	if d == "":
		export_dir = ""
		_mark_dirty()
		save()
		return true
	# 目录不存在就尝试创建（用户可能手打了一个新路径）
	if not DirAccess.dir_exists_absolute(d):
		var err := DirAccess.make_dir_recursive_absolute(d)
		if err != OK:
			push_warning("[DataManager] 创建导出目录失败：%s (err=%d)" % [d, err])
			return false
	export_dir = d
	_mark_dirty()
	save()
	return true


## 导出目录是不是用户自定义的（用于界面提示）
func has_custom_export_dir() -> bool:
	return export_dir.strip_edges() != ""


## 恢复默认导出目录
func reset_export_dir() -> void:
	export_dir = ""
	_mark_dirty()
	save()


# ============================================================
#  落盘 / 读盘
# ============================================================

func save() -> void:
	var payload := {
		"version": SAVE_VERSION,
		"voter_name": voter_name,
		"voter_id": ensure_voter_id(),
		"bans": bans,
		"export_dir": export_dir,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[DataManager] 无法写入 %s (err=%d)" % [
			SAVE_PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	_dirty = false
	_dirty_ms = 0


## 从磁盘读取本地数据（旧格式会自动迁移并提示）
func read_from_disk() -> void:
	# ---- 1. 名字与 id 先各读各的独立文件 ----
	if FileAccess.file_exists(NAME_PATH):
		voter_name = sanitize_name(_read_text(NAME_PATH))
	if FileAccess.file_exists(ID_PATH):
		var saved_id := _read_text(ID_PATH).strip_edges()
		if saved_id != "":
			voter_id = saved_id
	ensure_voter_id()

	# ---- 2. 读 votes.json ----
	bans.clear()
	if not FileAccess.file_exists(SAVE_PATH):
		_loaded = true
		return

	var txt := FileAccess.get_file_as_string(SAVE_PATH)
	if txt.is_empty():
		_loaded = true
		return

	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[DataManager] %s 解析失败，按空数据处理。" % SAVE_PATH)
		_loaded = true
		return

	var d: Dictionary = parsed
	var ver := int(d.get("version", 0))

	if ver >= SAVE_VERSION and typeof(d.get("bans", null)) == TYPE_ARRAY:
		# ---- 新格式 ----
		if String(d.get("voter_name", "")) != "" and voter_name == "":
			voter_name = sanitize_name(String(d["voter_name"]))
		if String(d.get("voter_id", "")) != "":
			voter_id = String(d["voter_id"])
			_write_text(ID_PATH, voter_id)
		export_dir = String(d.get("export_dir", ""))
		_ingest_bans(d["bans"])
	else:
		# ---- 旧格式：多人投票 / 更早的 {"鸣人": 3} ----
		var kept: Array = []
		var dropped := 0
		if typeof(d.get("bans", null)) == TYPE_DICTIONARY:
			# {version:2, voters:{...}, bans:{v1:[...]}}
			var old_bans: Dictionary = d["bans"]
			var voters_field: Dictionary = d.get("voters", {})
			for vid in old_bans.keys():
				var arr = old_bans[vid]
				if typeof(arr) == TYPE_ARRAY:
					if (arr as Array).size() > 0:
						for p in (arr as Array):
							kept.append(String(p))
					dropped += 1
			# 名字：如果旧文件里只有一个投票人，就用他的名字
			if voter_name == "" and voters_field.size() == 1:
				for k in voters_field.keys():
					var nm := sanitize_name(String(voters_field[k]))
					if nm != "" and nm != "历史票":
						voter_name = nm
		else:
			# 更早的 {"鸣人": 3}：票数没法还原成单人名单，直接丢弃
			for k in d.keys():
				if String(k) in ["version", "voter_name", "voter_id", "bans", "voters"]:
					continue
				dropped += 1

		_ingest_bans(kept)
		if voter_name != "":
			_write_text(NAME_PATH, voter_name)
		push_warning("[DataManager] 检测到旧版本数据，已迁移为单人模式（保留 %d 个 Ban，丢弃 %d 位旧投票人的结构）" % [bans.size(), dropped])
		legacy_migrated.emit(bans.size(), dropped)

	_loaded = true


func _ingest_bans(list) -> void:
	if typeof(list) != TYPE_ARRAY:
		return
	var seen := {}
	for p in (list as Array):
		var s := String(p)
		if s == "" or seen.has(s):
			continue
		seen[s] = true
		bans.append(s)


func is_first_run() -> bool:
	return not has_name()


# ============================================================
#  小工具
# ============================================================
func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()


func _write_text(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[DataManager] 无法写入 %s (err=%d)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(content)
	f.close()


func _mark_dirty() -> void:
	_dirty = true
	_dirty_ms = 0
