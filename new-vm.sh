#!/usr/bin/env bash
# ==============================================================================
#  new-vm.sh —— 从模板一键创建一台配好的 Ubuntu VM
#
#  用法:
#     new-vm.sh <名字> [选项]
#
#  例子:
#     new-vm.sh myapp --auto-ip                    # 自动挑个空闲静态 IP
#     new-vm.sh myapp                              # DHCP
#     new-vm.sh myapp --ip 192.168.0.120           # 指定静态 IP
#     new-vm.sh myapp --dhcp --cores 8 --mem 8192  # 改规格
#     new-vm.sh myapp --no-start                   # 只建不启动
#
#  跑完这台 VM 就已经能 SSH 上去了，终端会直接打出登录命令。
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 1; }
case "$1" in
    -h|--help) usage; exit 0 ;;
esac

NAME=""
VMID=""
IP=""
MODE="auto"          # auto | dhcp | static
CORES_OVR=""
MEM_OVR=""
DISK_OVR=""
KEY_OVR="$SSH_PUBKEY_FILE"
PASS_OVR="$CI_PASSWORD"
USER_OVR="$CI_USER"
GW_OVR="$GATEWAY"
DNS_OVR="$DNS"
DOMAIN_OVR="$SEARCH_DOMAIN"
DO_START=1
DO_WAIT=1
TAGS="ubuntu;dev"
EXTRA_DISK=""
SNAPSHOT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --vmid)    VMID="$2"; shift 2 ;;
        --ip)      IP="$2"; MODE="static"; shift 2 ;;
        --dhcp)    MODE="dhcp"; shift ;;
        --auto-ip) MODE="auto"; shift ;;
        --gw)      GW_OVR="$2"; shift 2 ;;
        --dns)     DNS_OVR="$2"; shift 2 ;;
        --domain)  DOMAIN_OVR="$2"; shift 2 ;;
        --cores)   CORES_OVR="$2"; shift 2 ;;
        --mem)     MEM_OVR="$2"; shift 2 ;;      # MiB
        --disk)    DISK_OVR="$2"; shift 2 ;;    # 20G / 200G
        --key)     KEY_OVR="$2"; shift 2 ;;     # 公钥文件
        --password) PASS_OVR="$2"; shift 2 ;;
        --user)    USER_OVR="$2"; shift 2 ;;
        --tags)    TAGS="$2"; shift 2 ;;
        --data-disk) EXTRA_DISK="$2"; shift 2 ;;
        --snapshot) SNAPSHOT=1; shift ;;
        --no-start) DO_START=0; DO_WAIT=0; shift ;;
        --no-wait)  DO_WAIT=0; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "未知选项: $1（-h 看用法）" ;;
        *)
            [ -z "$NAME" ] || die "只能给一个名字（多余: $1）"
            NAME="$1"; shift
            ;;
    esac
done

# =============================================================== 前置检查 ====
require_root
require_pve

[ -n "$NAME" ] || { usage; die "缺少 VM 名字"; }
[[ "$NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]] \
    || die "名字 '$NAME' 不合法：只允许字母数字和 . _ - ，且必须字母数字开头结尾"

is_template "$TPL_VMID" \
    || die "$TPL_VMID 不是模板（qm config $TPL_VMID | grep template）。先跑 build-template.sh"

[ -z "$VMID" ] && VMID=$(next_vmid)
[[ "$VMID" =~ ^[0-9]+$ ]] && [ "$VMID" -ge 100 ] || die "VMID 不合法: $VMID"
if [ -f "/etc/pve/qemu-server/$VMID.conf" ]; then
    die "VMID $VMID 已被占用（$(qm config "$VMID" 2>/dev/null | sed -n 's/^name: //p')）"
fi

[ -r "$KEY_OVR" ] || die "找不到公钥 $KEY_OVR"

CORES_F=${CORES_OVR:-$CORES}
MEM_F=${MEM_OVR:-$MEMORY_MB}
DISK_F=${DISK_OVR:-$DISK_SIZE}
TPL_DISK=$(qm config "$TPL_VMID" | sed -n 's/^scsi0: .*size=//p' | cut -d, -f1)
TPL_DISK_B=$(size_to_kb "${TPL_DISK:-0}")

# 内存下限。实测: 2048M 的 clone 在启动阶段被 OOM killer 干掉
# (systemd generator sd-gens 被杀)，boot 都完不成。4096M 正常。
MIN_MEM_MB="${MIN_MEM_MB:-4096}"
if [ "$MEM_F" -lt "$MIN_MEM_MB" ]; then
    die "内存 $MEM_F M 太小。这套模板实测至少要 ${MIN_MEM_MB}M（2G 会在启动阶段 OOM）"
fi

# 磁盘只能往大改（raw 盘没法缩）
if [ -n "$DISK_OVR" ] && [ "$(size_to_kb "$DISK_F")" -lt "${TPL_DISK_B:-0}" ]; then
    die "磁盘只能比模板的 ${TPL_DISK} 大（raw 盘不支持缩小）"
fi

# ------------------------------------------------------------------ 选 IP ---
HOST_BRIDGE_IP=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2) || true
case "$IP" in
    "$HOST_BRIDGE_IP") die "$IP 是 PVE 本机的地址，换一个" ;;
esac

if [ "$MODE" = "static" ]; then
    [ -n "$IP" ] || die "--ip 需要给地址"
    if printf '%s\n' "$(used_ips)" | grep -qxF "$IP"; then
        warn "$IP 已被别的 VM 配置占用（不一定是真冲突，确认后可用 --force-ip）"
    fi
fi

# =============================================================== 1. 克隆 ====
step "1/6  从模板 $TPL_VMID 克隆"
# lvm-thin 只支持 raw，所以只能 full clone（linked clone 用不了）
time_start=$(date +%s)
qm clone "$TPL_VMID" "$VMID" --name "$NAME" --full 1
ok "VM $VMID ($NAME) 已克隆，耗时 $(( $(date +%s) - time_start ))s"

# =============================================================== 2. 规格 ====
step "2/6  设置规格 ${CORES_F}C / ${MEM_F}M / ${DISK_F}"
# 气球地板要按【最终内存】算 —— --balloon N 的 N 是最小内存 MiB
# （QemuServer.pm:2538 balloon_min = balloon * 1024*1024），传 0/1 等于允许压穿
BALLOON_FLOOR=$(balloon_floor "$MEM_F")
qm set "$VMID" \
    --cores "$CORES_F" \
    --sockets 1 \
    --memory "$MEM_F" \
    --balloon "$BALLOON_FLOOR" \
    --onboot 0 \
    --tags "$TAGS" \
    --description "由 new-vm.sh 于 $(date -Iseconds) 从 $TPL_NAME 创建"

if [ "$(size_to_kb "$DISK_F")" -gt "${TPL_DISK_B:-0}" ]; then
    qm disk resize "$VMID" scsi0 "$DISK_F"
    ok "scsi0 已从 $TPL_DISK 扩到 $DISK_F（guest 首次开机自动 growpart 铺满）"
fi

if [ -n "$EXTRA_DISK" ]; then
    qm set "$VMID" --scsi1 "$STORAGE:$(size_to_kb "$EXTRA_DISK")"
    ok "已加数据盘 scsi1 ($EXTRA_DISK)，未格式化"
fi

if [ "$SNAPSHOT" -eq 1 ]; then
    qm snapshot "$VMID" "init" --description "new-vm.sh 创建时的干净状态" >/dev/null
    ok "已打快照 init"
fi

# =========================================================== 3. cloud-init ===
step "3/6  配置 cloud-init"
qm set "$VMID" \
    --ciuser "$USER_OVR" \
    --cipassword "$PASS_OVR" \
    --sshkeys "$KEY_OVR" \
    --nameserver "$DNS_OVR"

if [ -n "$DOMAIN_OVR" ]; then
    qm set "$VMID" --searchdomain "$DOMAIN_OVR"
else
    qm set "$VMID" --delete searchdomain 2>/dev/null || true
fi

if [ "$MODE" = "auto" ]; then
    IP=$(pick_free_ip "$IP_POOL")
    [ -n "$IP" ] || die "地址池 $IP_POOL 里找不到空闲 IP，手动 --ip 指定"
    MODE="static"
    ok "自动分配 IP $IP（来自 $IP_POOL）"
fi

if [ "$MODE" = "static" ]; then
    qm set "$VMID" --ipconfig0 "ip=$IP/24,gw=$GW_OVR"
    ok "网络: 静态 $IP/24 via $GW_OVR"
else
    qm set "$VMID" --ipconfig0 "ip=dhcp"
    ok "网络: DHCP"
fi

# ================================================================ 4. 启动 ====
if [ "$DO_START" -eq 0 ]; then
    step "完成（未启动）"
    echo "  qm start $VMID"
    exit 0
fi

step "4/6  启动 VM $VMID"
qm start "$VMID"
ok "已启动"

# ================================================================ 5. 等待 ====
FINAL_IP="$IP"
step "5/6  等待 cloud-init + guest agent 就绪"

if [ "$MODE" = "dhcp" ]; then
    # DHCP 的话从 guest agent 里问实际地址
    for _ in $(seq 1 90); do
        out=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null) || true
        if [ -n "$out" ]; then
            cand=$(qga_first_ipv4 "$out") || cand=""
            if [ -n "$cand" ]; then FINAL_IP="$cand"; break; fi
        fi
        sleep 4
    done
    [ -n "$FINAL_IP" ] || warn "没问到 DHCP 地址，稍后用 qm guest cmd $VMID network-get-interfaces 查"
else
    # 静态：等 guest agent 起来能证明 cloud-init 跑完了
    for _ in $(seq 1 90); do
        qm guest cmd "$VMID" ping >/dev/null 2>&1 && break
        sleep 4
    done
fi

if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
    ok "guest agent 已响应（cloud-init 已完成）"
else
    warn "guest agent 还没响应。VM 可能还在装东西，或磁盘扩容中"
    log "  排查: qm terminal $VMID   |   qm guest cmd $VMID ping"
fi

# ================================================================ 6. 汇总 ====
step "6/6  完成"
cat <<EOF
  VMID     $VMID
  名字     $NAME
  状态     $(qm status "$VMID" 2>/dev/null | awk '{print $2}')
  规格     ${CORES_F} 核 / ${MEM_F} MB / 磁盘 ${DISK_F}
  网络     $(qm config "$VMID" | sed -n 's/^ipconfig0: //p') → $FINAL_IP
  用户     $USER_OVR
  密码     ${PASS_OVR}
  登录     ssh -i $SSH_KEY_FILE $USER_OVR@${FINAL_IP}
          ssh -i $SSH_KEY_FILE root@${FINAL_IP}
EOF
[ "$DO_WAIT" -eq 1 ] && [ -n "$FINAL_IP" ] && [ "$MODE" = "static" ] && {
    if wait_tcp "$FINAL_IP" 22 120 "SSH"; then
        ok "SSH 已就绪"
    else
        warn "SSH 还没通，稍等一下或看 qm terminal $VMID"
    fi
}
echo
log "销毁这台:  qm destroy $VMID --purge --destroy-unreferenced-disks 1"
echo
