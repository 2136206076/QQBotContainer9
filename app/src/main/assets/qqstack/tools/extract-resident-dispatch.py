#!/usr/bin/env python3
"""从 SnowLuma 主库里导出 resident dispatch 载荷（libsnowluma_linux_resident_dispatch.so）。

这个文件为什么必须存在（绕 proot 的 workaround）：
    SnowLuma 运行时会把 hook 的 resident dispatch 载荷写进 memfd，然后调
    dlopen("/proc/self/fd/N") 从内存加载。在 proot 容器里 memfd 版 dlopen 加载不成，
    于是我们的 LD_PRELOAD 载入器 bin/slhook.c 在 dlopen 拦截器里做了兜底：
    把 memfd / /proc/self/fd/ 这类路径换成磁盘路径 $SNOWLUMA_RESIDENT_SO
    （默认 /opt/qqstack/libsnowluma_linux_resident_dispatch.so）再让真正的 dlopen 去加载。

    问题是官方发布包**从不单独提供**这个磁盘版 .so，于是拦截器 fallback 到一个
    不存在的文件上：dlopen 失败 → hook 退回 stub → SnowLuma 永远 awaiting readiness。

    好消息：SnowLuma 主库 native/snowluma-linux-arm64.so 文件内部本来就**内嵌**了一份
    完整的载荷 ELF（外层 .so 之后紧接着第二个 \x7fELF）。本脚本把它搜出来、解析它的
    ELF64 header 算出真实长度、裁剪写出到目标路径，让 slhook.c 的磁盘兜底真正 Available。

    ⚠ 偏移和长度**都必须运行时算**，不能写死：SnowLuma 一升级，内嵌位置就会变。
    ⚠ 主库里可能有**多个** \x7fELF（数据段里碰巧出现、或上游改了打包方式），
      所以候选之间必须用 PAYLOAD_HINT（resident_dispatch）做**硬约束**筛选，
      不能只取「第一个结构合法的」——否则会导出一段看着像、其实错的片段。

用法：
    python3 tools/extract-resident-dispatch.py                     # 默认路径，幂等
    python3 tools/extract-resident-dispatch.py --force             # 强制重新导出
    python3 tools/extract-resident-dispatch.py --source X --target Y
    python3 tools/extract-resident-dispatch.py --to-eof            # 取到源文件尾（对账用）
    python3 tools/extract-resident-dispatch.py --allow-unverified  # 没匹配到特征也强行导出

退出码：
    0  成功，或目标文件已是最新（幂等，什么都不做）
    1  出错：每一步都有中文说明，且**不会留下半截文件**（先写临时文件再原子替换）
    2  载荷疑似不对：所有候选都没有 resident_dispatch 特征，默认**拒绝写出**
       （宁可失败也不给错文件）；加 --allow-unverified 才降级为「写出 + 告警」
"""
import argparse
import hashlib
import os
import struct
import sys

# ---- 默认路径（容器内布局）----
DEFAULT_SOURCE = "/opt/snowluma/native/snowluma-linux-arm64.so"
DEFAULT_TARGET = "/opt/qqstack/libsnowluma_linux_resident_dispatch.so"

# ---- 已知基准值（真实 SnowLuma v2.1.1 主库实测，与部署文档附录 A 双向吻合）----
# 载荷起始偏移 0x24C00 = 150528，主库共 191560 字节 → 到文件尾 41032 字节。
# 「精确截断」版：按 ELF64 header（段头表/节头表末尾）算出来 14528 字节，
#                 已覆盖 PT_LOAD 最大的 p_offset+p_filesz（12568），尾部 26504 字节是无用数据。
# 「到文件尾」版：41032 字节，这个才是对着部署文档附录 A 的 md5 校验用的（--to-eof）。
KNOWN_OFFSET = 0x24C00                  # 150528
KNOWN_TRUNCATED_SIZE = 14528
KNOWN_TRUNCATED_MD5 = "d4ffd409bc0e1cbd4e4cb3e1ac1aeeba"
KNOWN_TO_EOF_SIZE = 41032
KNOWN_TO_EOF_MD5 = "73809b76bfc3c368e63eace3fcff991c"

# ---- 期望的「QQ × SnowLuma」配对（见部署文档 Version 对照表）----
# 这套 hook 载荷与客户端是**硬配对**的：版本不对的表现是「全都起来了、但 SnowLuma
# 永远 awaiting readiness」，而且不报错，最难查。所以只要产物对不上基准，
# 就把这张对照表抛给用户，让他先确认版本配对。
EXPECT_QQ_VERSION = "3.2.32-52194"
EXPECT_QQ_ARCH = "arm64"
EXPECT_SNOWLUMA_VERSION = "2.1.1"
EXPECT_SNOWLUMA_TARGET = "linux-arm64"

# ---- ELF 常量 ----
ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2          # e_ident[EI_CLASS]
ELFDATA2LSB = 1         # e_ident[EI_DATA]，小端
ET_DYN = 3              # e_type：共享库
EM_AARCH64 = 183        # e_machine：arm64
EHDR64_SIZE = 64        # ELF64 header 大小
PHENT64_SIZE = 56       # ELF64 program header 表项大小
SHENT64_SIZE = 64       # ELF64 section header 表项大小
MIN_SOURCE_SIZE = EHDR64_SIZE * 2   # 至少放得下外层头 + 一个载荷头

PT_LOAD = 1             # p_type：可加载段
PT_DYNAMIC = 2          # p_type：动态段
DT_NULL = 0             # d_tag：动态表结束
DT_STRTAB = 5           # d_tag：动态字符串表地址
DT_STRSZ = 10           # d_tag：动态字符串表大小
DT_SONAME = 14          # d_tag：SONAME 在字符串表里的下标
PHDR64_FMT = "<IIQQQQQQ"
PHDR64_FIELDS = (
    "p_type", "p_flags", "p_offset", "p_vaddr", "p_paddr",
    "p_filesz", "p_memsz", "p_align",
)
DYN64_FMT = "<QQ"       # d_tag, d_un
DYN64_SIZE = 16
MAX_DYN_ENTRIES = 8192  # 动态表项上限，防越界死循环

# e_ident 之后那 48 字节的 ELF64 header 字段
HEADER_FMT = "<HHIQQQIHHHHHH"
HEADER_FIELDS = (
    "e_type", "e_machine", "e_version", "e_entry", "e_phoff", "e_shoff",
    "e_flags", "e_ehsize", "e_phentsize", "e_phnum", "e_shentsize", "e_shnum",
    "e_shstrndx",
)

# 载荷的 SONAME / 动态符号串里应当出现这个名字 —— **硬约束**：挑候选时用它筛，
# 挑不出来就拒绝写出（除非显式 --allow-unverified）。
PAYLOAD_HINT = b"resident_dispatch"

# hint 命中分：分高的候选优先，分数相同时取偏移小的
HINT_NONE = 0           # 没命中
HINT_IN_PAYLOAD = 1     # 只在整段载荷里命中（动态字符串表没取到，弱匹配）
HINT_IN_DYNSTR = 2      # 在动态字符串表（SONAME / 动态符号名）里命中，强匹配

# 载荷没匹配到特征、且调用方没放行时的退出码（区别于 1=普通出错，方便 shell 侧识别）
EXIT_UNVERIFIED = 2

TARGET_MODE = 0o755


class ExtractError(Exception):
    """带中文说明的可预期失败。"""


def md5_of(data: bytes) -> str:
    """返回一段字节的 MD5（十六进制小写）。"""
    return hashlib.md5(data).hexdigest()


def read_source(path: str) -> bytes:
    """读取 SnowLuma 主库，顺手做存在性 / 大小 / 是否 ELF 的体检。"""
    if not os.path.isfile(path):
        raise ExtractError(
            f"找不到 SnowLuma 主库：{path}\n"
            f"  → SnowLuma 装了吗？正常应在 ${{SNOWLUMA_DIR:-/opt/snowluma}}/native/ 下。"
        )
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise ExtractError(f"读不了源文件 {path}：{e}")
    if len(data) < MIN_SOURCE_SIZE:
        raise ExtractError(
            f"源文件太小（{len(data)} 字节，至少要有 {MIN_SOURCE_SIZE}）：{path}\n"
            f"  → 文件可能没下全，重装 SnowLuma 试试。"
        )
    if not data.startswith(ELF_MAGIC):
        raise ExtractError(
            f"源文件开头不是 ELF magic：{path}\n"
            f"  → 它可能还是个压缩包或下载了一半，先 file {path} 看看。"
        )
    return data


def iter_elf_offsets(data: bytes, start: int = 1):
    """从 start 开始依次找出所有 ELF magic 的位置（第 0 个是外层库自己，跳过）。"""
    pos = data.find(ELF_MAGIC, start)
    while pos != -1:
        yield pos
        pos = data.find(ELF_MAGIC, pos + 1)


def parse_elf64_header(data: bytes, offset: int) -> dict:
    """在 offset 处解析 ELF64 header；不是合法的 ELF64 就返回 None。"""
    if offset + EHDR64_SIZE > len(data):
        return None
    ident = data[offset:offset + 16]
    if ident[4] != ELFCLASS64 or ident[5] != ELFDATA2LSB:
        return None
    values = struct.unpack_from(HEADER_FMT, data, offset + 16)
    return dict(zip(HEADER_FIELDS, values))


def payload_size(header: dict, offset: int, total: int) -> int:
    """载荷真实长度 = max(节头表末尾, 段头表末尾)。

    Returns:
        正常返回正数长度；0 表示两张表都是空的（算不出长度）；
        -1 表示算出来的长度超出源文件剩余范围。
    """
    sh_end = header["e_shoff"] + header["e_shnum"] * header["e_shentsize"]
    ph_end = header["e_phoff"] + header["e_phnum"] * header["e_phentsize"]
    size = max(sh_end, ph_end)
    if offset + size > total:
        return -1
    if size <= 0:
        return 0
    return size


def validate_header(header: dict, size: int) -> str:
    """逐项体检，返回空串表示通过，否则返回给人看的失败原因。"""
    if header["e_type"] != ET_DYN:
        return f"不是动态库（e_type={header['e_type']}，应为 {ET_DYN}）"
    if header["e_machine"] != EM_AARCH64:
        return f"不是 arm64（e_machine={header['e_machine']}，应为 {EM_AARCH64}）"
    if header["e_ehsize"] != EHDR64_SIZE:
        return f"header 尺寸异常（e_ehsize={header['e_ehsize']}）"
    if header["e_phnum"] and header["e_phentsize"] != PHENT64_SIZE:
        return f"段头表项尺寸异常（e_phentsize={header['e_phentsize']}）"
    if header["e_shnum"] and header["e_shentsize"] != SHENT64_SIZE:
        return f"节头表项尺寸异常（e_shentsize={header['e_shentsize']}）"
    if size <= 0:
        return "段头表和节头表都是空的，算不出载荷长度"
    return ""


def read_program_headers(payload: bytes, header: dict) -> list:
    """读出段头表；表是空的、尺寸不对或越界就返回空列表。"""
    count = header["e_phnum"]
    entsize = header["e_phentsize"]
    if count <= 0 or entsize < PHENT64_SIZE:
        return []
    table_end = header["e_phoff"] + count * entsize
    if table_end > len(payload):
        return []
    segments = []
    for index in range(count):
        offset = header["e_phoff"] + index * entsize
        segments.append(dict(zip(PHDR64_FIELDS, struct.unpack_from(PHDR64_FMT, payload, offset))))
    return segments


def vaddr_to_offset(segments: list, vaddr: int) -> int:
    """用 PT_LOAD 段把虚拟地址换算成文件偏移；换算不出来返回 -1。"""
    for seg in segments:
        if seg["p_type"] != PT_LOAD or seg["p_filesz"] <= 0:
            continue
        if seg["p_vaddr"] <= vaddr < seg["p_vaddr"] + seg["p_filesz"]:
            return seg["p_offset"] + (vaddr - seg["p_vaddr"])
    return -1


def extract_dynstr(payload: bytes, header: dict) -> bytes:
    """尽力取出动态字符串表（SONAME 和动态符号名都在里面），取不到返回空字节串。

    走的是标准路子：PT_DYNAMIC → DT_STRTAB/DT_STRSZ → 用 PT_LOAD 把虚址换成文件偏移。
    任一步对不上就返回空，交给上层降级处理，不硬猜。
    """
    segments = read_program_headers(payload, header)
    if not segments:
        return b""
    dyn_offset = -1
    for seg in segments:
        if seg["p_type"] == PT_DYNAMIC:
            dyn_offset = seg["p_offset"]
            break
    if dyn_offset < 0 or dyn_offset >= len(payload):
        return b""
    strtab_vaddr = None
    strtab_size = 0
    pos = dyn_offset
    for _ in range(MAX_DYN_ENTRIES):
        if pos + DYN64_SIZE > len(payload):
            return b""
        tag, value = struct.unpack_from(DYN64_FMT, payload, pos)
        if tag == DT_NULL:
            break
        if tag == DT_STRTAB and strtab_vaddr is None:
            strtab_vaddr = value
        elif tag == DT_STRSZ and not strtab_size:
            strtab_size = value
        pos += DYN64_SIZE
    if strtab_vaddr is None:
        return b""
    strtab_offset = vaddr_to_offset(segments, strtab_vaddr)
    if strtab_offset < 0 or strtab_offset >= len(payload):
        return b""
    if strtab_size <= 0 or strtab_offset + strtab_size > len(payload):
        # 尺寸不靠谱就别猜了，返回空让上层按「没取到 dynstr」处理
        return b""
    return payload[strtab_offset:strtab_offset + strtab_size]


def hint_score(payload: bytes, header: dict) -> int:
    """给候选载荷打「像不像 resident dispatch」的分，越大越可信。

    Returns:
        HINT_IN_DYNSTR(2)：动态字符串表（SONAME / 动态符号名）里命中 PAYLOAD_HINT；
        HINT_IN_PAYLOAD(1)：dynstr 取不到，只在整段载荷里命中（弱匹配）；
        HINT_NONE(0)：完全没命中。
    """
    dynstr = extract_dynstr(payload, header)
    if dynstr and PAYLOAD_HINT in dynstr:
        return HINT_IN_DYNSTR
    if PAYLOAD_HINT in payload:
        return HINT_IN_PAYLOAD
    return HINT_NONE


def locate_payload(data: bytes, source_path: str) -> tuple:
    """在主库里定位内嵌载荷，返回 (偏移, 头部字典, 长度, hint 命中分)。

    主库里可能有好几个结构合法的 ELF64（数据段里碰巧出现的 magic、或上游换了打包
    方式都可能造出来）。这里**先收集全部合法候选**，再按 (hint 分降序, 偏移升序) 挑
    最好的那个 —— 命中 resident_dispatch 特征的候选永远压过没命中的，避免被诱饵骗走。
    """
    magic_offsets = list(iter_elf_offsets(data))
    if not magic_offsets:
        # 这是最可能发生的"版本变了"场景，给最明确的提示
        raise ExtractError(
            f"SnowLuma 主库里没有内嵌载荷：{source_path}\n"
            f"  → 在整个 {len(data)} 字节里只找到文件头那一个 \\x7fELF。\n"
            f"  → 可能 SnowLuma 升级后换了加载方式（比如不再内嵌、或改成别的容器格式）。\n"
            f"  → 排查：strings -a '{source_path}' | grep -i resident"
        )
    candidates = []
    offsets_tried = []
    for offset in magic_offsets:
        header = parse_elf64_header(data, offset)
        if header is None:
            continue
        # 可能出现多个合法 ELF：先全部收下来，最后再按 hint 分排序挑
        size = payload_size(header, offset, len(data))
        if size > 0:
            reason = validate_header(header, size)
        elif size == 0:
            reason = "段头表和节头表都是空的，算不出载荷长度"
        else:
            reason = (f"载荷长度越界：偏移 {offset} 起放不下它自己声称的"
                      f"段头表/节头表，而源文件只有 {len(data)} 字节")
        if reason:
            offsets_tried.append(f"    偏移 {offset}：{reason}")
            continue
        candidates.append((offset, header, size))
    if not candidates:
        detail = "\n".join(offsets_tried) if offsets_tried else "    没有一个是合法的 ELF64 头"
        raise ExtractError(
            f"找到了 {len(magic_offsets)} 个 ELF magic，但都不是能用的 resident dispatch 载荷：\n"
            f"{detail}\n"
            f"  → 疑似 SnowLuma 版本变了，把 {source_path} 发出来定位。"
        )
    scored = []
    for offset, header, size in candidates:
        score = hint_score(data[offset:offset + size], header)
        scored.append((-score, offset, header, size))
    scored.sort(key=lambda item: (item[0], item[1]))
    neg_score, offset, header, size = scored[0]
    return offset, header, size, -neg_score


def already_up_to_date(target: str, payload: bytes) -> bool:
    """目标文件已存在且内容和本次要写的完全一致 → True（幂等跳过）。"""
    if not os.path.isfile(target):
        return False
    try:
        with open(target, "rb") as f:
            existing = f.read()
    except OSError:
        return False
    return existing == payload


def looks_like_target_missing_source(target: str) -> bool:
    """源文件没了但目标还在且像正常 ELF：这种情况下不算失败，跳过即可。"""
    try:
        with open(target, "rb") as f:
            head = f.read(EHDR64_SIZE)
    except OSError:
        return False
    return len(head) == EHDR64_SIZE and head.startswith(ELF_MAGIC) \
        and head[4] == ELFCLASS64 and head[5] == ELFDATA2LSB


def write_atomically(target: str, payload: bytes) -> None:
    """先写同目录临时文件、fsync 后再 os.replace 原子替换，避免留下半截文件。"""
    directory = os.path.dirname(target) or "."
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as e:
        raise ExtractError(f"建不了目标目录 {directory}：{e}")
    tmp_path = os.path.join(directory, "." + os.path.basename(target) + ".tmp")
    try:
        with open(tmp_path, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_path, TARGET_MODE)
        os.replace(tmp_path, target)
    except OSError as e:
        # 清理临时文件，别把半成品留在 /opt/qqstack 里
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise ExtractError(f"写目标文件失败 {target}：{e}")


def report_hint(offset: int, size: int, score: int) -> None:
    """把「挑中的这段到底像不像 resident dispatch」说清楚，存疑一律走 stderr。"""
    hint_text = PAYLOAD_HINT.decode()
    if score >= HINT_IN_DYNSTR:
        print(f"[extract]   ✓ 载荷的动态字符串表（SONAME/动态符号串）里含 "
              f"'{hint_text}'，确认是 resident dispatch")
    elif score == HINT_IN_PAYLOAD:
        print(f"[extract]   ⚠ 只在整段载荷里找到 '{hint_text}'，动态字符串表没取到（弱匹配）："
              f"偏移 {offset} / {size} 字节，建议 readelf -d 复核", file=sys.stderr)
    else:
        print(f"[extract] ✗✗✗ 疑似挑错了片段：偏移 {offset} 起的 {size} 字节里"
              f"没有 '{hint_text}' 特征", file=sys.stderr)
        print("[extract]    未能匹配到 resident_dispatch 载荷特征，导出结果可能不正确",
              file=sys.stderr)


def report_version_pairing_warning(reason: str) -> None:
    """统一提示：产物可疑时，先排除「SnowLuma 版本变了 / 跟 QQ 没配对」这个根因。

    hook 的 resident dispatch 载荷是从 SnowLuma 主库里抠的，主库一升级偏移和长度就会变；
    而 QQ 与 SnowLuma 又是硬配对的 —— 版本不对就卡在 awaiting readiness 且无报错。

    Args:
        reason: 本次可疑的具体表现（没命中特征 / MD5 对不上基准）。
    """
    print(f"[extract] ⚠ {reason}", file=sys.stderr)
    print("[extract]   SnowLuma 版本可能已升级，请对照 Version 对照表确认 QQ 与 SnowLuma 配对：",
          file=sys.stderr)
    print(f"[extract]     · QQ       期望 {EXPECT_QQ_VERSION}（{EXPECT_QQ_ARCH}）",
          file=sys.stderr)
    print(f"[extract]     · SnowLuma 期望 {EXPECT_SNOWLUMA_VERSION}"
          f"（{EXPECT_SNOWLUMA_TARGET}）", file=sys.stderr)
    print(f"[extract]   本脚本的基准就是 SnowLuma {EXPECT_SNOWLUMA_VERSION} 实测出来的："
          f"精确截断 {KNOWN_TRUNCATED_SIZE} 字节 / {KNOWN_TRUNCATED_MD5}，"
          f"到文件尾 {KNOWN_TO_EOF_SIZE} 字节 / {KNOWN_TO_EOF_MD5}。", file=sys.stderr)


def report_baseline(size: int, md5: str) -> None:
    """把两个已知基准 MD5 打出来，方便对着部署文档附录 A 人工对账。

    基准来自真实 SnowLuma v2.1.1 主库实测（载荷起始偏移 0x24C00 = 150528）：
      精确截断版 14528 字节 / d4ffd409…   到文件尾版 41032 字节 / 73809b76…
    后者正是部署文档附录 A 里记录的那个 md5。
    """
    print("[extract] 对账基准（真实 SnowLuma v2.1.1 主库实测，同部署文档附录 A）：")
    for label, b_size, b_md5 in (
        ("精确截断（默认）", KNOWN_TRUNCATED_SIZE, KNOWN_TRUNCATED_MD5),
        ("到文件尾(--to-eof)", KNOWN_TO_EOF_SIZE, KNOWN_TO_EOF_MD5),
    ):
        mark = "   ← 本次产物" if (b_size == size and b_md5 == md5) else ""
        print(f"[extract]   {label:<20} {b_size:>6} 字节   MD5 {b_md5}{mark}")
    print(f"[extract]   要与部署文档附录 A 对账，请加 --to-eof 导出：得到 {KNOWN_TO_EOF_MD5} "
          f"即一致，说明载荷偏移和抠法都正确。")


def extract(source: str, target: str, force: bool, allow_unverified: bool = False,
            to_eof: bool = False) -> int:
    """主流程：读源 → 定位载荷 → 幂等判断 → 原子写出。返回退出码。"""
    if os.path.isfile(target) and not os.path.isfile(source) \
            and looks_like_target_missing_source(target):
        print(f"[extract] 源已不在（{source}），但目标 {target} 还在且是正常 ELF，跳过")
        return 0

    data = read_source(source)
    try:
        offset, header, size, score = locate_payload(data, source)
    except ExtractError as e:
        # 连载荷都定位不到，最常见根因是 SnowLuma 升级/装错版本。
        # 把配对对照表一起抛出来，省得用户只看见一句「疑似版本变了」而无从下手。
        print(f"[extract] ✗ {e}", file=sys.stderr)
        report_version_pairing_warning("载荷定位失败，先排除 QQ × SnowLuma 版本配对问题")
        return 1
    mode_text = "按 ELF64 header 精确截断"
    if to_eof:
        # --to-eof：一直取到源文件尾（尾部是无用数据，但这样才对得上部署文档附录 A 的 md5）
        size = len(data) - offset
        mode_text = "--to-eof：取到源文件末尾"
        if size <= 0:
            raise ExtractError(f"载荷偏移 {offset} 已在源文件末尾之后（{len(data)} 字节）")
    payload = data[offset:offset + size]
    payload_md5 = md5_of(payload)

    print(f"[extract] 源文件   {source}")
    print(f"[extract]   大小   {len(data)} 字节   MD5 {md5_of(data)}")
    print(f"[extract] 载荷偏移 {offset}（0x{offset:X}）   长度 {size} 字节（{mode_text}）"
          f"   （e_type={header['e_type']} e_machine={header['e_machine']}）")
    if offset == KNOWN_OFFSET:
        print(f"[extract]   ✓ 偏移与基准一致（0x24C00 = {KNOWN_OFFSET}）")
    report_hint(offset, size, score)

    # 与已知基准对账：对不上（长度或 MD5 任一不同）就提示可能是 SnowLuma 版本变了
    expected_size = KNOWN_TO_EOF_SIZE if to_eof else KNOWN_TRUNCATED_SIZE
    expected_md5 = KNOWN_TO_EOF_MD5 if to_eof else KNOWN_TRUNCATED_MD5
    if size != expected_size or payload_md5 != expected_md5:
        report_version_pairing_warning(
            f"本次产物 {size} 字节 / MD5 {payload_md5}，与 SnowLuma "
            f"{EXPECT_SNOWLUMA_VERSION} 基准（{expected_size} 字节 / {expected_md5}）不一致")

    if score == HINT_NONE:
        # 没匹配到特征：在下面拒绝写出之前，先把版本配对的提示抛出来
        report_version_pairing_warning(
            f"PAYLOAD_HINT（'{PAYLOAD_HINT.decode()}'）未命中，挑中的片段疑似不对")
        # 没匹配到特征：默认**拒绝写出**（宁可失败也不给错文件），
        # 调用方显式 --allow-unverified 才降级成「写出 + 醒目告警」。
        print(f"[extract]    主库里所有结构合法的候选都没命中特征，"
              f"继续写出只会得到一段看着像、实际错的 .so", file=sys.stderr)
        print(f"[extract]    排查：strings -a '{source}' | grep -i resident "
              f"（看看是不是 SnowLuma 升级后改了内嵌方式）", file=sys.stderr)
        if not allow_unverified:
            print(f"[extract] ✗ 拒绝写出 {target}：目标文件保持原样，本次不做任何改动",
                  file=sys.stderr)
            print("[extract]   确认这份载荷确实对、只是名字改了的话，"
                  "显式加 --allow-unverified 强行导出", file=sys.stderr)
            return EXIT_UNVERIFIED
        print(f"[extract]   ⚠ 已按 --allow-unverified 放行，继续写出 {target}（结果自负）",
              file=sys.stderr)

    if already_up_to_date(target, payload) and not force:
        print(f"[extract] 目标已是最新，跳过：{target}")
        print(f"[extract]   MD5 {payload_md5}")
        report_baseline(size, payload_md5)
        return 0

    previous = md5_of(open(target, "rb").read()) if os.path.isfile(target) else "（原本不存在）"
    write_atomically(target, payload)
    with open(target, "rb") as f:
        written_md5 = md5_of(f.read())
    print(f"[extract] 已导出   {target}")
    print(f"[extract]   权限   {oct(TARGET_MODE)}   大小 {os.path.getsize(target)} 字节")
    print(f"[extract]   MD5   {written_md5}   （替换前 {previous}）")
    report_baseline(size, written_md5)
    print("[extract] ✓ libslhook.so 的磁盘兜底路径现在有文件了，重启 QQ 即可装上 hook")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="从 SnowLuma 主库导出 resident dispatch 载荷（绕 proot 下 memfd dlopen）",
        epilog=(
            "载荷筛选的硬约束：主库里可能出现多个结构合法的 ELF64，脚本会先用 "
            f"PAYLOAD_HINT（'{PAYLOAD_HINT.decode()}'）给每个候选打分（命中动态字符串表得分最高），"
            "再按分数挑——命中特征的候选永远压过没命中的。所有候选都没命中时默认拒绝写出"
            "（退出码 2），需要显式 --allow-unverified 才放行。\n"
            "对账：加 --to-eof 导出到源文件尾的版本，MD5 应为 "
            f"{KNOWN_TO_EOF_MD5}（{KNOWN_TO_EOF_SIZE} 字节），与部署文档附录 A 一致即为正确；"
            "默认（精确截断）版本的基准是 "
            f"{KNOWN_TRUNCATED_MD5}（{KNOWN_TRUNCATED_SIZE} 字节）。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--source", default=DEFAULT_SOURCE, help=f"SnowLuma 主库（默认 {DEFAULT_SOURCE}）")
    ap.add_argument("--target", default=DEFAULT_TARGET, help=f"输出路径（默认 {DEFAULT_TARGET}）")
    ap.add_argument("--force", action="store_true", help="目标已存在也强制重新导出")
    ap.add_argument(
        "--to-eof",
        action="store_true",
        help=("取到源文件末尾而不按 ELF64 header 精确截断（尾部是无用数据，但这样才对得上"
              f"部署文档附录 A 的 md5 {KNOWN_TO_EOF_MD5} / {KNOWN_TO_EOF_SIZE} 字节）"),
    )
    ap.add_argument(
        "--allow-unverified",
        action="store_true",
        help="载荷没匹配到 resident_dispatch 特征时也写出（默认拒绝，退出码 2）",
    )
    args = ap.parse_args()
    try:
        return extract(args.source, args.target, args.force, args.allow_unverified, args.to_eof)
    except ExtractError as e:
        print(f"[extract] ✗ {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
