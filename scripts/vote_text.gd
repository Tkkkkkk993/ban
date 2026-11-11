# ============================================================
#  vote_text.gd —— 「一段文字」形式的投票：生成 + 批量解析
# ------------------------------------------------------------
#  目的：除了传 json，还能让玩家复制一段**人能看懂的文字**发到群里，
#        组织者把这些文字攒进一个 txt，用本程序一次性批量识别统计。
#
#  一段投票文字长这样：
#
#      =====BAN投票开始=====
#      玩家：张三
#      数量：5
#      名单：
#      1. 漩涡鸣人[六道仙人] <90001_Portrait>
#      2. 宇智波佐助 <90002_Portrait>
#      3. 春野樱 <90003_Portrait>
#      =====BAN投票结束=====
#
#  为什么每行要带 <照片ID>：
#    显示名有重名（同一个名字对应多张不同的图），只有照片ID能唯一确定是哪张。
#    显示名放在前面给人看，ID 放在尖括号里给程序读。
#
#  解析是「宽容」的，专门为微信粘贴优化：
#    · ===== 多几个少几个都能认
#    · 冒号用全角「：」或半角「:」都行
#    · 序号 1. / 1、 / 1) 都认
#    · 中间多余的空行忽略
#    · 没有开始/结束标记时，退化成「找『玩家：』然后往下读名单」
# ============================================================
class_name VoteTextNS
extends RefCounted

const BLOCK_START := "=====BAN投票开始====="
const BLOCK_END := "=====BAN投票结束====="

## 照片 ID 用尖括号包起来，避免和显示名里的括号混淆
const ID_OPEN := "<"
const ID_CLOSE := ">"


# ============================================================
#  生成
# ============================================================

## 生成一段投票文字。
## voter_name : 玩家名（程序里「改名」设置的那个）
## entries    : [[照片ID, 显示名], ...]  顺序就是玩家 Ban 的顺序
## timestamp  : 可选，留空则用当前时间
static func build_block(voter_name: String, entries: Array,
		timestamp: String = "") -> String:
	var ts := timestamp
	if ts == "":
		ts = Time.get_datetime_string_from_system().replace("T", " ")

	var lines: Array[String] = []
	lines.append(BLOCK_START)
	lines.append("玩家：%s" % voter_name)
	lines.append("数量：%d" % entries.size())
	lines.append("名单：")
	if entries.is_empty():
		lines.append("（未选择任何忍者）")
	else:
		for i in range(entries.size()):
			var e: Array = entries[i]
			var photo := String(e[0]) if e.size() > 0 else ""
			var disp := String(e[1]) if e.size() > 1 else photo
			# 显示名里万一有尖括号，替换掉免得把解析搞乱
			disp = disp.replace("<", "＜").replace(">", "＞")
			lines.append("%d. %s %s%s%s" % [i + 1, disp, ID_OPEN, photo, ID_CLOSE])
	lines.append("时间：%s" % ts)
	lines.append(BLOCK_END)
	return "\n".join(lines)


## 便捷版：只给照片 ID 列表时，显示名就用 ID 本身
static func build_block_from_ids(voter_name: String, bans: Array,
		timestamp: String = "") -> String:
	var entries: Array = []
	for p in bans:
		entries.append([String(p), String(p)])
	return build_block(voter_name, entries, timestamp)


# ============================================================
#  解析（一份 txt 里可以有多段）
# ============================================================

## 解析一整段文本（可能包含多段投票）。
## 返回统计字典：
##   {
##     records: Array[Dictionary]   每条一段投票
##     errors:  Array[Dictionary]   [{reason, snippet}]
##     warnings:Array[Dictionary]   [{reason, snippet}]
##   }
## records 里每条：
##   {
##     voter_name, bans(Array[String] 全是照片ID), declared_count(int),
##     item_count(int), timestamp(String), snippet(String)
##   }
static func parse_blocks(text: String, source: String = "") -> Dictionary:
	var st := {"records": [], "errors": [], "warnings": []}
	var clean := _normalize(text)
	if clean.strip_edges() == "":
		st["errors"].append({"reason": "内容为空", "snippet": source})
		return st

	var lines := clean.split("\n")
	# 去掉每行尾部空白，保留行结构
	var stripped: Array[String] = []
	for ln in lines:
		stripped.append(String(ln).strip_edges(true, false))

	var has_markers := false
	for ln in stripped:
		if _is_start(ln):
			has_markers = true
			break

	if has_markers:
		_parse_with_markers(stripped, source, st)
	else:
		_parse_without_markers(stripped, source, st)

	if (st["records"] as Array).is_empty() and (st["errors"] as Array).is_empty():
		(st["errors"] as Array).append({
			"reason": "没找到可识别的投票内容（缺少「玩家：」或名单）",
			"snippet": source,
		})
	return st


# ---------------- 有标记时的解析 ----------------
static func _parse_with_markers(lines: Array[String], source: String, st: Dictionary) -> void:
	var i := 0
	while i < lines.size():
		if not _is_start(lines[i]):
			i += 1
			continue
		# 收集到结束标记
		var body: Array[String] = []
		var j := i + 1
		var closed := false
		while j < lines.size():
			if _is_end(lines[j]):
				closed = true
				break
			if _is_start(lines[j]):
				break        # 没写结束标记就又开始了一段
			body.append(lines[j])
			j += 1
		_collect_block(body, source, st, closed)
		i = j + 1 if closed else j


# ---------------- 没有标记时退化解析 ----------------
## 专门应对「玩家只复制了中间那段、或者 ===== 被微信吃了」的情况
static func _parse_without_markers(lines: Array[String], source: String, st: Dictionary) -> void:
	var i := 0
	while i < lines.size():
		if _is_player_line(lines[i]):
			# 从这里开始，往下收集到下一个「玩家：」或结尾
			var body: Array[String] = []
			var j := i
			while j < lines.size():
				if j > i and _is_player_line(lines[j]):
					break
				body.append(lines[j])
				j += 1
			_collect_block(body, source, st, false)
			i = j
		else:
			i += 1


# ---------------- 解析一段块的正文 ----------------
static func _collect_block(body: Array[String], source: String, st: Dictionary, closed: bool) -> void:
	var voter_name := ""
	var declared := -1
	var ts := ""
	var bans: Array[String] = []
	var unresolved: Array[String] = []
	var in_list := false

	for ln in body:
		if ln.strip_edges() == "":
			continue
		# 玩家名
		var pn := _find_player_line(ln)
		if pn != "":
			voter_name = pn
			continue
		# 数量（返回 int 或 null，所以必须显式标 Variant）
		var cnt: Variant = _find_count_line(ln)
		if cnt != null:
			declared = int(cnt)
			continue
		# 时间
		if _is_field_line(ln, ["时间", "导出时间", "生成时间"]):
			ts = _value_after_colon(ln)
			continue
		# 名单表头
		if _is_field_line(ln, ["名单", "Ban名单", "BAN名单", "列表"]):
			in_list = true
			continue
		if ln.contains("未选择任何忍者") or ln.contains("（空）"):
			in_list = true
			continue
		# 条目行
		var item: Variant = _parse_item(ln)
		if item != null:
			in_list = true
			var it: Dictionary = item
			var photo := String(it["photo"])
			var name := String(it["name"])
			if photo == "":
				# 没有 ID：尝试用显示名反查唯一照片
				var resolved := resolve_photo_by_name(name)
				if resolved != "":
					photo = resolved
					(st["warnings"] as Array).append({
						"reason": "条目「%s」没有照片ID，已按显示名唯一匹配" % name,
						"snippet": source,
					})
				else:
					unresolved.append(name)
					photo = name        # 先按名字当 ID，后面统计会显示名字
					(st["warnings"] as Array).append({
						"reason": "条目「%s」没有照片ID，且无法唯一匹配，按名字统计" % name,
						"snippet": source,
					})
			if not bans.has(photo):
				bans.append(photo)
			continue
		# 其它行：如果在名单区里，当作警告
		if in_list:
			(st["warnings"] as Array).append({
				"reason": "名单里有一行认不出来，已忽略：%s" % ln,
				"snippet": source,
			})

	if voter_name == "":
		(st["errors"] as Array).append({
			"reason": "这一段里没找到「玩家：」行，不知道是谁投的",
			"snippet": source,
		})
		return

	if not closed:
		(st["warnings"] as Array).append({
			"reason": "「%s」这段缺少结束标记（可能复制不全），已按实际内容解析" % voter_name,
			"snippet": source,
		})

	# 数量自检：声明的数量 vs 实际解析出的数量
	if declared >= 0 and declared != bans.size():
		(st["warnings"] as Array).append({
			"reason": "「%s」声明 %d 个，实际解析出 %d 个" % [voter_name, declared, bans.size()],
			"snippet": source,
		})

	(st["records"] as Array).append({
		"voter_name": voter_name,
		"bans": bans,
		"declared_count": declared if declared >= 0 else bans.size(),
		"item_count": bans.size(),
		"unresolved": unresolved,
		"timestamp": ts,
		"snippet": source,
	})


# ============================================================
#  行级识别
# ============================================================

static func _normalize(text: String) -> String:
	var t := text
	# 去 BOM
	if t.begins_with("\ufeff"):
		t = t.substr(1)
	t = t.replace("\r\n", "\n").replace("\r", "\n")
	# 全角空格 → 半角
	t = t.replace("\u3000", " ")
	return t


static func _is_start(ln: String) -> bool:
	var s := ln.replace(" ", "").replace("\u3000", "")
	return s.contains("BAN投票开始")


static func _is_end(ln: String) -> bool:
	var s := ln.replace(" ", "").replace("\u3000", "")
	return s.contains("BAN投票结束")


## 判断这一行像不像「玩家：xxx」
static func _is_player_line(ln: String) -> bool:
	return _find_player_line(ln) != ""


static func _find_player_line(ln: String) -> String:
	var s := ln.strip_edges()
	for label in ["玩家名", "玩家名字", "玩家", "投票人", "昵称"]:
		for sep in ["：", ":"]:
			var pre: String = String(label) + String(sep)
			if s.begins_with(pre):
				var v := s.substr(pre.length()).strip_edges()
				# 去掉可能的装饰
				v = v.replace("=", "").replace("【", "").replace("】", "").strip_edges()
				if v != "":
					return v
	return ""


## 判断是不是某个「字段名：值」的行
static func _is_field_line(ln: String, labels: Array) -> bool:
	var s := ln.strip_edges()
	for label in labels:
		for sep in ["：", ":"]:
			if s.begins_with(String(label) + String(sep)):
				return true
	return false


static func _value_after_colon(ln: String) -> String:
	var s := ln.strip_edges()
	var idx := s.find("：")
	if idx < 0:
		idx = s.find(":")
	if idx < 0:
		return ""
	return s.substr(idx + 1).strip_edges()


## 解析「数量：5」→ 5；不是这种行返回 null
static func _find_count_line(ln: String):
	var s := ln.strip_edges()
	for label in ["数量", "投票数", "票数", "个数", "总数"]:
		for sep in ["：", ":"]:
			var pre: String = String(label) + String(sep)
			if s.begins_with(pre):
				var v := s.substr(pre.length()).strip_edges()
				var num := _first_int(v)
				if num >= 0:
					return num
	return null


## 从字符串里取第一个整数，没有返回 -1
static func _first_int(s: String) -> int:
	var digits := ""
	for i in range(s.length()):
		var c := s[i]
		if c >= "0" and c <= "9":
			digits += c
		elif digits != "":
			break
	if digits == "":
		return -1
	return digits.to_int()


## 解析一条名单：返回 {name, photo} 或 null
## 支持：  1. 名字 <ID>    /    1、名字<ID>    /    1) 名字
static func _parse_item(ln: String) -> Variant:
	var s := ln.strip_edges()
	if s == "":
		return null
	# 必须有开头序号，避免把正文误当条目
	var i := 0
	while i < s.length() and s[i] >= "0" and s[i] <= "9":
		i += 1
	if i == 0:
		return null
	var rest := s.substr(i).strip_edges()
	if rest == "":
		return null
	# 序号后的分隔符
	var first := rest[0]
	if not (first == "." or first == "．" or first == "、" or first == ")" or first == "）" or first == ":" or first == "："):
		return null
	rest = rest.substr(1).strip_edges()
	if rest == "":
		return null

	# 抽尖括号里的照片 ID（可能用全角括号）
	var photo := ""
	var name := rest
	var o := rest.find(ID_OPEN)
	var oc := rest.find("＜")
	if o < 0 and oc >= 0:
		o = oc
	if o >= 0:
		var c := rest.find(ID_CLOSE, o)
		var cc := rest.find("＞", o)
		if c < 0 or (cc >= 0 and cc < c):
			c = cc
		if c > o:
			var gap: int = (c - o) - 1
			if gap > 0:
				photo = rest.substr(o + 1, gap).strip_edges()
			name = rest.substr(0, o).strip_edges()
	if name == "" and photo != "":
		name = photo
	return {"name": name, "photo": photo}


# ============================================================
#  显示名 → 照片ID 的反查（用于没带 ID 的手改文本）
# ============================================================

## 按显示名找唯一照片；找不到或有重名都返回 ""
static func resolve_photo_by_name(disp_name: String) -> String:
	var il := _image_loader()
	if il == null:
		return ""
	var hit := ""
	var n := 0
	for p in il.photos:
		var rec: Dictionary = p
		var nm := String(rec.get("name", ""))
		if nm == disp_name:
			n += 1
			hit = String(rec.get("photo", ""))
			if n > 1:
				return ""
	return hit


static func _image_loader() -> Node:
	var t := Engine.get_main_loop()
	if t is SceneTree:
		return (t as SceneTree).root.get_node_or_null("ImageLoader")
	return null
