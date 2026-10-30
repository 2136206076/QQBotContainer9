#!/usr/bin/env python3
"""SnowLuma 的 /proc/locks 兜底补丁（Termux / proot 版）——双路方案：结构化补丁优先。

背景：SnowLuma 靠读 /proc/locks 把「账号 → QQ 进程」对应起来。在 Android/proot 里
      /proc/locks 通常读不到（EACCES），于是账号识别永远失败、OneBot 起不来。

方案 A（首选，来自 2026-10-29 真机实测跑通过的 DSH 版部署包）：
      **结构化补丁** —— 精确改写 index.mjs 里的 getLinuxHolders() 这一个函数：
        ① 把 `const table = await fs$2.readFile("/proc/locks", "utf8");` 包进
           try/catch，读不到时 table = ""，不让整个函数抛异常；
        ② 在 `return holders;` 之前插入兜底：扫 /proc 找 QQ 主进程
           （跳过带 --type= 的子进程，用 isQqProcessName(name) 过滤）。
      改的是具体那一个函数，精度高、不依赖任何外部文件，所以优先走它。
      找不到锚点就**明确报错**，绝不猜 —— SnowLuma 版本变了要人工介入。

方案 B（兜底）：
      只有在方案 A 真的做不了（锚点没了）时才降级。做法是全局 monkey-patch
      fs.readFile / readFileSync / fs.promises.readFile，把对 /proc/locks 的访问
      重定向到 $SNOWLUMA_FAKE_LOCKS 替身文件（由 scripts/mkfake-locks.sh 用真实
      QQ 主进程 PID 生成）。
      弱点：替身文件有时效性（QQ 重启后 PID 变了、或没生成就失效），所以只作兜底，
      且降级时会在 stdout 明确打印「结构化补丁失败，已改用替身文件方案」+ 原因。

两条路共有的保障：
  · 幂等：命中任一方案的标记就跳过（--force 可强制重打）
  · 自动备份：改写前存一份 <file>.bak-snowluma-patch（已存在则不覆盖，避免二次覆盖备份）
  · --probe：只体检、不打补丁（会预判能走哪条路）
  · --force：忽略「已打过补丁」和「/proc/locks 可读」的判断，强制重打

用法：
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs          # 体检 + 打补丁
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs --probe  # 只体检
    python3 patch/patch_snowluma.py /opt/snowluma/index.mjs --force  # 强制重打

退出码：
    0  成功（方案 A）/ 已打过补丁跳过 / 本机 /proc/locks 可读、按设计不用打补丁
    1  两条路都做不了（会给出人工介入的具体指引）
    3  ⚠ 降级：方案 A 的锚点没了，实际写入的是方案 B（替身文件兜底）
       —— 这是**要人看一眼**的信号：补丁打上了，但精度不如方案 A，且替身文件
          有时效性。调用方**不要**因为它中断部署，打个醒目告警就行。

标记文件：
    每次真正跑完（--probe 只体检，不写）都会往
    ${STACK_DIR:-/opt/qqstack}/.locks-patch-method 写一笔，内容含：
      · method      —— A / B / NONE（NONE = 按设计没打补丁）
      · method_name —— 人话版的方案名
      · detail      —— 为什么走这条路 / 该怎么复核
      · target      —— 目标 index.mjs 路径
      · time        —— 本地时间
    以前成功、降级、跳过全都 return 0，调用方只能翻日志才分得清，容易被静默降级
    骗过去；现在人和脚本都能一眼查出来。写标记失败只告警，不影响退出码。
"""
import os
import re
import sys
import shutil
import time

# ==================== 方案 A：结构化补丁（首选）====================
# 标记：同时也是补丁正文里的第一行注释，幂等判断就靠它
STRUCT_MARK = '// [patch] /proc/locks 在 Android/proot 下不可读'

# 锚点 1：getLinuxHolders() 里读 /proc/locks 的那一行（注意是制表符缩进 + fs$2 这个
# 打包后的 fs 别名，别改成 fs —— 原函数作用域里就叫 fs$2）
STRUCT_OLD_READ = '\tconst table = await fs$2.readFile("/proc/locks", "utf8");'

# 锚点 2：getLinuxHolders() 的结尾（紧跟其后的那个函数用来确认没认错地方）
STRUCT_ANCHOR = '\treturn holders;\n}\nfunction deviceInodeKey(device, inode) {'

# 插到 `return holders;` 之前的兜底逻辑。
# 用到的 fs$2 / readProcessName / isQqProcessName / seen 都是原函数作用域里已有的标识符，
# 不要引入新名字，否则换了 SnowLuma 版本更容易崩。
STRUCT_FALLBACK = '''	if (!holders.length) {
		// [patch] /proc/locks 在 Android/proot 下不可读（EACCES），
		// 这里退化为"所有可见的 QQ 主进程"，让账号识别还能继续。
		let entries = [];
		try { entries = await fs$2.readdir("/proc"); } catch {}
		for (const entry of entries) {
			if (!/^\\d+$/.test(entry)) continue;
			const pid = Number(entry);
			try {
				const cmd = await fs$2.readFile(`/proc/${pid}/cmdline`, "utf8");
				if (!cmd || !cmd.includes("qq") || cmd.includes("--type=")) continue;
				const name = await readProcessName(pid);
				if (!isQqProcessName(name) || seen.has(pid)) continue;
				seen.add(pid);
				holders.push({ pid, name });
			} catch {}
		}
	}
'''

# ==================== 方案 B：替身文件（兜底）====================
SHIM_MARK = "SNOWLUMA_PROOT_PATCH"

SHIM = f"""
/* ==== {SHIM_MARK} : /proc/locks 兜底（proot 下读不到时改读替身文件） ==== */
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
}} catch (e) {{ console.warn('[{SHIM_MARK}] 注入失败:', e && e.message); }}
/* ==== {SHIM_MARK} END ==== */
"""

BAK_SUFFIX = ".bak-snowluma-patch"

# 替身文件生成脚本的位置：assets 的 qqstack/ 会整棵落到容器 /opt/qqstack，
# 本脚本在 /opt/qqstack/patch/ 下，所以生成脚本是同级 scripts/ 目录里那个。
MKFAKE_LOCKS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "mkfake-locks.sh"
)

# ==================== 退出码 ====================
EXIT_OK = 0        # 成功 / 已打过补丁跳过 / 按设计不用打补丁
EXIT_FAIL = 1      # 两条路都做不了
EXIT_FALLBACK = 3  # ⚠ 降级：实际走的是方案 B（替身文件兜底）

# ==================== 「本次走了哪条路」标记文件 ====================
# 成功 / 降级 / 跳过以前全都 return 0，只能靠日志分辨 —— 这里落成文件，方便人和脚本查。
METHOD_FILE_NAME = ".locks-patch-method"
DEFAULT_STACK_DIR = "/opt/qqstack"


def stack_dir():
    """容器里 qqstack 的根目录，等价于 shell 的 ${STACK_DIR:-/opt/qqstack}。

    注意：空字符串也算「没设」，跟 shell 的 :- 语义保持一致。
    """
    return os.environ.get("STACK_DIR") or DEFAULT_STACK_DIR


def method_file_path():
    """标记文件的完整路径。"""
    return os.path.join(stack_dir(), METHOD_FILE_NAME)


def write_method_marker(method, name, detail, target):
    """把本次实际走的路写进标记文件。

    Args:
        method: A / B / NONE（NONE = 按设计没打补丁）
        name:   人话版的方案名
        detail: 补充说明（为什么走这条路 / 该怎么复核）
        target: 目标 index.mjs 路径

    这个标记只是给人看的，写失败**只告警**，绝不能因为它把部署打断。
    """
    path = method_file_path()
    content = (
        f"method={method}\n"
        f"method_name={name}\n"
        f"detail={detail}\n"
        f"target={target}\n"
        f"time={time.strftime('%Y-%m-%d %H:%M:%S')}\n"
    )
    try:
        directory = os.path.dirname(path) or "."
        os.makedirs(directory, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  · 补丁方式标记已写入：{path}")
        print(f"    method={method}  （{name}）")
    except Exception as e:
        print(f"  ⚠ 写补丁方式标记失败（不影响部署）：{path} —— {type(e).__name__}: {e}")


def locks_readable():
    """体检 /proc/locks 在本机到底能不能读。

    Returns:
        True 表示能读；否则返回给人看的失败原因字符串。
    """
    try:
        with open("/proc/locks", "r") as f:
            f.read(1)
        return True
    except Exception as e:
        return f"{type(e).__name__}: {e}"


def find_hits(root):
    """在整个 SnowLuma 目录里定位 /proc/locks 的用法，方便手动改。"""
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


def try_structured_patch(src):
    """方案 A：改写 getLinuxHolders()。

    Returns:
        (新内容, None) 成功；
        (None, 失败原因) 锚点没找到 —— 交给上层降级到方案 B。
    """
    if STRUCT_OLD_READ not in src:
        return None, (
            "index.mjs 里找不到 getLinuxHolders() 读 /proc/locks 的那一行：\n"
            f"        期望 {STRUCT_OLD_READ.strip()!r}\n"
            "        → SnowLuma 大概升级过：fs 的别名（fs$2）或这段写法变了。"
        )
    if STRUCT_ANCHOR not in src:
        return None, (
            "index.mjs 里找不到 getLinuxHolders() 的结尾锚点：\n"
            "        期望 '\\treturn holders;\\n}\\nfunction deviceInodeKey(device, inode) {'\n"
            "        → SnowLuma 大概升级过：这个函数被拆分/改名/挪位置了。"
        )

    # ① 读 /proc/locks 包进 try/catch：读不到就当空表，别让函数抛异常
    new_read = (STRUCT_MARK + '\n'
                '\tlet table = "";\n'
                '\ttry {\n'
                '\t\ttable = await fs$2.readFile("/proc/locks", "utf8");\n'
                '\t} catch {\n'
                '\t\ttable = "";\n'
                '\t}')
    out = src.replace(STRUCT_OLD_READ, new_read, 1)

    # ② 在 return holders; 之前插入「扫 /proc 找 QQ 主进程」的兜底
    out = out.replace(STRUCT_ANCHOR, STRUCT_FALLBACK + STRUCT_ANCHOR, 1)
    return out, None


def build_shim(src):
    """方案 B：在文件最前面注入 fs.readFile 重定向。

    ESM 的 import 会被提升，补丁里自己也用 import，所以放在最前面是安全的。
    """
    return SHIM + "\n" + src


def backup(target):
    """改写前备份一份；备份已存在就不覆盖（否则二次运行会把补丁版盖进备份里）。"""
    bak = target + BAK_SUFFIX
    if os.path.exists(bak):
        return bak, False
    shutil.copy2(target, bak)
    return bak, True


def write_target(target, content):
    """写回目标文件（UTF-8）。"""
    with open(target, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    args = [a for a in sys.argv[1:]]
    flags = [a for a in args if a.startswith("--")]
    target = next((a for a in args if not a.startswith("--")), "/opt/snowluma/index.mjs")
    force = "--force" in flags

    print("== 1. /proc/locks 可读性 ==")
    r = locks_readable()
    if r is True:
        print("  ✓ /proc/locks 可读 —— 你的 proot 环境能读它")
        # 「能读」不等于「SnowLuma 一定不报错」：proot 下 /proc/locks 可能是空的，
        # 或者 SnowLuma 走的是另一条取锁路径。所以这里把「按设计不打补丁」说清楚，
        # 免得下次出问题了用户以为补丁早就打过了。
        print("    → 按设计此时**不打** /proc/locks 兜底补丁；")
        print("      如果 SnowLuma 仍报 EACCES /proc/locks，请加 --force 重跑本脚本。")
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

    if not os.path.isfile(target):
        print("== 3. 打补丁 ==")
        print(f"  ✗ 目标文件不存在：{target}")
        return EXIT_FAIL

    src = open(target, "r", encoding="utf-8", errors="replace").read()

    print("== 3. 方案 A：结构化补丁可行性 ==")
    if STRUCT_MARK in src or SHIM_MARK in src:
        # 已经打过了：锚点自然找不到了（被替换/追加过），别再报「锚点缺失、将降级」，
        # 否则日志看着像这次要降级，其实第 4 步会直接跳过。
        done = "结构化补丁（方案 A）" if STRUCT_MARK in src else "替身文件兜底（方案 B）"
        print(f"  · 检测到已打过 {done} —— 本次将跳过（加 --force 可从备份还原后重打）")
    else:
        probe_out, probe_reason = try_structured_patch(src)
        if probe_out is not None:
            print("  ✓ 两个锚点都在 —— 将按 getLinuxHolders() 结构化改写（方案 A）")
        else:
            print("  ✗ 锚点缺失 —— 将降级为替身文件方案（方案 B）")
            for line in probe_reason.splitlines():
                print(f"    {line}")

    if "--probe" in flags:
        # 只体检：不动文件、也不写标记文件
        print("  · --probe：只体检，不写补丁、不写标记文件")
        return EXIT_OK

    print("== 4. 补丁状态 ==")
    if STRUCT_MARK in src:
        if not force:
            print("  ✓ 已打过结构化补丁（方案 A），跳过")
            write_method_marker(
                "A", "结构化补丁（方案 A，已打过，本次跳过）",
                "幂等命中 STRUCT_MARK，未做改动；加 --force 可从备份还原后重打",
                target)
            return EXIT_OK
        # --force：先尽量用备份还原到原始版本，再重打，避免补丁叠加
        bak = target + BAK_SUFFIX
        if os.path.isfile(bak):
            src = open(bak, "r", encoding="utf-8", errors="replace").read()
            print(f"  · --force：已从备份还原原始版本再重打：{bak}")
        else:
            print(f"  ✗ --force 但找不到备份 {bak}，不敢在已打补丁的文件上再打一遍")
            return EXIT_FAIL
    elif SHIM_MARK in src:
        if not force:
            print("  ✓ 已打过替身文件补丁（方案 B），跳过")
            write_method_marker(
                "B", "替身文件兜底（方案 B，已打过，本次跳过）",
                "幂等命中 SHIM_MARK，未做改动；这是降级方案，建议核对 SnowLuma 版本后"
                "从备份还原、重打方案 A",
                target)
            return EXIT_OK
        bak = target + BAK_SUFFIX
        if os.path.isfile(bak):
            src = open(bak, "r", encoding="utf-8", errors="replace").read()
            print(f"  · --force：已从备份还原原始版本，重新尝试结构化补丁：{bak}")
        else:
            print(f"  ✗ --force 但找不到备份 {bak}，不敢重复注入替身文件补丁")
            return EXIT_FAIL

    print("== 5. 写入补丁 ==")
    new_src, reason = try_structured_patch(src)
    if new_src is not None:
        bak, created = backup(target)
        write_target(target, new_src)
        print(f"  ✓ 方案 A（结构化补丁）已写入 {target}")
        print(f"    {os.path.basename(target)}: 读 /proc/locks 包了 try/catch；"
              f"getLinuxHolders 加了扫 /proc 找 QQ 主进程的兜底")
        print(f"  {'✓' if created else '·'} 备份 {bak}"
              f"{'' if created else '（已存在，未覆盖）'}")
        write_method_marker(
            "A", "结构化补丁（方案 A，优选）",
            "精确改写 getLinuxHolders()：/proc/locks 读取包 try/catch + 扫 /proc 找"
            " QQ 主进程兜底；不依赖任何外部文件",
            target)
        return EXIT_OK

    # ---------- 降级：方案 A 做不了，明确说明原因后走方案 B ----------
    print("  ⚠ 结构化补丁失败，已改用替身文件方案")
    print(f"    原因：{reason}")
    print("    → 结构化补丁改的是具体那一个函数，精度最高；现在只能全局重定向"
          " fs.readFile 到替身文件。")

    if r is True and not force:
        print("  ✓ /proc/locks 可读，按设计不打补丁 —— 本次没有修改任何文件")
        print("    （如果你确认 SnowLuma 仍然报 EACCES /proc/locks，请加 --force 重跑本脚本）")
        write_method_marker(
            "NONE", "未打补丁：/proc/locks 可读",
            "本机 /proc/locks 能读，按设计不做兜底，未修改任何文件；若 SnowLuma 仍报"
            " EACCES /proc/locks，请加 --force 重跑本脚本",
            target)
        return EXIT_OK

    bak, created = backup(target)
    write_target(target, build_shim(src))
    print(f"  ⚠ 方案 B（替身文件）已写入 {target}")
    print(f"  {'✓' if created else '·'} 备份 {bak}"
          f"{'' if created else '（已存在，未覆盖）'}")
    print("  ⚠ 替身文件有时效性，QQ 重启后 PID 会变 —— 记得生成/刷新：")
    print(f"       bash {MKFAKE_LOCKS}")
    print("     （start-all.sh 等 OneBot 就绪的循环里也会自动刷新一次）")
    print("  ⚠ 退出码 3：这是降级成功，不是失败 —— 调用方请打醒目告警，别中断部署")
    write_method_marker(
        "B", "替身文件兜底（方案 B，降级）",
        "方案 A 的锚点缺失，已改用全局 fs.readFile 重定向到 $SNOWLUMA_FAKE_LOCKS；"
        "替身文件有时效性（QQ 重启后 PID 会变），建议核对 SnowLuma 版本后重打方案 A",
        target)
    return EXIT_FALLBACK


if __name__ == "__main__":
    sys.exit(main())
