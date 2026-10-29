#!/bin/bash
# 冻结 QQ 热更新（幂等，可反复执行）
#   1) /etc/hosts 里把 qqpatch.gtimg.cn 指到 0.0.0.0
#   2) 删掉已经偷偷下好的新版整包（不影响当前运行的版本）
# 用法：bash scripts/freeze-hotupdate.sh
set -u
DOMAIN="qqpatch.gtimg.cn"
VCFG="${QQ_HOME:-/root}/.config/QQ/versions/config.json"

if grep -q "$DOMAIN" /etc/hosts 2>/dev/null; then
  echo "[freeze] hosts 已屏蔽 $DOMAIN"
else
  if echo "0.0.0.0 $DOMAIN" >>/etc/hosts 2>/dev/null; then
    echo "[freeze] 已写入 /etc/hosts"
  else
    echo "[freeze] ⚠ /etc/hosts 不可写（proot 把它 bind 成只读了？）"
    echo "         请改用宿主侧方案：在 Termux 里执行"
    echo "         echo '0.0.0.0 $DOMAIN' >> \$PREFIX/etc/hosts"
  fi
fi

# 验证是否真的生效
if command -v getent >/dev/null 2>&1; then
  R=$(getent hosts "$DOMAIN" 2>/dev/null | head -1)
  case "$R" in
    "0.0.0.0"*) echo "[freeze] ✓ 解析已指向 0.0.0.0" ;;
    *) echo "[freeze] ⚠ 解析结果：$R（未生效，QQ 仍可能升级）" ;;
  esac
fi

# 清掉已经下好的新版目录（形如 3.2.34-53644，zip 也一起清）
if [ -d "${QQ_HOME:-/root}/.config/QQ/versions" ]; then
  N=0
  for d in "${QQ_HOME:-/root}"/.config/QQ/versions/*-*; do
    [ -e "$d" ] || continue
    rm -rf "$d" && N=$((N+1))
  done
  [ "$N" -gt 0 ] && echo "[freeze] 已清理 $N 个已下载的新版本目录" || echo "[freeze] 没有已下载的新版本"
fi

[ -f "$VCFG" ] && python3 -c "
import json,sys
d=json.load(open('$VCFG'))
print('[freeze] base=%s cur=%s ready=%s' % (d.get('baseVersion'),d.get('curVersion'),d.get('readyVersion') or '(空)'))
" 2>/dev/null
