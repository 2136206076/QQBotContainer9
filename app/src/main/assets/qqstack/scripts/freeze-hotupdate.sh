#!/bin/bash
# 冻结 QQ 热更新 / 整包自动更新（幂等，可反复执行）
#   手段 1（网络层）：/etc/hosts 把下列域名指到 0.0.0.0，并在 nsswitch 强制 files 优先，
#           让 QQ 拉不到更新检查/更新包。覆盖：
#             - proxy.hotupdate.qq.com        版本更新检查（"版本更新中"的源头）
#             - dldir1.qq.com / dldir2.qq.com 整包客户端更新包下载（"版本更新中 3%"的下载源）
#             - qqpatch.gtimg.cn             增量热更新 / 补丁 CDN
#   手段 2（落盘层）：每次启动前清空 ~/.config/QQ/versions/（已下好的新版本下次启动才替换，先删掉）
#   手段 3（保险）：把 versions/ 设为只读，下载器即便发起了请求也写不进盘 —— 下载即失败（fail-fast），
#           不占存储；配合手段 1，绝大多数情况下连接在第一时间就被拒，连流量都几乎不耗。
# 用法：bash scripts/freeze-hotupdate.sh
set -u

# 需要屏蔽的更新相关域名（QQ 整包更新 + 热更新）
DOMAINS="proxy.hotupdate.qq.com dldir1.qq.com dldir2.qq.com qqpatch.gtimg.cn"
HOSTS=/etc/hosts
QQ_HOME_DIR="${QQ_HOME:-/root}"
VERSIONS_DIR="$QQ_HOME_DIR/.config/QQ/versions"
VCFG="$VERSIONS_DIR/config.json"

# ---------- 1) 写 hosts（先规范化，避免历史 CRLF / 重复条目） ----------
# 允许重写：先确保可写（上一轮可能被我们锁成只读）
chmod u+w "$HOSTS" 2>/dev/null || true
if [ -w "$HOSTS" ] || [ ! -e "$HOSTS" ]; then
  TMP=$(mktemp 2>/dev/null || echo /tmp/hosts.$$)
  if [ -f "$HOSTS" ]; then
    # 先摘掉所有旧屏蔽条目（按域名），避免越跑越长；同时去 CRLF（否则主机名末尾 \r 会让记录失配）
    tr -d '\r' <"$HOSTS" 2>/dev/null >"$TMP.orig" 2>/dev/null
    cp "$TMP.orig" "$TMP" 2>/dev/null
    for D in $DOMAINS; do
      grep -v "[[:space:]]${D}[[:space:]]*$" "$TMP" >"$TMP.f" 2>/dev/null && mv "$TMP.f" "$TMP"
    done
  else
    printf '127.0.0.1 localhost\n::1 localhost\n' >"$TMP"
  fi
  grep -q "localhost" "$TMP" 2>/dev/null || printf '127.0.0.1 localhost\n::1 localhost\n' >>"$TMP"
  for D in $DOMAINS; do
    printf '0.0.0.0 %s\n' "$D" >>"$TMP"
  done
  if cat "$TMP" >"$HOSTS" 2>/dev/null; then
    echo "[freeze] ✓ hosts 已把更新域名指向 0.0.0.0（已去重/去 CR）"
  else
    echo "[freeze] ⚠ /etc/hosts 不可写（proot 把它 bind 成只读了？）"
    echo "         请改用宿主侧方案：在 Termux 里执行"
    for D in $DOMAINS; do echo "         echo '0.0.0.0 $D' >> \$PREFIX/etc/hosts"; done
  fi
  rm -f "$TMP" "$TMP.orig" "$TMP.f"
else
  echo "[freeze] ⚠ /etc/hosts 不可写"
fi

# 写完即锁：运行时让 QQ 无法再删改 hosts 条目（防 QQ 像 Windows 版那样偷偷去掉屏蔽行）
chmod a-w "$HOSTS" 2>/dev/null || true

# ---------- 1.5) 保证 glibc 先查 /etc/hosts ----------
if [ -f /etc/nsswitch.conf ]; then
  if ! grep -qE '^hosts:[[:space:]]*files' /etc/nsswitch.conf 2>/dev/null; then
    sed -i 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf 2>/dev/null \
      && echo "[freeze] ✓ nsswitch 已改为 files 优先（原来是 DNS 优先）"
  fi
else
  printf 'hosts: files dns\n' >/etc/nsswitch.conf 2>/dev/null \
    && echo "[freeze] ✓ 补写 /etc/nsswitch.conf（hosts: files dns）"
fi

# ---------- 2) 验证（逐域名） ----------
for D in $DOMAINS; do
  R=""
  if command -v getent >/dev/null 2>&1; then
    R=$(getent ahostsv4 "$D" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "$R" ] || R=$(getent hosts "$D" 2>/dev/null | head -1 | awk '{print $1}')
  fi
  case "$R" in
    0.0.0.0 | 127.*) echo "[freeze] ✓ $D -> ${R}（QQ 拉不到更新）" ;;
    "") echo "[freeze] · $D 解析无结果（也算屏蔽成功：域名不可达）" ;;
    *) echo "[freeze] ⚠ $D 仍解析到 $R（未走 /etc/hosts，靠 versions 只读兜底）" ;;
  esac
done

# ---------- 3) 清掉已经下好的新版目录（形如 3.2.34-53644） ----------
# 先把 versions 设为可写（上一轮可能被我们钉成只读），清完再钉回只读
mkdir -p "$VERSIONS_DIR" 2>/dev/null
chmod u+w "$VERSIONS_DIR" 2>/dev/null || true
if [ -d "$VERSIONS_DIR" ]; then
  N=0
  for d in "$VERSIONS_DIR"/*-*; do
    [ -e "$d" ] || continue
    rm -rf "$d" && N=$((N+1))
  done
  [ "$N" -gt 0 ] && echo "[freeze] 已清理 $N 个已下载的新版本目录" || echo "[freeze] 没有已下载的新版本"
fi

# ---------- 4) 钉死 versions/ 为只读：下载器落盘写不进，下载即失败（fail-fast） ----------
chmod a-w "$VERSIONS_DIR" 2>/dev/null
find "$VERSIONS_DIR" -type d -exec chmod a+x {} + 2>/dev/null   # 保留目录可遍历
echo "[freeze] ✓ versions/ 已设为只读（更新包无法落盘，下载即失败，不占存储）"

[ -f "$VCFG" ] && python3 -c "
import json,sys
d=json.load(open('$VCFG'))
print('[freeze] base=%s cur=%s ready=%s' % (d.get('baseVersion'),d.get('curVersion'),d.get('readyVersion') or '(空)'))
" 2>/dev/null
