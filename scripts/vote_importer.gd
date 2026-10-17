# ============================================================
#  vote_importer.gd —— 投票导入 + 合并统计（组织者端核心）
# ------------------------------------------------------------
#  流程：
#    1. 搜集要导入的 json（单个文件 / 多选 / 整个文件夹）
#    2. 逐个校验 format == "naruto_ban_vote"，坏文件只记错误不中断
#    3. 同一个 voter_id 出现多份 → 按 timestamp 取最新的那份
#       （timestamp 缺失或格式不对时，退回比文件修改时间）
#    4. 合并统计：对每人的 bans 去重后逐个 +1
#
#  统计口径（防刷票）：
#    同一个人即使把同一个忍者写进 bans 十次，也只算 1 票。
#
#  用法（静态函数，不需要实例化，也不占 Autoload）：
#    const VoteImporter := preload("res://scripts/vote_importer.gd")
#    var stats := VoteImporter.import_paths(paths)
#    # stats.ranking / stats.voters / stats.errors ...
# ============================================================
class_name VoteImporterNS
extends RefCounted

const EXPECT_FORMAT := "naruto_ban_vote"
## 一个文件夹里最多读多少个 json（防止误选到超大目录卡住）
const MAX_FILES_PER_DIR := 2000


# ============================================================
#  入口
# ============================================================

## 导入一批路径（文件或文件夹都可以混着传）。
## 返回统计结果字典，字段见类注释。
static func import_paths(paths: Array) -> Dictionary:
	var files := collect_vote_files(paths)
	return import_files(files)


## 从路径列表里展开出所有 .json 文件（文件夹会递归一层，不递归子目录）
static func collect_vote_files(paths: Array) -> Array:
	var out: Array = []
	var seen := {}
	for p in paths:
		var path := String(p)
		if path == "":
			continue
		if DirAccess.dir_exists_absolute(path):
			var d := DirAccess.open(path)
			if d == null:
				continue
			var listed := d.get_files()
			listed.sort()
			var n := 0
			for f in listed:
				if f.get_extension().to_lower() != "json":
					continue
				var full := path.path_join(f)
				if not seen.has(full):
					seen[full] = true
					out.append(full)
				n += 1
				if n >= MAX_FILES_PER_DIR:
					break
		else:
			if not seen.has(path):
				seen[path] = true
				out.append(path)
	return out


## 导入一批具体文件路径，做校验 + 去重 + 合并
static func import_files(files: Array) -> Dictionary:
	var st := _empty_stats()
	st["file_count"] = files.size()

	# voter_id -> { record, order }
	var by_voter := {}

	for path in files:
		var r := load_vote_file(String(path))
		if not r["ok"]:
			(st["errors"] as Array).append({"file": String(path), "reason": String(r["error"])})
			continue

		var vid := String(r["voter_id"])
		if by_voter.has(vid):
			# 同一个 voter_id 又来一份 → 比谁更新
			var old: Dictionary = by_voter[vid]
			var old_key := _freshness_key(old)
			var new_key := _freshness_key(r)
			var keep_new := new_key > old_key
			var loser: Dictionary = old if keep_new else r
			var winner: Dictionary = r if keep_new else old
			(st["duplicates"] as Array).append({
				"voter_id": vid,
				"voter_name": String(winner["voter_name"]),
				"kept_file": String(winner["path"]),
				"dropped_file": String(loser["path"]),
				"kept_timestamp": String(winner["timestamp_effective"]),
				"dropped_timestamp": String(loser["timestamp_effective"]),
			})
			if keep_new:
				by_voter[vid] = r
		else:
			by_voter[vid] = r

	# ---- 汇总 ----
	var counts := {}                 # photo -> 票数
	var voters_of := {}              # photo -> Array[投票人名]
	var per_voter := []              # [{voter_id, voter_name, count, bans}]
	var banned_any := {}             # photo -> true
	var all_voter_names: Array = []

	# 按名字稳定排序，保证多次运行输出一致
	var vids := by_voter.keys()
	vids.sort_custom(func(a, b) -> bool:
		var na := String((by_voter[a] as Dictionary)["voter_name"])
		var nb := String((by_voter[b] as Dictionary)["voter_name"])
		if na != nb:
			return na < nb
		return String(a) < String(b))

	for vid in vids:
		var rec: Dictionary = by_voter[vid]
		var uniq: Array = rec["bans"]
		per_voter.append({
			"voter_id": vid,
			"voter_name": String(rec["voter_name"]),
			"count": uniq.size(),
			"bans": uniq.duplicate(),
			"file": String(rec["path"]),
			"timestamp": String(rec["timestamp_effective"]),
		})
		all_voter_names.append(String(rec["voter_name"]))
		for p in uniq:
			var s := String(p)
			counts[s] = int(counts.get(s, 0)) + 1
			banned_any[s] = true
			if not voters_of.has(s):
				voters_of[s] = []
			(voters_of[s] as Array).append(String(rec["voter_name"]))

	# ---- 排名 ----
	var ranking: Array = []
	for photo in counts.keys():
		ranking.append({
			"file": String(photo),
			"count": int(counts[photo]),
			"voters": voters_of.get(photo, []),
		})
	_sort_ranking(ranking)

	st["voters"] = per_voter
	st["voter_names"] = all_voter_names
	st["voter_count"] = per_voter.size()
	st["total_bans"] = ranking.size()
	st["ranking"] = ranking
	st["banned_set"] = banned_any
	st["voter_names_of"] = voters_of
	return st


# ============================================================
#  读单个文件 + 校验
# ============================================================

## 读取并校验一个投票 json。
## 返回 { ok, error, path, voter_id, voter_name, timestamp, timestamp_effective, bans }
static func load_vote_file(path: String) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "error": msg, "path": path, "voter_id": "",
			"voter_name": "", "timestamp": "", "timestamp_effective": "", "bans": []}

	if not FileAccess.file_exists(path):
		return fail.call("文件不存在")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return fail.call("打不开（err=%d）" % FileAccess.get_open_error())
	var size := f.get_length()
	f.close()
	if size <= 0:
		return fail.call("空文件")
	if size > 8 * 1024 * 1024:
		return fail.call("文件过大（%d 字节），不像是投票文件" % size)

	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges() == "":
		return fail.call("内容为空")
	var parsed = JSON.parse_string(txt)
	if parsed == null:
		return fail.call("不是合法 JSON（解析失败）")
	if typeof(parsed) != TYPE_DICTIONARY:
		return fail.call("JSON 顶层不是对象")
	var d: Dictionary = parsed

	var fmt := String(d.get("format", ""))
	if fmt != EXPECT_FORMAT:
		if fmt == "":
			return fail.call("缺少 format 字段（不是本程序导出的投票文件）")
		return fail.call("format 不匹配：期望 %s，实际 %s" % [EXPECT_FORMAT, fmt])

	if typeof(d.get("bans", null)) != TYPE_ARRAY:
		return fail.call("缺少 bans 数组或类型不对")

	var vid := String(d.get("voter_id", "")).strip_edges()
	var vname := String(d.get("voter_name", "")).strip_edges()
	if vid == "" and vname == "":
		return fail.call("voter_id 和 voter_name 都为空，无法识别是谁投的")

	var ts := String(d.get("timestamp", ""))
	# 归一化 bans：去重、去空、转字符串
	var seen := {}
	var bans: Array = []
	for p in (d["bans"] as Array):
		var s := String(p).strip_edges()
		if s == "" or seen.has(s):
			continue
		seen[s] = true
		bans.append(s)

	return {
		"ok": true,
		"error": "",
		"path": path,
		"voter_id": vid,
		"voter_name": vname if vname != "" else vid,
		"timestamp": ts,
		"timestamp_effective": _effective_timestamp(ts, path),
		"bans": bans,
	}


## 用于「谁更新」的排序键：优先用 json 里的 timestamp，缺失就用文件修改时间。
static func _freshness_key(rec: Dictionary) -> String:
	return String(rec.get("timestamp_effective", ""))


## 归一化成可比较的 "YYYY-MM-DDTHH:MM:SS"；
## timestamp 字段缺失/格式不对时退回文件的修改时间。
static func _effective_timestamp(ts: String, path: String) -> String:
	var norm := _normalize_ts(ts)
	if norm != "":
		return norm
	var mtime := int(FileAccess.get_modified_time(path))
	if mtime <= 0:
		return "0000-00-00T00:00:00"
	return Time.get_datetime_string_from_unix_time(mtime)


## 尽量把各种写法归一化成 "YYYY-MM-DDTHH:MM:SS"，认不出来返回 ""
static func _normalize_ts(raw: String) -> String:
	var s := raw.strip_edges()
	if s == "":
		return ""
	# 去掉毫秒/时区尾巴
	s = s.replace("Z", "")
	if s.contains("."):
		s = s.split(".")[0]
	if s.contains("+"):
		s = s.split("+")[0]
	# 支持 "2026-10-07 15:30:00" 和 "2026-10-07T15:30:00"
	s = s.replace(" ", "T")
	var parts := s.split("T")
	if parts.size() != 2:
		return ""
	var date_parts := parts[0].split("-")
	var time_parts := parts[1].split(":")
	if date_parts.size() != 3 or time_parts.size() < 2:
		return ""
	for v in date_parts:
		if not v.is_valid_int():
			return ""
	for v in time_parts:
		if not v.is_valid_int():
			return ""
	var sec := int(time_parts[2]) if time_parts.size() >= 3 else 0
	return "%04d-%02d-%02dT%02d:%02d:%02d" % [
		int(date_parts[0]), int(date_parts[1]), int(date_parts[2]),
		int(time_parts[0]), int(time_parts[1]), sec]


# ============================================================
#  结果整理
# ============================================================

## 票数降序；同票按文件名升序，保证结果稳定可复现
static func _sort_ranking(ranking: Array) -> void:
	ranking.sort_custom(func(a, b) -> bool:
		if int(a["count"]) != int(b["count"]):
			return int(a["count"]) > int(b["count"])
		return String(a["file"]) < String(b["file"]))


## 取 Top N（N <= 0 表示全部）
static func top_n(ranking: Array, n: int) -> Array:
	if n <= 0 or n >= ranking.size():
		return ranking.duplicate()
	return ranking.slice(0, n)


## 组装最终汇总结果（导出 final_result.json 用）。
## name_resolver: Callable(photo) -> 显示名；不传就原样用文件名。
static func build_final_result(stats: Dictionary, name_resolver: Variant = null) -> Dictionary:
	var ranking: Array = stats.get("ranking", [])
	var picks: Array = []
	for i in range(ranking.size()):
		var r: Dictionary = ranking[i]
		var photo := String(r["file"])
		var disp := photo
		if name_resolver is Callable and (name_resolver as Callable).is_valid():
			var got = (name_resolver as Callable).call(photo)
			if got != null and String(got) != "":
				disp = String(got)
		picks.append({
			"rank": i + 1,
			"file": photo,
			"name": disp,
			"count": int(r["count"]),
			"voters": r["voters"],
		})
	return {
		"format": "naruto_ban_result",
		"version": 1,
		"generated_at": Time.get_datetime_string_from_system(),
		"total_voters": int(stats.get("voter_count", 0)),
		"voters": stats.get("voter_names", []),
		"total_ban_marks": int(stats.get("total_bans", 0)),
		"file_count": int(stats.get("file_count", 0)),
		"duplicate_count": (stats.get("duplicates", []) as Array).size(),
		"error_count": (stats.get("errors", []) as Array).size(),
		"ranking": picks,
	}


## 纯文本汇总（发群用）
static func build_text_result(stats: Dictionary, top: int,
		name_resolver: Variant = null) -> String:
	var picks := top_n(stats.get("ranking", []), top)
	var lines: Array[String] = []
	lines.append("火影忍者 公共 Ban 选结果（Top %d）" % picks.size())
	lines.append("参与人数：%d 人" % int(stats.get("voter_count", 0)))
	lines.append("")
	if picks.is_empty():
		lines.append("（没有任何有效投票）")
	else:
		for i in range(picks.size()):
			var r: Dictionary = picks[i]
			var photo := String(r["file"])
			var disp := photo
			if name_resolver is Callable and (name_resolver as Callable).is_valid():
				var got = (name_resolver as Callable).call(photo)
				if got != null and String(got) != "":
					disp = String(got)
			lines.append("%d. %s - %d票" % [i + 1, disp, int(r["count"])])
	var dup: Array = stats.get("duplicates", [])
	var errs: Array = stats.get("errors", [])
	if not dup.is_empty() or not errs.is_empty():
		lines.append("")
		if not dup.is_empty():
			lines.append("（有 %d 位玩家交了多份，已按最新一份计）" % dup.size())
		if not errs.is_empty():
			lines.append("（有 %d 个文件格式不对，已跳过）" % errs.size())
	lines.append("")
	lines.append("生成时间：%s" % Time.get_datetime_string_from_system())
	return "\n".join(lines)


static func _empty_stats() -> Dictionary:
	return {
		"file_count": 0,
		"voter_count": 0,
		"voters": [],          # [{voter_id, voter_name, count, bans, file, timestamp}]
		"voter_names": [],
		"total_bans": 0,       # 被 Ban 过的不同忍者数
		"ranking": [],         # [{file, count, voters}]
		"banned_set": {},
		"voter_names_of": {},
		"errors": [],          # [{file, reason}]
		"duplicates": [],      # [{voter_id, voter_name, kept_file, dropped_file, ...}]
	}
