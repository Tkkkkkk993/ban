# ============================================================
#  image_loader.gd —— Autoload「ImageLoader」
# ------------------------------------------------------------
#  职责：
#    1. 自动探测头像目录（优先可执行文件旁的目录，其次 res://）
#    2. 扫描目录下 .png/.jpg/.jpeg/.webp，用「文件名去扩展名」作为照片 ID
#    3. 后台线程分批加载图片，生成缩略图并缓存到 user://thumbs/
#    4. 对外提供取图接口（卡片、排名面板、结果弹窗共用同一份纹理缓存）
#
#  【为什么不用 ResourceLoader 加载图片】
#    实测 Godot 4.6.3 下对 res://...png 调用 Image.load_from_file() 会报
#      WARNING: Loaded resource as image file, this will not work on export
#    即「从 res:// 读图片在导出后的 exe 里不生效」。
#    所以本工程一律走「文件系统绝对路径 + FileAccess 读字节 + 从内存解码」，
#    完全不经过编辑器导入管线。这样：
#      · 编辑器里能跑，导出的 exe 里也能跑
#      · 运行中往目录里丢新头像，重新扫描即可生效，不用重启、不用重新导入
#      · 导出 pck 里不含头像，包体很小
#
#  【线程】只用一个后台线程串行解码，纹理创建放主线程。
# ============================================================
extends Node

## 扫描完成，参数为 [{name, photo, path, group, mtime}] 数组
signal scan_finished(found: bool, items: Array)
## 一批缩略图加载完成，参数为 [{photo, texture}] 数组
signal batch_loaded(items: Array)
## 队列清空、本轮请求全部完成
signal all_loaded()
## 单张图片损坏/读取失败
signal image_failed(photo: String, reason: String)

const MAX_LOAD_COUNT := 9999          # 默认首次加载张数（不限制；数量由目录内容决定）
const BATCH_SIZE := 8                 # 每帧最多转成纹理的张数（防止一帧塞太多）
const THUMB_SIZE := 128               # 缩略图边长
const SUPPORTED_EXT := ["png", "jpg", "jpeg", "webp"]
const THUMB_DIR := "user://thumbs"
const META_FILE := "characters.json"

## 候选头像目录名。按顺序探测，取第一个存在的。
const CANDIDATE_DIRS := [
	"characters", "avatars", "images", "touxiang", "head", "头像",
	"忍者头像参考",   # 原始素材目录名，保留兼容
]

## 检视面板可调：默认首次加载张数
@export var max_load_count: int = MAX_LOAD_COUNT

## 缩略图边长（想在检视面板调就改这里；缓存文件名不含尺寸，改了要清 user://thumbs）
@export var thumbnail_size: int = THUMB_SIZE

## 「加载更多」按钮每次追加的张数
@export var extra_load_count: int = 200

# ---------------- 运行时状态 ----------------
var avatar_dir := ""                       # 探测到的头像目录
var avatar_dir_is_external := false        # true = 来自可执行文件旁的外部目录
var photos: Array[Dictionary] = []         # 全部扫描结果
var groups: Array[String] = []             # 全部分组名（来自 characters.json）

var _index: Dictionary = {}                # photo -> photos 下标（O(1) 查找）
var _memory_images: Dictionary = {}        # photo -> Image（缩略图，已转好格式）
var _textures: Dictionary = {}             # photo -> ImageTexture
var _meta: Dictionary = {}                 # photo(小写) -> {name, group}
var _invalidated: Dictionary = {}          # photo -> true 表示缓存不可信，强制重做
var _texture_resolver: Callable = Callable()   # 可替换的取纹理实现（默认走 get_thumbnail）

var _loading := false
var _requested := 0                        # 已提交的照片数
var _finished := 0

# ---------------- 后台线程 ----------------
var _thread: Thread = null
var _mutex := Mutex.new()
var _queue: Array = []                     # 待处理：[{photo, path, mtime, force_file}]
var _results: Array = []                   # 已完成：[{photo, image, from_cache, mtime}]
var _wake := Semaphore.new()
var _quit := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(THUMB_DIR)
	_start_worker()


func _exit_tree() -> void:
	_quit = true
	_wake.post()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


# ============================================================
#  目录探测 / 扫描
# ============================================================

## 探测头像目录。返回目录路径，找不到返回空字符串。
## 顺序很重要：先看 exe 同级（导出后玩家自带素材），再看 res://（编辑器里就是工程根目录）。
func detect_avatar_dir() -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	for d in CANDIDATE_DIRS:
		var p: String = exe_dir.path_join(String(d))
		if DirAccess.dir_exists_absolute(p):
			avatar_dir_is_external = true
			return p
	for d in CANDIDATE_DIRS:
		var p: String = "res://" + String(d)
		if DirAccess.dir_exists_absolute(p):
			avatar_dir_is_external = false
			return p
	return ""


## 扫描头像目录。返回 [{name, photo, path, group, mtime}]。
## name 是可显示的忍者名（characters.json 里有就用它，否则等于 photo）。
func scan_directory() -> Array[Dictionary]:
	photos.clear()
	groups.clear()
	_meta.clear()
	_invalidated.clear()
	_index.clear()

	avatar_dir = detect_avatar_dir()
	if avatar_dir == "":
		scan_finished.emit(false, [])
		return photos

	_load_meta_file()

	var d := DirAccess.open(avatar_dir)
	if d == null:
		push_warning("[ImageLoader] 无法打开头像目录：%s" % avatar_dir)
		scan_finished.emit(false, [])
		return photos

	var files := d.get_files()
	files.sort()
	var gset := {}
	for f in files:
		var ext := f.get_extension().to_lower()
		if not SUPPORTED_EXT.has(ext):
			continue
		var photo := f.get_basename()
		var full := _to_fs_path(avatar_dir.path_join(f))
		var meta: Dictionary = _meta.get(photo.to_lower(), {})
		var grp := String(meta.get("group", ""))
		if grp != "":
			gset[grp] = true
		_index[photo] = photos.size()
		photos.append({
			"name": String(meta.get("name", photo)),
			"photo": photo,
			"path": full,
			"group": grp,
			"mtime": _safe_mtime(full),
		})

	groups.assign(gset.keys())
	groups.sort()
	scan_finished.emit(true, photos)
	return photos


## 把 res:// 路径转成真实文件系统路径，便于 FileAccess 直读。
## 编辑器里 res:// 就是工程根目录，所以映射成绝对路径即可；
## 导出后若走外部目录，本来就已经是绝对路径，原样返回。
func _to_fs_path(p: String) -> String:
	if p.begins_with("res://"):
		return ProjectSettings.globalize_path(p)
	return p


## 取文件修改时间；取不到就返回 0（退化成「不参与缓存校验」）
func _safe_mtime(path: String) -> int:
	return int(FileAccess.get_modified_time(path))


## 读取可选的 characters.json 元数据。支持两种写法：
##   { "90001_headshot": {"name": "漩涡鸣人", "group": "木叶"} }
##   { "90001_headshot": "漩涡鸣人" }
func _load_meta_file() -> void:
	var path := _to_fs_path(avatar_dir.path_join(META_FILE))
	if not FileAccess.file_exists(path):
		return
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[ImageLoader] %s 不是合法的 JSON 对象，已忽略。" % META_FILE)
		return
	for k in parsed.keys():
		var key := String(k)
		var val = parsed[k]
		if typeof(val) == TYPE_DICTIONARY:
			_meta[key.to_lower()] = {
				"name": String(val.get("name", key)),
				"group": String(val.get("group", "")),
			}
		elif typeof(val) == TYPE_STRING:
			_meta[key.to_lower()] = {"name": String(val), "group": ""}
		else:
			_meta[key.to_lower()] = {"name": key, "group": ""}


## 按照片 ID 找一条扫描记录（O(1)）
func find_photo(photo: String) -> Dictionary:
	if photo == "":
		return {}
	var i = _index.get(photo, -1)
	if typeof(i) == TYPE_INT and int(i) >= 0 and int(i) < photos.size():
		return photos[int(i)]
	return {}


## 按照片 ID 取显示名（找不到映射就回退成照片 ID）
func get_display_name(photo: String) -> String:
	var rec := find_photo(photo)
	if rec.is_empty():
		return photo
	var n := String(rec["name"])
	return n if n != "" else photo


# ============================================================
#  加载调度
# ============================================================

func is_loading() -> bool:
	return _loading


## 已提交/完成的照片数量
func get_requested_count() -> int:
	return _requested


## 本次会话已经出图的张数
func get_finished_count() -> int:
	return _finished


## 异步加载一批：从 photos 的第 start 个开始，提交 count 张。
## 图片在线程里解码 + 缩成缩略图并缓存到 user://thumbs/，
## 主线程每帧最多取 BATCH_SIZE 张转成 ImageTexture 后发 batch_loaded。
func load_batch(start: int, count: int) -> void:
	if photos.is_empty():
		return
	var end: int = mini(start + count, photos.size())
	if start >= end:
		all_loaded.emit()
		return

	_loading = true
	_mutex.lock()
	for i in range(start, end):
		var item: Dictionary = photos[i]
		_queue.append({
			"photo": item["photo"],
			"path": item["path"],
			"mtime": item["mtime"],
			# res:// 来源的图必须走 FileAccess 直读，
			# 否则导出后 Image.load_from_file() 读不到（见文件头说明）
			"force_file": not avatar_dir_is_external,
		})
		_requested = maxi(_requested, i + 1)
	_wake.post()
	_mutex.unlock()


## 追加加载 extra_load_count 张（「加载更多」按钮）
func load_more() -> void:
	load_batch(_requested, extra_load_count)


## 一次性加载全部剩余（「全部加载」按钮）
func load_all() -> void:
	if photos.is_empty():
		return
	load_batch(_requested, photos.size() - _requested)


## 清空队列并停止本轮加载
func cancel_pending() -> void:
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	_loading = false


func _start_worker() -> void:
	if _thread != null and _thread.is_started():
		return
	_thread = Thread.new()
	_thread.start(_worker_loop)


func _worker_loop() -> void:
	while true:
		if _quit:
			return
		var item: Dictionary = {}
		_mutex.lock()
		if not _queue.is_empty():
			item = _queue.pop_front()
		_mutex.unlock()
		if item.is_empty():
			_wake.wait()
			continue

		var out := _process_one(item)
		if out.is_empty():
			continue
		_mutex.lock()
		_results.append(out)
		_mutex.unlock()


## 线程内：取缓存或生成缩略图。返回 {photo, image, from_cache, mtime}
func _process_one(item: Dictionary) -> Dictionary:
	var photo := String(item["photo"])
	var path := String(item["path"])
	var mtime := int(item["mtime"])
	var force_file := bool(item.get("force_file", false))

	var img: Image = null
	var from_cache := false

	# 1) 命中缩略图缓存就直接读缓存
	if not _invalidated.has(photo):
		var cache_path := thumb_cache_path(photo, mtime)
		if FileAccess.file_exists(cache_path):
			var cached := Image.load_from_file(cache_path)
			if cached != null and not cached.is_empty():
				img = cached
				from_cache = true
			else:
				# 缓存文件坏了：标记失效，强制重做
				_invalidated[photo] = true

	# 2) 没命中就原图解码 + 缩放
	if img == null:
		var src := _load_image_file(path, force_file)
		if src == null or src.is_empty():
			call_deferred("_emit_failed", photo, "图片无法解码（可能已损坏或路径不可读）")
			return {}
		img = _make_thumb(src)

	return {"photo": photo, "image": img, "from_cache": from_cache, "mtime": mtime}


## 从文件读一张图。
## prefer_file=true 时用 FileAccess 读字节 + 从内存解码（导出后也能用）。
## 两条路都失败就返回 null，由调用方跳过。
func _load_image_file(path: String, prefer_file: bool) -> Image:
	var ext := path.get_extension().to_lower()

	if prefer_file:
		var bytes := _read_bytes(path)
		if bytes.is_empty():
			push_warning("[ImageLoader] 读不到文件字节：%s" % path)
			return null
		var img := _decode_bytes(bytes, ext)
		if img != null and not img.is_empty():
			return img
		push_warning("[ImageLoader] 字节解码失败：%s" % path)
		return null

	# 非 res://（外部目录）时直接读文件即可
	if not path.begins_with("res://"):
		var direct := Image.load_from_file(path)
		if direct != null and not direct.is_empty():
			return direct
		var bytes2 := _read_bytes(path)
		if bytes2.is_empty():
			return null
		return _decode_bytes(bytes2, ext)

	# res:// 且有导入缓存的场景：先试正常加载，失败再退回字节流
	var via_res := Image.load_from_file(path)
	if via_res != null and not via_res.is_empty():
		return via_res
	var bytes3 := _read_bytes(path)
	if bytes3.is_empty():
		return null
	return _decode_bytes(bytes3, ext)


## 按照片 ID 取原始整图（右键看大图用），失败返回 null
func load_full_image(photo: String) -> Image:
	var rec := find_photo(photo)
	if rec.is_empty():
		return null
	var img := _load_image_file(String(rec["path"]), not avatar_dir_is_external)
	if img == null or img.is_empty():
		return null
	return img


## 读原始字节（走真实文件系统路径，导出后同样可用）
func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


## 按扩展名从内存解码
func _decode_bytes(bytes: PackedByteArray, ext: String) -> Image:
	var img := Image.new()
	var err := FAILED
	match ext:
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		_:
			# 扩展名不认识时逐个试
			err = img.load_png_from_buffer(bytes)
			if err != OK:
				err = img.load_jpg_from_buffer(bytes)
			if err != OK:
				err = img.load_webp_from_buffer(bytes)
	if err != OK:
		return null
	return img


## 生成缩略图：等比缩到不超过 thumbnail_size 的方框内
func _make_thumb(src: Image) -> Image:
	var im := src.duplicate() as Image
	im.convert(Image.FORMAT_RGBA8)
	var w := im.get_width()
	var h := im.get_height()
	if w <= 0 or h <= 0:
		return im
	var side := maxi(1, thumbnail_size)
	var scale_f: float = float(side) / float(maxi(w, h))
	var nw: int = maxi(1, int(round(w * scale_f)))
	var nh: int = maxi(1, int(round(h * scale_f)))
	if nw != w or nh != h:
		im.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	return im


func _emit_failed(photo: String, reason: String) -> void:
	push_warning("[ImageLoader] 跳过 %s：%s" % [photo, reason])
	image_failed.emit(photo, reason)


# ============================================================
#  每帧收割线程结果 → 主线程建纹理
# ============================================================
func _process(_delta: float) -> void:
	var budget := BATCH_SIZE
	var out: Array = []
	while budget > 0:
		var item: Dictionary = {}
		_mutex.lock()
		if not _results.is_empty():
			item = _results.pop_front()
		_mutex.unlock()
		if item.is_empty():
			break

		var photo := String(item["photo"])
		var img: Image = item["image"]
		var mtime := int(item["mtime"])

		# 缓存未命中时，把刚做好的缩略图写盘（写盘放主线程更稳）
		if not bool(item["from_cache"]):
			var cache := thumb_cache_path(photo, mtime)
			var err: int = img.save_png(cache)
			if err != OK:
				# 缓存写不进去不算致命，内存里照样有图
				push_warning("[ImageLoader] 缩略图写盘失败：%s (err=%d)" % [photo, err])
			else:
				_invalidated.erase(photo)

		_memory_images[photo] = img
		_textures[photo] = ImageTexture.create_from_image(img)
		out.append({"photo": photo, "texture": _textures[photo]})
		budget -= 1

	if not out.is_empty():
		_finished += out.size()
		batch_loaded.emit(out)

	if _loading:
		_mutex.lock()
		var empty: bool = _queue.is_empty() and _results.is_empty()
		_mutex.unlock()
		if empty:
			_loading = false
			all_loaded.emit()


# ============================================================
#  取图接口
# ============================================================

## 缩略图缓存路径。照片 ID + 修改时间参与命名，源图一改缓存自动失效。
func thumb_cache_path(photo: String, mtime: int) -> String:
	var raw := "%s|%d|%d" % [photo, mtime, thumbnail_size]
	var key := raw.sha256_text().substr(0, 24)
	return THUMB_DIR.path_join(key + ".png")


## 取缩略图纹理；内存里没有就同步补一次（单张，很快）。
## 传照片 ID 或完整路径都能识别。
## 注意：正常情况下请用 resolve_texture()，它会走可替换的实现。
func get_thumbnail(path_or_photo: String) -> Texture2D:
	var photo := path_or_photo.get_file().get_basename()
	if photo == "":
		photo = path_or_photo
	if _textures.has(photo):
		return _textures[photo]

	var rec := find_photo(photo)
	if rec.is_empty():
		return null
	var mtime := int(rec["mtime"])

	var img: Image = null
	var mem = _memory_images.get(photo, null)
	if mem is Image:
		img = mem
	if img == null:
		var cache_path := thumb_cache_path(photo, mtime)
		if FileAccess.file_exists(cache_path) and not _invalidated.has(photo):
			img = Image.load_from_file(cache_path)
		if img == null or img.is_empty():
			var src := _load_image_file(String(rec["path"]), not avatar_dir_is_external)
			if src == null or src.is_empty():
				return null
			img = _make_thumb(src)
		if img == null or img.is_empty():
			return null
		_memory_images[photo] = img

	var tex := ImageTexture.create_from_image(img)
	_textures[photo] = tex
	return tex


## 是否已经出过图（未出图时排名面板会用占位方块）
func has_texture(photo: String) -> bool:
	return _textures.has(photo)


## 已加载的纹理数量
func get_texture_count() -> int:
	return _textures.size()


## 释放纹理缓存（内存吃紧时的兜底，卡片会重新取图）
func purge_textures() -> void:
	_textures.clear()


## 换一个「取纹理」的实现。默认就是 get_thumbnail；
## 自检脚本会把它换成更省内存的版本，避免加载上千张全图。
func set_texture_resolver(fn: Callable) -> void:
	if fn.is_valid():
		_texture_resolver = fn


## 统一的取纹理入口（内部都走这里，方便替换实现）
func resolve_texture(photo: String) -> Texture2D:
	if _texture_resolver.is_valid():
		return _texture_resolver.call(photo)
	return get_thumbnail(photo)


## 头像目录不存在时的提示文案
func get_missing_dir_hint() -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	return "没有找到头像目录。\n\n请把忍者头像放进下面任意一个目录：\n%s\n\n或者放在程序旁边：\n%s\n\n放好后点工具栏的「重新扫描」即可，不用重启。" % [
		"、".join(CANDIDATE_DIRS.slice(0, 6)), exe_dir]
