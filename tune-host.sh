#!/usr/bin/env bash
# ==============================================================================
#  tune-host.sh —— 调整宿主（PVE 节点）上影响模板默认行为的设置
#
#  目前只管一件事：PVE 自动气球（auto ballooning）
#
#  【为什么必须改】
#  pvestatd 的算法（pvestatd.pm:296-320）:
#      goal = memtotal * ballooning-target / 100 - memused
#    goal > 0  ->  宿主有富余，把内存【送给】VM，直到各自 maxmem
#    goal < 0  ->  宿主被 VM 占太多，从 VM【收回】内存，每轮 100MB 逼近 balloon 地板
#
#  PVE 默认 ballooning-target = 80。VM 吃满后 memused 上到 80% 以上，goal 转负，
#  PVE 就一轮轮往回收，把每台 VM 压到各自的 balloon 地板。
#  实测: 配 4096M 的 VM 被压到 948M；配 2048M 的在启动阶段直接 OOM
#        (systemd generator sd-gens 被杀，boot 完不成)。
#  也就是说模板里写的 memory 是名存实亡的。
#
#  【改成什么】
#  ballooning-target = 100 -> goal 恒为正 -> 每台 VM 稳定在 maxmem，
#  也就是配置文件里的 memory 值。VM 实际可用内存 = 你写的那个数字。
#
#  【代价】
#  内存不再自动回收。所有 VM 的 memory 之和必须 <= 宿主物理内存，
#  否则宿主吃 swap 甚至 OOM。气球设备仍在，GUI 里可以手动调小
#  （地板 = 内存的 BALLOON_FLOOR_PCT%）。
#
#  【注意】
#  改完必须 systemctl restart pvestatd，它会缓存节点配置。
#  之后 VM 内存每轮 100MB 往回涨，2-4 分钟才到满。
#
# 用法:
#     ./tune-host.sh            # 应用 conf.env 里的设置
#     ./tune-host.sh --show     # 只看当前状态
#     ./tune-host.sh --revert   # 恢复 PVE 默认（80）
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_pve

MODE="apply"
case "${1:-}" in
    --show)   MODE="show" ;;
    --revert) MODE="revert" ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")       ;;
    *) die "未知参数 $1（-h 看用法）" ;;
esac

CUR=$(get_auto_balloon_target)
: "${CUR:=80 (PVE 默认，配置文件里没写)}"

step "PVE 自动气球现状"
echo "    ballooning-target = $CUR"
if [ "${CUR%% *}" = "100" ]; then
    echo "    含义: 每台 VM 稳定在 maxmem（= 配置的 memory），不会被回收"
else
    echo "    含义: 宿主内存占用到这个百分比后，就开始从 VM 往回收"
    echo "    ⚠️  非 100 -> VM 配的内存会被悄悄收回去，内存太小时会 OOM"
fi
echo
echo "    各 VM 实到内存:"
FOUND=0
for v in $(qm list | awk 'NR>1 && $3 != "stopped" {print $1}'); do
    line=$(echo "info balloon" | timeout 5 qm monitor "$v" 2>/dev/null | grep -o 'balloon:.*') || line=""
    if [ -n "$line" ]; then
        FOUND=1
        echo "      VM $v: $(printf '%s' "$line" | sed 's/^balloon: //')"
    fi
done
[ "$FOUND" -eq 0 ] && echo "      （没有运行中的 VM）"
echo

restart_pvestatd() {
    log "重启 pvestatd 让配置生效（它会缓存节点配置）..."
    systemctl restart pvestatd
    sleep 3
    ok "已重启。VM 内存每轮 100MB 往目标走，2-4 分钟到满"
}

case "$MODE" in
    show) exit 0 ;;
    revert)
        step "恢复 PVE 默认：ballooning-target = 80"
        pvenode config set --ballooning-target 80
        restart_pvestatd
        echo "    VM 内存会开始被逐步回收（每轮 100MB，逼近 balloon 地板）"
        ;;
    apply)
        WANT="${AUTO_BALLOON_TARGET:-100}"
        if [ "${CUR%% *}" = "$WANT" ]; then
            ok "已经是 $WANT，配置无需改动"
            pvenode config get 2>/dev/null | grep -q ballooning-target \
                || warn "但 pvestatd 可能还在用旧值，建议: systemctl restart pvestatd"
        else
            step "设置 ballooning-target = $WANT"
            pvenode config set --ballooning-target "$WANT"
            restart_pvestatd
        fi
        echo
        echo "  当前行为:"
        echo "    · VM 实到内存 = 配置里的 memory（气球稳定在 maxmem）"
        echo "    · 气球设备还在，GUI 里可手动调小，地板 = 内存的 ${BALLOON_FLOOR_PCT:-25}%"
        echo "    · ⚠️ 所有 VM 的 memory 之和必须 <= 宿主内存，否则宿主吃 swap / OOM"
        echo "    · 改回 PVE 默认:  $SCRIPT_DIR/tune-host.sh --revert"
        echo
        ;;
esac
