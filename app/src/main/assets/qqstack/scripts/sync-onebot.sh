#!/bin/bash
# 把 SnowLuma 实际使用的 OneBot 监听端口 / 访问令牌，同步到 QQ Agent 的配置里。
#
# 为什么需要这一步：
#   SnowLuma 首次启动会给 http / ws 两个监听器各生成一个**随机 accessToken**
#   （config/onebot_<uin>.json 里的 networks.wsServers[0].accessToken）。
#   QQ Agent 默认 accessToken 是空字符串，于是它连 ws://127.0.0.1:3001 时
#   握手被拒（401），面板就一直显示「未连接 OneBot」，看起来像协议端没起来 —— 
#   实际上 QQ 登录、端口都在监听。
#
# 做法：读 SnowLuma 的配置（优先每个账号的 onebot_<uin>.json，其次全局 onebot.json），
#       取出 ws/http 的端口与令牌写进 QQ Agent 的 data/config.json。
#       只在「当前 agent 指向本机」时才改，用户自己填了外部协议端地址的不动。
#
# 用法：bash scripts/sync-onebot.sh [等待秒数，默认 8]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/deploy.env" ] && . "$HERE/deploy.env"

SL_DIR="${SNOWLUMA_DIR:-/opt/snowluma}"
AGENT_HOME="${AGENT_DIR:-/opt/qqagent}"
CFG="$AGENT_HOME/data/config.json"
WAIT="${1:-8}"

[ -f "$CFG" ] || { echo "[onebot-sync] 跳过：$CFG 还不存在"; exit 0; }

# SnowLuma 的配置是账号上线（startSession）时才落盘的，启动脚本里给它一点时间。
i=0
while [ "$i" -lt "$WAIT" ]; do
  ls "$SL_DIR"/config/onebot*.json >/dev/null 2>&1 && break
  sleep 1; i=$((i+1))
done

python3 - "$SL_DIR" "$CFG" <<'PY'
import glob, json, os, sys

sl_dir, cfg_path = sys.argv[1], sys.argv[2]
cfg_dir = os.path.join(sl_dir, 'config')

def load(p):
    try:
        with open(p, encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:
        return None

# 全局配置 + 最新的账号快照（快照覆盖全局，和 SnowLuma 自己的合并顺序一致）
cands = []
g = os.path.join(cfg_dir, 'onebot.json')
if os.path.isfile(g):
    cands.append(g)
per = sorted(glob.glob(os.path.join(cfg_dir, 'onebot_*.json')), key=os.path.getmtime, reverse=True)
if per:
    cands.append(per[0])
if not cands:
    print('[onebot-sync] 跳过：SnowLuma 还没写出 config/onebot*.json（QQ 还没登录？）')
    sys.exit(0)

def servers(doc, kind):
    nets = doc.get('networks') if isinstance(doc.get('networks'), dict) else doc
    out = []
    for a in (nets.get(kind) or []):
        if isinstance(a, dict) and a.get('enabled') is not False:
            out.append(a)
    return out

picked = {}
for kind in ('wsServers', 'httpServers'):
    # 后来的源优先；同名覆盖，不同名追加（默认名 ws-default / http-default）
    merged = {}
    for p in cands:
        d = load(p)
        if not d:
            continue
        for a in servers(d, kind):
            merged[a.get('name') or ''] = a
    if not merged:
        continue
    pref = 'ws-default' if kind == 'wsServers' else 'http-default'
    picked[kind] = merged.get(pref) or list(merged.values())[0]

if not picked:
    print('[onebot-sync] 跳过：配置里没有任何 OneBot 监听器')
    sys.exit(0)

ws = picked.get('wsServers') or {}
ht = picked.get('httpServers') or {}
ws_port = int(ws.get('port') or 3001)
ht_port = int(ht.get('port') or 3000)
ws_tok = str(ws.get('accessToken') or '')
ht_tok = str(ht.get('accessToken') or '')

try:
    with open(cfg_path, encoding='utf-8') as f:
        cfg = json.load(f)
except Exception as e:
    print('[onebot-sync] 读 agent 配置失败：%s' % e)
    sys.exit(0)

ob = cfg.get('onebot') if isinstance(cfg.get('onebot'), dict) else {}
cur_ws = str(ob.get('wsUrl') or '')
# 只在指向本机时才接管；用户填了外部协议端就别碰
local = (not cur_ws) or ('127.0.0.1' in cur_ws) or ('localhost' in cur_ws)
if not local:
    print('[onebot-sync] 跳过：面板里配的是外部协议端（%s），保持不动' % cur_ws)
    sys.exit(0)

want = {
    'wsUrl': 'ws://127.0.0.1:%d' % ws_port,
    'httpUrl': 'http://127.0.0.1:%d' % ht_port,
    'accessToken': ws_tok,
    'httpAccessToken': ht_tok or ws_tok,
}
diff = {k: v for k, v in want.items() if str(ob.get(k) or '') != v}
if not diff:
    # 令牌有可能刚好为空（我们预置的配置），也要说清楚状态，别让人以为没跑
    print('[onebot-sync] ✓ 已对齐（ws:%d http:%d，令牌%s）' % (ws_port, ht_port, '空' if not ws_tok else '已同步'))
    sys.exit(0)

ob.update(want)
cfg['onebot'] = ob
tmp = cfg_path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
os.replace(tmp, cfg_path)
print('[onebot-sync] ✓ 已把 SnowLuma 的端口/令牌写进面板配置：ws://127.0.0.1:%d（令牌%s）' % (ws_port, '空' if not ws_tok else '已同步'))
print('CHANGED')
PY
