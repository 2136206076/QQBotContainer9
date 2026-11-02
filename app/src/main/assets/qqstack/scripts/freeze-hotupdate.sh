#!/bin/bash
# 冻结 QQ 热更新（幂等，可反复执行）
#   1) /etc/hosts 里把 qqpatch.gtimg.cn 指到 0.0.0.0（并保证 nsswitch 是 files 优先）
#   2) 删掉已经偷偷下好的新版整包（不影响当前运行的版本）
# 用法：bash scripts/freeze-hotupdate.sh
#
# 注意：即使 hosts 屏蔽没生效（proot 的解析器偶尔会绕开 /etc/hosts，见下面第 2 步的
# 诊断输出），第 3 步「每次启动前清空 versions/」仍然能挡住升级 —— QQ 下载完新包之后
# 是在**下次启动时**才替换的，我们在它启动前把目录删掉，替换就没有东西可换。
set -u
DOMAIN="qqpatch.gtimg.cn"
HOSTS=/etc/hosts
VCFG="${QQ_HOME:-/root}/.config/QQ/versions/config.json"

# ---------- 1) 写 hosts（先规范化，避免历史 CRLF / 重复条目把条目变成无效行） ----------
if [ -w "$HOSTS" ] || [ ! -e "$HOSTS" ]; then
  TMP=$(mktemp 2>/dev/null || echo /tmp/hosts.$$)
  # tr -d '\r'：某些编辑器/老版本写出的 CRLF 会让 glibc 把主机名末尾的 \r 当成名字的一部分，
  #            于是 "qqpatch.gtimg.cn" 查不到那条记录、照样走 DNS —— 这正是日志里
  #            「hosts 已屏蔽」却「解析未生效」的头号嫌疑。
  # grep -v：先摘掉旧的同名条目，避免越跑越长。
  if [ -f "$HOSTS" ]; then
    tr -d '\r' <"$HOSTS" 2>/dev/null | grep -v "[[:space:]]${DOMAIN}[[:space:]]*$" >"$TMP" 2>/dev/null
  else
    printf '127.0.0.1 localhost\n::1 localhost\n' >"$TMP"
  fi
  # 万一原文件读不出/被清空，至少把 localhost 补回来，别把域名解析整个搞坏
  grep -q "localhost" "$TMP" 2>/dev/null || printf '127.0.0.1 localhost\n::1 localhost\n' >>"$TMP"
  printf '0.0.0.0 %s\n' "$DOMAIN" >>"$TMP"
  if cat "$TMP" >"$HOSTS" 2>/dev/null; then
    echo "[freeze] ✓ hosts 已指向 0.0.0.0（已去重/去 CR）"
  else
    echo "[freeze] ⚠ /etc/hosts 不可写（proot 把它 bind 成只读了？）"
    echo "         请改用宿主侧方案：在 Termux 里执行"
    echo "         echo '0.0.0.0 $DOMAIN' >> \$PREFIX/etc/hosts"
  fi
  rm -f "$TMP"
else
  echo "[freeze] ⚠ /etc/hosts 不可写"
fi

# ---------- 1.5) 保证 glibc 先查 /etc/hosts ----------
# 没有 nsswitch.conf 时 glibc 的内置默认是 "dns [!UNAVAIL=return] files"：
# DNS 优先且成功就返回，/etc/hosts 根本轮不到。补上这一行能让上面写的条目真正生效。
if [ -f /etc/nsswitch.conf ]; then
  # 注意要判「files 在最前」：`hosts: dns [!UNAVAIL=return] files` 里也有 files 字样，
  # 但那是 DNS 优先，/etc/hosts 根本轮不到 —— 只判断"包含 files"会漏掉这种写法。
  if ! grep -qE '^hosts:[[:space:]]*files' /etc/nsswitch.conf 2>/dev/null; then
    sed -i 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf 2>/dev/null \
      && echo "[freeze] ✓ nsswitch 已改为 files 优先（原来是 DNS 优先）"
  fi
else
  printf 'hosts: files dns\n' >/etc/nsswitch.conf 2>/dev/null \
    && echo "[freeze] ✓ 补写 /etc/nsswitch.conf（hosts: files dns）"
fi

# ---------- 2) 验证 ----------
R=""
if command -v getent >/dev/null 2>&1; then
  R=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$R" ] || R=$(getent hosts "$DOMAIN" 2>/dev/null | head -1 | awk '{print $1}')
fi
case "$R" in
  0.0.0.0 | 127.*) echo "[freeze] ✓ 解析已指向 ${R}（QQ 拉不到更新包）" ;;
  "")
    echo "[freeze] · 解析查询没结果（也算屏蔽成功：域名不可达）" ;;
  *)
    echo "[freeze] ⚠ 解析仍返回 $R（没走 /etc/hosts）"
    echo "         ↳ 兜底：每次启动前都会清空 versions/，已下好的新版本不会被替换生效"
    echo "         ↳ 诊断：nsswitch=[$(grep -E '^hosts:' /etc/nsswitch.conf 2>/dev/null)] hosts=[$(ls -l "$HOSTS" 2>/dev/null | awk '{print $1,$3,$5}')]"
    echo "         ↳ 条目原文（出现 ^M 说明是 CRLF，主机名会被读成 qqpatch.gtimg.cn\\r 从而失配）："
    echo "           [$(grep -m1 "$DOMAIN" "$HOSTS" 2>/dev/null | cat -A)]"
    ;;
esac

# ---------- 3) 清掉已经下好的新版目录（形如 3.2.34-53644，zip 也一起清） ----------
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
