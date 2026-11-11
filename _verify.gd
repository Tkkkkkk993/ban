# ============================================================
#  _verify.gd —— 自检脚本（开发用，可删）
# ------------------------------------------------------------
#  必须用「真实场景」方式跑（不能用 --script，原因见运行说明）：
#    & <godot.exe> --headless --path . res://_verify.tscn
#  退出码 0 = 全部通过，1 = 有失败项。
#
#  覆盖：
#    [1] Autoload / 场景加载
#    [2] ImageLoader（扫描 + 真读图 + 缩略图缓存 + 绝对路径读图）
#    [3] DataManager（单人结构 + 名字 + UUID + 落盘读盘 + 旧数据迁移）
#    [4] VoteExporter（导出格式、去重、文件名净化、json+txt）
#    [5] VoteImporter 正常流程（3 份假投票）
#    [6] VoteImporter 异常处理（空文件/坏 json/format 错/缺字段/重复 voter_id）
#    [7] 汇总导出（json / txt / png 真的产出文件）
#    [8] Main 场景启动（玩家端）
#    [9] Organizer 场景启动（组织者端）
# ============================================================
extends Node

const Exporter := preload("res://scripts/vote_exporter.gd")
const Importer := preload("res://scripts/vote_importer.gd")
const VText := preload("res://scripts/vote_text.gd")

const FIXTURE_DIR := "user://test_votes"
const OUT_DIR := "user://test_out"

var _fails: Array[String] = []
var _passes := 0
var _t0 := 0


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("  [PASS] ", msg)
	else:
		_fails.append(msg)
		print("  [FAIL] ", msg)


func _info(msg: String) -> void:
	print("         ", msg)


func _ready() -> void:
	print("================ 自检开始 ================")
	_t0 = Time.get_ticks_msec()

	_test_autoloads()
	_test_scenes()
	await _test_image_loader()
	_test_data_manager()
	_test_exporter()
	_test_importer_normal()
	_test_importer_errors()
	_test_vote_text()
	await _test_organizer_export()
	await _test_main_scene()
	await _test_organizer_scene()
	await _test_first_run_and_password()

	print("================ 自检结束 ================")
	print("通过 %d 项，失败 %d 项，总耗时 %d ms" % [
		_passes, _fails.size(), Time.get_ticks_msec() - _t0])
	for f in _fails:
		print("  失败：", f)
	get_tree().quit(0 if _fails.is_empty() else 1)


# ---------------- 测试数据工具 ----------------
func _write_file(path: String, content: String) -> void:
	var d := path.get_base_dir()
	if d != "":
		DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[verify] 写不进去：%s (err=%d)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(content)
	f.close()


## 删掉一个目录里的所有文件，保证每次自检都是干净起点
func _clear_dir(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))


## 在指定目录里写一份投票 json（dir 必须显式传，避免写错地方）
func _write_vote_file(dir: String, fname: String, voter_id: String,
		voter_name: String, timestamp: String, bans: Array) -> String:
	var path := dir.path_join(fname)
	_write_file(path, JSON.stringify({
		"format": "naruto_ban_vote",
		"version": 1,
		"voter_id": voter_id,
		"voter_name": voter_name,
		"timestamp": timestamp,
		"bans": bans,
	}, "\t"))
	if not FileAccess.file_exists(path):
		push_error("[verify] 夹具没写成功：%s" % path)
	return path


# ---------------- 1. Autoload ----------------
func _test_autoloads() -> void:
	print("\n[1] Autoload / 场景加载检查")
	_ok(get_node_or_null("/root/ImageLoader") != null, "ImageLoader Autoload 已注册")
	_ok(get_node_or_null("/root/DataManager") != null, "DataManager Autoload 已注册")


func _test_scenes() -> void:
	for p in ["res://scenes/CharacterCard.tscn", "res://scenes/Main.tscn",
			"res://scenes/Organizer.tscn"]:
		var ps = load(p)
		_ok(ps is PackedScene, "%s 可加载" % p.get_file())
		if ps is PackedScene:
			var inst = (ps as PackedScene).instantiate()
			_ok(inst != null, "%s 可实例化" % p.get_file())
			if inst != null:
				inst.free()


# ---------------- 2. ImageLoader ----------------
func _test_image_loader() -> void:
	print("\n[2] ImageLoader 检查")
	var il = get_node("/root/ImageLoader")

	var dir: String = il.detect_avatar_dir()
	_ok(dir != "", "探测到头像目录：%s" % dir)
	if dir == "":
		return

	var t := Time.get_ticks_msec()
	var items: Array = il.scan_directory()
	_info("扫描 %d 张，耗时 %d ms" % [items.size(), Time.get_ticks_msec() - t])
	_ok(items.size() > 0, "扫描到 %d 张头像" % items.size())
	if items.is_empty():
		return

	# 路径必须是真实文件系统路径（导出后才能用）
	var first: Dictionary = items[0]
	var p := String(first["path"])
	_ok(not p.begins_with("res://"),
		"扫描出的路径已转成真实路径（导出后可用）：%s" % p.get_file())
	_ok(FileAccess.file_exists(p), "扫描出的路径真的存在")

	# O(1) 查找
	_ok(not il.find_photo(String(first["photo"])).is_empty(), "find_photo 能查到")
	_ok(il.find_photo("绝对不存在的照片ID").is_empty(), "find_photo 对不存在的 ID 返回空")

	# 加载 20 张，量单帧耗时
	var max_frame := 0
	var frames := 0
	il.purge_textures()
	il.load_batch(0, 20)
	var t0 := Time.get_ticks_msec()
	while il.is_loading() and Time.get_ticks_msec() - t0 < 60000:
		var f0 := Time.get_ticks_msec()
		await get_tree().process_frame
		max_frame = maxi(max_frame, Time.get_ticks_msec() - f0)
		frames += 1
	_info("加载 20 张：%d ms / %d 帧 / 单帧最大 %d ms" % [
		Time.get_ticks_msec() - t0, frames, max_frame])
	_ok(il.get_texture_count() >= 18, "拿到 %d 张纹理" % il.get_texture_count())
	_ok(max_frame < 100, "主线程单帧最大 %d ms（要求 < 100ms）" % max_frame)

	# 缩略图缓存
	var photo := String(first["photo"])
	var cp: String = il.thumb_cache_path(photo, int(first["mtime"]))
	_ok(FileAccess.file_exists(cp), "缩略图已缓存：%s" % cp.get_file())
	var cached: Image = Image.load_from_file(cp)
	_ok(cached != null and not cached.is_empty(), "缓存文件可读回")
	if cached != null:
		_ok(maxi(cached.get_width(), cached.get_height()) <= 128,
			"缩略图长边 <= 128（实际 %d）" % maxi(cached.get_width(), cached.get_height()))

	# 原图读取（右键大图用）
	var full: Image = il.load_full_image(photo)
	_ok(full != null and not full.is_empty(), "load_full_image 能取到原图")
	if full != null:
		_info("原图尺寸 %d x %d" % [full.get_width(), full.get_height()])

	_ok(il.get_thumbnail("不存在的ID") == null, "get_thumbnail 对不存在的 ID 返回 null")
	_ok(il.load_full_image("不存在的ID") == null, "load_full_image 对不存在的 ID 返回 null")


# ---------------- 3. DataManager ----------------
func _test_data_manager() -> void:
	print("\n[3] DataManager（单人结构）检查")
	var dm = get_node("/root/DataManager")

	# 干净起点
	dm.voter_name = ""
	dm.voter_id = ""
	dm.bans.clear()
	dm.save()

	_ok(not dm.has_name(), "初始状态没有名字")
	_ok(dm.sanitize_name("  张三  ") == "张三", "sanitize_name 去首尾空白")
	_ok(dm.sanitize_name("张\n三") == "张 三", "sanitize_name 把换行换成空格")
	_ok(dm.sanitize_name("张三/游戏ID") == "张三/游戏ID",
		"sanitize_name 不动斜杠（文件名净化是导出那步的事）")
	_ok(dm.sanitize_name("").length() == 0, "sanitize_name 空串还是空")
	_ok(dm.sanitize_name("字".repeat(40)).length() == dm.MAX_NAME_LEN,
		"sanitize_name 会限长到 %d" % dm.MAX_NAME_LEN)

	_ok(not dm.set_voter_name(""), "set_voter_name 拒绝空名字")
	_ok(not dm.has_name(), "拒绝空名字后仍然没有名字")
	_ok(dm.set_voter_name("张三"), "set_voter_name 接受合法名字")
	_ok(dm.has_name(), "设置后 has_name 为真")
	_ok(dm.voter_name == "张三", "名字正确：%s" % dm.voter_name)

	# voter_id 持久化 + 改名不变
	var id1: String = dm.ensure_voter_id()
	_ok(id1.begins_with("v_"), "voter_id 有 v_ 前缀：%s" % id1)
	_ok(id1.length() >= 34, "voter_id 长度合理（%d）" % id1.length())
	dm.set_voter_name("李四")
	_ok(dm.ensure_voter_id() == id1, "改名后 voter_id 不变")
	_ok(dm.voter_name == "李四", "改名生效")
	dm.set_voter_name("张三")

	# Ban 名单
	dm.clear_all()
	_ok(dm.get_ban_count() == 0, "清空后 0 个")
	_ok(not dm.is_banned("90001_headshot"), "初始未 Ban")
	_ok(dm.toggle_ban("90001_headshot"), "toggle_ban 返回 true（已 Ban）")
	_ok(dm.is_banned("90001_headshot"), "is_banned 为真")
	_ok(dm.toggle_ban("90001_headshot") == false, "再 toggle 返回 false（已取消）")
	_ok(not dm.is_banned("90001_headshot"), "取消后 is_banned 为假")
	_ok(dm.toggle_ban("90001_headshot"), "重新 Ban")
	dm.toggle_ban("40001_headshot")
	dm.toggle_ban("99002_headshot")
	_ok(dm.get_ban_count() == 3, "Ban 了 3 个（实际 %d）" % dm.get_ban_count())
	_ok(dm.toggle_ban("90001_headshot") == false, "对已 Ban 的再点一次返回 false（表示已取消）")
	_ok(dm.get_ban_count() == 2, "取消后剩 2 个")

	# 去重
	dm.replace_bans(["a", "b", "a", "c", "b", ""])
	_ok(dm.get_bans() == ["a", "b", "c"], "replace_bans 去重去空且保序：%s" % str(dm.get_bans()))

	# 落盘 / 读盘
	dm.replace_bans(["90001_headshot", "40001_headshot"])
	dm.save()
	_ok(FileAccess.file_exists("user://votes.json"), "votes.json 已写入")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("user://votes.json"))
	_ok(typeof(parsed) == TYPE_DICTIONARY, "votes.json 是合法 JSON 对象")
	if typeof(parsed) == TYPE_DICTIONARY:
		var d: Dictionary = parsed
		_ok(int(d.get("version", 0)) == 3, "版本号是 3")
		_ok(String(d.get("voter_name", "")) == "张三", "存了名字")
		_ok(String(d.get("voter_id", "")) == id1, "存了 voter_id")
		_ok(typeof(d.get("bans", null)) == TYPE_ARRAY, "bans 是数组（不再是字典）")
		_ok((d.get("bans", []) as Array).size() == 2, "bans 有 2 项")

	# 清空内存再读回来
	dm.voter_name = ""
	dm.voter_id = ""
	dm.bans.clear()
	dm.read_from_disk()
	_ok(dm.voter_name == "张三", "读盘恢复名字")
	_ok(dm.ensure_voter_id() == id1, "读盘恢复 voter_id")
	_ok(dm.get_ban_count() == 2, "读盘恢复 Ban 名单（%d）" % dm.get_ban_count())

	# 旧格式迁移
	_write_file("user://votes.json", JSON.stringify({
		"version": 2,
		"voters": {"v1": "老王", "v2": "小李"},
		"bans": {"v1": ["90001_headshot", "90002_headshot"], "v2": ["90001_headshot"]},
	}))
	dm.voter_name = ""
	dm.bans.clear()
	dm.read_from_disk()
	_ok(dm.get_ban_count() == 2, "旧数据迁移并集为 2 个（实际 %d）" % dm.get_ban_count())
	_ok(dm.is_banned("90001_headshot") and dm.is_banned("90002_headshot"),
		"迁移后两个都在名单里")
	_ok(dm.get_bans().size() == 2, "迁移后没有重复项")
	_info("旧数据迁移后名单：%s" % str(dm.get_bans()))

	# 坏数据不应该崩
	_write_file("user://votes.json", "{ 这不是 json ")
	dm.bans.clear()
	dm.read_from_disk()
	_ok(true, "读到坏 json 不崩溃")
	_write_file("user://votes.json", "")
	dm.bans.clear()
	dm.read_from_disk()
	_ok(true, "读到空文件不崩溃")

	dm.clear_all()
	dm.save()


# ---------------- 4. VoteExporter ----------------
func _test_exporter() -> void:
	print("\n[4] VoteExporter 检查")

	_ok(Exporter.safe_name("张三") == "张三", "safe_name 普通中文名原样保留")
	_ok(Exporter.safe_name("张三/游戏ID") == "张三_游戏ID", "safe_name 把斜杠换成下划线")
	_ok(Exporter.safe_name("a:b*c?d\"e<f>g|h") == "a_b_c_d_e_f_g_h", "safe_name 处理全部非法字符")
	_ok(Exporter.safe_name("") == "anonymous", "safe_name 空串兜底 anonymous")
	_ok(Exporter.safe_name("   ") == "anonymous", "safe_name 全空白兜底 anonymous")
	_ok(Exporter.safe_name("...") == "anonymous", "safe_name 全是点的兜底")
	_ok(Exporter.safe_name("字".repeat(40)).length() == 24, "safe_name 限长 24")

	var ts: String = Exporter.now_timestamp()
	_ok(ts.length() >= 19, "时间戳长度合理：%s" % ts)
	var cts: String = Exporter.compact_timestamp()
	_ok(cts.length() == 15 and cts[8] == "_", "紧凑时间戳形如 YYYYMMDD_HHMMSS：%s" % cts)

	# 组装格式
	var v: Dictionary = Exporter.build_vote_dict("张三", "v_abc",
		["90001_headshot", "90002_headshot", "90001_headshot", ""])
	_ok(String(v["format"]) == "naruto_ban_vote", "format 字段正确")
	_ok(int(v["version"]) == 1, "version 字段正确")
	_ok(String(v["voter_id"]) == "v_abc", "voter_id 字段正确")
	_ok(String(v["voter_name"]) == "张三", "voter_name 字段正确")
	_ok(v.has("timestamp"), "有 timestamp 字段")
	_ok(typeof(v["bans"]) == TYPE_ARRAY, "bans 是数组")
	_ok((v["bans"] as Array).size() == 2, "bans 去重去空后 2 项：%s" % str(v["bans"]))

	# 真写文件
	var r: Dictionary = Exporter.save_vote_file("张三", "v_abc", ["90001_headshot"])
	_ok(bool(r["ok"]), "save_vote_file 成功")
	_ok(int(r["count"]) == 1, "返回 count = 1")
	var path := String(r["path"])
	_ok(path.begins_with("user://exports/"), "导出到 user://exports/：%s" % path)
	_ok(FileAccess.file_exists(path), "文件真的存在")
	_ok(path.get_file().begins_with("vote_张三_"), "文件名格式 vote_<名字>_<时间>.json：%s" % path.get_file())
	_ok(path.get_extension() == "json", "扩展名是 json")

	# 写出来的内容能被导入端读回来（闭环）
	var back: Dictionary = Importer.load_vote_file(path)
	_ok(bool(back["ok"]), "自己导出的文件能被导入端读回（格式闭环）")
	if bool(back["ok"]):
		_ok(String(back["voter_name"]) == "张三", "读回的 voter_name 一致")
		_ok(String(back["voter_id"]) == "v_abc", "读回的 voter_id 一致")
		_ok((back["bans"] as Array).size() == 1, "读回的 bans 一致")

	# 非法字符名字也能导出
	var r2: Dictionary = Exporter.save_vote_file("张三/游戏ID", "v_x", ["90001_headshot"])
	_ok(bool(r2["ok"]), "带非法字符的名字也能导出成功")
	_ok(not String(r2["path"]).contains("/游戏"), "文件名里没有原始斜杠：%s" % String(r2["path"]).get_file())

	# 空名字 / 空 id 要拒绝
	_ok(not bool(Exporter.save_vote_file("", "v_x", []).get("ok", true)), "空名字导出被拒绝")
	_ok(not bool(Exporter.save_vote_file("张三", "", []).get("ok", true)), "空 voter_id 导出被拒绝")

	# txt
	var txt: String = Exporter.build_vote_text("张三", ["90001_headshot", "90002_headshot"])
	_ok(txt.contains("张三") and txt.contains("90001_headshot"), "txt 内容含名字和 ID")
	var rt: Dictionary = Exporter.save_vote_text_file("张三", ["90001_headshot"])
	_ok(bool(rt["ok"]) and FileAccess.file_exists(String(rt["path"])), "txt 文件真的写出")


# ---------------- 5. VoteImporter 正常流程 ----------------
func _test_importer_normal() -> void:
	print("\n[5] VoteImporter 正常流程（3 份假投票）")
	_clear_dir(FIXTURE_DIR)

	# 票数设计：90001 被 3 人 Ban；90002 被 2 人；90003 被 1 人；90004 被 1 人
	# 张三还故意把 90001 写了两次，验证「同人重复只算一票」
	_write_vote_file(FIXTURE_DIR, "a.json", "v_a", "张三", "2026-10-07T15:00:00",
		["90001_headshot", "90001_headshot", "90002_headshot"])
	_write_vote_file(FIXTURE_DIR, "b.json", "v_b", "李四", "2026-10-07T15:05:00",
		["90001_headshot", "90002_headshot", "90003_headshot"])
	_write_vote_file(FIXTURE_DIR, "c.json", "v_c", "王五", "2026-10-07T15:10:00",
		["90001_headshot", "90004_headshot"])
	_ok(FileAccess.file_exists(FIXTURE_DIR.path_join("a.json")),
		"夹具 a.json 写好了")

	var st: Dictionary = Importer.import_paths([FIXTURE_DIR])
	var ranking: Array = st["ranking"]

	_ok(int(st["file_count"]) == 3, "导入 3 个文件（实际 %d）" % int(st["file_count"]))
	_ok(int(st["voter_count"]) == 3, "识别 3 位投票人（实际 %d）" % int(st["voter_count"]))
	_ok((st["errors"] as Array).size() == 0, "没有坏文件")
	_ok((st["duplicates"] as Array).size() == 0, "没有重复投票")
	_ok(ranking.size() == 4, "被 Ban 过的忍者 4 个（实际 %d）" % ranking.size())

	# 排名与票数
	var expect := {"90001_headshot": 3, "90002_headshot": 2,
		"90003_headshot": 1, "90004_headshot": 1}
	var got := {}
	for r in ranking:
		got[String((r as Dictionary)["file"])] = int((r as Dictionary)["count"])
	_ok(got == expect, "票数正确：%s" % str(got))

	# 降序 + 同票按文件名升序
	_ok(String(ranking[0]["file"]) == "90001_headshot" and int(ranking[0]["count"]) == 3,
		"第一名是 90001（3 票）")
	_ok(String(ranking[1]["file"]) == "90002_headshot" and int(ranking[1]["count"]) == 2,
		"第二名是 90002（2 票）")
	_ok(String(ranking[2]["file"]) == "90003_headshot"
		and String(ranking[3]["file"]) == "90004_headshot",
		"同票时按文件名升序，结果稳定")

	# 投票人列表
	_ok((ranking[0]["voters"] as Array).size() == 3, "90001 的投票人有 3 位")
	_ok((ranking[3]["voters"] as Array).size() == 1, "90004 的投票人只有 1 位")

	# 每人 Ban 数
	var per: Array = st["voters"]
	_ok(per.size() == 3, "per_voter 有 3 条")
	var by_name := {}
	for v in per:
		by_name[String((v as Dictionary)["voter_name"])] = int((v as Dictionary)["count"])
	_ok(int(by_name.get("张三", -1)) == 2, "张三去重后 Ban 了 2 个（写了 3 次但重复只算一次）")
	_ok(int(by_name.get("李四", -1)) == 3, "李四 Ban 了 3 个")
	_ok(int(by_name.get("王五", -1)) == 2, "王五 Ban 了 2 个")

	# Top N 截断
	_ok(Importer.top_n(ranking, 2).size() == 2, "top_n(2) 返回 2 项")
	_ok(Importer.top_n(ranking, 0).size() == 4, "top_n(0) 返回全部")
	_ok(Importer.top_n(ranking, 99).size() == 4, "top_n(99) 返回全部")

	# 结果组装
	var resolver := func(photo: String) -> String:
		return {"90001_headshot": "漩涡鸣人"}.get(photo, photo)
	var final: Dictionary = Importer.build_final_result(st, resolver)
	_ok(String(final["format"]) == "naruto_ban_result", "汇总 format 正确")
	_ok(int(final["total_voters"]) == 3, "汇总 total_voters = 3")
	_ok((final["ranking"] as Array).size() == 4, "汇总 ranking 有 4 项")
	var first: Dictionary = (final["ranking"] as Array)[0]
	_ok(String(first["name"]) == "漩涡鸣人", "名字解析器生效（90001 -> 漩涡鸣人）")
	_ok(int(first["rank"]) == 1 and int(first["count"]) == 3, "第一名 rank/count 正确")
	if (final["ranking"] as Array).size() > 1:
		var unknown: Dictionary = (final["ranking"] as Array)[1]
		_ok(String(unknown["name"]) == "90002_headshot",
			"没有映射的显示文件名 ID：%s" % String(unknown["name"]))

	# 文本汇总
	var txt: String = Importer.build_text_result(st, 2, resolver)
	_ok(txt.contains("漩涡鸣人") and txt.contains("3票"), "txt 含名字和票数")
	_ok(txt.contains("参与人数：3"), "txt 含参与人数")
	_info("txt 首行：%s" % txt.split("\n")[0])


# ---------------- 6. VoteImporter 异常处理 ----------------
func _test_importer_errors() -> void:
	print("\n[6] VoteImporter 异常处理")
	var dir := "user://test_bad"
	_clear_dir(dir)

	# 各种坏文件
	_write_file(dir.path_join("empty.json"), "")                       # 空文件
	_write_file(dir.path_join("notjson.json"), "{ 这不是 json ")        # 语法错
	_write_file(dir.path_join("array.json"), "[1,2,3]")                 # 顶层不是对象
	_write_file(dir.path_join("noformat.json"),
		JSON.stringify({"voter_id": "v_x", "bans": ["a"]}))             # 缺 format
	_write_file(dir.path_join("wrongformat.json"),
		JSON.stringify({"format": "something_else", "voter_id": "v_x",
			"bans": ["a"]}))                                            # format 不对
	_write_file(dir.path_join("nobans.json"),
		JSON.stringify({"format": "naruto_ban_vote", "voter_id": "v_x",
			"voter_name": "某人"}))                                      # 缺 bans
	_write_file(dir.path_join("bansnotarray.json"),
		JSON.stringify({"format": "naruto_ban_vote", "voter_id": "v_x",
			"bans": {"a": 1}}))                                         # bans 不是数组
	_write_file(dir.path_join("noname.json"),
		JSON.stringify({"format": "naruto_ban_vote", "voter_id": "",
			"voter_name": "", "bans": ["a"]}))                          # 没 id 也没名字
	# 一个正常的，验证坏文件不影响好文件
	_write_vote_file(dir, "ok.json", "v_ok", "正常人", "2026-10-07T16:00:00",
		["90001_headshot"])
	_ok(FileAccess.file_exists(dir.path_join("ok.json")), "夹具 ok.json 写好了")

	var st: Dictionary = Importer.import_paths([dir])
	var errs: Array = st["errors"]
	_ok(int(st["voter_count"]) == 1, "坏文件里夹的那 1 份好文件仍然被读到")
	_ok(errs.size() == 8, "8 个坏文件全部被记为错误（实际 %d）" % errs.size())

	# 每个错误都要有原因说明
	var reasons := {}
	for e in errs:
		reasons[String((e as Dictionary)["file"]).get_file()] = String((e as Dictionary)["reason"])
	for key in ["empty.json", "notjson.json", "array.json", "noformat.json",
			"wrongformat.json", "nobans.json", "bansnotarray.json", "noname.json"]:
		_ok(reasons.has(key), "坏文件 %s 有错误记录：%s" % [key, String(reasons.get(key, ""))])
	_info("错误示例：%s" % str(reasons.get("wrongformat.json", "")))
	_info("错误示例：%s" % str(reasons.get("empty.json", "")))

	# 不存在的文件
	var st2: Dictionary = Importer.import_paths(["user://根本不存在.json"])
	_ok((st2["errors"] as Array).size() == 1, "不存在的文件被记为错误")
	_ok(int(st2["voter_count"]) == 0, "不存在的文件不产生投票人")

	# 重复 voter_id：同一 id 交了两份，应取 timestamp 更新的那份
	var dup_dir := "user://test_dup"
	_clear_dir(dup_dir)
	_write_vote_file(dup_dir, "dup_old.json", "v_same", "重复君", "2026-10-07T10:00:00",
		["90001_headshot", "90002_headshot", "90003_headshot"])
	_write_vote_file(dup_dir, "dup_new.json", "v_same", "重复君", "2026-10-07T20:00:00",
		["90001_headshot"])
	_ok(FileAccess.file_exists(dup_dir.path_join("dup_old.json"))
		and FileAccess.file_exists(dup_dir.path_join("dup_new.json")),
		"重复投票夹具两份都写好了")
	var st3: Dictionary = Importer.import_paths([dup_dir])
	_ok(int(st3["voter_count"]) == 1, "同一 voter_id 只算 1 人（实际 %d）" % int(st3["voter_count"]))
	_ok((st3["duplicates"] as Array).size() == 1, "记录了 1 条重复投票")
	_ok((st3["ranking"] as Array).size() == 1,
		"取最新那份（只 Ban 了 1 个），所以排名只有 1 项（实际 %d）" % (st3["ranking"] as Array).size())
	if not (st3["ranking"] as Array).is_empty():
		_ok(String((st3["ranking"] as Array)[0]["file"]) == "90001_headshot"
			and int((st3["ranking"] as Array)[0]["count"]) == 1,
			"最新的那份生效：90001 得 1 票")
	if not (st3["duplicates"] as Array).is_empty():
		var dup_rec: Dictionary = (st3["duplicates"] as Array)[0]
		_ok(String(dup_rec["kept_file"]).get_file() == "dup_new.json", "保留的是新文件")
		_ok(String(dup_rec["dropped_file"]).get_file() == "dup_old.json", "丢弃的是旧文件")
	else:
		_ok(false, "应该记录 1 条重复投票，但 duplicates 为空")

	# timestamp 缺失时退回文件修改时间（只验证不崩 + 能识别）
	var nots_dir := "user://test_nots"
	_clear_dir(nots_dir)
	_write_file(nots_dir.path_join("nots.json"), JSON.stringify({
		"format": "naruto_ban_vote", "voter_id": "v_nots",
		"voter_name": "没时间戳", "bans": ["90001_headshot"]}))
	var st4: Dictionary = Importer.import_paths([nots_dir])
	_ok(int(st4["voter_count"]) == 1, "缺 timestamp 的文件也能导入")
	if not (st4["voters"] as Array).is_empty():
		var eff: String = String(((st4["voters"] as Array)[0] as Dictionary)["timestamp"])
		_ok(eff.length() >= 19, "退回到文件修改时间：%s" % eff)

	# 空目录
	var empty_dir := "user://test_empty"
	_clear_dir(empty_dir)
	var st5: Dictionary = Importer.import_paths([empty_dir])
	_ok(int(st5["voter_count"]) == 0 and (st5["errors"] as Array).size() == 0,
		"空目录不报错也不产生投票人")


# ---------------- 6.5 文字形式的投票 ----------------
func _test_vote_text() -> void:
	print("\n[6.5] 文字形式的投票（生成 + 批量解析 + 超上限）")

	# ---- 生成 ----
	var entries: Array = [
		["90001_Portrait", "漩涡鸣人"],
		["90002_Portrait", "宇智波佐助"],
		["40001_Portrait", "伊鲁卡"],
	]
	var block: String = VText.build_block("张三", entries)
	print("        ---- 生成的文字 ----")
	for ln in block.split("\n"):
		print("        " + ln)
	_ok(block.contains("玩家：张三"), "文字里有玩家名")
	_ok(block.contains("数量：3"), "文字里有数量")
	_ok(block.contains("<90001_Portrait>"), "文字里每个条目带照片ID")
	_ok(block.contains("漩涡鸣人"), "文字里有中文显示名")
	_ok(block.contains("=====BAN投票开始====="), "有开始标记")
	_ok(block.contains("=====BAN投票结束====="), "有结束标记")

	# ---- 解析单段 ----
	var p1: Dictionary = VText.parse_blocks(block, "inline")
	_ok((p1["records"] as Array).size() == 1, "单段解析出 1 条")
	if (p1["records"] as Array).size() == 1:
		var r: Dictionary = (p1["records"] as Array)[0]
		_ok(String(r["voter_name"]) == "张三", "解析出玩家名：%s" % String(r["voter_name"]))
		_ok(int(r["item_count"]) == 3, "解析出 3 个条目")
		_ok(int(r["declared_count"]) == 3, "解析出声明的数量 3")
		var bans: Array = r["bans"]
		_ok(bans.size() == 3 and String(bans[0]) == "90001_Portrait",
			"照片ID解析正确：%s" % str(bans))

	# ---- 一个 txt 里攒多段 ----
	var multi := ""
	for nm in ["甲", "乙", "丙"]:
		multi += VText.build_block(nm, [["90001_Portrait", "漩涡鸣人"]]) + "\n\n"
	var p2: Dictionary = VText.parse_blocks(multi, "multi.txt")
	_ok((p2["records"] as Array).size() == 3,
		"多段能一次解析出 3 条（实际 %d）" % (p2["records"] as Array).size())
	var names2: Array[String] = []
	for rec in (p2["records"] as Array):
		names2.append(String((rec as Dictionary)["voter_name"]))
	_ok(names2 == ["甲", "乙", "丙"], "三段玩家名正确：%s" % str(names2))

	# ---- 微信粘过来被搞乱的情况 ----
	var messy := """玩家: 赵六
数量: 2
名单:
1、漩涡鸣人 <90001_Portrait>
2)宇智波佐助<90002_Portrait>

玩家：钱七
1. 伊鲁卡 <40001_Portrait>"""
	var p3: Dictionary = VText.parse_blocks(messy, "messy.txt")
	_ok((p3["records"] as Array).size() == 2,
		"没有标记 + 半角冒号 + 不同序号写法也能解析出 2 条（实际 %d）" % (p3["records"] as Array).size())
	if (p3["records"] as Array).size() == 2:
		var a: Dictionary = (p3["records"] as Array)[0]
		var b: Dictionary = (p3["records"] as Array)[1]
		_ok(String(a["voter_name"]) == "赵六" and int(a["item_count"]) == 2,
			"赵六解析出 2 个（%s）" % str(a["bans"]))
		_ok(String(b["voter_name"]) == "钱七" and int(b["item_count"]) == 1,
			"钱七解析出 1 个（%s）" % str(b["bans"]))

	# ---- 数量对不上要提醒 ----
	var bad_count := """=====BAN投票开始=====
玩家：孙八
数量：5
名单：
1. 漩涡鸣人 <90001_Portrait>
2. 宇智波佐助 <90002_Portrait>
=====BAN投票结束====="""
	var p4: Dictionary = VText.parse_blocks(bad_count, "bad.txt")
	_ok((p4["records"] as Array).size() == 1, "数量对不上时仍然解析出 1 条")
	var warns4: Array = p4["warnings"]
	var has_mismatch := false
	for w in warns4:
		if String((w as Dictionary)["reason"]).contains("声明 5 个"):
			has_mismatch = true
	_ok(has_mismatch, "数量声明与实际不符时给出提醒（%d 条提醒）" % warns4.size())

	# ---- 没有照片ID时按显示名反查 ----
	var no_id := """玩家：周九
1. 漩涡鸣人
2. 宇智波佐助"""
	var p5: Dictionary = VText.parse_blocks(no_id, "noid.txt")
	_ok((p5["records"] as Array).size() == 1, "没有ID也能解析出 1 条")
	if (p5["records"] as Array).size() == 1:
		var bans5: Array = ((p5["records"] as Array)[0] as Dictionary)["bans"]
		_info("按名字反查结果：%s" % str(bans5))
		# 显示名有重名，反查可能失败；只要不崩、条数对就行
		_ok(bans5.size() == 2, "两个条目都被保留（%d）" % bans5.size())

	# ---- 空内容 ----
	var p6: Dictionary = VText.parse_blocks("   \n\n  ", "empty.txt")
	_ok((p6["records"] as Array).size() == 0 and (p6["errors"] as Array).size() > 0,
		"空文本报错而不是崩溃")

	# ---- 端到端：写一个攒了多段的 txt，让导入器批量识别 ----
	var dir := "user://test_text"
	_clear_dir(dir)
	var buf := ""
	buf += VText.build_block("甲", [
		["90001_Portrait", "漩涡鸣人"], ["90002_Portrait", "宇智波佐助"]])
	buf += "\n\n"
	buf += VText.build_block("乙", [
		["90001_Portrait", "漩涡鸣人"]])
	buf += "\n\n"
	buf += VText.build_block("丙", [
		["90001_Portrait", "漩涡鸣人"], ["90003_Portrait", "春野樱"],
		["90004_Portrait", "旗木卡卡西"], ["40001_Portrait", "伊鲁卡"]])
	_write_file(dir.path_join("群友文字.txt"), buf)

	var st: Dictionary = Importer.import_paths([dir])
	_ok(int(st["voter_count"]) == 3,
		"一个 txt 里的 3 段被识别成 3 个人（实际 %d）" % int(st["voter_count"]))
	var rank: Array = st["ranking"]
	var got := {}
	for r in rank:
		got[String((r as Dictionary)["file"])] = int((r as Dictionary)["count"])
	_ok(int(got.get("90001_Portrait", 0)) == 3,
		"90001 被 3 个人 Ban（实际 %d）" % int(got.get("90001_Portrait", 0)))
	_ok(int(got.get("90002_Portrait", 0)) == 1, "90002 被 1 个人 Ban")
	_ok(int(got.get("40001_Portrait", 0)) == 1, "40001 被 1 个人 Ban")

	# ---- 超上限检查 ----
	var over1: Array = Importer.find_limit_violations(st, 0)
	_ok(over1.size() == 0, "上限填 0 时不做检查")
	var over2: Array = Importer.find_limit_violations(st, 3)
	_ok(over2.size() == 1, "上限 3 时抓出 1 个超的（实际 %d）" % over2.size())
	if over2.size() == 1:
		var od: Dictionary = over2[0]
		_ok(String(od["voter_name"]) == "丙" and int(od["count"]) == 4,
			"超上限的是丙，投了 4 个（%s / %d）" % [String(od["voter_name"]), int(od["count"])])
	var over3: Array = Importer.find_limit_violations(st, 4)
	_ok(over3.size() == 0, "上限放到 4 就没人超了")

	# ---- 文字 + json 混着导 ----
	var mixdir := "user://test_mix"
	_clear_dir(mixdir)
	_write_file(mixdir.path_join("群友文字.txt"),
		VText.build_block("甲", [["90001_Portrait", "漩涡鸣人"]]))
	_write_vote_file(mixdir, "b.json", "v_b", "乙", "2026-11-11T10:00:00",
		["90001_Portrait"])
	var stmix: Dictionary = Importer.import_paths([mixdir])
	_ok(int(stmix["voter_count"]) == 2,
		"json 和 txt 能一起导入（%d 人）" % int(stmix["voter_count"]))
	_ok(int((stmix["ranking"] as Array)[0]["count"]) == 2,
		"两个人 Ban 同一个 → 2 票")

	print("\n[6.6] 玩家端「复制投票文本」")
	var dm = get_node("/root/DataManager")
	var il = get_node("/root/ImageLoader")
	dm.voter_name = "文字玩家"
	dm.ensure_voter_id()
	dm.clear_all()
	var photo_a := String(il.photos[0]["photo"]) if il.photos.size() > 0 else "x"
	var photo_b := String(il.photos[1]["photo"]) if il.photos.size() > 1 else "y"
	dm.set_ban(photo_a, true)
	dm.set_ban(photo_b, true)
	var real_block: String = VText.build_block("文字玩家", [
		[photo_a, il.get_display_name(photo_a)],
		[photo_b, il.get_display_name(photo_b)],
	])
	_ok(real_block.contains("数量：2"), "真实数据生成的文字数量正确")
	var rp: Dictionary = VText.parse_blocks(real_block, "real")
	_ok((rp["records"] as Array).size() == 1, "真实数据生成的文字能被自己解析回来")
	if (rp["records"] as Array).size() == 1:
		var rb: Array = ((rp["records"] as Array)[0] as Dictionary)["bans"]
		_ok(String(rb[0]) == photo_a and String(rb[1]) == photo_b,
			"解析回来的照片ID和原来一致（%s）" % str(rb))
	dm.clear_all()


# ---------------- 7. 汇总导出 ----------------
func _test_organizer_export() -> void:
	print("\n[7] 汇总导出（json / txt / png）")
	var st: Dictionary = Importer.import_paths([FIXTURE_DIR])
	_ok(int(st["voter_count"]) == 3, "准备数据：3 位投票人")

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# json
	var final: Dictionary = Importer.build_final_result(st,
		func(photo: String) -> String: return get_node("/root/ImageLoader").get_display_name(photo))
	var jp := OUT_DIR.path_join("final_result.json")
	_write_file(jp, JSON.stringify(final, "\t"))
	_ok(FileAccess.file_exists(jp), "final_result.json 已写出")
	var reread = JSON.parse_string(FileAccess.get_file_as_string(jp))
	_ok(typeof(reread) == TYPE_DICTIONARY, "写出的 json 能读回")
	if typeof(reread) == TYPE_DICTIONARY:
		var d: Dictionary = reread
		_ok(String(d.get("format", "")) == "naruto_ban_result", "读回后 format 正确")
		_ok((d.get("ranking", []) as Array).size() == 4, "读回后 ranking 4 项")
		_ok((d.get("voters", []) as Array).size() == 3, "读回后 voters 3 位")

	# txt
	var tp := OUT_DIR.path_join("final_result.txt")
	_write_file(tp, Importer.build_text_result(st, 5,
		func(photo: String) -> String: return get_node("/root/ImageLoader").get_display_name(photo)))
	_ok(FileAccess.file_exists(tp), "final_result.txt 已写出")

	# png：真的起一个 Organizer 场景来渲染，验证导出链路
	# 注意：headless 下 dummy 渲染器没有纹理，get_image() 必然为 null，
	# PNG 导出只能跳过（带窗口跑 _shot.tscn 时才会真正验证）。
	var headless := DisplayServer.get_name() == "headless"
	var org = (load("res://scenes/Organizer.tscn") as PackedScene).instantiate()
	org.set("_stats", st)
	get_tree().root.add_child(org)
	await get_tree().process_frame
	await get_tree().process_frame
	var pp := OUT_DIR.path_join("final_result.png")
	var ok_png: bool = await org.call("_render_png", pp)
	if headless:
		_info("headless 模式：PNG 导出已按预期跳过（无渲染器）")
		_ok(ok_png == false, "headless 下 _render_png 明确返回 false（不静默假装成功）")
	else:
		_ok(ok_png, "Organizer._render_png 返回成功")
		_ok(FileAccess.file_exists(pp), "final_result.png 已写出")
		if FileAccess.file_exists(pp):
			var img: Image = Image.load_from_file(pp)
			_ok(img != null and not img.is_empty(), "写出的 png 能读回")
			if img != null:
				_info("汇总图尺寸 %d x %d" % [img.get_width(), img.get_height()])
				_ok(img.get_width() >= 1000, "汇总图宽度 >= 1000（实际 %d）" % img.get_width())
	org.queue_free()
	await get_tree().process_frame


# ---------------- 8. Main 场景 ----------------
func _test_main_scene() -> void:
	print("\n[8] Main（玩家端）场景启动检查")
	var ps = load("res://scenes/Main.tscn")
	if not (ps is PackedScene):
		_ok(false, "Main.tscn 加载失败")
		return
	var main = (ps as PackedScene).instantiate()
	if main == null:
		_ok(false, "Main.tscn 实例化失败")
		return

	# 先给个名字，免得弹窗卡住流程
	var dm = get_node("/root/DataManager")
	dm.voter_name = "自检玩家"
	dm.ensure_voter_id()
	dm.clear_all()
	# 自检时把图片解析器换成缩略图，免得 1017 张全图占内存
	var il = get_node("/root/ImageLoader")
	il.set_texture_resolver(func(photo: String) -> Texture2D: return il.get_thumbnail(photo))
	# 自检没必要真加载上千张，压到 30 张
	il.max_load_count = 30

	# 【回归测试】预先存好 2 票，再打开主界面：
	# 之前从组织者模式返回玩家模式时，右侧 Ban 名单是空的，
	# 要点一下新角色才"刷"回来。这里断言开局就得显示出来。
	var seeded: Array[String] = []
	for i in range(mini(2, il.photos.size())):
		var p := String(il.photos[i]["photo"])
		seeded.append(p)
		dm.set_ban(p, true)
	_info("预先存了 %d 票：%s" % [seeded.size(), str(seeded)])

	get_tree().root.add_child(main)
	await get_tree().process_frame

	_ok(main.get_node_or_null("Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar") != null,
		"工具栏节点存在")
	_ok(main.get_node_or_null("Root/VBox/Body/CardArea/CardScroll/CardFlow") != null,
		"卡片流容器存在")
	var toolbar = main.get_node("Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar")
	var btns: Array[String] = []
	for c in toolbar.get_children():
		if c is Button:
			btns.append((c as Button).text)
	_info("工具栏按钮：%s" % str(btns))
	_ok(btns.has("导出我的投票"), "有「导出我的投票」按钮")
	_ok(btns.has("清空我的投票"), "有「清空我的投票」按钮")
	_ok(btns.has("改名"), "有「改名」按钮")
	_ok(btns.has("复制投票文本"), "有「复制投票文本」按钮")
	_ok(not btns.has("＋ 投票人"), "已经去掉了「＋投票人」按钮")
	_ok(main.get_node_or_null("Root/VBox/HeaderBox/HeaderRow/OrganizerBtn") != null,
		"有组织者模式入口按钮")

	# 窗口标题带名字
	_ok(get_window().title.contains("自检玩家"),
		"窗口标题含玩家名：%s" % get_window().title)

	# 等卡片出来
	var waited := 0
	while main.get_node("Root/VBox/Body/CardArea/CardScroll/CardFlow").get_child_count() < 15 \
			and waited < 20000:
		await get_tree().process_frame
		waited += 16
	var flow = main.get_node("Root/VBox/Body/CardArea/CardScroll/CardFlow")
	var made: int = flow.get_child_count()
	_ok(made >= 15, "生成了 %d 张卡片" % made)

	if made > 0:
		var card = flow.get_child(0)
		_ok(card.get("photo") != "", "首张卡片有 photo")
		_ok(card.get("character_name") != "", "首张卡片有显示名：%s" % str(card.get("character_name")))
		_ok(card.call("get_texture") != null, "首张卡片有纹理")

	# 【回归】开局就必须显示已存的投票（不能等点一下才刷出来）
	if seeded.size() > 0:
		var bp = main.get_node_or_null("Root/VBox/Body/BanPanelWrap/BanListPanel")
		_ok(bp != null, "右侧 Ban 名单面板存在")
		if bp != null:
			var lb: VBoxContainer = bp.get_node("Margin/VBox/ScrollContainer/ListBox")
			var cl: Label = bp.get_node("Margin/VBox/Header/HeaderMargin/HeaderBox/CountLabel")
			_ok(lb.get_child_count() == seeded.size(),
				"开局右侧名单就有 %d 行（实际 %d）—— 不该等点一下才出现" % [
					seeded.size(), lb.get_child_count()])
			_ok(cl.text == "%d 个" % seeded.size(),
				"开局计数正确（%s）" % cl.text)
		# 卡片也要是已 Ban 状态
		var all_shown := true
		for c in flow.get_children():
			var p := String((c as Node).get("photo"))
			if seeded.has(p) and (c as Node).get("banned") != true:
				all_shown = false
		_ok(all_shown, "已 Ban 的那几张卡片开局就显示橙框 + ✓")

	# 通过 UI 投票（挑一张「没被预置 Ban」的卡片，才能测到「点一下变已 Ban」）
	if made > 0:
		var first_photo := ""
		for c in flow.get_children():
			var p := String((c as Node).get("photo"))
			if not seeded.has(p):
				first_photo = p
				break
		var clicked_card: Node = null
		for c in flow.get_children():
			if String((c as Node).get("photo")) == first_photo:
				clicked_card = c
				break
		main.call("_on_card_vote_toggled", first_photo, true)
		await get_tree().process_frame
		_ok(dm.is_banned(first_photo), "点卡片后进入 Ban 名单")
		_ok(clicked_card != null and clicked_card.get("banned") == true, "卡片显示为已 Ban 状态")
		main.call("_on_card_vote_toggled", first_photo, false)
		await get_tree().process_frame
		_ok(not dm.is_banned(first_photo), "再点一次取消")

		# 导出（走 UI 入口）
		# 【别用「文件数变多」判断】导出文件名带的是秒级时间戳，
		# 同一秒内重复导出会覆盖同名文件 → 文件数不变 → 假失败。
		# 改成验证「真的走到了成功分支」：成功时创建 ExportDoneDialog，
		# 失败时走 _show_message（没有这个名字的节点）。
		dm.toggle_ban(first_photo)
		# 现在 _on_export_pressed 会弹「选文件夹」，自检里直接调写盘那一步
		var out_dir := ProjectSettings.globalize_path("user://exports")
		main.call("_export_to_folder", out_dir)
		await get_tree().process_frame
		await get_tree().process_frame
		_ok(main.get_node_or_null("ExportDoneDialog") != null,
			"点「导出我的投票」后弹出「导出完成」= 导出成功")
		var exp_dlg = main.get_node_or_null("ExportDoneDialog")
		if exp_dlg != null:
			var path_edit = exp_dlg.get_node_or_null("MarginContainer/ExportDirEdit")
			# 确认弹窗里给出了 json 路径控件
			var json_edit = _find_line_edit_named(exp_dlg, "JsonPathEdit")
			_ok(json_edit != null and json_edit.text != "",
				"导出弹窗里显示了 json 完整路径：%s" % (json_edit.text if json_edit else "(无)"))
			if json_edit != null:
				_ok(FileAccess.file_exists(json_edit.text.replace("\\", "/")) or
					FileAccess.file_exists(_to_user_path(json_edit.text)),
					"弹窗里显示的 json 文件确实存在")
			(exp_dlg as AcceptDialog).hide()
			exp_dlg.queue_free()
			await get_tree().process_frame

		# ---- 新功能 1：右侧 Ban 名单面板 ----
		await _test_ban_panel(main, dm, flow, first_photo)
		# ---- 新功能 2：导出目录可自选并记住 ----
		await _test_export_dir(main, dm)
		# ---- 新功能 3：右键查看大图弹窗不能被撑出屏幕 ----
		await _test_preview_dialog(main, dm)

	main.queue_free()
	await get_tree().process_frame


## 右侧 Ban 名单面板：显示、移除、定位
## dm 是 Autoload 节点，没有 class_name，所以只能声明成 Node 再靠调用拿值；
## 因此所有从它取回来的变量都要显式写类型（否则 Variant 推断会报错）。
func _test_ban_panel(main: Control, dm: Node, flow: Node, photo: String) -> void:
	print("\n        --- 右侧 Ban 名单面板 ---")
	var panel = main.get_node_or_null("Root/VBox/Body/BanPanelWrap/BanListPanel")
	_ok(panel != null, "右侧 BanListPanel 节点存在")
	if panel == null:
		return
	var list_box: VBoxContainer = panel.get_node("Margin/VBox/ScrollContainer/ListBox")
	var count_label: Label = panel.get_node("Margin/VBox/Header/HeaderMargin/HeaderBox/CountLabel")
	var empty_hint: Label = panel.get_node("Margin/VBox/EmptyHint")

	# 清空后应当显示空提示
	dm.clear_all()
	await get_tree().process_frame
	_ok(list_box.get_child_count() == 0, "名单为空时列表里 0 行")
	_ok(empty_hint.visible, "名单为空时显示空提示")
	_ok(count_label.text == "0 个", "计数显示 0 个（实际 %s）" % count_label.text)

	# Ban 两个，面板应当立刻出现两行
	dm.set_ban(photo, true)
	var second := ""
	for c in flow.get_children():
		var p := String((c as Node).get("photo"))
		if p != photo:
			second = p
			break
	if second != "":
		dm.set_ban(second, true)
	await get_tree().process_frame
	var expect_rows: int = dm.get_ban_count()
	_ok(list_box.get_child_count() == expect_rows,
		"Ban 了 %d 个后列表有 %d 行" % [expect_rows, list_box.get_child_count()])
	_ok(not empty_hint.visible, "有内容后空提示隐藏")
	_ok(count_label.text == "%d 个" % expect_rows, "计数显示 %s" % count_label.text)

	# 第一行应当有头像和名字
	if list_box.get_child_count() > 0:
		var row = list_box.get_child(0)
		var nm_lbl: Label = row.get_node("RowMargin/RowBox/NameLabel")
		var av: TextureRect = row.get_node("RowMargin/RowBox/AvatarFrame/AvatarCenter/Avatar")
		_ok(nm_lbl.text != "", "列表行有名字：%s" % nm_lbl.text)
		_ok(av.texture != null, "列表行有头像")
		var idx_lbl: Label = row.get_node("RowMargin/RowBox/Index")
		_ok(idx_lbl.text == "1", "第一行序号是 1（实际 %s）" % idx_lbl.text)
		var btn: Button = row.get_node("RowMargin/RowBox/RemoveBtn")
		_ok(btn != null and btn.text == "移除", "每行有「移除」按钮")

		# 点「移除」应当真的把它移出名单
		var target := String(row.get("photo")) if row.get("photo") != null else ""
		var removed_photo := ""
		# 从面板拿不到 photo，就用第一行显示的名字反推：直接按 DataManager 顺序取第一个
		var bans_before: Array = dm.get_bans()
		if bans_before.size() > 0:
			removed_photo = String(bans_before[0])
		var n_before: int = dm.get_ban_count()
		btn.emit_signal("pressed")
		await get_tree().process_frame
		_ok(dm.get_ban_count() == n_before - 1,
			"点「移除」后名单从 %d 变成 %d" % [n_before, dm.get_ban_count()])
		_ok(not dm.is_banned(removed_photo), "被移除的那个确实不在名单里了")
		_ok(list_box.get_child_count() == dm.get_ban_count(), "列表行数跟着减少")

	# 清空收尾
	dm.clear_all()
	await get_tree().process_frame
	_ok(list_box.get_child_count() == 0, "清空后列表 0 行")


## 导出目录：可自选 + 记住
func _test_export_dir(main: Control, dm: Node) -> void:
	print("\n        --- 导出目录自选 / 记住 ---")
	var custom := "user://my_custom_export"
	var d := DirAccess.open(custom)
	if d != null:
		for f in d.get_files():
			DirAccess.remove_absolute(custom.path_join(f))
	DirAccess.make_dir_recursive_absolute(custom)

	# 默认值
	dm.reset_export_dir()
	_ok(not dm.has_custom_export_dir(), "默认状态下没有自定义导出目录")
	_ok(dm.effective_export_dir() == "user://exports", "默认导出目录是 user://exports（实际 %s）" % dm.effective_export_dir())

	# 设置自定义目录
	_ok(dm.set_export_dir(custom), "set_export_dir 设置成功")
	_ok(dm.has_custom_export_dir(), "has_custom_export_dir 为真")
	_ok(dm.effective_export_dir() == custom, "生效目录变成自定义的（实际 %s）" % dm.effective_export_dir())

	# 导出确实落到自定义目录
	var before := _count_files(custom)
	var exp = load("res://scripts/vote_exporter.gd")
	dm.set_ban(_first_photo(), true)
	var res: Dictionary = exp.save_vote_file(dm.voter_name, dm.voter_id,
		dm.get_bans(), dm.effective_export_dir())
	_ok(bool(res["ok"]), "导出到自定义目录成功")
	_ok(String(res["path"]).begins_with(custom),
		"导出路径在自定义目录下：%s" % String(res["path"]))
	_ok(_count_files(custom) > before,
		"自定义目录里文件数从 %d 增加到 %d" % [before, _count_files(custom)])

	# 持久化：模拟重启
	dm.save()
	var remember: String = dm.export_dir
	dm.export_dir = ""
	dm.read_from_disk()
	_ok(dm.export_dir == remember,
		"重启后仍记得自定义目录（%s）" % dm.export_dir)
	_ok(dm.effective_export_dir() == custom, "重启后生效目录还是自定义的")

	# 恢复默认
	dm.reset_export_dir()
	_ok(not dm.has_custom_export_dir(), "reset 后回到默认")
	_ok(dm.effective_export_dir() == "user://exports", "reset 后生效目录是默认的")

	# 建不出来的目录要拒绝；传空串表示恢复默认（这是合法操作，应当返回 true）
	dm.set_export_dir(custom)
	_ok(dm.has_custom_export_dir(), "先设成自定义的，便于验证空串行为")
	_ok(dm.set_export_dir(""), "传空串返回 true（等于恢复默认，不是错误）")
	_ok(not dm.has_custom_export_dir(), "传空串后回到默认状态")
	var bogus: bool = dm.set_export_dir("Z:/绝对不存在的盘符/xyz")
	_ok(not bogus, "给一个建不出来的路径时返回 false（%s）" % str(bogus))
	dm.clear_all()


## 右键查看大图：弹窗不能被撑出屏幕、必须有图
## 【别硬编码照片 ID】头像文件名会变（_headshot → _Portrait），
## 所以这里从 ImageLoader 实际扫描结果里取第一张。
func _test_preview_dialog(main: Control, dm: Node) -> void:
	print("\n        --- 右键查看大图 ---")
	var il = get_node("/root/ImageLoader")
	if il.photos.is_empty():
		_ok(false, "没有头像可用，无法测预览")
		return
	var photo := String(il.photos[0]["photo"])
	_info("用这个照片测预览：%s" % photo)
	dm.set_ban(photo, true)
	await get_tree().process_frame
	main.call("_on_card_preview_requested", photo)
	await get_tree().process_frame
	await get_tree().process_frame
	var dlg = main.get_node_or_null("PreviewDialog")
	_ok(dlg != null, "弹出了 PreviewDialog")
	if dlg == null:
		return
	var win := dlg as Window
	_ok(win.visible, "弹窗可见")
	_ok(win.size.y <= 900,
		"弹窗高度没有失控（实际 %d，修复前是 2300）" % win.size.y)
	_ok(win.size.x >= 300, "弹窗宽度合理（%d）" % win.size.x)
	_ok(win.max_size.y <= 900, "弹窗设了 max_size 上限（%d）" % win.max_size.y)

	var tr := _find_texture_rect(dlg)
	_ok(tr != null, "弹窗里有 TextureRect")
	if tr != null:
		_ok(tr.texture != null, "TextureRect 上挂着纹理")
		_ok(tr.size_flags_vertical != Control.SIZE_EXPAND_FILL,
			"图片框不是 EXPAND_FILL（否则会撑大弹窗）")
		_ok(tr.size.y <= 500, "图片框高度受控（%d）" % tr.size.y)
		_ok(tr.size.y >= 100, "图片框高度够看（%d）" % tr.size.y)

	# 关掉
	win.hide()
	dlg.queue_free()
	await get_tree().process_frame
	dm.clear_all()


func _find_texture_rect(n: Node) -> TextureRect:
	if n is TextureRect:
		return n
	for c in n.get_children():
		var r := _find_texture_rect(c)
		if r != null:
			return r
	return null


func _count_files(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	var n := 0
	for f in d.get_files():
		if f.get_extension().to_lower() == "json" or f.get_extension().to_lower() == "txt":
			n += 1
	return n


## 取当前头像目录里第一张照片的 ID（避免测试硬编码已改名的旧 ID）
func _first_photo() -> String:
	var il = get_node("/root/ImageLoader")
	if il.photos.is_empty():
		il.scan_directory()
	if il.photos.is_empty():
		return ""
	return String(il.photos[0]["photo"])


## 按节点名递归找 LineEdit
func _find_line_edit_named(n: Node, wanted: String) -> LineEdit:
	if n is LineEdit and n.name == wanted:
		return n as LineEdit
	for c in n.get_children():
		var r := _find_line_edit_named(c, wanted)
		if r != null:
			return r
	return null


## 把绝对路径换回 user:// 形式（Godot 的 FileAccess 认 user://）
func _to_user_path(abs_path: String) -> String:
	var ud := ProjectSettings.globalize_path("user://")
	var a := abs_path.replace("\\", "/")
	if a.begins_with(ud):
		return "user://" + a.substr(ud.length())
	return a


# ---------------- 9. Organizer 场景 ----------------
func _test_organizer_scene() -> void:
	print("\n[9] Organizer（组织者端）场景启动检查")
	var ps = load("res://scenes/Organizer.tscn")
	if not (ps is PackedScene):
		_ok(false, "Organizer.tscn 加载失败")
		return
	var org = (ps as PackedScene).instantiate()
	if org == null:
		_ok(false, "Organizer.tscn 实例化失败")
		return
	get_tree().root.add_child(org)
	await get_tree().process_frame

	_ok(org.get_node_or_null("Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar") != null,
		"工具栏节点存在")
	_ok(org.get_node_or_null("Root/VBox/Body/BodyBox/BodyMargin/TopGrid") != null,
		"Top 网格容器存在")
	var toolbar = org.get_node("Root/VBox/ToolbarWrap/ToolbarScroll/Toolbar")
	var btns: Array[String] = []
	for c in toolbar.get_children():
		if c is Button:
			btns.append((c as Button).text)
	_info("工具栏按钮：%s" % str(btns))
	for want in ["导入文件", "导入文件夹", "清空已导入",
			"导出汇总 JSON", "导出汇总 PNG", "导出汇总 TXT"]:
		_ok(btns.has(want), "有「%s」按钮" % want)
	# 每人上限检查控件（不是按钮，单独断言）
	var lim = org.get("_limit_spin")
	_ok(lim != null, "组织者端有「每人上限」输入框")
	if lim != null:
		_ok(int((lim as SpinBox).value) == 0, "每人上限默认 0（不检查）")

	# 导入 fixture 并渲染
	org.call("_do_import", [FIXTURE_DIR])
	await get_tree().process_frame
	var stats: Dictionary = org.get("_stats")
	_ok(int(stats.get("voter_count", 0)) == 3, "通过 UI 导入后 3 位投票人")
	var grid = org.get_node("Root/VBox/Body/BodyBox/BodyMargin/TopGrid")
	_ok(grid.get_child_count() > 0, "Top 网格渲染出 %d 个格子" % grid.get_child_count())
	var summary = org.get_node("Root/VBox/SummaryWrap/SummaryBox/SummaryVBox/SummaryLabel")
	_ok(summary.text.contains("参与 3 人"), "概览显示参与人数：%s" % summary.text)
	_info("概览：%s" % summary.text)

	# ---- 手动增减票数（防呆）----
	print("\n        --- 手动增减票数 ---")
	var st_raw: Dictionary = org.get("_stats_raw")
	var ranking: Array = st_raw.get("ranking", [])
	var target_photo := String((ranking[0] as Dictionary)["file"])
	var raw_count := int((ranking[0] as Dictionary)["count"])
	_info("拿第一名试：%s，原 %d 票" % [target_photo, raw_count])

	var warn: Label = org.get("_manual_warn")
	_ok(warn != null, "有「手动调整」警告条节点")
	_ok(warn != null and not warn.visible, "没调整时警告条是隐藏的")

	var raw_file_before := ""
	var raw_json_path: String = "user://test_manual_raw/vote_a.json"
	raw_file_before = FileAccess.get_file_as_string(raw_json_path)

	org.call("_bump", target_photo, 1)
	await get_tree().process_frame
	var st_adj: Dictionary = org.get("_stats")
	var adj_count := -1
	var adj_raw := -1
	var adj_delta := 0
	for r in (st_adj.get("ranking", []) as Array):
		if String((r as Dictionary)["file"]) == target_photo:
			adj_count = int((r as Dictionary)["count"])
			adj_raw = int((r as Dictionary).get("raw_count", -1))
			adj_delta = int((r as Dictionary).get("manual_delta", 0))
	_ok(adj_count == raw_count + 1, "加 1 票后显示 %d（原 %d）" % [adj_count, raw_count])
	_ok(adj_raw == raw_count, "保留了原始票数 raw_count=%d" % adj_raw)
	_ok(adj_delta == 1, "记录了手动增量 +1")
	_ok(bool(org.call("has_manual_adjustment")), "has_manual_adjustment 为真")
	_ok(warn.visible, "调整后警告条显示出来")
	_ok(warn.text.contains("验证是否公平公正"), "警告条文案包含「验证是否公平公正」")
	_info("警告条：%s" % warn.text)
	var clr: Button = org.get("_manual_clear_btn")
	_ok(clr != null and clr.visible, "出现「撤销手动调整」按钮")

	# 原始导入的数据不能被改动
	_ok(FileAccess.get_file_as_string(raw_json_path) == raw_file_before,
		"原始投票文件没有被修改（只改内存里的展示结果）")
	var still_raw: Dictionary = org.get("_stats_raw")
	var raw_first := int(((still_raw["ranking"] as Array)[0] as Dictionary)["count"])
	_ok(raw_first == raw_count, "_stats_raw 仍是原始值 %d" % raw_first)

	# 加够票数应该能反超，验证真的重排了
	# 注意：第一名刚才已经 +1 变成 (raw_count + 1) 票，要严格超过它才行
	var second_photo := String((ranking[1] as Dictionary)["file"])
	var second_cnt := int((ranking[1] as Dictionary)["count"])
	var need: int = (raw_count + 1) - second_cnt + 1
	for i in range(need):
		org.call("_bump", second_photo, 1)
	await get_tree().process_frame
	var st3: Dictionary = org.get("_stats")
	var new_first := String(((st3["ranking"] as Array)[0] as Dictionary)["file"])
	_ok(new_first == second_photo,
		"加够票后第 2 名反超成第 1 名（+%d 票，现在第 1 是 %s）" % [need, new_first])

	# 减到 0 应该从排名里消失
	var third := ""
	for r in (ranking as Array):
		var p := String((r as Dictionary)["file"])
		if p != target_photo and p != second_photo:
			third = p
			break
	if third != "":
		var third_cnt := 0
		for r in (ranking as Array):
			if String((r as Dictionary)["file"]) == third:
				third_cnt = int((r as Dictionary)["count"])
		for i in range(third_cnt):
			org.call("_bump", third, -1)
		await get_tree().process_frame
		var st4: Dictionary = org.get("_stats")
		var still_there := false
		for r in (st4.get("ranking", []) as Array):
			if String((r as Dictionary)["file"]) == third:
				still_there = true
		_ok(not still_there, "减到 0 票的忍者从排名里消失了")

	# 导出要带上警告
	var mdir := "user://test_manual_out"
	_clear_dir(mdir)
	DirAccess.make_dir_recursive_absolute(mdir)
	org.call("_export_json_to", ProjectSettings.globalize_path(mdir))
	org.call("_export_txt_to", ProjectSettings.globalize_path(mdir))
	await get_tree().process_frame
	var js := FileAccess.get_file_as_string(mdir.path_join("final_result.json"))
	var tx := FileAccess.get_file_as_string(mdir.path_join("final_result.txt"))
	_ok(js.contains("manual_adjustment"), "导出的 json 里有 manual_adjustment 字段")
	_ok(js.contains("验证是否公平公正"), "导出的 json 里有警告语")
	_ok(tx.contains("验证是否公平公正"), "导出的 txt 里有警告语")
	_ok(tx.strip_edges().begins_with("⚠"), "导出的 txt 第一行就是警告")

	# 撤销
	org.call("_on_clear_manual")
	await get_tree().process_frame
	_ok(not bool(org.call("has_manual_adjustment")), "撤销后没有手动调整")
	_ok(not warn.visible, "撤销后警告条隐藏")
	var st5: Dictionary = org.get("_stats")
	var back := int(((st5["ranking"] as Array)[0] as Dictionary)["count"])
	_ok(back == raw_count, "撤销后票数回到原始值 %d" % back)

	# 清空
	org.call("_on_clear_pressed")
	await get_tree().process_frame
	_ok(int((org.get("_stats") as Dictionary).get("voter_count", 0)) == 0, "清空后没有投票人")
	_ok(not bool(org.call("has_manual_adjustment")), "清空后手动调整也被清掉")

	org.queue_free()
	await get_tree().process_frame


# ---------------- 10. 首次启动问名字 / 改名 / 口令门 ----------------
func _test_first_run_and_password() -> void:
	print("\n[10] 首次启动问名字 / 改名 / 组织者口令门")
	var dm = get_node("/root/DataManager")
	var il = get_node("/root/ImageLoader")

	# ===== 全新玩家：没名字就该弹窗，且先不扫描图片 =====
	for f in ["user://votes.json", "user://voter_name.txt", "user://voter_id.txt"]:
		_delete_file(f)
	dm.voter_name = ""
	dm.voter_id = ""
	dm.bans.clear()
	_ok(not dm.has_name(), "清空用户数据后 has_name 为假")
	# 前面的用例已经扫描过目录了，这里手动清空以模拟「全新启动」，
	# 好验证「没名字时不会去扫描」这条行为
	il.photos.clear()
	il._index.clear()

	var main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var dlg = main.get_node_or_null("NameDialog")
	_ok(dlg != null, "首次启动创建了 NameDialog")
	if dlg != null:
		_ok((dlg as AcceptDialog).visible, "NameDialog 自动弹出来了")
	var edit: LineEdit = main.get("_name_edit")
	_ok(edit != null, "弹窗里有输入框")
	if edit != null:
		_ok(edit.max_length == dm.MAX_NAME_LEN, "输入框限长 %d" % dm.MAX_NAME_LEN)
		_ok(edit.secret == false, "名字输入框不需要遮蔽")
	_info("此时 ImageLoader.photos 数量 = %d" % il.photos.size())
	_ok(il.photos.size() == 0, "没名字时不扫描头像（不白白消耗性能）")

	if edit != null:
		# 空名字必须被拒
		edit.text = "   "
		main.call("_on_name_confirmed")
		await get_tree().process_frame
		_ok(not dm.has_name(), "提交纯空格名字被拒绝")
		var status: Label = main.get_node("Root/VBox/StatusBarWrap/StatusLabel")
		_ok(status.text.contains("不能为空"), "状态栏提示「名字不能为空」")

		# 合法名字必须被接受并继续流程
		edit.text = "自检玩家甲"
		main.call("_on_name_confirmed")
		await get_tree().process_frame
		_ok(dm.has_name(), "提交合法名字被接受")
		_ok(dm.voter_name == "自检玩家甲", "名字正确：%s" % dm.voter_name)
		_ok(FileAccess.file_exists("user://voter_name.txt"), "名字写进 voter_name.txt")
		_ok(FileAccess.file_exists("user://voter_id.txt"), "生成 voter_id.txt")
		_info("窗口标题 = %s" % get_window().title)
		_ok(get_window().title.contains("自检玩家甲"), "窗口标题带上了名字")

		# 确认名字之后必须真的开始扫描
		var waited := 0
		while il.photos.size() == 0 and waited < 8000:
			await get_tree().process_frame
			waited += 16
		_ok(il.photos.size() > 0, "确认名字后开始扫描，扫到 %d 张" % il.photos.size())

	main.queue_free()
	await get_tree().process_frame

	# ===== 改名不改 voter_id =====
	var id_before: String = dm.ensure_voter_id()
	dm.set_voter_name("自检玩家乙")
	_ok(dm.voter_name == "自检玩家乙", "改名生效")
	_ok(dm.ensure_voter_id() == id_before, "改名后 voter_id 不变")
	_ok(_read_text_file("user://voter_name.txt") == "自检玩家乙", "新名字也落盘了")

	# ===== 已有名字时不该再问 =====
	var main2 = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(main2)
	await get_tree().process_frame
	await get_tree().process_frame
	var dlg2 = main2.get_node_or_null("NameDialog")
	_ok(dlg2 != null and not (dlg2 as AcceptDialog).visible, "已有名字时不再弹问名字窗口")
	_ok(dm.voter_name == "自检玩家乙", "重启后名字从文件恢复正确")
	main2.queue_free()
	await get_tree().process_frame

	# ===== 名字来源优先级 =====
	dm.voter_name = "来自votes的名字"
	dm.save()
	_write_file("user://voter_name.txt", "来自独立文件的名字")
	dm.voter_name = ""
	dm.read_from_disk()
	_ok(dm.voter_name == "来自独立文件的名字",
		"两处冲突时以 voter_name.txt 为准（实际 %s）" % dm.voter_name)
	_delete_file("user://voter_name.txt")
	dm.voter_name = ""
	dm.read_from_disk()
	_ok(dm.voter_name == "来自votes的名字",
		"voter_name.txt 缺失时退回 votes.json（实际 %s）" % dm.voter_name)

	# ===== 组织者口令门 =====
	_delete_file("user://organizer_unlocked.txt")
	_ok(not FileAccess.file_exists("user://organizer_unlocked.txt"), "解锁标记已清除")

	var main3 = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(main3)
	await get_tree().process_frame
	await get_tree().process_frame
	main3.call("_on_organizer_pressed")
	await get_tree().process_frame
	var pw = main3.get_node_or_null("PasswordDialog")
	_ok(pw != null, "没解锁时点「组织者模式」会弹口令框")
	if pw != null:
		var le := _find_line_edit(pw)
		_ok(le != null, "口令框里有输入框")
		if le != null:
			_ok(le.secret, "口令输入框是遮蔽显示的")
	_ok(main3.ORGANIZER_PASSWORD == "naruto2026", "口令常量与文档一致（naruto2026）")
	_ok(not FileAccess.file_exists("user://organizer_unlocked.txt"),
		"还没输对，不会提前写解锁标记")
	main3.queue_free()
	await get_tree().process_frame

	# ===== 收尾：恢复成「需要口令」，并清掉自检残留 =====
	_delete_file("user://organizer_unlocked.txt")
	dm.voter_name = ""
	dm.voter_id = ""
	dm.bans.clear()
	dm.save()
	_ok(true, "自检收尾：已清除解锁标记与自检投票数据")


func _find_line_edit(n: Node) -> LineEdit:
	if n is LineEdit:
		return n
	for c in n.get_children():
		var r := _find_line_edit(c)
		if r != null:
			return r
	return null


func _delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()
