#!/usr/bin/env bash
# ==============================================================================
#  bootstrap.sh —— 在一台【全新的 PVE】上复现整套 Ubuntu Server VM 模板
#
#  这是整套东西的入口。做的事情:
#    1. 环境体检（只读，不改任何东西）
#    2. 准备输入: 拉取并校验 Ubuntu cloud image；确认 SSH 密钥
#    3. 宿主设置: PVE 自动气球（否则 VM 内存会被悄悄回收）
#    4. 构建模板: build-template.sh
#    5. 冒烟验证: smoke-test.sh（建一台临时 VM 跑 28 项检查后销毁）
#    6. 拿产出的配置和 reference/ 里的期望值比对
#
#  用法:
#     ./bootstrap.sh              # 完整流程
#     ./bootstrap.sh --check      # 只体检，不改任何东西
#     ./bootstrap.sh --no-verify  # 构建但不跑冒烟测试（省 3-4 分钟）
#     ./bootstrap.sh --force      # 覆盖已存在的模板
#     ./bootstrap.sh --force --no-verify
#
#  全程幂等：重复跑安全（模板已存在时会拒绝，除非 --force）。
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="full"
VERIFY=1
FORCE=0
for a in "$@"; do
    case "$a" in
        --check)     MODE="check" ;;
        --no-verify) VERIFY=0 ;;
        --force)     FORCE=1 ;;
        -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数: $a（-h 看用法）" ;;
    esac
done

PROBLEMS=0
WARNINGS=0
pass() { ok "$1"; }
bad()  { err "$1"; PROBLEMS=$((PROBLEMS + 1)); }
warn1() { warn "$1"; WARNINGS=$((WARNINGS + 1)); }

# ==============================================================================
#  网络参数自动推导
# ==============================================================================
# 只推导 conf.env 的 AUTO_DERIVE 里列出的键。想钉死某个值就把它从 AUTO_DERIVE
# 删掉 —— 这样"哪些是自动的、哪些是我定的"一目了然，也不需要在脚本里维护
# 一份"出厂默认值"表（那份表迟早会和 conf.env 脱节）。

derive_net_params() {   # derive_net_params <只读:1 表示只报告不写回>
    local readonly="${1:-0}"
    local changed=0 differing=0 k cur new

    local CIDR; CIDR=$(bridge_cidr "$BRIDGE")
    if [ -z "$CIDR" ]; then
        warn "网桥 $BRIDGE 上没有全局 IPv4，跳过网络参数推导"
        return 1
    fi
    local baddr="${CIDR%%/*}" pfx="${CIDR##*/}"
    local net; net=$(cidr_network "$baddr" "$pfx")
    local bcast; bcast=$(cidr_broadcast "$baddr" "$pfx")

    # --- GATEWAY ---
    new=$(default_gw_in_subnet "$CIDR")
    [ -z "$new" ] && new=$(int2ip $(( net + 1 )))
    DERIVED_GATEWAY="$new"

    # --- DNS ---
    # 关键: 跳过 CGNAT 段(100.64.0.0/10)。宿主装了 Tailscale 时 resolv.conf 里
    # 是 100.100.100.100(MagicDNS)，guest 没装 Tailscale 就访问不到，
    # 下发过去等于没有 DNS。这种坑很隐蔽 —— VM 能 ping 通但什么都解析不了。
    new=""
    local ns
    while read -r ns; do
        [ -n "$ns" ] || continue
        case "$ns" in *:*) continue ;; esac          # 跳过 IPv6
        is_cgnat "$ns" && continue                    # 跳过 Tailscale/CGN
        new="$ns"; break
    done < <(awk '/^[[:space:]]*nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)
    [ -z "$new" ] && new="$DERIVED_GATEWAY"
    DERIVED_DNS="$new"
    DNS_FELLBACK=0
    awk '/^[[:space:]]*nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null \
        | grep -qE '^(127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|::1)' \
        && DNS_FELLBACK=1

    # --- SEARCH_DOMAIN ---
    # 跳过 *.ts.net(Tailscale MagicDNS 域)，guest 上解析不了也没意义
    new=""
    for d in $(awk '/^[[:space:]]*search/ { $1=""; sub(/^[[:space:]]+/, ""); print }' \
                 /etc/resolv.conf 2>/dev/null); do
        is_ts_domain "$d" && continue
        new="$d"; break
    done
    DERIVED_SEARCH_DOMAIN="$new"

    # --- IP_POOL ---
    # 可用地址 = 网络地址+1 .. 广播地址-1，跳过前后各 10 个，最多 100 个
    local lo=$(( net + 11 )) hi=$(( bcast - 11 ))
    [ "$hi" -lt "$lo" ] && { hi=$lo; }               # 极小网段兜底
    [ $(( hi - lo + 1 )) -gt 100 ] && hi=$(( lo + 99 ))
    DERIVED_IP_POOL="$(int2ip "$lo")-$(int2ip "$hi")"

    # --- BUILD_IP ---
    DERIVED_BUILD_IP="${DERIVED_IP_POOL%%-*}"

    # --- 报告 + 按需写回 ---
    info "网桥 $BRIDGE = $CIDR  →  可用段 $(int2ip $(( net + 1 ))) - $(int2ip $(( bcast - 1 )))"
    [ "$DNS_FELLBACK" -eq 1 ] && warn "resolv.conf 里只有 Tailscale/CGN 的 DNS，DNS 回退用网关 $DERIVED_GATEWAY"

    for k in GATEWAY DNS SEARCH_DOMAIN IP_POOL BUILD_IP; do
        case " $AUTO_DERIVE " in
            *" $k "*) ;;
            *) printf '      %-14s 手动固定，不推导\n' "$k"; continue ;;
        esac
        cur="${!k}"
        new="${!k}"
        eval "new=\$DERIVED_$k"
        if [ "$cur" = "$new" ]; then
            printf '      %-14s %s\n' "$k" "$new"
        else
            differing=$(( differing + 1 ))
            if [ "$readonly" -eq 0 ]; then
                printf '      %-14s %s → %s   已写入\n' "$k" "$cur" "$new"
            else
                printf '      %-14s %s → %s   待写入\n' "$k" "$cur" "$new"
            fi
            if [ "$readonly" -eq 0 ]; then
                if grep -qE "^${k}=" "$CONF_FILE"; then
                    sed -i "s|^${k}=.*|${k}=${new}|" "$CONF_FILE"
                else
                    printf '%s=%s\n' "$k" "$new" >> "$CONF_FILE"
                fi
                changed=1
            fi
        fi
    done

    # 返回值: 0 = 正常(已写回或本就一致) / 2 = 只读模式下存在差异
    [ "$readonly" -eq 1 ] && [ "$differing" -gt 0 ] && return 2
    return 0
}

# ==============================================================================
step "1/6  环境体检"
# ==============================================================================
require_root
require_pve
pass "PVE $(pve_version)  节点 $(hostname)"

# 架构: cloud image 是 amd64
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    pass "架构 x86_64（匹配 amd64 cloud image）"
else
    bad "架构是 $ARCH，本模板用的 amd64 cloud image 跑不了"
fi

# genisoimage: PVE 生成 cloud-init ISO 靠它。
# 正常装了 pve 的机器都有（qemu-server 包依赖它），这里是保险。
if command -v genisoimage >/dev/null 2>&1; then
    pass "genisoimage 在（PVE 生成 cloud-init ISO 靠它）"
else
    bad "缺 genisoimage。装: apt update && apt install -y genisoimage"
fi

# 存储
if storage_exists "$STORAGE"; then
    STYPE=$(pvesm status --storage "$STORAGE" | awk 'NR>1{print $2}')
    SCONTENT=$(pvesh get /storage/$STORAGE --output-format json 2>/dev/null | grep -oE '"content":"[^"]*"' | tr -d '"' | sed 's/content://')
    pass "存储 $STORAGE 激活（类型 $STYPE，内容 ${SCONTENT:-未知}）"
    case "$SCONTENT" in
        *images*) ;;
        *) bad "存储 $STORAGE 的 content 不含 images，放不了 VM 磁盘" ;;
    esac
    # lvm-thin 只支持 raw -> clone 只能 full clone
    if [ "$STYPE" = "lvmthin" ]; then
        warn1 "存储是 lvm-thin，只支持 raw -> clone 只能是 full clone（100G 盘约 30 秒）"
        warn1 "  想秒级 linked clone 需要 qcow2 存储，lvm-thin 给不了"
    fi
else
    bad "存储 $STORAGE 不存在或未激活"
fi

# 网桥
if bridge_exists "$BRIDGE"; then
    BADDR=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2 || true)
    pass "网桥 $BRIDGE 存在${BADDR:+（本机 $BADDR）}"
    # 静态网段是否和网桥同网段（真正的修复在 derive_net_params，这里先报个警）
    if [ -n "$BADDR" ] && [ -n "$GATEWAY" ]; then
        b3=$(echo "$BADDR" | cut -d. -f1-3)
        g3=$(echo "$GATEWAY" | cut -d. -f1-3)
        if [ "$b3" != "$g3" ]; then
            warn1 "conf.env 的 GATEWAY=$GATEWAY 与网桥 $BRIDGE 的 $BADDR 不同网段"
            warn1 "  跑 ./bootstrap.sh 会自动改成推导值（也可从 conf.env 的 AUTO_DERIVE 里删掉 GATEWAY 来钉死）"
        fi
    fi
else
    bad "网桥 $BRIDGE 不存在。新装 PVE 默认有 vmbr0；改 conf.env 的 BRIDGE 或先建网桥"
fi

# 磁盘余量: cloud image 要下到 CLOUD_IMG 所在的那个挂载点
IMG_DIR=$(dirname "$CLOUD_IMG")
IMG_FREE_KB=$(df -Pk "$IMG_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
IMG_FREE_GB=$(( IMG_FREE_KB / 1024 / 1024 ))
if [ "$IMG_FREE_KB" -ge $(( 1024 * 1024 )) ]; then
    pass "镜像存放位置 $IMG_DIR 余 ${IMG_FREE_GB}G（够放 cloud image）"
else
    bad "$IMG_DIR 只剩 ${IMG_FREE_GB}G，放不下约 600M 的 cloud image"
fi

# 内存
HOST_RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
pass "宿主内存 ${HOST_RAM_MB}M"
if [ "$HOST_RAM_MB" -lt $(( MEMORY_MB + 2048 )) ]; then
    warn1 "宿主内存 ${HOST_RAM_MB}M < 模板默认 ${MEMORY_MB}M + 2G 余量"
    warn1 "  构建不受影响（构建期只分配 ${BUILD_MEM_MB:-自动} M），但同时跑不了那么多 VM"
fi

# SSH 密钥 —— 这是最容易在新机器上卡住的地方
if [ -r "$SSH_KEY_FILE" ] && [ -r "$SSH_PUBKEY_FILE" ]; then
    pass "SSH 密钥就绪（$SSH_KEY_FILE）"
    NEED_KEY=0
else
    NEED_KEY=1
    warn "没有可用的 SSH 密钥: $SSH_KEY_FILE"
fi

# 模板是否已存在
if vm_exists "$TPL_VMID"; then
    if is_template "$TPL_VMID"; then
        pass "模板 $TPL_VMID 已存在（$(qm config "$TPL_VMID" | sed -n 's/^name: //p')）"
        TEMPLATE_EXISTS=1
    else
        bad "VMID $TPL_VMID 被一台普通 VM 占了（不是模板）。换个 TPL_VMID 或先删掉它"
        TEMPLATE_EXISTS=0
    fi
else
    pass "VMID $TPL_VMID 空闲"
    TEMPLATE_EXISTS=0
fi

# 自动气球现状
CUR_TARGET=$(get_auto_balloon_target)
: "${CUR_TARGET:=80（PVE 默认，配置文件里没写）}"
if [ "${CUR_TARGET%% *}" = "${AUTO_BALLOON_TARGET:-100}" ]; then
    pass "自动气球 ballooning-target = ${CUR_TARGET%% *}（符合预期）"
else
    warn "自动气球 ballooning-target = $CUR_TARGET，期望 ${AUTO_BALLOON_TARGET:-100}"
    warn "不修的话 VM 内存会被慢慢回收（详见 tune-host.sh 顶部注释）"
fi

if [ "$MODE" = "check" ]; then
    step "网络参数推导（只读预览，不会改 conf.env）"
    if derive_net_params 1; then
        info "conf.env 里的网络参数已经和本机一致"
    else
        info "标了「待写入」的项与 conf.env 现状不同 —— 跑 ./bootstrap.sh 会自动改写"
    fi
    echo
    if [ "$PROBLEMS" -gt 0 ]; then
        err "体检未通过: $PROBLEMS 个问题 / $WARNINGS 个提醒"
        exit 1
    fi
    ok "体检通过（$WARNINGS 个提醒）"
    exit 0
fi

if [ "$PROBLEMS" -gt 0 ]; then
    echo
    die "有 $PROBLEMS 个阻断性问题，先解决上面的 ✘ 再跑"
fi

# ==============================================================================
step "2/6  准备输入"
# ==============================================================================
# ---- 网络参数：按本机实际情况推导并回写 conf.env ----
# 换机器时这几个值原本要手改，现在自动完成。
info "按本机网络推导 AUTO_DERIVE 里的键: $AUTO_DERIVE"
if derive_net_params 0; then
    ok "网络参数已与本机对齐"
else
    warn "网络参数推导被跳过（网桥 $BRIDGE 上没有全局 IPv4？）"
    warn1 "静态 IP 的 VM 可能上不了网，确认 conf.env 里的 GATEWAY/DNS/IP_POOL"
fi

# ---- SSH 密钥 ----
if [ "$NEED_KEY" -eq 1 ]; then
    KEYDIR=$(dirname "$SSH_KEY_FILE")
    mkdir -p "$KEYDIR"
    log "生成 ed25519 密钥: $SSH_KEY_FILE"
    ssh-keygen -t ed25519 -N '' -C "root@$(hostname)" -f "$SSH_KEY_FILE" >/dev/null
    # conf.env 里的路径要跟着改
    sed -i "s|^SSH_KEY_FILE=.*|SSH_KEY_FILE=$SSH_KEY_FILE|; s|^SSH_PUBKEY_FILE=.*|SSH_PUBKEY_FILE=$SSH_KEY_FILE.pub|" "$CONF_FILE"
    ok "已生成，私钥权限 $(stat -c '%a' "$SSH_KEY_FILE")"
    echo
    echo "  ⚠️  把下面这行公钥加到你自己的机器上，否则 clone 出来的 VM 你连不进去："
    echo
    echo "      $(cat "$SSH_KEY_FILE.pub")"
    echo
    info "  （也可以之后建机时用 new-vm.sh --key <你的公钥文件> 覆盖）"
else
    info "复用现有密钥 $SSH_KEY_FILE"
fi

# ---- cloud image ----
IMG_NEED=0
if [ ! -f "$CLOUD_IMG" ]; then
    IMG_NEED=1
    log "cloud image 不存在，准备下载"
elif [ -n "${CLOUD_IMG_SHA256:-}" ]; then
    got=$(sha256sum "$CLOUD_IMG" | cut -d' ' -f1)
    if [ "$got" != "$CLOUD_IMG_SHA256" ]; then
        warn "现有 cloud image 指纹不符，删掉重下"
        IMG_NEED=1
    fi
fi

if [ "$IMG_NEED" -eq 1 ]; then
    [ -n "${CLOUD_IMG_URL:-}" ] || die "conf.env 缺 CLOUD_IMG_URL"
    mkdir -p "$(dirname "$CLOUD_IMG")"
    info "下载 $CLOUD_IMG_URL"
    info "约 600M，慢的话几分钟"
    # 下到 .part 再改名，避免中断留下半个文件被当成有效输入
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar -o "$CLOUD_IMG.part" "$CLOUD_IMG_URL" \
            || die "下载失败: curl -fL -o '$CLOUD_IMG' '$CLOUD_IMG_URL'"
    else
        wget -O "$CLOUD_IMG.part" "$CLOUD_IMG_URL" || die "下载失败"
    fi
    mv "$CLOUD_IMG.part" "$CLOUD_IMG"

    if [ -n "${CLOUD_IMG_SHA256:-}" ]; then
        got=$(sha256sum "$CLOUD_IMG" | cut -d' ' -f1)
        [ "$got" = "$CLOUD_IMG_SHA256" ] || {
            rm -f "$CLOUD_IMG"
            die "下载的文件指纹不对，已删除。
  期望: $CLOUD_IMG_SHA256
  实际: $got
  上游换了内容的话，去 https://cloud-images.ubuntu.com/noble/ 找新的日期目录，
  更新 conf.env 的 CLOUD_IMG_URL 和 CLOUD_IMG_SHA256"
        }
        ok "sha256 校验通过"
    else
        warn1 "conf.env 没设 CLOUD_IMG_SHA256，跳过校验"
    fi
else
    pass "cloud image 就绪且指纹匹配"
fi

# ==============================================================================
step "3/6  宿主设置"
# ==============================================================================
"$SCRIPT_DIR/tune-host.sh" 2>&1 | sed 's/^/  /'

# ==============================================================================
step "4/6  构建模板"
# ==============================================================================
BUILD_ARGS=()
[ "$TEMPLATE_EXISTS" -eq 1 ] && [ "$FORCE" -eq 0 ] && {
    echo
    warn "模板 $TPL_VMID 已存在。跳过构建（要重建加 --force）"
    BUILD_ARGS=(SKIP)
}
if [ "${BUILD_ARGS[0]:-}" = "SKIP" ]; then
    ok "沿用现有模板"
else
    [ "$FORCE" -eq 1 ] && BUILD_ARGS=(--force)
    info "这一步约 3-5 分钟（下载包最慢）"
    "$SCRIPT_DIR/build-template.sh" "${BUILD_ARGS[@]}" 2>&1 | grep -vE '^transferred ' | sed 's/^/  /'
    ok "模板构建完成"
fi

# ==============================================================================
step "5/6  验证"
# ==============================================================================
if [ "$VERIFY" -eq 1 ]; then
    info "冒烟测试会建一台临时 VM，跑完自动销毁（约 3-4 分钟）"
    if "$SCRIPT_DIR/smoke-test.sh"; then
        pass "冒烟测试全部通过"
    else
        die "冒烟测试没过。带 --keep 重跑能保留那台 VM 进去看:
      $SCRIPT_DIR/smoke-test.sh --keep
      完整日志: /var/log/pve-template-build.log"
    fi
else
    warn "跳过了冒烟测试（--no-verify）。建议至少手动跑一次: $SCRIPT_DIR/smoke-test.sh"
fi

# ==============================================================================
step "6/6  与期望配置比对"
# ==============================================================================
REF_VM="$SCRIPT_DIR/reference/expected-9000.conf"
REF_NODE="$SCRIPT_DIR/reference/expected-node-config"

# 比对时忽略每次构建必然不同的字段
# 每次构建必然变化的字段 + 脱敏掉的两项（参考文件里是 <hidden>，本来也比不了）
# 注意 qm config 输出的是 "key: value"，不是 key=value，正则要按前者写
IGNORE='^(meta|ctime|smbios1|vmgenid|net0|description|scsi0|efidisk0|ide2|cipassword|sshkeys):'

if [ -f "$REF_VM" ]; then
    qm config "$TPL_VMID" 2>/dev/null | grep -vE "$IGNORE" | sort > /tmp/.pvestudio.actual
    # 滤掉忽略字段、[special:*] 段、空行和 # 注释行
    grep -vE "$IGNORE" "$REF_VM" | grep -vE '^[[:space:]]*\[|^[[:space:]]*$|^[[:space:]]*#' \
        | sort > /tmp/.pvestudio.expect
    if diff -u /tmp/.pvestudio.expect /tmp/.pvestudio.actual > /tmp/.pvestudio.diff 2>&1; then
        pass "模板配置与 reference/expected-9000.conf 完全一致"
    else
        warn "模板配置与参考值有差异（- 是参考 / + 是实际）:"
        head -20 /tmp/.pvestudio.diff | sed 's/^/      /'
        warn "差异不一定是问题（参考文件是某次构建的快照），确认一下就行"
    fi
    rm -f /tmp/.pvestudio.{actual,expect,diff}
else
    warn "找不到 $REF_VM，跳过比对"
fi

if [ -f "$REF_NODE" ]; then
    if [ "$(get_auto_balloon_target)" = "$(grep -oE '[0-9]+' "$REF_NODE" | head -1)" ]; then
        pass "节点配置与 reference/expected-node-config 一致"
    else
        warn "节点配置与参考值不一致"
    fi
fi

# ==============================================================================
cat <<EOF

$(printf '%s' "$C_G")════════════════════════════════════════════════════════$(printf '%s' "$C_0")

  Bootstrap 完成。模板: VMID $TPL_VMID  ($(qm config "$TPL_VMID" 2>/dev/null | sed -n 's/^name: //p'))

$(printf '%s' "$C_B")  建 VM$(printf '%s' "$C_0")

    # 命令行（推荐，会自动挑空闲 IP 并等 SSH 就绪）
    $SCRIPT_DIR/new-vm.sh myapp --auto-ip

    # GUI
    Web UI -> Datacenter -> QEMU -> VM Templates -> $TPL_NAME -> Create VM
    -> Cloud-init 页填 Hostname / IP -> Finish -> Start

$(printf '%s' "$C_B")  常用$(printf '%s' "$C_0")

    $SCRIPT_DIR/smoke-test.sh          # 28 项验证
    $SCRIPT_DIR/tune-host.sh --show    # 看内存气球现状
    vim $CONF_FILE && $SCRIPT_DIR/build-template.sh --force   # 改配置后重建

$(printf '%s' "$C_D")  配置:  $CONF_FILE
  文档:  $SCRIPT_DIR/README.md
  日志:  /var/log/pve-template-build.log
$(printf '%s' "$C_0")

EOF
