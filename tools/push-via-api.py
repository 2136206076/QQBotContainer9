#!/usr/bin/env python3
"""
绕过 git push，直接用 GitHub API 把工程推上去（一次 commit，不产生多余提交）。

为什么需要它：
  gh repo create 走的是 api.github.com（通），但 git push 走 github.com（不通）。
  国内网络 / 部分运营商常出现「api 能连、github.com 连不上」，表现就是：
      fatal: unable to access 'https://github.com/xxx/xxx.git/': Failed to connect ... after 31564 ms
  本脚本完全走 api.github.com，不需要 git 协议、不需要 SSH、不需要代理。

原理：Git Database API 三步走
  1) 每个文件 POST /git/blobs      → 拿到 blob sha
  2) 一次 POST /git/trees          → 拿到 tree sha
  3) POST /git/commits + 更新 ref  → 一次提交搞定（空仓库也能建根提交）

用法：
    python3 tools/push-via-api.py                      # 推到当前 git remote，或自动猜
    python3 tools/push-via-api.py QQBotContainer9      # 指定仓库名
    python3 tools/push-via-api.py QQBotContainer9 -m "说明"
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
SKIP_DIRS = {".git", "__pycache__", "build", ".gradle", ".idea"}
SKIP_FILES = {".DS_Store"}


def sh(*args):
    return subprocess.run(list(args), capture_output=True, text=True)


def get_token():
    r = sh("gh", "auth", "token")
    t = r.stdout.strip()
    if r.returncode != 0 or not t:
        sys.exit("✗ 拿不到 gh token。先执行：gh auth login")
    return t


def owner_of(token):
    r = sh("gh", "api", "user", "--jq", ".login")
    o = r.stdout.strip()
    return o or None


def req(method, path, payload=None, tok=""):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(API + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + tok)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    r.add_header("User-Agent", "push-via-api")
    if data:
        r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=120) as resp:
        body = resp.read().decode("utf-8", "replace")
        return json.loads(body) if body else {}


def collect(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_FILES or fn.endswith((".apk", ".zip", ".tar.gz")):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            out.append((rel, full))
    return sorted(out)


def main():
    args = [a for a in sys.argv[1:]]
    msg = "QQBotContainer: 手机端 QQ 机器人容器 App"
    if "-m" in args:
        i = args.index("-m")
        msg = args[i + 1] if i + 1 < len(args) else msg
        args = args[:i]
    repo = args[0] if args else None

    tok = get_token()
    owner = owner_of(tok)
    if not repo:
        r = sh("git", "remote", "get-url", "origin")
        if r.returncode == 0 and "github.com" in r.stdout:
            u = r.stdout.strip().rstrip("/").replace(".git", "")
            parts = u.split("github.com/")[-1].split("/")
            if len(parts) == 2:
                owner, repo = parts[0], parts[1]
    if not owner or not repo:
        sys.exit("✗ 无法确定仓库。用法：python3 tools/push-via-api.py <仓库名>")
    R = f"{owner}/{repo}"
    print(f"→ 目标仓库 {R}")

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = collect(root)
    print(f"→ 共 {len(files)} 个文件")

    # 1) blobs
    blobs = []
    for rel, full in files:
        with open(full, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        try:
            j = req("POST", f"/repos/{R}/git/blobs",
                    {"content": b64, "encoding": "base64"}, tok)
        except urllib.error.HTTPError:
            print(f"  ✗ blob 失败：{rel}")
            raise
        # 只给真正的可执行脚本加执行位（沙盒/解压后常常全是 777，别照抄权限位）
        mode = "100755" if rel.endswith(".sh") else "100644"
        blobs.append({"path": rel, "mode": mode, "type": "blob", "sha": j["sha"]})
    print(f"✓ 已上传 {len(blobs)} 个 blob")

    # 2) tree
    tree = req("POST", f"/repos/{R}/git/trees", {"tree": blobs}, tok)
    print(f"✓ tree {tree['sha']}")

    # 3) commit（空仓库 parents 为空，创建根提交）
    parents = []
    try:
        ref = req("GET", f"/repos/{R}/git/ref/heads/main", tok=tok)
        parents = [ref["object"]["sha"]]
    except urllib.error.HTTPError:
        try:
            ref = req("GET", f"/repos/{R}/git/ref/heads/master", tok=tok)
            parents = [ref["object"]["sha"]]
        except urllib.error.HTTPError:
            parents = []
    commit = req("POST", f"/repos/{R}/git/commits",
                 {"message": msg, "tree": tree["sha"], "parents": parents}, tok)
    print(f"✓ commit {commit['sha'][:8]}")

    # 4) 更新 ref
    branch = "main"
    if not parents:
        try:
            req("POST", f"/repos/{R}/git/refs",
                {"ref": "refs/heads/main", "sha": commit["sha"]}, tok)
        except urllib.error.HTTPError:
            branch = "master"
            req("POST", f"/repos/{R}/git/refs",
                {"ref": "refs/heads/master", "sha": commit["sha"]}, tok)
    else:
        req("PATCH", f"/repos/{R}/git/refs/heads/{branch}", {"sha": commit["sha"]}, tok)
    print(f"✓ 已更新 refs/heads/{branch}")

    # 5) 触发编译
    try:
        req("POST", f"/repos/{R}/actions/workflows/build-apk.yml/dispatches",
            {"ref": branch}, tok)
        print("✓ 已触发云端编译")
    except urllib.error.HTTPError as e:
        print(f"（自动触发失败，稍后到 Actions 页手动 Run workflow；HTTP {e.code}）")

    print()
    print(f"  仓库   https://github.com/{R}")
    print(f"  进度   https://github.com/{R}/actions")
    print("  等 5~8 分钟，绿了到底部 Artifacts 下载 QQBotContainer-debug")


if __name__ == "__main__":
    main()
