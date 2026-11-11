# ============================================================
#  _shot.gd —— 开真窗口跑两个模式并截图（开发用，可删）
# ------------------------------------------------------------
#  为什么需要它：
#    headless 用的是 dummy 渲染器，做不到两件事：
#      1. 看不到界面排版对不对
#      2. PNG 导出（SubViewport.get_texture().get_image()）必然失败
#    所以这个脚本开真窗口跑一遍，把界面截图 + 验证 PNG 导出。
#
#  运行（不要加 --headless）：
#    & <godot.exe> --path . res://_shot.tscn
# ============================================================
extends Node

const OUT_DIR := "res://_shots"
const FIXTURE_SRC := "user://test_votes"

var _main: Control
var _org: Control


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await get_tree().process_frame
	DisplayServer.window_set_size(Vector2i(1280, 800))
	DisplayServer.window_set_position(Vector2i(50, 30))
	await get_tree().process_frame

	# 先给个名字，跳过首次启动的弹窗，直接看主界面
	var dm = get_node("/root/DataManager")
	dm.voter_name = "张三"
	dm.ensure_voter_id()
	dm.clear_all()
	dm.save()

	await _run_player_mode()
	await _run_organizer_mode()

	print("全部截图与验证完成，输出在 ", OUT_DIR)
	get_tree().quit(0)


# ---------------- 玩家模式 ----------------
func _run_player_mode() -> void:
	print("\n=== 玩家模式 ===")
	var il = get_node("/root/ImageLoader")
	il.max_load_count = 60        # 少加载一点，截图快

	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_main)
	await _wait(2.5)
	print("窗口标题：", get_window().title)
	await _shot("01_玩家模式_初始")

	# Ban 几个好认的
	var flow = _main.get_node("Root/VBox/Body/CardArea/CardScroll/CardFlow")
	var picked: Array[String] = []
	for c in flow.get_children():
		var nm := String(c.get("character_name"))
		if nm in ["漩涡鸣人", "宇智波佐助", "春野樱", "旗木卡卡西", "伊鲁卡"]:
			picked.append(String(c.get("photo")))
	for p in picked:
		_main.call("_on_card_vote_toggled", p, true)
		await _wait(0.15)
	await _wait(0.6)
	print("已 Ban %d 个：%s" % [picked.size(), str(picked)])
	var dm = get_node("/root/DataManager")
	print("DataManager 里 Ban 了 ", dm.get_ban_count(), " 个")
	await _shot("02_玩家模式_已Ban")
	# 右侧 Ban 名单面板（本轮新增）
	await _shot("02b_右侧Ban名单")

	# 右键查看大图：确认弹窗不再被撑到屏幕外
	if picked.size() > 0:
		_main.call("_on_card_preview_requested", picked[0])
		await _wait(1.0)
		var pv = _main.get_node_or_null("PreviewDialog")
		if pv != null:
			print("大图弹窗尺寸 = %s   （修复前是 480x2300）" % str((pv as Window).size))
		await _shot("02c_查看大图")
		if pv != null:
			(pv as Window).hide()
			pv.queue_free()
			await _wait(0.4)

	# 说明：导出位置现在改成「点导出 → 弹系统『选文件夹』」。
	# 那是操作系统的原生窗口，不在游戏视口里，截图抓不到，
	# 所以下面只用日志确认它被创建，并截「导出完成」弹窗。
	# 导出：先确认会弹「选文件夹」，再直接调写盘那一步截图
	var before := _count_files("user://exports")
	_main.call("_on_export_pressed")
	await _wait(0.6)
	print("选文件夹对话框是否弹出：", get_tree().root.find_child("FolderPicker", true, false) != null)
	# 关掉它（自检不真的点系统对话框）
	var fp = get_tree().root.find_child("FolderPicker", true, false)
	if fp != null:
		(fp as Window).hide()
		fp.queue_free()
	await _wait(0.3)
	_main.call("_export_to_folder", ProjectSettings.globalize_path("user://exports"))
	await _wait(1.0)
	await _shot("03_玩家模式_导出弹窗")
	var after := _count_files("user://exports")
	print("导出前后 exports 文件数：%d -> %d" % [before, after])

	# 关掉导出完成弹窗，再演示「复制投票文本」
	for c in _main.get_children():
		if c.name == "ExportDoneDialog":
			(c as Window).hide()
			c.queue_free()
	await _wait(0.4)
	_main.call("_on_copy_text_pressed")
	await _wait(1.0)
	await _shot("03b_复制投票文本")
	print("剪贴板内容长度：", DisplayServer.clipboard_get().length())

	_main.queue_free()
	await _wait(0.4)


# ---------------- 组织者模式 ----------------
func _run_organizer_mode() -> void:
	print("\n=== 组织者模式 ===")
	_org = (load("res://scenes/Organizer.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(_org)
	await _wait(1.5)
	await _shot("04_组织者模式_空")

	# 导入自检生成的假投票
	_org.call("_do_import", [FIXTURE_SRC])
	await _wait(1.5)
	var stats: Dictionary = _org.get("_stats")
	print("导入结果：参与 %d 人，被 Ban 过的忍者 %d 个" % [
		int(stats.get("voter_count", 0)), (stats.get("ranking", []) as Array).size()])
	await _shot("05_组织者模式_已汇总")

	# 演示「每人上限」检查：把上限设成 1，必然有人超
	var lim: SpinBox = _org.get("_limit_spin")
	if lim != null:
		lim.value = 1
		await _wait(0.8)
		await _shot("05b_每人上限检查")
		print("把每人上限设成 1，看有没有超")

	# 导出三件套（现在是先弹「选文件夹」；截图脚本直接调写盘那一步）
	var out_dir := ProjectSettings.globalize_path("user://exports")
	var ok_json: bool = _export_and_report("json", out_dir)
	var ok_txt: bool = _export_and_report("txt", out_dir)
	await _org.call("_export_png_to", out_dir)
	await _wait(1.5)
	var png_path := out_dir.path_join("final_result.png")
	var ok_png: bool = FileAccess.file_exists(png_path)
	print("导出 PNG：%s" % ("成功" if ok_png else "失败"))
	if ok_png:
		var img: Image = Image.load_from_file(png_path)
		if img != null:
			print("  汇总图尺寸：%d x %d" % [img.get_width(), img.get_height()])
			img.save_png(OUT_DIR.path_join("06_汇总结果图.png"))
	await _shot("07_组织者模式_导出后")

	_org.queue_free()
	await _wait(0.4)


func _export_and_report(kind: String, out_dir: String) -> bool:
	match kind:
		"json":
			_org.call("_export_json_to", out_dir)
		"txt":
			_org.call("_export_txt_to", out_dir)
	var path := out_dir.path_join("final_result.%s" % kind)
	var exists := FileAccess.file_exists(path)
	print("导出 %s：%s" % [kind.to_upper(), "成功" if exists else "失败"])
	if exists and kind == "txt":
		var txt := FileAccess.get_file_as_string(path)
		print("  TXT 内容前 3 行：")
		var lines := txt.split("\n")
		for i in range(mini(3, lines.size())):
			print("    " + lines[i])
	return exists


# ---------------- 工具 ----------------
func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _count_files(dir: String) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	return d.get_files().size()


func _shot(name: String) -> void:
	# 真窗口下 frame_post_draw 会正常触发
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		print("截图失败：", name)
		return
	var path := OUT_DIR.path_join(name + ".png")
	var err: int = img.save_png(path)
	print("截图 %s (err=%d)" % [name, err])
