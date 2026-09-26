#!/usr/bin/env bash
# ==============================================================================
#  build-template.sh —— 从官方 cloud image 构建一个 PVE 模板
#
#  产出：VMID 9000 类型的 PVE VM Template（UEFI + virtio + 原生 cloud-init）
#  之后用 GUI 点两下，或者 new-vm.sh 一行命令，就能clone出配好的 Ubuntu VM。
#
#  用法：
#     ./build-template.sh              # 构建（模板已存在会拒绝）
#     ./build-template.sh --force      # 删掉旧模板重新构建
#     ./build-template.sh --keep       # 保留构建态（调试用，别用于生产）
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FORCE=0
KEEP=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --keep)  KEEP=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "未知参数: $a" ;;
    esac
done
[ "$KEEP_CLEAN" = "1" ] && KEEP=1

BUILD_START=$(date +%s)
mkdir -p "$(dirname "$BUILD_LOG")"
: > "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

# ==============================================================================
step "0/9  前置检查"
# ==============================================================================
require_root
require_pve

command -v genisoimage >/dev/null 2>&1 \
    || die "缺 genisoimage（PVE 用它生成 cloud-init ISO）：apt install genisoimage"

[ "$(uname -m)" = "x86_64" ] \
    || die "本模板用 amd64 cloud image，当前架构是 $(uname -m)"

# ---- cloud image: 存在性 + 指纹校验 ----
# 可复现构建的前提是输入一致，所以不只看文件在不在，还要看 sha256 对不对。
# 指纹不符说明文件被改过或换了版本，继续下去得不到和 reference/ 里一样的模板。
if [ ! -f "$CLOUD_IMG" ]; then
    die "缺少 cloud image: $CLOUD_IMG
  下载: bootstrap.sh 会自动拉并校验；或手动
        wget -O '$CLOUD_IMG' '$CLOUD_IMG_URL'"
fi
if [ -n "${CLOUD_IMG_SHA256:-}" ]; then
    got=$(sha256sum "$CLOUD_IMG" | cut -d' ' -f1)
    [ "$got" = "$CLOUD_IMG_SHA256" ] || die "cloud image 指纹不符！
    期望: $CLOUD_IMG_SHA256
    实际: $got
    文件: $CLOUD_IMG
  处理: 删掉重下，或改 conf.env 的 CLOUD_IMG_URL / CLOUD_IMG_SHA256
        rm -f '$CLOUD_IMG'"
    ok "cloud image 指纹匹配（$CLOUD_IMG_URL）"
else
    warn "conf.env 没设 CLOUD_IMG_SHA256，跳过指纹校验（构建结果不可复现）"
fi

storage_exists "$STORAGE" || die "存储 $STORAGE 不存在或未激活"
bridge_exists "$BRIDGE"   || die "网桥 $BRIDGE 不存在"

if qm status "$TPL_VMID" >/dev/null 2>&1 || [ -f "/etc/pve/qemu-server/$TPL_VMID.conf" ]; then
    if [ "$FORCE" -eq 0 ]; then
        die "VMID $TPL_VMID 已存在（$(qm status "$TPL_VMID" 2>/dev/null || echo unknown)）。
    要重建的话：./build-template.sh --force"
    fi
    step "0/9  删除已存在的模板 $TPL_VMID"
    # qm destroy 不会停运行中的 VM，得先停
    if qm status "$TPL_VMID" 2>/dev/null | grep -q running; then
        info "模板在运行，先停机 ..."
        timeout 150 qm shutdown "$TPL_VMID" --timeout 60 >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            qm status "$TPL_VMID" 2>/dev/null | grep -q running || break
            sleep 2
        done
        qm status "$TPL_VMID" 2>/dev/null | grep -q running && qm stop "$TPL_VMID" >/dev/null
    fi
    # 卷可能被 lock 住，重试几次
    for i in 1 2 3; do
        if qm destroy "$TPL_VMID" --purge --destroy-unreferenced-disks 1 2>&1 | tail -1; then
            break
        fi
        warn "删除重试 $i/3 ..."
        sleep 5
    done
    [ -f "/etc/pve/qemu-server/$TPL_VMID.conf" ] \
        && die "删不掉 $TPL_VMID，手动检查: qm status $TPL_VMID; lvs | grep $TPL_VMID"
    ok "旧模板已删除"
fi

if [ "$KEEP" -eq 0 ]; then
    if ping -c1 -W1 "$BUILD_IP" >/dev/null 2>&1; then
        die "构建用 IP $BUILD_IP 已被占用，改 conf.env 里的 BUILD_IP"
    fi
fi

[ -r "$SSH_KEY_FILE" ] || die "找不到私钥 $SSH_KEY_FILE"
[ -r "$SSH_PUBKEY_FILE" ] || die "找不到公钥 $SSH_PUBKEY_FILE"

ok "PVE $(pve_version)"
ok "cloud image: $CLOUD_IMG ($(qemu-img info "$CLOUD_IMG" 2>/dev/null | awk '/virtual size/{print $3,$4}'))"
ok "存储 $STORAGE / 网桥 $BRIDGE"
ok "构建 IP $BUILD_IP，模板规格 ${CORES}C / ${MEMORY_MB}M / ${DISK_SIZE}"
[ "$KEEP" -eq 1 ] && warn "KEEP 模式：不会清理 cloud-init 状态和 SSH host key"

# ==============================================================================
step "0b/9  宿主设置：关掉 PVE 自动气球回收"
# ==============================================================================
# 不做这步的话，模板里写的 ${MEMORY_MB}M 是名存实亡的 —— pvestatd 会把内存
# 一点点收回去（详见 tune-host.sh 顶部注释）
if [ -x "$SCRIPT_DIR/tune-host.sh" ]; then
    "$SCRIPT_DIR/tune-host.sh" 2>&1 | sed 's/^/  /'
    ok "宿主设置已对齐（回滚: $SCRIPT_DIR/tune-host.sh --revert）"
else
    warn "找不到 tune-host.sh，跳过宿主设置。VM 内存可能被自动气球回收"
fi

# ==============================================================================
step "1/9  创建模板 VM 骨架"
# ==============================================================================
# 构建这台机器的内存。模板平时不运行，只有构建那一刻在跑（装包最多 2-3G），
# 所以按宿主实际余量分配就够，不必顶满 MEMORY_MB —— 这样 8G 的机器也能构建一个
# 标称 20G 的模板。构建结束前会把配置里的 memory 写回 MEMORY_MB。
auto_build_mem() {
    local want="${BUILD_MEM_MB:-}"
    if [ -z "$want" ]; then
        local avail_mb
        avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
        want=$(( avail_mb / 2 ))
        [ "$want" -gt "$MEMORY_MB" ] && want="$MEMORY_MB"
        [ "$want" -gt 4096 ] && want=4096
    fi
    [ "$want" -lt 2048 ] && want=2048
    echo "$want"
}
BUILD_MEM=$(auto_build_mem)

# 注意: cores/memory 是写进配置的，clone 时会作为默认值继承。
# --balloon 传的是【内存地板】(MiB)，不是目标值 —— 传 0/1 等于允许被压到 0/1 MiB
BALLOON_FLOOR=$(balloon_floor "$MEMORY_MB")
log "内存气球地板: ${BALLOON_FLOOR}M (内存的 ${BALLOON_FLOOR_PCT:-25}%)"
if [ "$BUILD_MEM" -ne "$MEMORY_MB" ]; then
    log "构建期只分配 ${BUILD_MEM}M（省宿主内存），构建完配置写回 ${MEMORY_MB}M"
fi

qm create "$TPL_VMID" \
    --name "$TPL_NAME" \
    --description "Ubuntu 24.04 LTS Dev/测试模板 — 由 build-template.sh 生成于 $(date -Iseconds)" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --cores "$CORES" \
    --sockets 1 \
    --memory "$BUILD_MEM" \
    --balloon "$BALLOON_FLOOR" \
    --cpu "${CPU:-host}" \
    --net0 "$NET_MODEL,bridge=$BRIDGE" \
    --agent 1 \
    --tablet 1 \
    --serial0 socket \
    --vga std \
    --onboot 0 \
    --protection 0
ok "VM $TPL_VMID 已创建（UEFI/OVMF, q35, virtio-scsi-single, 气球地板 ${BALLOON_FLOOR}M, guest agent）"

# ==============================================================================
step "2/9  导入系统盘并扩容到 $DISK_SIZE"
# ==============================================================================
if qm disk import "$TPL_VMID" "$CLOUD_IMG" "$STORAGE" --format raw --target-disk unused0 2>/dev/null; then
    :
else
    qm importdisk "$TPL_VMID" "$CLOUD_IMG" "$STORAGE" --format raw --target-disk unused0
fi

UNUSED_VOL=$(qm config "$TPL_VMID" | sed -n 's/^unused0: //p' | cut -d, -f1)
[ -n "$UNUSED_VOL" ] || die "导入的磁盘卷名解析失败"
ok "导入为 $UNUSED_VOL"

qm set "$TPL_VMID" --scsi0 "$UNUSED_VOL,discard=on,iothread=1,ssd=1,media=disk"
qm disk resize "$TPL_VMID" scsi0 "$DISK_SIZE"
ACTUAL=$(qm config "$TPL_VMID" | sed -n 's/^scsi0: .*size=//p' | cut -d, -f1)
ok "scsi0 已挂载，实际大小 ${ACTUAL:-?}"

# ==============================================================================
step "3/9  配置 cloud-init 驱动器"
# ==============================================================================
# local-lvm:cloudinit 是 PVE 的占位写法：启动时 PVE 自动为每个 VM 生成
# 独立的 vm-<vmid>-cloudinit 4MiB 卷并填入 user-data / network-config / meta-data
qm set "$TPL_VMID" \
    --ide2 "$STORAGE:cloudinit,media=cdrom" \
    --citype nocloud \
    --ciupgrade 0 \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --sshkeys "$SSH_PUBKEY_FILE" \
    --nameserver "$DNS" \
    --boot "order=scsi0"

# 构建期用静态 IP，方便直接 SSH 进去定制；转模板前会改回 DHCP
qm set "$TPL_VMID" --ipconfig0 "ip=$BUILD_IP/24,gw=$GATEWAY"
[ -n "$SEARCH_DOMAIN" ] && qm set "$TPL_VMID" --searchdomain "$SEARCH_DOMAIN"

ok "cloud-init 驱动器就绪，user=$CI_USER，ip=$BUILD_IP/24"
log "cloud-init ISO 在 VM 启动时自动生成（日志: journalctl -u pvedaemon -f 里能看到）"

# ==============================================================================
step "4/9  首次启动，等 SSH 就绪"
# ==============================================================================
qm start "$TPL_VMID"
ok "VM 已启动，VM 100% 依赖它第一次把 cloud-init 跑完"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
log "等 SSH 22 端口 ($BUILD_IP) ..."
wait_tcp "$BUILD_IP" 22 420 "SSH" || {
    err "SSH 起不来。排查:"
    log "  qm status $TPL_VMID          # VM 状态"
    log "  qm terminal $TPL_VMID       # 看启动画面（q 退出）"
    log "  tail -f $BUILD_LOG"
    exit 1
}
ok "SSH 端口已开"

log "等 cloud-init 跑完 ..."
waited=0
while true; do
    # 注意两点:
    #   1. 只看 stdout 里的 "status: xxx"，不看退出码 —— 状态是 "degraded" 时
    #      cloud-init 退出码也非 0，但功能是好的（PVE 生成的 user-data 用了已
    #      废弃的 `user:` 字段，Ubuntu 24.04 的 cloud-init 26.1 会标 degraded）
    #   2. 失败时不能写 `|| state=""` —— 那会把已经捕获到的输出覆盖成空
    state=$(guest_ssh "$CI_USER" "$BUILD_IP" "cloud-init status" 2>/dev/null \
            | sed -n 's/.*status: //p' | tr -d '\r') || true
    case "$state" in
        done|degraded*) ok "cloud-init $state"; break ;;
        error)         err "cloud-init 报错了"
                       guest_ssh "$CI_USER" "$BUILD_IP" \
                         "sudo tail -40 /var/log/cloud-init-output.log" 2>/dev/null || true
                       exit 1 ;;
        disabled)      ok "cloud-init 未启用（异常）"; break ;;
    esac
    sleep 5
    waited=$((waited + 5))
    [ "$waited" -ge 420 ] && { err "cloud-init 420s 还没跑完（当前: ${state:-SSH 未就绪}）"; exit 1; }
    [ $((waited % 30)) -eq 0 ] && info "cloud-init: ${state:-SSH 未就绪} ${waited}s"
done

# ==============================================================================
step "5/9  guest 内部定制（装包 / SSH / 系统调优）"
# ==============================================================================
PKGS=$(echo "$PKG_CORE $PKG_EXTRA" | tr '[:space:]' '\n' | grep -v '^$' | sort -u | tr '\n' ' ') || true

log "上传 provision.sh ..."
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SCRIPT_DIR/guest/provision.sh" "$CI_USER@$BUILD_IP:/tmp/provision.sh" \
    || die "scp 失败"

info "装 ${PKGS} 个软件包（最慢的一步，通常 2-5 分钟）..."
guest_ssh "$CI_USER" "$BUILD_IP" \
    "sudo bash /tmp/provision.sh \
        --user '$CI_USER' \
        --password '$CI_PASSWORD' \
        --key-file '$SSH_KEY_FILE' \
        --timezone '$TIMEZONE' \
        --swap '$SWAP_SIZE' \
        --packages '$PKGS'"
ok "guest 定制完成"

# ==============================================================================
step "6/9  验证 guest 状态"
# ==============================================================================
verify() {
    local desc="$1" cmd="$2" expect="$3"
    local out
    # 命令退出码非 0 不代表没输出（比如 systemctl is-active 未运行时退出 3），
    # 所以只兜住执行失败，绝不能覆盖已捕获的输出
    out=$(guest_ssh "$CI_USER" "$BUILD_IP" "$cmd" 2>/dev/null | tr -d '\r') || true
    if printf '%s' "$out" | grep -qi -- "$expect"; then
        ok "$desc"
    else
        warn "$desc —— 期望匹配 '$expect'，实际: ${out:-<空>}"
    fi
}

verify "系统版本"        ". /etc/os-release; echo \$PRETTY_NAME"            "24.04"
verify "根分区已铺满整个盘" "findmnt -no SIZE /"                             "G"
verify "根分区可用空间"  "df -h --output=avail / | tail -1 | awk '{print \$1}'" "[0-9]"
verify "guest agent"     "systemctl is-active qemu-guest-agent"             "active"
verify "guest agent 开机自启" "systemctl is-enabled qemu-guest-agent"       "enabled"
verify "root 免密登录"   "sudo -n true && echo yes"                        "yes"
verify "sudo 免密"       "sudo -n id -u | grep -qx 0 && echo yes"           "yes"
verify "growpart 可用"   "command -v growpart"                              "growpart"
verify "resize_rootfs 打开" "grep -c '^resize_rootfs: true' /etc/cloud/cloud.cfg" "1"
verify "时区"            "cat /etc/timezone"                               "$TIMEZONE"
verify "编译器"          "gcc --version | head -1"                          "gcc"
verify "已装包数"        "dpkg -l | awk '/^ii/{print \$2}' | wc -l"        "^[0-9]"

if qm guest cmd "$TPL_VMID" ping >/dev/null 2>&1; then
    ok "PVE -> guest agent 通道正常（qm guest cmd $TPL_VMID ping）"
else
    warn "PVE -> guest agent 没回应，检查 virtio-serial 通道"
fi

# ==============================================================================
step "7/9  清理成可克隆的干净状态"
# ==============================================================================
# 这一步决定 template 的质量：清掉实例身份、主机密钥、日志、包缓存，
# 让每台 clone 都能拿到全新的 machine-id 和 SSH host key
#
# ⚠️ 整个清理必须在【同一个 SSH 会话】里做完，而且 SSH host key 必须最后删。
# 原因: Ubuntu 24.04 的 sshd 是 socket 激活的（ssh.socket），每个新连接都会
# 起一个全新的 sshd 进程、重新从磁盘读 host key 文件。文件一删，新连接直接被
# reset —— 之前就是这么把构建脚本自己踢下线的。
if [ "$KEEP" -eq 1 ]; then
    warn "KEEP 模式：跳过清理（这台 VM 不能直接当模板用）"
else
    log "停掉会自动重装/重启的服务 ..."
    guest_ssh "$CI_USER" "$BUILD_IP" "sudo systemctl stop unattended-upgrades 2>/dev/null; \
        sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null; true"

    # 用 base64 传输，避免多层引号转义地狱
    CLEAN_B64=$(cat <<'CLEAN_EOF' | base64 -w0
set -u
say() { echo "[clean] $*"; }

say "cloud-init clean ..."
cloud-init clean --logs --machine-id 2>/dev/null \
    || rm -rf /var/lib/cloud/instances /var/lib/cloud/instance /var/lib/cloud/data

say "抹掉实例身份 / 日志 / 包缓存 / 历史 ..."
rm -f /etc/machine-id /var/lib/dbus/machine-id
: > /etc/machine-id
rm -rf /var/log/journal/*
rm -f /var/log/*.log /var/log/*.gz /var/log/lastlog /var/log/wtmp /var/log/btmp /var/log/faillog
rm -f /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
rm -f /root/.bash_history /home/*/.bash_history
rm -f /etc/sudoers.d/*+ 2>/dev/null
# 构建期静态 IP 的 netplan 一并删掉: 避免 clone 时残留错误的静态配置。
# 正常情况下 clone 的 cloud-init 会重新生成 50-cloud-init.yaml。
# 万一没生成，guest 是"没网"这种显式失败，而不是"悄悄用错 IP"这种隐性失败。
rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/01-netcfg.yaml

say "回收磁盘空间 ..."
sync
fstrim -av 2>&1 | sed 's/^/[clean]   /'

# ---- 验证（在删 host key 之前还能查）----
MID=$(wc -c < /etc/machine-id | tr -d ' ')
HK_BEFORE=$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l | tr -d ' ')
PKGS=$(dpkg -l | awk '/^ii/{print $2}' | wc -l | tr -d ' ')
ROOTFS=$(df -h --output=size / | tail -1 | tr -d ' ')
USED=$(du -sh --one-file-system / 2>/dev/null | awk '{print $1}')
echo "[clean] RESULT machine_id_bytes=$MID hostkeys_before=$HK_BEFORE pkgs=$PKGS rootfs=$ROOTFS used=$USED"

# ---- host key 必须最后删 ----
say "移除 SSH host key（clone 时由 cloud-init 重新生成）..."
rm -f /etc/ssh/ssh_host_*
HK_AFTER=$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l | tr -d ' ')
echo "[clean] RESULT hostkeys_after=$HK_AFTER"
say "清理完成，这个 SSH 会话到此为止（host key 已删，新连接会失败）"
CLEAN_EOF
)

    log "执行清理（约 30-60 秒）..."
    CLEAN_OUT=$(guest_ssh "$CI_USER" "$BUILD_IP" \
        "echo '$CLEAN_B64' | base64 -d | sudo bash" 2>/dev/null) || CLEAN_OUT=""
    printf '%s\n' "$CLEAN_OUT" | sed 's/^/  /'

    mid=$(printf '%s' "$CLEAN_OUT" | sed -n 's/.*machine_id_bytes=\([0-9]*\).*/\1/p' | head -1)
    hka=$(printf '%s' "$CLEAN_OUT" | sed -n 's/.*hostkeys_after=\([0-9]*\).*/\1/p' | head -1)
    used=$(printf '%s' "$CLEAN_OUT" | sed -n 's/.*used=\([^ ]*\).*/\1/p' | head -1)

    if [ "$mid" = "0" ]; then
        ok "machine-id 已清空"
    else
        err "machine-id 没清干净（bytes=${mid:-?}）"
    fi
    if [ "$hka" = "0" ]; then
        ok "SSH host key 已移除"
    else
        err "host key 还在（count=${hka:-?}）"
    fi
    ok "镜像内实际占用 $used"
    [ -n "$CLEAN_OUT" ] || err "清理过程没输出，可能中途断了 —— 检查 $BUILD_LOG"
fi

# ==============================================================================
step "8/9  恢复模板默认网络（构建静态 IP → DHCP）"
# ==============================================================================
if [ "$KEEP" -eq 1 ]; then
    warn "KEEP 模式：ipconfig0 仍是 $BUILD_IP"
else
    qm set "$TPL_VMID" --ipconfig0 "ip=dhcp"
    ok "模板默认网络 = DHCP（新建 VM 时可在 GUI 的 Cloud-init 页改成静态）"
fi

# 写回最终规格。构建期为了省宿主内存只分了 BUILD_MEM，
# 模板配置里要的是 MEMORY_MB（clone 时的默认值）。
if [ "$BUILD_MEM" -ne "$MEMORY_MB" ] && [ "$KEEP" -eq 0 ]; then
    qm set "$TPL_VMID" --memory "$MEMORY_MB"
    ok "配置里的 memory 已写回 ${MEMORY_MB}M（构建期用的是 ${BUILD_MEM}M）"
fi

# 清掉 [special:cloudinit] 里的待应用变更。
# 起因: 构造 --ide2 cloudinit 驱动和设置 cloudinit 选项在同一条 qm set 里时，
# PVE 会把已有选项挪进这个"pending"段（记的是变更前的旧值）。
# 不清的话每个 clone 都会继承它，GUI 上会显示"待应用变更"，
# 而且里面还留着构建期的静态 IP，看着很误导。
# 实测它首次启动后会自愈，功能无害，但这里主动清干净。
# 重新 set 一次 ipconfig0 没用，只有这个 cloudinit API 会清。
if pvesh set "/nodes/$PVE_NODE/qemu/$TPL_VMID/cloudinit" >/dev/null 2>&1; then
    if grep -q 'special:cloudinit' "/etc/pve/qemu-server/$TPL_VMID.conf" 2>/dev/null; then
        warn "[special:cloudinit] 待应用段仍存在（首次启动会自愈，不影响功能）"
    else
        ok "已清掉 [special:cloudinit] 待应用段"
    fi
else
    warn "调 cloudinit API 失败，pending 段可能残留（不影响功能）"
fi
[ -n "$SEARCH_DOMAIN" ] || qm set "$TPL_VMID" --delete searchdomain 2>/dev/null || true
qm set "$TPL_VMID" --tags "template;ubuntu-2404;dev" 2>/dev/null \
    || qm set "$TPL_VMID" --tags "template" 2>/dev/null || true

# ==============================================================================
step "9/9  关机并转成模板"
# ==============================================================================
if qm status "$TPL_VMID" 2>/dev/null | grep -q running; then
    log "关机 ..."
    timeout 180 qm shutdown "$TPL_VMID" --timeout 120 >/dev/null \
        || { warn "优雅关机超时，强制停机"; qm stop "$TPL_VMID"; }
    for _ in $(seq 1 30); do
        qm status "$TPL_VMID" 2>/dev/null | grep -q running || break
        sleep 2
    done
fi

if [ "$KEEP" -eq 1 ]; then
    warn "KEEP 模式：不转模板，VM $TPL_VMID 留给你手动检查"
    log "SSH: ssh -i $SSH_KEY_FILE $CI_USER@$BUILD_IP"
else
    qm template "$TPL_VMID"
    ok "VM $TPL_VMID 已转成模板"
fi

# ==============================================================================
ELAPSED=$(( $(date +%s) - BUILD_START ))
step "构建完成（耗时 $((ELAPSED / 60))m$((ELAPSED % 60))s）"
# ==============================================================================
qm config "$TPL_VMID" 2>/dev/null | sed 's/^/    /'
echo
USED_PCT=$(lvs --noheadings -o data_percent pve/data 2>/dev/null | tr -d ' ' || echo "?")
echo "    存储占用: thin pool 已用 ${USED_PCT}%"

cat <<EOF

$(printf '%s' "$C_B")下一步$(printf '%s' "$C_0")

  1) 命令行一键建机（推荐先用这个验证）:
     $SCRIPT_DIR/new-vm.sh myapp --auto-ip

  2) GUI 建机:
     Web UI → Datacenter → QEMU → VM Templates → 选中 $TPL_NAME → Create VM
     → 填 VMID / 名字 → Edit Config 里确认 CPU/内存/磁盘
     → Cloud-init 页勾 Enable，填 Hostname / IP(Address) / SSH Keys
     → Finish，然后 Start

  3) 冒烟测试（确认模板没问题）:
     $SCRIPT_DIR/smoke-test.sh

$(printf '%s' "$C_D")  日志: $BUILD_LOG
  配置: $CONF_FILE
$(printf '%s' "$C_0")
EOF
