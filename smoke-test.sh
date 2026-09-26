#!/usr/bin/env bash
# ==============================================================================
#  smoke-test.sh —— 验证模板是否真的能用
#
#  从模板建一台临时 VM，逐项检查：DHCP/静态 IP、SSH、host key 唯一性、
#  磁盘自动扩容、guest agent、预装包、root 免密。默认检查完就销毁。
#
#  用法:
#     ./smoke-test.sh              # 用 DHCP，测完销毁
#     ./smoke-test.sh --keep       # 测完保留，自己看一眼
#     ./smoke-test.sh --ip 1.2.3.4 # 指定静态 IP
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

KEEP=0
IP=""
WAIT_SEC=420
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --ip)   IP="$2"; shift 2 ;;
        --wait) WAIT_SEC="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数 $1" ;;
    esac
done

require_root
require_pve
is_template "$TPL_VMID" || die "$TPL_VMID 不是模板（qm config $TPL_VMID | grep template）"

VMID=$(next_vmid)
NAME="smoke-$$"
PASS=0
FAIL=0

cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        warn "保留测试 VM $VMID（名字 $NAME）"
        return
    fi
    if ! vm_exists "$VMID"; then
        return
    fi
    log "销毁测试 VM $VMID ..."
    # qm destroy 不会停运行中的 VM，得先停。少了这步会销毁失败，
    # 而错误被吞掉后还会打印"已销毁"，留下一堆垃圾 VM。
    if qm status "$VMID" 2>/dev/null | grep -q running; then
        timeout 90 qm shutdown "$VMID" --timeout 45 >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            qm status "$VMID" 2>/dev/null | grep -q running || break
            sleep 2
        done
        qm status "$VMID" 2>/dev/null | grep -q running && qm stop "$VMID" >/dev/null 2>&1 || true
    fi
    if qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
        ok "已销毁测试 VM $VMID"
    else
        err "销毁失败，手动清理: qm destroy $VMID --purge --destroy-unreferenced-disks 1"
    fi
}
trap cleanup EXIT

check() {  # check <描述> <期望正则> <ssh 命令...>
    local desc="$1" expect="$2"; shift 2
    local out rc
    # 退出码非 0 不代表失败（systemctl is-active 未运行会退 3），所以只有
    # 「命令执行不了」且「没有任何输出」才判定为 SSH 挂了
    out=$(guest_ssh "$CI_USER" "$IP" "$@" 2>&1 | tr -d '\r') && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
        out="__ssh_unreachable__"
    fi
    if printf '%s' "$out" | grep -qE -- "$expect"; then
        ok "$desc"
        PASS=$((PASS + 1))
    else
        err "$desc  —— 输出: ${out:-<空>}"
        FAIL=$((FAIL + 1))
    fi
}

step "0/5  从模板建测试 VM $VMID"
qm clone "$TPL_VMID" "$VMID" --name "$NAME" --full 1
# 内存用 MIN_MEM_MB（默认 4096）而不是更小的值 —— 实测 2048M 会在启动阶段 OOM，
# 那样测出来的失败没有意义。气球地板同样按内存算。
TEST_MEM="${TEST_MEM_MB:-$MIN_MEM_MB}"
qm set "$VMID" --cores 2 --memory "$TEST_MEM" --balloon "$(balloon_floor "$TEST_MEM")" --onboot 0
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASSWORD" \
               --sshkeys "$SSH_PUBKEY_FILE" --nameserver "$DNS"
if [ -n "$IP" ]; then
    qm set "$VMID" --ipconfig0 "ip=$IP/24,gw=$GATEWAY"
    MODE="静态 $IP"
else
    qm set "$VMID" --ipconfig0 "ip=dhcp"
    MODE="DHCP"
    IP=""
fi
ok "已建好（$MODE）"

step "1/5  启动并等 SSH"
qm start "$VMID"
if [ -z "$IP" ]; then
    info "等 guest agent 报出 DHCP 地址 ..."
    for _ in $(seq 1 100); do
        out=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null) || true
        cand=$(qga_first_ipv4 "$out") || cand=""
        if [ -n "$cand" ]; then IP="$cand"; break; fi
        sleep 3
    done
    [ -n "$IP" ] || { err "没拿到 DHCP 地址"; exit 1; }
    ok "DHCP 地址: $IP"
fi

wait_tcp "$IP" 22 "$WAIT_SEC" "SSH" || { err "SSH 起不来: qm terminal $VMID"; exit 1; }
ok "SSH 已通 ($IP)"

step "2/5  等 cloud-init 完成"
log "等 cloud-init 完成（degraded 也算完成，见 README）"
for _ in $(seq 1 120); do
    st=$(guest_ssh "$CI_USER" "$IP" "cloud-init status" 2>/dev/null | sed -n 's/.*status: //p' | tr -d '\r') || true
    case "$st" in
        done|degraded*) break ;;
        error) err "cloud-init 报错"
                guest_ssh "$CI_USER" "$IP" "sudo tail -30 /var/log/cloud-init-output.log" 2>/dev/null || true
                exit 1 ;;
    esac
    sleep 5
done
case "$st" in
    done|degraded*) ok "cloud-init $st" ;;
    *)             err "cloud-init 未完成: ${st:-SSH 不通}"; FAIL=$((FAIL+1)) ;;
esac

step "3/5  逐项检查"
check "系统是 Ubuntu 24.04"        "24\.04"           ". /etc/os-release; echo \$PRETTY_NAME"
check "根分区已铺满整个盘"          "^[0-9.]+[GMT]$"   "findmnt -no SIZE /"
check "根分区不是 3.5G（已扩容）"     "^[0-9.]+[GMT]$"   "df -h --output=size / | tail -1 | tr -d ' '"
check "machine-id 已重新生成"        "^[0-9a-f]{32}$"   "cat /etc/machine-id"
check "SSH host key 存在"            "ssh_host_"        "ls /etc/ssh/ssh_host_ed25519_key"
check "时区"                        "$TIMEZONE"        "cat /etc/timezone"
check "sudo 免密"                    "^0$"              "sudo -n id -u"
check "root 免密登录"                "yes"              "sudo -n bash -c 'echo yes'"
check "guest agent 跑着"             "active"           "systemctl is-active qemu-guest-agent"
check "guest agent 开机自启"          "enabled"          "systemctl is-enabled qemu-guest-agent"
check "启动过程没有 OOM"              "^0$"              "sudo -n dmesg | grep -ci 'out of memory' || true"
check "growpart 在"                  "growpart"         "command -v growpart"
check "gcc 在"                       "gcc"              "gcc --version | head -1"
check "git 在"                       "git version"      "git --version"
check "python3 在"                   "Python 3"         "python3 --version"
check "jq 在"                        "jq-"              "jq --version"
check "htop 在"                      "htop"             "command -v htop"
check "vim 在"                       "VIM - Vi"         "vim --version | head -1"
check "tmux 在"                      "tmux"             "tmux -V"
check "rg 在"                        "ripgrep"          "rg --version"
check "出网正常（DNS 解析）"           "cloud-images\.ubuntu\.com" "getent hosts cloud-images.ubuntu.com"
check "apt update 正常"              "^(0|没有|无)"      "sudo -n apt-get -qq update 2>&1 | tail -3; echo 0"
check "密码登录开着"                  "^yes$"            "sudo -n sshd -T | awk '/^passwordauthentication/{print \$2}'"
# 注: sshd -T 会把 prohibit-password 输出成它的旧别名 without-password，
#     两者是同一个设置，两个拼法都认
check "root 只允许 key 登录"           "^(prohibit-password|without-password)$" "sudo -n sshd -T | awk '/^permitrootlogin/{print \$2}'"
check "resolv.conf 正常"              "^[1-9]"          "grep -c nameserver /etc/run/systemd/resolve/resolv.conf 2>/dev/null || grep -c nameserver /etc/resolv.conf"

step "4/5  PVE 侧检查"
if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
    ok "PVE 能 ping 通 guest agent"; PASS=$((PASS+1))
else
    err "PVE -> guest agent 不通"; FAIL=$((FAIL+1))
fi
if qm guest cmd "$VMID" get-osinfo >/dev/null 2>&1; then
    ok "guest agent 能报 OS 信息"; PASS=$((PASS+1))
else
    err "guest agent get-osinfo 失败"; FAIL=$((FAIL+1))
fi

# 内存必须真的到位 —— 这是 PVE 自动气球最容易悄悄吃掉的东西。
# 注意: 气球每轮 100MB 往 maxmem 走，要 2-4 分钟才收敛。
# 这里先轮询等它到位再判定，否则测的是"还没涨上去"的中间态（之前就误判过一次）。
# 另外 TEST_MEM 本来就是 MiB，不能过 size_to_mb（纯数字会被当成 KB 再除 1024）。
WANT_MB="$TEST_MEM"
info "等气球把内存涨到 maxmem（最多 4 分钟）..."
BAL=""
ACT=0
for _ in $(seq 1 40); do
    BAL=$(echo "info balloon" | timeout 5 qm monitor "$VMID" 2>/dev/null | grep -o 'balloon:.*') || BAL=""
    a=$(printf '%s' "$BAL" | grep -oE 'actual=[0-9]+' | cut -d= -f2) || a=0
    ACT="${a:-0}"
    [ "$ACT" -ge $(( WANT_MB - 256 )) ] && break
    sleep 6
done
if [ "$ACT" -ge $(( WANT_MB - 256 )) ]; then
    ok "guest 实到内存 ${ACT}M / 配置 ${WANT_MB}M（气球已到 maxmem）"
    PASS=$((PASS+1))
else
    err "guest 只拿到 ${ACT}M，配置是 ${WANT_MB}M —— 内存被气球回收了"
    [ -n "$BAL" ] && log "    $BAL"
    log "    查: pvenode config get | grep ballooning-target   （应为 100）"
    log "    改完要 systemctl restart pvestatd 才生效"
    FAIL=$((FAIL+1))
fi
ok "规格: $(qm config "$VMID" | sed -n 's/^scsihw: //p') / $(qm config "$VMID" | grep -oE 'cores: [0-9]+' || true)"

step "5/5  结果"
echo
if [ "$FAIL" -eq 0 ]; then
    ok "全部 $PASS 项通过 —— 模板可用"
    exit 0
else
    err "$FAIL 项失败，$PASS 项通过"
    log "带 --keep 重跑就能保留这台 VM 进去手动排查"
    exit 1
fi
