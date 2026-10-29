#!/usr/bin/env python3
"""
构建前把 proot 弄进 jniLibs。

为什么这么绕：Android 10+ 不允许 App exec 自己数据目录里的文件（W^X / SELinux），
唯一保证可执行的目录是 APK 的 nativeLibraryDir，而这里只接受 lib*.so 命名的文件。
所以 Termux / UserLAnd 的通行做法就是把可执行程序改名成 .so 塞进 jniLibs。

本脚本从 Termux 官方仓库（packages.termux.dev）取 aarch64 的
proot / libtalloc / libandroid-shmem 三个 deb，拆包后改名放到：
    app/src/main/jniLibs/arm64-v8a/libproot.so
    app/src/main/jniLibs/arm64-v8a/libproot-loader.so
    app/src/main/jniLibs/arm64-v8a/libtalloc.so
    app/src/main/jniLibs/arm64-v8a/libandroid-shmem.so

手动放文件也可以，放好了就跳过下载。proot 是 GPL-2.0，分发 APK 时需同时提供源码
（termux/proot 仓库），README 里已写。
用法：python3 tools/fetch-proot.py [--force]
"""
import io
import os
import sys
import stat
import urllib.request
import gzip
import tarfile

REPO = "https://packages.termux.dev/apt/termux-main"
ARCH = "aarch64"
WANT = {
    "proot": ["bin/proot", "libexec/proot/loader"],
    "libtalloc": ["lib/libtalloc.so.2"],
    "libandroid-shmem": ["lib/libandroid-shmem.so"],
}
OUTNAME = {
    "bin/proot": "libproot.so",
    "libexec/proot/loader": "libproot-loader.so",
    "lib/libtalloc.so.2": "libtalloc.so",
    "lib/libandroid-shmem.so": "libandroid-shmem.so",
}
ROOT = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(ROOT, "..", "app", "src", "main", "jniLibs", "arm64-v8a")


def get(url, binary=True):
    req = urllib.request.Request(url, headers={"User-Agent": "fetch-proot/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    return data if binary else data.decode("utf-8", "replace")


def packages_index():
    for path in (f"dists/stable/main/binary-{ARCH}/Packages.gz",
                 f"dists/stable/main/binary-{ARCH}/Packages"):
        try:
            raw = get(f"{REPO}/{path}")
            if path.endswith(".gz"):
                raw = gzip.decompress(raw)
            return raw.decode("utf-8", "replace")
        except Exception as e:
            print(f"  · {path} 取不到：{e}")
    raise SystemExit("✗ 拿不到 Packages 索引，检查网络")


def latest(idx, name):
    """在这个 Packages 索引里找指定包名的最新版本条目"""
    best, cur = None, {}
    for line in idx.splitlines():
        if not line.strip():
            if cur.get("Package") == name:
                best = cur
            cur = {}
            continue
        if line.startswith(" "):
            continue
        k, _, v = line.partition(": ")
        cur[k] = v.strip()
    if cur.get("Package") == name:
        best = cur
    if not best:
        raise SystemExit(f"✗ 索引里没有 {name}")
    return best


def ar_extract(deb, wanted_suffixes):
    """deb 是 ar 归档：'!<arch>' + 若干 [60字节头][数据]。返回 {成员名: bytes}"""
    assert deb[:8] == b"!<arch>\n", "不是 ar 归档"
    pos, out = 8, {}
    while pos + 60 <= len(deb):
        hdr = deb[pos:pos + 60]
        name = hdr[0:16].decode().strip()
        try:
            size = int(hdr[48:58].decode().strip())
        except Exception:
            break
        pos += 60
        data = deb[pos:pos + size]
        pos += size + (size % 2)
        if any(name.startswith(s) for s in wanted_suffixes):
            out[name] = data
    return out


def main():
    force = "--force" in sys.argv
    os.makedirs(DEST, exist_ok=True)
    if not force and all(os.path.exists(os.path.join(DEST, n)) for n in
                         ("libproot.so", "libproot-loader.so", "libtalloc.so", "libandroid-shmem.so")):
        print("✓ jniLibs 里 proot 四件套已齐，跳过（要重下加 --force）")
        return 0

    print(f"· 仓库 {REPO}  架构 {ARCH}")
    idx = packages_index()
    os.makedirs("/tmp/qqbot-proot", exist_ok=True)

    for pkg, members in WANT.items():
        e = latest(idx, pkg)
        print(f"· {pkg} {e.get('Version')}  ← {e['Filename']}")
        deb = get(f"{REPO}/{e['Filename']}")
        parts = ar_extract(deb, ("data.tar",))
        blob = next(v for k, v in parts.items() if k.startswith("data.tar"))
        with tarfile.open(fileobj=io.BytesIO(blob)) as tf:
            for want in members:
                hit = None
                for m in tf.getmembers():
                    if m.isfile() and m.name.endswith(want):
                        hit = m
                        break
                if not hit:
                    print(f"  ⚠ {pkg} 里没找到 {want}")
                    continue
                out = os.path.join(DEST, OUTNAME[want])
                with open(out, "wb") as f:
                    f.write(tf.extractfile(hit).read())
                os.chmod(out, os.stat(out).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                print(f"  ✓ {os.path.basename(out)}")

    print("✓ proot 就位。下一步：./gradlew assembleDebug")
    return 0


if __name__ == "__main__":
    sys.exit(main())
