# ============================================================
#  ui_file_picker.gd —— 共用的「选一个文件夹」弹窗
# ------------------------------------------------------------
#  为什么单独抽出来：
#    玩家端「导出我的投票」和组织者端三个导出按钮，都需要让用户
#    自己选导出位置（不再偷偷写到 AppData 里）。
#
#  起始目录的优先级：上次用过的目录 → 桌面 → 文档 → 用户主目录。
#  这样弹出来就是用户熟悉的地方，不会莫名其妙停在 C 盘深处。
# ============================================================
class_name UIFilePicker
extends RefCounted

## 选一个起始目录（都不可用时返回空串，让系统自己决定）
static func default_start_dir(hint: String = "") -> String:
	var h := hint.strip_edges()
	if h != "" and DirAccess.dir_exists_absolute(h):
		return h
	# 桌面最顺手，其次文档、下载，最后用环境变量兜底
	# （注意：OS 没有 SYSTEM_DIR_HOME 这个枚举，别想当然）
	var tries: Array = [
		OS.SYSTEM_DIR_DESKTOP,
		OS.SYSTEM_DIR_DOCUMENTS,
		OS.SYSTEM_DIR_DOWNLOADS,
	]
	for sys in tries:
		var d := OS.get_system_dir(int(sys))
		if d != "" and DirAccess.dir_exists_absolute(d):
			return d
	# 兜底：用户主目录
	for env_name in ["USERPROFILE", "HOME"]:
		var home := OS.get_environment(String(env_name))
		if home != "" and DirAccess.dir_exists_absolute(home):
			return home
	return ""


## 弹出「选择文件夹」对话框。
## parent     : 挂到哪个节点上（一般是当前场景根节点）
## title      : 对话框标题
## start_dir  : 起始目录（传上次用过的；无效会自动换成桌面/文档）
## on_ok      : 选中后回调，参数是绝对目录路径
static func pick_folder(parent: Node, title: String, start_dir: String,
		on_ok: Callable) -> void:
	if parent == null:
		return
	var dlg := FileDialog.new()
	dlg.name = "FolderPicker"
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.title = title
	var sd := default_start_dir(start_dir)
	if sd != "":
		dlg.current_dir = sd

	dlg.dir_selected.connect(func(picked: String) -> void:
		dlg.queue_free()
		if on_ok.is_valid():
			on_ok.call(picked))
	dlg.canceled.connect(func() -> void: dlg.queue_free())
	parent.add_child(dlg)
	dlg.popup_centered(Vector2i(880, 620))
