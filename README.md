# vps-tuneup

小内存 Linux VPS 一键优化脚本（内存调优为主，附可选的原生 BBR 开启）。把在 5 台实机（410MB–1GB，Ubuntu）上验证过的调优打法固化成一个幂等脚本：重复运行安全，单步失败不中断、最后汇总，可重跑补齐失败项。

## 做什么

1. **关闭闲杂服务**：snapd、multipathd、unattended-upgrades、networkd-dispatcher、packagekit（含各自的 socket 单元）。snap 里装了应用时自动跳过 snapd；无法确认 snap 是否为空时也保守跳过。
2. **journald 限容**：`SystemMaxUse=100M`、`RuntimeMaxUse=32M` 并 vacuum——日志失控时 journald 能吃掉 200MB+ 内存，这是实测过的最大暗坑。
3. **加 swap**：优先 zram（压缩内存交换，大小 = 物理内存 50%，lz4，swappiness=60）。内核缺 zram 模块时自动补装 `linux-modules-extra-$(uname -r)`（Ubuntu 精简镜像常见）；zram 实在不可用时退回 512M swap 文件（swappiness=10，写 fstab 持久化）。已有 swap 时自动跳过。
4. **代理进程内存帽子**：自动发现所有 `sing-box*` / `xray*` systemd 服务，逐个写 drop-in：`GOMEMLIMIT=80MiB` + `GOGC=50`，防止 Go 运行时堆无上限增长。
5. **（可选）开启原生 BBR v1**：仅在加 `--bbr` 时执行——设 `net.core.default_qdisc=fq` 与 `net.ipv4.tcp_congestion_control=bbr`，写 `/etc/sysctl.d/99-bbr.conf` 持久化，设置后回读验证。只影响 TCP，UDP/QUIC（如 Hysteria2）不受影响。本脚本永不更换内核：BBRv3 需另行换 XanMod 内核，不在脚本范围内。

## 绝不碰

sshd、防火墙、代理配置本体、tailscaled、docker；网络栈默认不动，加 `--bbr` 时也只改上面那两个拥塞控制 sysctl。全部设置均持久化，重启不丢。

## 用法

先下载、看一眼，再运行（不要盲目 curl | bash）：

```bash
curl -fsSLO https://raw.githubusercontent.com/signyf/vps-tuneup/main/vps-tuneup.sh
less vps-tuneup.sh              # 先审一遍
sudo bash vps-tuneup.sh --dry-run   # 演练：只打印将要做的事，不改系统
sudo bash vps-tuneup.sh             # 正式执行（仅内存优化）
sudo bash vps-tuneup.sh --bbr       # 正式执行 + 开启原生 BBR v1（可与 --dry-run 组合）
```

命令行开关：`--bbr`（开启内核原生 BBR v1，默认关）、`--dry-run`（演练模式）。

运行结束会打印调优前后的 `free -h` 对比和改动/跳过/失败汇总。验收标准：`free -h` 里 Swap 不再是 0、used 明显下降。

## 可调参数（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GOMEMLIMIT_MIB` | 80 | 每个代理进程的内存帽子（MiB） |
| `ZRAM_PERCENT` | 50 | zram 大小 = 物理内存百分比 |
| `SWAPFILE_MB` | 512 | 回退 swap 文件大小（MB） |
| `JOURNAL_MAX` | 100M | journald 磁盘上限 |

例：`sudo GOMEMLIMIT_MIB=64 bash vps-tuneup.sh`

## 适用范围

- 需要 systemd；包自动安装仅支持 apt 系（Debian/Ubuntu）。其他发行版会跳过安装步骤，其余优化（关服务、journald、swap 文件、内存帽子）照常执行。
- 容器型 VPS（OpenVZ/LXC）若内核不允许 swapon，脚本会明确报告"加不了 swap"，其余步骤不受影响。

## 背景

小内存代理机卡顿的通病不是 CPU，而是：出厂零 swap、系统镜像自带一堆桌面/企业级闲杂服务白占 100MB+、journald 无上限、Go 写的代理进程堆只涨不缩。本脚本逐项对治，均来自实机调优记录（五台机器调后 used 分别下降 30–190MB 不等）。
