# -*- coding: utf-8 -*-
"""
build_characters_json.py —— 由「忍者id4月6号.json」生成头像目录的 characters.json

映射依据（按优先级）：
  1. icon_id  == 文件名去扩展名
  2. res_id   == 文件名去扩展名
  3. str(id)  == 文件名去扩展名

输出：
  <头像目录>/characters.json      { "20001": {"name": "...", "group": ""}, ... }
以及控制台的匹配率报告 + 未匹配清单，方便人工补。

用法：
  python build_characters_json.py            # 只做 DRY RUN 预览
  python build_characters_json.py --write    # 真正写文件
"""
import io
import json
import os
import re
import sys
import collections

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS_DIR)           # 工程根目录（本脚本放在 tools/ 下）
ID_FILE = os.path.join(ROOT, "忍者id4月6号.json")
AVATAR_DIR = os.path.join(ROOT, "忍者头像参考")
OUT_FILE = os.path.join(AVATAR_DIR, "characters.json")

WRITE = "--write" in sys.argv


def main():
    # ---------- 1. 读 ID 表 ----------
    with io.open(ID_FILE, encoding="utf-8") as f:
        rows = json.load(f)
    print("ID 表条目数:", len(rows))

    lookup = {}          # key -> (name, source)
    lookup_by_id = {}    # str(id) -> name
    for r in rows:
        if not isinstance(r, dict):
            continue
        name = (r.get("name") or "").strip()
        if not name:
            continue
        for key_field in ("icon_id", "res_id"):
            v = r.get(key_field)
            if v is None:
                continue
            k = str(v).strip()
            if k:
                lookup.setdefault(k, (name, key_field))
        v = r.get("id")
        if v is not None:
            k = str(v).strip()
            lookup_by_id.setdefault(k, name)
            lookup.setdefault(k, (name, "id"))

    # ---------- 2. 扫描头像 ----------
    files = sorted(
        f for f in os.listdir(AVATAR_DIR)
        if f.lower().endswith((".png", ".jpg", ".jpeg", ".webp"))
    )
    print("头像文件数:", len(files))

    # 文件名形如 90001_headshot.png / 90001_1_headshot.png / 90393_headshot@2.png
    # 取「第一个下划线之前的数字段」作为查找 key。
    out = {}
    unmatched = []
    matched_by = collections.Counter()
    for fn in files:
        stem = os.path.splitext(fn)[0]
        key = stem.split("_")[0]
        got = lookup.get(key)
        if got is None:
            unmatched.append((stem, key))
            continue
        name, src = got
        matched_by[src] += 1
        out[stem] = {"name": name, "group": ""}

    print()
    print("=== 匹配结果 ===")
    print("已匹配: %d / %d (%.1f%%)" % (len(out), len(files),
                                      100.0 * len(out) / max(1, len(files))))
    print("命中字段分布:", dict(matched_by))
    print("产出的不同忍者名: %d 个" % len(set(v["name"] for v in out.values())))

    # ---------- 3. 重名检查（同一名字对应多个头像：形态/皮肤，程序里各算一项） ----------
    name_count = collections.Counter(v["name"] for v in out.values())
    multi = [(n, c) for n, c in name_count.most_common(20) if c > 1]
    print()
    print("=== 同名多头像（前 20，程序里会各算一个可投票项）===")
    for n, c in multi:
        print("  %s x%d" % (n, c))

    # ---------- 4. 未匹配清单 ----------
    print()
    print("=== 未匹配（共 %d 个，程序里会回退显示文件名 ID）===" % len(unmatched))
    for stem, key in unmatched:
        print("  %-28s key=%s" % (stem, key))

    # ---------- 5. 关键抽查 ----------
    print()
    print("=== 抽查 ===")
    for probe in ("20001_headshot", "40001_headshot", "90001_headshot",
                  "90001_1_headshot", "99002_headshot", "90372_Portrait",
                  "21746_headshot", "90393_headshot@2"):
        v = out.get(probe)
        print("  %-24s -> %s" % (probe, v["name"] if v else "(无)"))

    # ---------- 6. 写文件 ----------
    if WRITE:
        with io.open(OUT_FILE, "w", encoding="utf-8", newline="\n") as f:
            f.write("{\n")
            items = sorted(out.items())
            for i, (k, v) in enumerate(items):
                comma = "," if i < len(items) - 1 else ""
                f.write('  %s: { "name": %s, "group": "" }%s\n' % (
                    json.dumps(k, ensure_ascii=False),
                    json.dumps(v["name"], ensure_ascii=False),
                    comma))
            f.write("}\n")
        print()
        print("已写出:", OUT_FILE, "(%d 条, %.1f KB)" % (
            len(out), os.path.getsize(OUT_FILE) / 1024.0))
    else:
        print()
        print("（DRY RUN，未写文件。加 --write 才会写出 %s）" % OUT_FILE)


if __name__ == "__main__":
    main()
