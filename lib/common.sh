#!/usr/bin/env bash
# ==============================================================================
#  lib/common.sh —— build-template.sh / new-vm.sh 共用
#  只定义函数和加载 conf.env，不执行任何动作。
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/conf.env}"

# 本机节点名（pvesh 的路径里要用）。
# /etc/pve/nodes/ 下每个子目录就是一个节点，取法最权威也最简单；
# 多节点集群取第一个（本套脚本只操作本机）。
PVE_NODE="$(find /etc/pve/nodes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1)"
PVE_NODE="$(basename "${PVE_NODE:-}")"
: "${PVE_NODE:=$(hostname)}"

if [ ! -f "$CONF_FILE" ]; then
    # 全新 clone 里没有这个文件是正常的 —— 它含凭据，被 .gitignore 排除了。
    # 第一次用的人一定会撞上这里，所以把下一步直接写出来。
    echo "找不到配置文件: $CONF_FILE" >&2
    if [ -f "$SCRIPT_DIR/conf.env.example" ]; then
        echo "" >&2
        echo "  首次使用先复制一份模板并改掉里面的密码:" >&2
        echo "" >&2
        echo "      cp $SCRIPT_DIR/conf.env.example $CONF_FILE" >&2
        echo "      vi  $CONF_FILE      # 至少改 CI_PASSWORD" >&2
        echo "" >&2
        echo "  然后跑 ./bootstrap.sh --check 体检" >&2
    else
        echo "  （连 conf.env.example 都没有，仓库可能不完整）" >&2
    fi
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[34m'; C_D=$'\033[2m';  C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=
fi

_ts() { date '+%H:%M:%S'; }
log()  { printf '%s%s%s %s\n'  "$C_D" "$(_ts)" "$C_0" "$*"; }
ok()   { printf '%s%s%s  ✔ %s\n' "$C_D" "$(_ts)" "$C_0" "$*"; }
info() { printf '%s%s%s  › %s\n' "$C_D" "$(_ts)" "$C_0" "$*"; }
warn() { printf '%s%s%s  ! %s\n' "$C_D" "$(_ts)" "$C_Y" "$*"; }
err()  { printf '%s%s%s  ✘ %s\n' "$C_D" "$(_ts)" "$C_R" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s▸ %s%s\n' "$C_B$C_0" "$*" "$C_0"; }

confirm() {  # confirm "问题"  (非交互返回 yes)
    local prompt="$1" ans
    [ -t 0 ] || return 0
    read -r -p "  $prompt [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# ---------- 前置检查 ----------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限（直接用 root 跑本脚本）"
}

require_pve() {
    command -v qm >/dev/null 2>&1 || die "找不到 qm，这不是 PVE 主机"
    pveversion >/dev/null 2>&1 || die "pveversion 执行失败"
}

# pveversion 的输出是 "pve-manager/9.2.2/hash (running kernel: ...)"，
# 直接 awk '{print $2}' 抓到的是 "(running"，所以按斜杠切。
pve_version() {
    pveversion 2>/dev/null | head -1 | grep -oE 'pve-manager/[0-9][0-9.]*' | cut -d/ -f2
}

storage_exists() {
    pvesm status --storage "$1" 2>/dev/null | grep -q "active"
}

bridge_exists() {
    ip link show "$1" >/dev/null 2>&1
}

next_vmid() {
    pvesh get /cluster/nextid --output-format json | tr -d '" '
}

# 模板判定。不能用 `qm status` —— 它对模板只输出 "status: stopped"，
# 不带 template 字样。唯一可靠的来源是配置里的 template: 1
is_template() {
    qm config "$1" 2>/dev/null | grep -q '^template: 1$'
}

vm_exists() {
    [ -f "/etc/pve/qemu-server/$1.conf" ]
}

# ---------- SSH 到 guest ----------
# guest_ssh <user> <ip> <command...>
guest_ssh() {
    local user="$1" ip="$2"; shift 2
    ssh -q \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o LogLevel=ERROR \
        -i "$SSH_KEY_FILE" \
        "$user@$ip" "$@"
}

# 轮询等 SSH 端口通
wait_tcp() {  # wait_tcp <ip> <port> <timeout_s> <描述>
    local ip="$1" port="$2" timeout="$3" what="${4:-服务}" waited=0
    while ! timeout 2 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if [ "$waited" -ge "$timeout" ]; then
            return 1
        fi
        if [ $((waited % 15)) -eq 0 ]; then
            info "等 $what 上线… ${waited}s/${timeout}s"
        fi
    done
    return 0
}

# 轮询等 guest 里某条命令成功
wait_cmd() {  # wait_cmd <user> <ip> <timeout_s> <描述> -- <cmd...>
    local user="$1" ip="$2" timeout="$3" what="$4"; shift 4
    [ "${1:-}" = "--" ] && shift
    local waited=0
    while true; do
        if guest_ssh "$user" "$ip" "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge "$timeout" ]; then
            err "等「$what」超时（${timeout}s）"
            return 1
        fi
        if [ $((waited % 30)) -eq 0 ]; then
            info "等「$what」… ${waited}s/${timeout}s"
        fi
    done
}

# ---------- IP / CIDR 运算 ----------
# 推导网络参数要用。全用整数算，避免依赖 python/ipcalc。

ip2int() {  # 192.168.0.250 -> 3232235770
    local IFS=.
    read -r a b c d <<< "$1"
    echo $(( a*16777216 + b*65536 + c*256 + d ))
}

int2ip() {  # 3232235770 -> 192.168.0.250
    local i="$1"
    printf '%d.%d.%d.%d' \
        $(( (i/16777216) % 256 )) $(( (i/65536) % 256 )) \
        $(( (i/256) % 256 ))     $(( i % 256 ))
}

mask2int() {  # 前缀长度 -> 掩码整数。 24 -> 4294967040
    local pfx="$1" m=0 i
    [ "$pfx" -eq 0 ] && { echo 0; return; }
    for (( i=0; i<32; i++ )); do
        [ "$i" -lt "$pfx" ] && m=$(( m | (1 << (31 - i)) ))
    done
    echo "$m"
}

cidr_network() {  # 192.168.0.250/24 -> 3232235776
    local ip="$1" pfx="$2"
    echo $(( $(ip2int "$ip") & $(mask2int "$pfx") ))
}

cidr_broadcast() {  # 192.168.0.250/24 -> 3232236031
    local ip="$1" pfx="$2"
    echo $(( $(ip2int "$ip") | (0xFFFFFFFF ^ $(mask2int "$pfx")) ))
}

# 网桥上第一个非环回 IPv4（带前缀长度）。取不到就返回空。
bridge_cidr() {  # bridge_cidr <网桥名>
    ip -4 -o addr show dev "$1" scope global 2>/dev/null \
        | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' \
        | head -1 | awk '{print $2}'
}

# 同一子网内的默认网关；不在同一子网就返回空
default_gw_in_subnet() {  # default_gw_in_subnet <本机CIDR>
    local cidr="$1" ip pfx
    ip="${cidr%%/*}"; pfx="${cidr##*/}"
    local net; net=$(cidr_network "$ip" "$pfx")
    local gw
    gw=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $3; exit}')
    [ -n "$gw" ] || return 0
    local gwnet; gwnet=$(cidr_network "$gw" "$pfx")
    [ "$gwnet" = "$net" ] && echo "$gw"
    return 0
}

ip_in_cidr() {  # ip_in_cidr <ip> <cidr，如 100.64.0.0/10>
    local ip="$1" cidr="$2"
    local m; m=$(cidr_network "$cidr" "${cidr##*/}")
    [ $(( $(ip2int "$ip") & $(mask2int "${cidr##*/}") )) -eq "$m" ]
}

# CGNAT 段 100.64.0.0/10：Tailscale / 部分运营商 NAT 网关都在这里。
# 宿主若装了 Tailscale，/etc/resolv.conf 的 nameserver 往往就是 100.100.100.100
# （MagicDNS）。把它当 DNS 下发给 VM 是错的 —— guest 没装 Tailscale，根本访问不到，
# 结果就是 guest 完全无法解析域名。所以推导时要跳过这一段。
is_cgnat() {
    ip_in_cidr "$1" "100.64.0.0/10"
}

# Tailscale MagicDNS 的搜索域形如 <machine>.ts.net，同样不能下发给 guest。
is_ts_domain() {
    case "$1" in
        *.ts.net|ts.net) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 resolv.conf 取第一个非环回 nameserver
resolv_nameserver() {
    awk '/^[[:space:]]*nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null \
        | grep -vE '^127\.|^::1$' || true
}

resolv_search() {
    awk '/^[[:space:]]*search/ { $1=""; sub(/^[[:space:]]+/, ""); print; exit }' \
        /etc/resolv.conf 2>/dev/null | tr -s ' ' | cut -d' ' -f1 || true
}

# ---------- IP 工具 ----------
ip_in_pool() {  # ip_in_pool <ip> <start-end>
    local ip="$1" range="${2%-*}" start="${2%-*}" end="${2#*-}"
    # 整数化比较
    local IFS=.
    read -r a b c d <<<"$ip"
    local ia=$((a*256*256*256 + b*256*256 + c*256 + d))
    IFS=.
    read -r a b c d <<<"$start"
    local is=$((a*256*256*256 + b*256*256 + c*256 + d))
    IFS=.
    read -r a b c d <<<"$end"
    local ie=$((a*256*256*256 + b*256*256 + c*256 + d))
    [ "$ia" -ge "$is" ] && [ "$ia" -le "$ie" ]
}

# 收集 PVE 里已被占用的 IP（所有 VM/LXC 的 ipconfig + 实际运行中的）
used_ips() {
    local dir f
    for dir in /etc/pve/qemu-server /etc/pve/lxc; do
        for f in "$dir"/*.conf; do
            [ -e "$f" ] || continue
            grep -hoE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null \
                | cut -d= -f2
        done
    done | sort -u
}

# 探测 IP 是否没人用。
# 保守策略: ping 不通不算空 —— ARP 表里只要还有 MAC 记录就跳掉，
# 因为对方可能开着防火墙只是不回 ICMP。
ip_is_free() {
    local ip="$1"
    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        return 1
    fi
    if ip neigh show to "$ip" 2>/dev/null | grep -q 'lladdr'; then
        return 1
    fi
    return 0
}

# 从地址池里找一个空闲 IP
pick_free_ip() {  # pick_free_ip <pool> [要排除的IP...]
    local pool="$1"; shift
    local self_ip
    self_ip=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2) || true

    local taken
    taken=$( { used_ips; printf '%s\n' "$@"; printf '%s\n' "$self_ip"; } \
             | grep -v '^$' | sort -u )

    # 展开地址池：支持 192.168.0.100-199 和 a.b.c.1-10, 172.16.0.5 两种写法
    local cand list=""
    local seg
    local IFS_save="$IFS"
    IFS=','
    for seg in $pool; do
        unset IFS
        local start="${seg%-*}" end="${seg#*-}"
        if [ "$start" = "$seg" ]; then
            cand="$seg"
            list="$list $cand"
            continue
        fi
        local IFS=.
        read -r a b c d <<<"$start"
        local i=$(( a*16777216 + b*65536 + c*256 + d ))
        IFS=.
        read -r a b c d <<<"$end"
        local e=$(( a*16777216 + b*65536 + c*256 + d ))
        while [ "$i" -le "$e" ]; do
            list="$list $(printf '%d.%d.%d.%d' \
                $(( (i/16777216) % 256 )) $(( (i/65536) % 256 )) \
                $(( (i/256) % 256 )) $(( i % 256 )))"
            i=$((i + 1))
        done
        IFS=$IFS_save
    done
    unset IFS
    IFS=$IFS_save

    # 先按配置占用过滤，再按实际存活探测
    for cand in $list; do
        printf '%s\n' "$taken" | grep -qxF "$cand" && continue
        ip_is_free "$cand" || continue
        printf '%s' "$cand"
        return 0
    done
    return 1
}

# IP_POOL 里有几个地址当前在 ARP 表里有条目（= 有人在用）。
#
# 静态分配的地址如果落在路由器的 DHCP 段里，就可能出现"今天空闲、明天被 DHCP
# 发给别人"的冲突 —— 分配时刻探测不出来（ip_is_free 只能看到当下）。
# 这个函数给 bootstrap --check 用来提示风险，不负责解决。
pool_arp_hits() {  # pool_arp_hits <start-end> [网桥]
    local range="$1" br="${2:-$BRIDGE}"
    local lo="${range%%-*}" hi="${range#*-}"
    local lo_i hi_i
    lo_i=$(ip2int "$lo"); hi_i=$(ip2int "$hi")
    local i n=0
    for (( i=lo_i; i<=hi_i && i-lo_i<=2048; i++ )); do
        ip neigh show to "$(int2ip "$i")" dev "$br" 2>/dev/null | grep -q lladdr && n=$(( n + 1 ))
    done
    echo "$n"
}

# ---------- 其他 ----------

# 从 qga 的 network-get-interfaces 输出里提取第一个非回环 IPv4。
# PVE 打的是缩进过的 JSON，冒号两边有空格:  "ip-address" : "192.168.0.5"
# 新版 QGA 字段在 ip-addresses 数组里，老版是顶层 ip-address，两种都认。
qga_first_ipv4() {
    printf '%s' "$1" \
        | grep -oE '"(ip-address|address)"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -vE '^127\.' \
        | head -1
}
size_to_kb() {  # 100G -> 104857600 (KB)
    local s="${1%G}"
    case "$1" in
        *G) echo $(( s * 1024 * 1024 )) ;;
        *M) echo $(( ${1%M} * 1024 )) ;;
        *)  echo "$1" ;;
    esac
}

size_to_mb() {
    echo $(( $(size_to_kb "$1") / 1024 ))
}

# 内存气球地板（MiB）。
# `qm set --balloon N` 的 N 是【最小内存】不是目标值，见 QemuServer.pm:2538
#     balloon_min = $conf->{balloon} * 1024*1024
# 自动气球会拿它当缩容下限，所以这个值必须合理，不能写 0 或 1。
balloon_floor() {  # balloon_floor <memory_mb>
    local mem="$1" pct="${BALLOON_FLOOR_PCT:-25}"
    local floor=$(( mem * pct / 100 ))
    # 至少给 512 MiB
    [ "$floor" -lt 512 ] && floor=512
    echo "$floor"
}

# 宿主自动气球目标设置（节点级）
get_auto_balloon_target() {
    pvenode config get 2>/dev/null | sed -n 's/^ballooning-target: //p' || true
}
