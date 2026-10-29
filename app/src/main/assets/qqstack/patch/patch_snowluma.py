#!/usr/bin/env python3
"""SnowLuma 的 /proc/locks 兜底补丁（Termux / proot 版）

背景：DSH 版部署包里的 patch_snowluma.py 是为 Android/proot 写的，它把
      SnowLuma 读 /proc/locks（用来把"账号 → QQ 进程"对应起来）改成扫 /proc。
      本脚本是当你手上没有原版补丁时的兜底实现，特点：

  1. 先体检：/proc/locks 在**你这台机器**上到底能不能读。
     Termux + proot-distro 是直通 /proc 的，有些机器其实能读 —— 能读就别打补丁。
  2. 能读 → 什么都不改，直接退出。
  3. 读不了 → 在 index.mjs 顶部注入一段 monkey-patch：
     把 fs.readFile / fs.readFileSync / fs.promises.readFile 对 /proc/locks 的访问
     重定向到 $SNOWLUMA_FAKE_LOCKS（默认 /opt/qqstack/fake-locks），
     该文件由 scripts/mkfake-locks.sh 用真实 QQ 主进程 PID 生成。
  4. 幂等（有标记就跳过）、自动备份（.bak-snowluma-patch）。

用法：
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs          # 体检 + 按需打补丁
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs --probe  # 只体检定位
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs --force  # 不管能不能读都打
"""
import os
import re
import sys
import shutil
import subprocess

MARK = "SNOWLUMA_PROOT_PATCH"

SHIM = f"""
/* ==== {MARK} : /proc/locks 兜底（proot 下读不到时改读替身文件） ==== */
import __slFs from 'node:fs';
import __slFsP from 'node:fs/promises';
const __SL_LOCKS = process.env.SNOWLUMA_FAKE_LOCKS || '/opt/qqstack/fake-locks';
const __slIsLocks = (p) => p === '/proc/locks' || p === 'proc/locks';
try {{
  const __origSync = __slFs.readFileSync;
  __slFs.readFileSync = function (p, ...a) {{
    if (__slIsLocks(p)) {{
      try {{ return __origSync.call(__slFs, __SL_LOCKS, ...a); }} catch (e) {{
        return __origSync.call(__slFs, __SL_LOCKS, 'utf8');
      }}
    }}
    return __origSync.call(__slFs, p, ...a);
  }};
  const __origCb = __slFs.readFile;
  __slFs.readFile = function (p, ...a) {{
    if (__slIsLocks(p)) return __origCb.call(__slFs, __SL_LOCKS, ...a);
    return __origCb.call(__slFs, p, ...a);
  }};
  try {{
    const __origP = __slFsP.readFile;
    __slFsP.readFile = async function (p, ...a) {{
      if (__slIsLocks(p)) return __origP.call(__slFsP, __SL_LOCKS, ...a);
      return __origP.call(__slFsP, p, ...a);
    }};
  }} catch (e) {{}}
}} catch (e) {{ console.warn('[{MARK}] 注入失败:', e && e.message); }}
/* ==== {MARK} END ==== */
"""


def locks_readable():
    try:
        with open("/proc/locks", "r") as f:
            f.read(1)
        return True
    except Exception as e:
        return f"{type(e).__name__}: {e}"


def find_hits(root):
    """在整个 SnowLuma 目录里定位 /proc/locks 的用法，方便手动改"""
    hits = []
    pat = re.compile(rb"['\"]/proc/locks['\"]")
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git")]
        for fn in filenames:
            if not fn.endswith((".mjs", ".js", ".cjs")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                data = open(path, "rb").read()
            except Exception:
                continue
            for m in pat.finditer(data):
                line = data[: m.start()].count(b"\n") + 1
                hits.append((path, line))
                break
    return hits


def main():
    args = [a for a in sys.argv[1:]]
    flags = [a for a in args if a.startswith("--")]
    target = next((a for a in args if not a.startswith("--")), "/opt/snowluma/index.mjs")

    print("== 1. /proc/locks 可读性 ==")
    r = locks_readable()
    if r is True:
        print("  ✓ 可读 —— 你的 proot 环境能读 /proc/locks")
    else:
        print(f"  ✗ 读不了：{r}")

    print("== 2. 定位 /proc/locks 的用法 ==")
    root = os.path.dirname(os.path.abspath(target)) or "/opt/snowluma"
    hits = find_hits(root)
    if hits:
        for path, line in hits[:20]:
            print(f"  · {path}:{line}")
    else:
        print("  （没在源码里找到 '/proc/locks' 字面量，可能是拼接出来的路径）")

    if "--probe" in flags:
        return 0

    if not os.path.isfile(target):
        print(f"  ✗ 目标文件不存在：{target}")
        return 1

    src = open(target, "r", encoding="utf-8", errors="replace").read()
    if MARK in src:
        print("== 3. 补丁状态 ==")
        print("  ✓ 已打过补丁，跳过（要重打先删掉 index.mjs 再还原备份）")
        return 0

    if r is True and "--force" not in flags:
        print("== 3. 补丁状态 ==")
        print("  ✓ /proc/locks 能读，不需要打补丁，不做任何修改")
        print("    （如果你确认 SnowLuma 仍然报 EACCES /proc/locks，加 --force 再跑一次）")
        return 0

    print("== 3. 写入补丁 ==")
    bak = target + ".bak-snowluma-patch"
    if not os.path.exists(bak):
        shutil.copy2(target, bak)
        print(f"  ✓ 备份 → {bak}")
    # 注入到最前面（ESM 的 import 会被提升，但补丁里也用 import，安全）
    open(target, "w", encoding="utf-8").write(SHIM + "\n" + src)
    print(f"  ✅ 补丁已写入 {target}")
    print("  记得生成替身文件：bash scripts/mkfake-locks.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
