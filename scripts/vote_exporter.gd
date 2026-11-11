# ============================================================
#  vote_exporter.gd —— 投票导出（玩家端核心功能）
# ------------------------------------------------------------
#  把「我是谁 + 我 Ban 了哪些」导成一份标准 json，玩家发给组织者。
#
#  输出格式：
#    {
#      "format": "naruto_ban_vote",
#      "version": 1,
#      "voter_id": "v_xxxx",
#      "voter_name": "张三",
#      "timestamp": "2026-10-07T15:30:00",
#      "bans": ["90001_headshot", "90002_headshot"]
#    }
#
#  【bans 里放的是文件名去扩展名，不是显示名】
#    因为显示名可能重名（PVE 副本 vs 决斗场），而文件名唯一。
#
#  【文件名净化】
#    群友可能把名字填成 "张三/游戏ID" 或带 emoji，
#    这些字符在 Windows 上是非法文件名字符，直接拿来拼文件名会写盘失败。
#    所以统一把非法字符换成下划线。
#
#  用法（全部是静态函数，不需要实例化，也不占 Autoload）：
#    const VoteExporter := preload("res://scripts/vote_exporter.gd")
#    var r := VoteExporter.save_vote_file(name, id, bans)
#    if r.ok: print(r.path)
# ============================================================
class_name VoteExporterNS
extends RefCounted

# 文本格式的生成交给 vote_text.gd，这里只负责「导出成文件」
const VoteText := preload("res://scripts/vote_text.gd")

## 输出目录（自动创建）
const EXPORT_DIR := "user://exports"
## 格式标识，导入端靠它校验
const FORMAT_TAG := "naruto_ban_vote"
const FORMAT_VERSION := 1

## Windows 非法文件名字符 + 控制字符
const ILLEGAL_CHARS := ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]


## 生成时间戳字符串：2026-10-07T15:30:00
static func now_timestamp() -> String:
	return Time.get_datetime_string_from_system()


## 生成文件名用的紧凑时间戳：20261007_153000
static func compact_timestamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [
		int(d.get("year", 0)), int(d.get("month", 0)), int(d.get("day", 0)),
		int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0)),
	]


## 把名字净化成安全的文件名片段
static func safe_name(raw: String, fallback: String = "anonymous") -> String:
	var n := raw.strip_edges()
	# 去掉非法字符和控制字符
	for ch in ILLEGAL_CHARS:
		n = n.replace(ch, "_")
	var out := ""
	for i in range(n.length()):
		var c := n[i]
		var code := c.unicode_at(0)
		if code < 32:
			continue
		out += c
	# 去掉首尾的点和空格（Windows 不允许文件名以点/空格结尾）
	out = out.strip_edges()
	while out.begins_with("."):
		out = out.substr(1)
	while out.ends_with("."):
		out = out.substr(0, out.length() - 1)
	if out.strip_edges() == "":
		out = fallback
	if out.length() > 24:
		out = out.substr(0, 24)
	return out


## 组装投票数据字典
## bans 会自动去重并保持原顺序
static func build_vote_dict(voter_name: String, voter_id: String,
		bans: Array) -> Dictionary:
	var seen := {}
	var uniq: Array = []
	for p in bans:
		var s := String(p)
		if s == "" or seen.has(s):
			continue
		seen[s] = true
		uniq.append(s)
	return {
		"format": FORMAT_TAG,
		"version": FORMAT_VERSION,
		"voter_id": voter_id,
		"voter_name": voter_name,
		"timestamp": now_timestamp(),
		"bans": uniq,
	}


## 生成导出文件路径（不写盘）。带时间戳，同一秒内重复导出不会互相覆盖。
## out_dir 传空则用默认的 user://exports/
static func make_export_path(voter_name: String, out_dir: String = "") -> String:
	var dir := out_dir.strip_edges()
	if dir == "":
		dir = EXPORT_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("vote_%s_%s.json" % [
		safe_name(voter_name), compact_timestamp()])


## 导出投票文件。
## out_dir 为空时写到默认的 user://exports/；用户自选目录时传进来。
## 返回 { ok: bool, path: String, error: String, count: int }
static func save_vote_file(voter_name: String, voter_id: String, bans: Array,
		out_dir: String = "") -> Dictionary:
	if voter_name.strip_edges() == "":
		return {"ok": false, "path": "", "error": "名字为空，无法导出", "count": 0}
	if voter_id.strip_edges() == "":
		return {"ok": false, "path": "", "error": "缺少 voter_id，无法导出", "count": 0}

	var data := build_vote_dict(voter_name, voter_id, bans)
	var path := make_export_path(voter_name, out_dir)

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "path": path,
			"error": "写盘失败（err=%d，路径 %s）" % [err, path], "count": 0}
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

	return {
		"ok": true,
		"path": path,
		"error": "",
		"count": (data["bans"] as Array).size(),
	}


## 导出成纯文本（方便直接粘到群里，也能被组织者端批量识别）
## 格式见 vote_text.gd 顶部注释。每行带 <照片ID>，所以显示名重名也不会统计错。
static func build_vote_text(voter_name: String, bans: Array) -> String:
	var entries: Array = []
	for p in bans:
		var photo := String(p)
		entries.append([photo, _display_name_of(photo)])
	return VoteText.build_block(voter_name, entries)


## 查显示名（本类是静态工具，通过 Autoload 拿 ImageLoader；拿不到就用照片ID）
static func _display_name_of(photo: String) -> String:
	var t := Engine.get_main_loop()
	if t is SceneTree:
		var il = (t as SceneTree).root.get_node_or_null("ImageLoader")
		if il != null:
			var n := String(il.get_display_name(photo))
			if n != "":
				return n
	return photo


## 导出投票文本文件，返回 { ok, path, error }
static func save_vote_text_file(voter_name: String, bans: Array,
		out_dir: String = "") -> Dictionary:
	if voter_name.strip_edges() == "":
		return {"ok": false, "path": "", "error": "名字为空，无法导出"}
	var dir := out_dir.strip_edges()
	if dir == "":
		dir = EXPORT_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("vote_%s_%s.txt" % [
		safe_name(voter_name), compact_timestamp()])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "path": path,
			"error": "写盘失败（err=%d）" % FileAccess.get_open_error()}
	f.store_string(build_vote_text(voter_name, bans))
	f.close()
	return {"ok": true, "path": path, "error": ""}
