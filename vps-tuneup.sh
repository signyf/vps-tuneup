#!/usr/bin/env bash
#
# vps-tuneup.sh — 小内存 Linux VPS 一键内存优化（幂等，可重复跑）
#
# 做什么：
#   1. 关闭纯占内存的闲杂服务（snapd / multipathd / unattended-upgrades /
#      networkd-dispatcher / packagekit）——snap 里装了应用时自动跳过 snapd
#   2. 给 journald 限容（SystemMaxUse / RuntimeMaxUse）并 vacuum
#   3. 加 swap：优先 zram（压缩内存交换，含缺模块时自动补装
#      linux-modules-extra），zram 不可用时退回 512M swap 文件
#   4. 给 sing-box / xray 服务加 GOMEMLIMIT + GOGC 内存帽子（systemd drop-in）
#   5.（可选，--bbr 才执行）开启内核原生 BBR v1：net.core.default_qdisc=fq +
#      net.ipv4.tcp_congestion_control=bbr，写 /etc/sysctl.d/99-bbr.conf 持久化，
#      设置后回读验证。只影响 TCP，不影响 UDP/QUIC（如 Hysteria2）。
#      本脚本永不更换内核：BBRv3 需另行换 XanMod 内核，不在脚本范围。
#
# 绝不碰：sshd、防火墙、代理配置本体、tailscaled、docker。网络栈默认不动；
# 显式加 --bbr 时也只改上面那两个拥塞控制 sysctl。
#
# 用法：
#   sudo bash vps-tuneup.sh              # 正式执行（仅内存优化）
#   sudo bash vps-tuneup.sh --bbr        # 额外开启原生 BBR v1（可与 --dry-run 组合）
#   sudo bash vps-tuneup.sh --dry-run    # 只演练，打印将要做的事，不改系统
#
# 可调环境变量：
#   GOMEMLIMIT_MIB=80   每个代理进程的内存帽子（MiB）
#   ZRAM_PERCENT=50     zram 大小 = 物理内存的百分比
#   SWAPFILE_MB=512     回退 swap 文件大小（MB）
#   JOURNAL_MAX=100M    journald 磁盘上限
#
# 说明：包自动安装仅支持 apt 系（Debian/Ubuntu）；其他发行版会跳过安装，
# 其余步骤（关服务 / journald / swap 文件 / 内存帽子）照常执行。
# 全部设置均持久化，重启不丢。单步失败不中断，最后汇总，可重跑补失败项。

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

DRY_RUN=0
ENABLE_BBR=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --bbr) ENABLE_BBR=1 ;;
    --help|-h)
      sed -n '2,33p' "$0" | sed 's/^#\s\?//'
      exit 0 ;;
    *) echo "unknown option: $arg (only --dry-run / --bbr / --help)" >&2; exit 2 ;;
  esac
done

GOMEMLIMIT_MIB="${GOMEMLIMIT_MIB:-80}"
ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
SWAPFILE_MB="${SWAPFILE_MB:-512}"
JOURNAL_MAX="${JOURNAL_MAX:-100M}"

CHANGES=0; SKIPS=0; FAILS=0
ok()   { printf '  [OK]   %s\n' "$*"; CHANGES=$((CHANGES+1)); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIPS=$((SKIPS+1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
step() { printf '\n== %s ==\n' "$*"; }

# 执行一条会改系统的命令；dry-run 时只打印
do_run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  [DRY] %s\n' "$*"; return 0; fi
  "$@"
}

# 确保文件里有且仅有这一行（幂等）。返回 0=做了改动，1=原本就有
ensure_line() { # file line
  if [ -f "$1" ] && grep -qxF "$2" "$1" 2>/dev/null; then return 1; fi
  if [ "$DRY_RUN" = 1 ]; then printf '  [DRY] append to %s: %s\n' "$1" "$2";
  else printf '%s\n' "$2" >> "$1"; fi
  return 0
}

# 把文件内容设为指定文本（幂等）。返回 0=做了改动，1=内容已一致
write_file() { # file content
  if [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then return 1; fi
  if [ "$DRY_RUN" = 1 ]; then printf '  [DRY] write %s (content below)\n%s\n' "$1" "$2";
  else printf '%s\n' "$2" > "$1"; fi
  return 0
}

# 把 ini 文件里的 key 设为 value（处理被注释的出厂行）。返回 0=改动，1=已一致，2=无此 key
set_ini_key() { # file key value
  local file="$1" key="$2" val="$3"
  if [ -f "$file" ] && grep -Eq "^[[:space:]]*${key}=${val}$" "$file"; then return 1; fi
  if [ -f "$file" ] && grep -Eq "^#?[[:space:]]*${key}=" "$file"; then
    do_run sed -i "s|^#\?[[:space:]]*${key}=.*|${key}=${val}|" "$file" && return 0
    return 1
  fi
  return 2
}

if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" = 0 ]; then
  echo "需要 root：请用 sudo bash $0" >&2; exit 1
fi

HAVE_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
  HAVE_SYSTEMD=1
fi
HAVE_APT=0; command -v apt-get >/dev/null 2>&1 && HAVE_APT=1
APT_UPDATED=0
apt_update_once() {
  [ "$APT_UPDATED" = 1 ] && return 0
  APT_UPDATED=1
  do_run apt-get update
}

echo "vps-tuneup: host=$(hostname) kernel=$(uname -r) systemd=${HAVE_SYSTEMD} apt=${HAVE_APT} dry_run=${DRY_RUN} bbr=${ENABLE_BBR}"
step "调优前"
free -h || true

# ---------------------------------------------------------------- 1. 闲杂服务
if [ "$HAVE_SYSTEMD" = 1 ]; then
  step "关闭闲杂服务"
  # snap 安全检查：装了 snap 应用、或无法确认（snap list 超时/报错）时不动 snapd
  snap_state="absent"
  if systemctl cat snapd.service >/dev/null 2>&1; then
    snap_state="unknown"
    if out=$(timeout 20 snap list 2>/dev/null); then
      if [ "$(printf '%s' "$out" | grep -c .)" -le 1 ]; then snap_state="empty"; else snap_state="has-snaps"; fi
    fi
  fi
  for unit in snapd.service snapd.socket multipathd.service multipathd.socket \
              unattended-upgrades.service networkd-dispatcher.service packagekit.service; do
    case "$unit" in
      snapd.*)
        if [ "$snap_state" = "has-snaps" ]; then skip "$unit（snap 里装了应用，保留）"; continue; fi
        if [ "$snap_state" = "unknown" ];  then skip "$unit（无法确认 snap 是否为空，保守保留）"; continue; fi
        ;;
    esac
    if ! systemctl cat "$unit" >/dev/null 2>&1; then skip "$unit（不存在）"; continue; fi
    en=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    ac=$(systemctl is-active  "$unit" 2>/dev/null || true)
    if [ "$en" = "disabled" ] && [ "$ac" != "active" ]; then skip "$unit（已关闭）"; continue; fi
    lbl="已关闭 $unit"; [ "$DRY_RUN" = 1 ] && lbl="（演练）将关闭 $unit"
    if do_run systemctl disable --now "$unit" >/dev/null 2>&1; then ok "$lbl"; else fail "关闭 $unit 失败"; fi
  done
else
  step "关闭闲杂服务"; skip "非 systemd 系统，跳过"
fi

# ---------------------------------------------------------------- 2. journald 限容
if [ "$HAVE_SYSTEMD" = 1 ] && [ -f /etc/systemd/journal.conf ]; then
  step "journald 限容"
  changed=0
  set_ini_key /etc/systemd/journal.conf SystemMaxUse "$JOURNAL_MAX" && changed=1
  rc=$?
  if [ "$rc" = 2 ]; then ensure_line /etc/systemd/journal.conf "SystemMaxUse=$JOURNAL_MAX" && changed=1; fi
  set_ini_key /etc/systemd/journal.conf RuntimeMaxUse 32M && changed=1
  rc=$?
  if [ "$rc" = 2 ]; then ensure_line /etc/systemd/journal.conf "RuntimeMaxUse=32M" && changed=1; fi
  if [ "$changed" = 1 ]; then
    do_run systemctl restart systemd-journald
    lbl="journald 已限容 SystemMaxUse=$JOURNAL_MAX RuntimeMaxUse=32M"
    [ "$DRY_RUN" = 1 ] && lbl="（演练）$lbl"
    ok "$lbl"
  else
    skip "journald 限容已设置"
  fi
  do_run journalctl --vacuum-size="$JOURNAL_MAX" >/dev/null 2>&1 || true
else
  step "journald 限容"; skip "无 journal.conf，跳过"
fi

# ---------------------------------------------------------------- 3. swap（zram 优先）
step "swap"
swapfile_setup() {
  if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q '^/swapfile'; then
    skip "swap 文件已在用"; return 0
  fi
  local avail_kb need_kb
  avail_kb=$(df -P / 2>/dev/null | awk 'NR==2{print $4}')
  need_kb=$(( SWAPFILE_MB * 1024 * 6 / 5 ))
  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
    fail "磁盘可用空间不足（需要约 ${need_kb}KB），无法建 swap 文件"; return 1
  fi
  if [ ! -f /swapfile ]; then
    do_run fallocate -l "${SWAPFILE_MB}M" /swapfile 2>/dev/null \
      || do_run dd if=/dev/zero of=/swapfile bs=1M count="$SWAPFILE_MB" status=none
  fi
  do_run chmod 600 /swapfile
  do_run mkswap /swapfile >/dev/null 2>&1
  if [ "$DRY_RUN" = 1 ]; then do_run swapon /swapfile; ok "（演练）将创建 ${SWAPFILE_MB}M swap 文件"; return 0; fi
  if swapon /swapfile 2>/dev/null; then
    ensure_line /etc/fstab "/swapfile none swap sw 0 0" >/dev/null 2>&1 || true
    write_file /etc/sysctl.d/99-swapfile.conf "vm.swappiness=10" >/dev/null 2>&1 || true
    do_run sysctl -p /etc/sysctl.d/99-swapfile.conf >/dev/null 2>&1 || true
    ok "已启用 ${SWAPFILE_MB}M swap 文件（swappiness=10，已写 fstab）"; return 0
  fi
  fail "swapon 被拒（容器型内核常见），此机加不了 swap"; return 1
}

if swapon --show 2>/dev/null | grep -q .; then
  skip "已有 swap：$(swapon --show | tail -n +2 | awk '{print $1, $2}' | tr '\n' ' ')"
else
  zram_done=0
  if [ "$HAVE_APT" = 1 ]; then
    if [ ! -e /etc/default/zramswap ]; then
      apt_update_once
      do_run apt-get install -y zram-tools >/dev/null 2>&1 \
        || fail "zram-tools 安装失败（apt 锁被占或源不可用，稍后重跑本脚本可补）"
    fi
    if [ -e /etc/default/zramswap ] || [ "$DRY_RUN" = 1 ]; then
      if [ -e /etc/default/zramswap ]; then
        set_ini_key /etc/default/zramswap PERCENT "$ZRAM_PERCENT" >/dev/null 2>&1 || true
        set_ini_key /etc/default/zramswap ALGO lz4 >/dev/null 2>&1 || true
      else
        printf '  [DRY] 将写入 /etc/default/zramswap: PERCENT=%s ALGO=lz4\n' "$ZRAM_PERCENT"
      fi
      if ! lsmod 2>/dev/null | grep -q '^zram'; then
        if ! do_run modprobe zram 2>/dev/null; then
          # 内核模块缺失（Ubuntu 精简镜像常见）：补装 modules-extra 再试
          apt_update_once
          do_run apt-get install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
          do_run modprobe zram 2>/dev/null || true
        fi
      fi
      if [ "$HAVE_SYSTEMD" = 1 ]; then
        do_run systemctl enable zramswap >/dev/null 2>&1 || true
        do_run systemctl restart zramswap >/dev/null 2>&1 || true
      fi
      if [ "$DRY_RUN" = 1 ]; then
        ok "（演练）将配置 zram（内存的 ${ZRAM_PERCENT}%、lz4、swappiness=60）"; zram_done=1
      elif swapon --show 2>/dev/null | grep -qi zram; then
        write_file /etc/sysctl.d/99-zram.conf "vm.swappiness=60" >/dev/null 2>&1 || true
        do_run sysctl -p /etc/sysctl.d/99-zram.conf >/dev/null 2>&1 || true
        ok "zram 已启用（swappiness=60）"; zram_done=1
      else
        fail "zramswap 未能启动（journalctl -u zramswap 可见原因），改走 swap 文件"
      fi
    fi
  else
    skip "非 apt 系，zram 自动安装跳过，改走 swap 文件"
  fi
  [ "$zram_done" = 0 ] && swapfile_setup
fi

# ---------------------------------------------------------------- 4. 代理进程内存帽子
if [ "$HAVE_SYSTEMD" = 1 ]; then
  step "sing-box / xray 内存帽子（GOMEMLIMIT=${GOMEMLIMIT_MIB}MiB）"
  units=$( { systemctl list-units --all --no-legend 'sing-box*.service' 'xray*.service' 2>/dev/null | awk '{print $1}';
             systemctl list-unit-files --no-legend 'sing-box*.service' 'xray*.service' 2>/dev/null | awk '{print $1}'; } | sort -u )
  if [ -z "$units" ]; then
    skip "未发现 sing-box / xray 服务"
  else
    reloaded=0
    for unit in $units; do
      dir="/etc/systemd/system/${unit}.d"
      content="[Service]
Environment=GOMEMLIMIT=${GOMEMLIMIT_MIB}MiB
Environment=GOGC=50"
      do_run mkdir -p "$dir"
      if write_file "$dir/memlimit.conf" "$content"; then
        ok "$unit 已加内存帽子"
        if [ "$reloaded" = 0 ]; then do_run systemctl daemon-reload; reloaded=1; fi
        do_run systemctl try-restart "$unit" >/dev/null 2>&1 || true
      else
        skip "$unit 帽子已设置"
      fi
    done
  fi
else
  step "sing-box / xray 内存帽子"; skip "非 systemd 系统，跳过"
fi

# ---------------------------------------------------------------- 5. BBR（可选，--bbr）
step "BBR 拥塞控制（TCP）"
if [ "$ENABLE_BBR" = 0 ]; then
  skip "未指定 --bbr，默认不动网络栈"
elif ! command -v sysctl >/dev/null 2>&1; then
  skip "无 sysctl 命令，跳过"
else
  cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  bbr_conf="net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr"
  conf_same=0; write_file /etc/sysctl.d/99-bbr.conf "$bbr_conf" || conf_same=1
  if [ "$cur_cc" = "bbr" ] && [ "$conf_same" = 1 ]; then
    skip "BBR 已开启且已持久化"
  else
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    case " $avail " in
      *" bbr "*) ;;
      *)
        do_run modprobe tcp_bbr >/dev/null 2>&1 || true
        if [ "$DRY_RUN" = 1 ]; then
          avail="$avail bbr"  # 演练：假设 modprobe 成功；正式运行会真实回读验证
        else
          avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
        fi
        ;;
    esac
    case " $avail " in
      *" bbr "*)
        do_run sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        do_run sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        if [ "$DRY_RUN" = 1 ]; then
          ok "（演练）将开启 BBR（fq + bbr，含持久化写入；仅影响 TCP）"
        elif [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")" = "bbr" ]; then
          ok "BBR 已开启（fq + bbr，已持久化；仅影响 TCP，UDP/QUIC 不受影响）"
        else
          fail "BBR 设置后回读不是 bbr，请手动检查 sysctl 输出"
        fi
        ;;
      *)
        fail "内核无 tcp_bbr（available: ${avail:-空}），开启不了（BBRv3 需换 XanMod 等带补丁的内核）"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 汇总
step "调优后"
free -h || true
printf '\n汇总：改动 %d 项，跳过 %d 项，失败 %d 项。所有设置均持久化，重启不丢。\n' "$CHANGES" "$SKIPS" "$FAILS"
if [ "$DRY_RUN" = 1 ]; then echo "（本次为 --dry-run 演练，未对系统做任何修改）"; fi
if [ "$FAILS" -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
  echo "有失败项：处理掉原因（如 apt 锁）后重跑本脚本即可补齐，重复执行安全。"
fi
exit 0
