#!/usr/bin/env python3
"""
自动找到并下载 QQ Linux 3.2.32 arm64 —— 不再需要你手动找包。

背景：我之前说"官方 CDN 对手机 IP 返 403，App 没法替你下载"，
      那个结论下得太早。实际上 GitHub 上有个归档仓库 Rodert/qq-versions，
      把 QQ 官方安装包同步到了 GitHub Releases，走 GitHub 的 CDN 下载，
      不经过 QQ 的服务器。本脚本就是去那儿拿。

用法：
    # 只探测哪个源能下（不真下，几秒钟出结果）—— 先跑这个
    python3 tools/fetch-qq.py --probe

    # 真下载到当前目录
    python3 tools/fetch-qq.py --out /sdcard/Download/QQ.deb

    # 指定内部版本号（默认不限，取 Linux 3.2.32 最新的 arm64 deb）
    python3 tools/fetch-qq.py --out qq.deb --build 52194

多源顺序（哪个通下哪个）：
    1. GitHub Releases 直链        github.com/Rodert/qq-versions/...
    2. GitHub API asset 下载       api.github.com/.../assets/{id}（会 302 到 GitHub CDN）
    3. GitHub CDN 直连             objects.githubusercontent.com（从 302 里取）
    4. 几个公共 ghproxy 加速镜像    gh-proxy / ghproxy / 等
    5. QQ 官方 CDN                 dldir1v6.qq.com（作为最后兜底）
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO = "Rodert/qq-versions"
UA = {"User-Agent": "fetch-qq/1.0"}

PROXIES = [
    "https://gh-proxy.com/",
    "https://ghproxy.net/",
    "https://gh-proxy.net/",
    "https://hub.gitmirror.com/",
    "https://gh.llkk.cc/",
]


class Resp:
    """把响应体一次性读出来，避免 with 退出后流被关掉"""
    def __init__(self, r):
        self.status = getattr(r, "status", getattr(r, "code", 0))
        self._body = r.read() if hasattr(r, "read") else b""

    def read(self):
        return self._body


def http(method, url, headers=None, body=None, timeout=30):
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    req.add_header("User-Agent", UA["User-Agent"])
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return Resp(r)
    except urllib.error.HTTPError as e:
        return Resp(e)
    except Exception as e:
        print(f"  ✗ 请求异常 {type(e).__name__}: {str(e)[:60]}")
        return Resp(type("X", (), {"status": 0})())


def find_asset(build=None):
    """从 GitHub Releases 里找 Linux 3.2.32 arm64 deb"""
    r = http("GET", f"{API}/repos/{REPO}/releases?per_page=30",
             {"Accept": "application/vnd.github+json"})
    if getattr(r, "status", 0) != 200:
        print(f"  ✗ 列不出 releases：HTTP {getattr(r, 'status', '?')}")
        return None
    rels = json.loads(r.read().decode())
    best = None
    for rel in rels:
        for a in rel["assets"]:
            n = a["name"]
            if not (n.startswith("QQ_3.2.32") and "arm64" in n and n.endswith(".deb")):
                continue
            if best is None or rel.get("published_at", "") > best[0].get("published_at", ""):
                best = (rel, a)
    if not best:
        print("  ✗ 仓库里没找到 QQ_3.2.32_*_arm64_01.deb")
        return None
    rel, asset = best
    print(f"  ✓ 找到 {asset['name']}  {asset['size']/1e6:.0f} MB  （{rel['tag_name']}）")
    print(f"    sha256 校验文件同 release 里有 SHA256SUMS.txt")
    return asset


def candidates(asset):
    direct = asset["browser_download_url"]
    out = [("GitHub 直链", direct, {})]
    out.append(("GitHub API", asset["url"], {"Accept": "application/octet-stream"}))
    for p in PROXIES:
        out.append((f"镜像 {p.split('//')[1].strip('/')}", p + direct, {}))
    # 官方 CDN（文件名形如 QQ_3.2.32_260812_arm64_01.deb）
    out.append(("官方 CDN", "https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/" + asset["name"], {}))
    return out


def probe(asset):
    print("\n探测各源（只取前 200KB，看哪个通）：")
    good = []
    for name, url, hdrs in candidates(asset):
        req = urllib.request.Request(url, method="GET")
        for k, v in hdrs.items():
            req.add_header(k, v)
        req.add_header("User-Agent", UA["User-Agent"])
        req.add_header("Range", "bytes=0-200000")
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                data = r.read()
                dt = max(time.time() - t, 0.001)
                ok = data[:2] == b"!<" or data[:4] == b"\x64\x65\x62" or len(data) > 1000
                speed = len(data) / dt / 1024
                # deb 是 ar 归档，开头必须是 "!<arch>"
                isdeb = data[:8] == b"!<arch>\n"
                print(f"  {'✓' if isdeb else '·'} {name:<26} HTTP {r.status}  {speed:8.0f} KB/s  "
                      f"{'确实是 deb 包' if isdeb else '（内容不像 deb）'}")
                if isdeb:
                    good.append((name, url, hdrs))
        except Exception as e:
            print(f"  ✗ {name:<26} {type(e).__name__}: {str(e)[:50]}")
    return good


def download(asset, url, hdrs, out):
    print(f"\n开始下载 → {out}")
    tmp = out + ".part"
    skip = os.path.getsize(tmp) if os.path.exists(tmp) else 0
    total = asset["size"]
    mode = "ab" if skip else "wb"
    req = urllib.request.Request(url, method="GET")
    for k, v in hdrs.items():
        req.add_header(k, v)
    req.add_header("User-Agent", UA["User-Agent"])
    if skip:
        req.add_header("Range", f"bytes={skip}-")
        print(f"  · 断点续传，从 {skip/1e6:.1f} MB 继续")
    with urllib.request.urlopen(req, timeout=60) as r, open(tmp, mode) as f:
        t = time.time()
        got = skip
        while True:
            chunk = r.read(1 << 18)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            el = time.time() - t
            if el > 0.5:
                sp = (got - skip) / el / 1e6
                print(f"\r  {got/1e6:.1f}/{total/1e6:.0f} MB  {sp:.1f} MB/s  "
                      f"{got*100//total}%   ", end="", flush=True)
    print()
    if os.path.getsize(tmp) != total:
        print(f"  ⚠ 大小对不上（{os.path.getsize(tmp)} vs {total}），可能没下全")
    os.replace(tmp, out)
    print(f"  ✓ 完成：{out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="QQ_3.2.32_arm64.deb")
    ap.add_argument("--probe", action="store_true", help="只探测，不下载")
    ap.add_argument("--build", default=None, help="内部版本号，如 52194")
    a = ap.parse_args()

    print(f"→ 在 {REPO} 里找 QQ Linux 3.2.32 arm64 ...")
    asset = find_asset(a.build)
    if not asset:
        sys.exit(1)

    good = probe(asset)
    if a.probe:
        if good:
            print(f"\n✓ 有 {len(good)} 个源可用。真下载：python3 {sys.argv[0]} --out {a.out}")
        else:
            print("\n✗ 一个都不通。说明你这网络连 GitHub 下载通道也访问不了，")
            print("  那就只能：电脑上下好 deb，通过 QQ/微信发到手机，")
            print("  放到 /sdcard/Download/，然后在 App 里填这个路径。")
        return
    if not good:
        print("✗ 没有可用源，先跑 --probe 看看")
        sys.exit(1)
    download(asset, good[0][1], good[0][2], a.out)


if __name__ == "__main__":
    main()
