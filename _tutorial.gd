# ============================================================
#  _tutorial.gd —— 按「新手教程」的顺序走一遍完整流程并截图
# ------------------------------------------------------------
#  只做两件事：驱动界面 + 截图。不修改任何产品代码。
#  输出：res://_shots/玩家-第N步 xxx.png / 组织者-第N步 xxx.png
# ============================================================
extends Node

const OUT := "res://_shots"
const VOTES_DIR := "user://tutorial_votes"
const EXPORT_DIR := "user://tutorial_export"

var _main: Node
var _org: Node


func _ready() -> void:
	# 让截图分辨率稳定
	get_window().size = Vector2i(1280, 800)
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute(OUT)
	_clear_out()
	await _player_flow()
	await _organizer_flow()

	print("\n全部截图完成，输出在 res://_shots")
	get_tree().quit(0)


# ------------------------------------------------------------
#  玩家视角
# ------------------------------------------------------------
func _player_flow() -> void:
	print("\n=== 玩家视角 ===")
	# 模拟「第一次打开程序」：既清磁盘文件，也要清 DataManager 内存里的状态
	# （只删文件不够——Autoload 在进程启动时就把名字和票读进内存了）
	_reset_player("")
	await get_tree().process_frame

	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(1.2)

	# ---- 第1步：取名 ----
	var ndlg = _main.get_node_or_null("NameDialog")
	print("  取名弹窗存在=%s 可见=%s" % [
		str(ndlg != null), str((ndlg as Window).visible if ndlg != null else false)])
	await _shot("玩家-第1步 取名")

	# 填名字并确认
	var ne: LineEdit = _main.get("_name_edit")
	if ne != null:
		ne.text = "张三"
	_main.call("_on_name_confirmed")
	# 代码直接调确认函数不会像真人点击那样让弹窗自动关闭，这里手动关掉
	if ndlg != null:
		(ndlg as Window).hide()
	await _wait(2.2)

	# ---- 第2步：选择忍者投票 ----
	# 先滚到卡片区顶部，点几个有代表性的忍者
	var flow: Node = _main.get_node("Root/VBox/Body/CardArea/CardScroll/CardFlow")
	# 只加载了前 60 个，这里挑前几张点
	var picked: Array = []
	for i in range(flow.get_child_count()):
		if picked.size() >= 3:
			break
		var c = flow.get_child(i)
		var photo := String((c as Node).get("photo"))
		_main.call("_on_card_vote_toggled", photo, true)
		picked.append(photo)
		await get_tree().process_frame
	await _wait(0.5)
	await _shot("玩家-第2步 选择忍者投票")

	# ---- 第3步：移除一个（演示右侧名单每行的「移除」按钮）----
	# 原来这里只是又截一次同样的画面，和第2步一模一样，对教程没用。
	# 改成真的移除一个，画面和状态都会变，学员能看出差别。
	var victim := String(picked[0]) if picked.size() > 0 else ""
	if victim != "":
		_main.call("_on_unban_requested", victim)
		await _wait(0.9)
	await _shot("玩家-第3步 移除已选忍者")
	# 再点回来，后面步骤仍然是 3 个
	if victim != "":
		_main.call("_on_card_vote_toggled", victim, true)
		await _wait(0.7)

	# ---- 第4步：搜索忍者 ----
	var se: LineEdit = _main.get("_search_edit")
	if se != null:
		se.text = "鸣人"
		_main.call("_on_search_changed", "鸣人")
	await _wait(0.8)
	await _shot("玩家-第4步 搜索忍者")
	if se != null:
		se.text = ""
		_main.call("_on_search_changed", "")
	await _wait(0.6)

	# ---- 第5步：右键查看大图 ----
	var pv_photo := String(picked[0]) if picked.size() > 0 else ""
	if pv_photo != "":
		_main.call("_on_card_preview_requested", pv_photo)
		await _wait(0.9)
		await _shot("玩家-第5步 右键查看大图")
		var pv = _main.get_node_or_null("PreviewDialog")
		if pv != null:
			(pv as Window).hide()
			pv.queue_free()
			await _wait(0.4)

	# ---- 第6步：复制投票文本 ----
	_main.call("_on_copy_text_pressed")
	await _wait(0.9)
	await _shot("玩家-第6步 复制投票文本")
	var td = _main.get_node_or_null("VoteTextDialog")
	if td != null:
		(td as Window).hide()
		td.queue_free()
		await _wait(0.4)

	# ---- 第7步：导出投票文件 ----
	# 真实使用时会弹系统「选文件夹」；脚本里直接写到固定目录，再截「导出完成」
	var out_dir := ProjectSettings.globalize_path(EXPORT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_main.call("_export_to_folder", out_dir)
	await _wait(0.9)
	await _shot("玩家-第7步 导出投票文件")
	var ed = _main.get_node_or_null("ExportDoneDialog")
	if ed != null:
		(ed as Window).hide()
		ed.queue_free()
		await _wait(0.4)

	# ---- 第8步：改名（顺带展示入口）----
	_main.call("_prompt_for_name", false)
	await _wait(0.8)
	await _shot("玩家-第8步 改名")
	var nd = _main.get_node_or_null("NameDialog")
	if nd != null:
		(nd as Window).hide()
		nd.queue_free()
		await _wait(0.4)

	_main.queue_free()
	await _wait(0.6)


# ------------------------------------------------------------
#  组织者视角
# ------------------------------------------------------------
func _organizer_flow() -> void:
	print("\n=== 组织者视角 ===")
	# 先造一批「群友交上来的投票」，供导入演示
	_make_votes()
	# 名字要有（否则玩家界面会先弹取名窗，挡住口令门演示），
	# 但组织者解锁标记要清掉，这样才会弹口令门
	_reset_player("组织者")
	_write_user("voter_name.txt", "组织者")
	await get_tree().process_frame

	# ---- 第1步：进入组织者模式（口令门）----
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(1.4)
	_main.call("_on_organizer_pressed")
	await _wait(0.9)
	await _shot("组织者-第1步 输入口令")
	var pd = _main.get_node_or_null("PasswordDialog")
	if pd != null:
		(pd as Window).hide()
		pd.queue_free()
		await _wait(0.4)
	_main.queue_free()
	await _wait(0.5)

	# 跳过口令门，直接进组织者界面
	_write_user("organizer_unlocked.txt", "1")
	_org = (load("res://scenes/Organizer.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_org)
	await _wait(1.6)
	await _shot("组织者-第2步 组织者界面")

	# ---- 第3步：导入群友的投票 ----
	_org.call("_do_import", [VOTES_DIR])
	await _wait(1.6)
	await _shot("组织者-第3步 导入投票文件")

	# ---- 第4步：调整「取前 N 名」（真的改数量，画面上会多出第二排）----
	# 原来这里只是又截一次导入后的画面，和第3步一模一样。
	var top: SpinBox = _org.get("_top_spin")
	if top != null:
		top.value = 10
		await _wait(1.0)
	await _shot("组织者-第4步 调整显示前N名")

	# ---- 第5步：核对每人上限 ----
	var lim: SpinBox = _org.get("_limit_spin")
	if lim != null:
		lim.value = 5
		await _wait(0.9)
	await _shot("组织者-第5步 每人上限检查")

	# ---- 第6步：导出汇总 ----
	var out_dir := ProjectSettings.globalize_path(EXPORT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_org.call("_export_json_to", out_dir)
	_org.call("_export_txt_to", out_dir)
	await _org.call("_export_png_to", out_dir)
	await _wait(1.8)
	await _shot("组织者-第6步 导出汇总结果")

	# ---- 第7步：手动增减（进阶）----
	var raw: Dictionary = _org.get("_stats_raw")
	var ranking: Array = raw.get("ranking", [])
	if ranking.size() > 0:
		var photo := String((ranking[0] as Dictionary)["file"])
		_org.call("_bump", photo, 1)
		await _wait(0.9)
	await _shot("组织者-第7步 手动增减票数")

	# ---- 第8步：撤销手动调整 ----
	_org.call("_on_clear_manual")
	await _wait(0.8)
	await _shot("组织者-第8步 撤销手动调整")

	_org.queue_free()
	await _wait(0.5)


# ------------------------------------------------------------
#  工具
# ------------------------------------------------------------
func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("!! 截图失败：" + name)
		return
	var path := OUT.path_join(name + ".png")
	var err := img.save_png(path)
	print("  截图 %s (err=%d)" % [name, err])


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _clear_out() -> void:
	var d := DirAccess.open(OUT)
	if d == null:
		return
	for f in d.get_files():
		if f.to_lower().ends_with(".png"):
			DirAccess.remove_absolute(OUT.path_join(f))


func _clear_dir(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))


func _clear_user_data() -> void:
	var names: Array[String] = ["votes.json", "voter_name.txt", "voter_id.txt",
		"organizer_unlocked.txt"]
	for n in names:
		var p: String = "user://" + n
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## 重置成「全新玩家」：磁盘 + 内存
func _reset_player(name_to_set: String) -> void:
	_clear_user_data()
	var dm = get_node("/root/DataManager")
	dm.voter_name = name_to_set
	dm.clear_all()
	dm.reset_export_dir()


func _write_user(name: String, text: String) -> void:
	var p := "user://" + name
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


## 造 8 个群友的投票（文字形式，模拟群里发来的）
func _make_votes() -> void:
	_clear_dir(VOTES_DIR)
	var il = get_node("/root/ImageLoader")
	if il.photos.is_empty():
		il.scan_directory()
	var photos: Array = il.photos
	if photos.size() < 20:
		return
	var VT = load("res://scripts/vote_text.gd")

	var names := ["t2", "tk3", "tk4", "tk4345", "tk5", "tk6", "tk68768", "大傻逼"]
	var idx := 0
	for ni in range(names.size()):
		var nm := String(names[ni])
		var bans: Array = []
		for k in range(5 + (ni % 2)):
			var slot: int = (idx + k * 3) % 18
			var photo := String(photos[slot]["photo"])
			if bans.has(photo):
				continue
			bans.append(photo)
		idx += 1
		var entries: Array = []
		for b in bans:
			entries.append([String(b), il.get_display_name(String(b))])
		var block: String = VT.build_block(nm, entries)
		var f := FileAccess.open(VOTES_DIR.path_join("vote_%s.txt" % nm),
			FileAccess.WRITE)
		if f != null:
			f.store_string(block)
			f.close()
	print("  造了 8 份投票到 " + VOTES_DIR)
