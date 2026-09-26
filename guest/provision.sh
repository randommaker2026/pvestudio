#!/usr/bin/env bash
# ==============================================================================
#  guest/provision.sh —— 在 guest 里跑，完成模板定制
#
#  由 build-template.sh 通过 SSH 投递到 VM 内执行。全部用 root 跑。
#  参数：--password <pw> --key-file <path> --timezone <tz> --swap <size> --packages "<list>"
# ==============================================================================
set -euo pipefail

PASSWORD=""
KEY_FILE=""
TIMEZONE="Asia/Shanghai"
SWAP_SIZE="0"
PACKAGES=""
CI_USER="ubuntu"

while [ $# -gt 0 ]; do
    case "$1" in
        --password)  PASSWORD="$2";  shift 2 ;;
        --key-file)  KEY_FILE="$2";  shift 2 ;;
        --timezone)  TIMEZONE="$2";  shift 2 ;;
        --swap)      SWAP_SIZE="$2"; shift 2 ;;
        --packages)  PACKAGES="$2";  shift 2 ;;
        --user)      CI_USER="$2";   shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
LOG_TAG="provision"
say() { echo "[$LOG_TAG] $*"; }

# ---------------------------------------------------------------- 前置检查 ----
[ "$(id -u)" -eq 0 ] || { echo "必须以 root 运行" >&2; exit 1; }
say "系统: $(. /etc/os-release; echo "$PRETTY_NAME") / 内核 $(uname -r)"

# cloud-init 必须跑完，否则 authorized_keys / 用户还没建好
# 注意: 状态是 "degraded" 时 cloud-init 的退出码也非 0，但功能是好的
# （PVE 生成的 user-data 用了已废弃的 `user:` 字段，cloud-init 26.1 会标 degraded），
# 所以只取 stdout 文本，不看退出码
ci_state=$(cloud-init status 2>/dev/null | sed -n 's/.*status: //p' | tr -d '\r') || true
say "cloud-init 状态: ${ci_state:-未知}"
case "$ci_state" in
    done|degraded*) : ;;
    *)
        say "等 cloud-init 跑完 ..."
        timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
        ci_state=$(cloud-init status 2>/dev/null | sed -n 's/.*status: //p' | tr -d '\r') || true
        say "cloud-init 状态: ${ci_state:-未知}"
        case "$ci_state" in
            done|degraded*|disabled) : ;;
            *) say "警告: cloud-init 状态异常，继续往下走" ;;
        esac
        ;;
esac

# ------------------------------------------------------------------ 时区 ----
say "设置时区: $TIMEZONE"
ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

# ------------------------------------------------------------------ 软件包 --
say "apt update ..."
apt-get -qq update

if [ -n "$PACKAGES" ]; then
    # shellcheck disable=SC2086
    PKG_LIST=$(echo "$PACKAGES" | tr '[:space:]' '\n' | grep -v '^$' | sort -u) || true
    if [ -z "$PKG_LIST" ]; then
        say "包列表为空，跳过"
    else
        say "安装 $(echo "$PKG_LIST" | wc -l) 个软件包 ..."
        # shellcheck disable=SC2086
        apt-get -y -qq -o Dpkg::Use-Pty=0 install $PKG_LIST
    fi
else
    say "跳过软件包安装（未提供 --packages）"
fi

# 装完再来一轮，确保依赖完整、grub 元数据刷新
apt-get -y -qq -o Dpkg::Use-Pty=0 --fix-broken install || true
apt-get clean
rm -rf /var/lib/apt/lists/*
say "软件包安装完成"

# ------------------------------------------------------- guest agent --------
say "启用 qemu-guest-agent"
systemctl enable --now qemu-guest-agent.service

# Ubuntu 24.04 里这个单元没有 [Install] 段（靠 D-Bus 按需激活），
# 所以 `systemctl enable` 是空操作，is-enabled 会报 static。
# 手动挂一个 multi-user.target.wants 软链，保证开机一定起 ——
# 否则 clone 出来的 VM 在 PVE 第一次问它时要等 D-Bus 激活，容易超时。
if [ "$(systemctl is-enabled qemu-guest-agent.service 2>/dev/null || true)" = "static" ]; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /lib/systemd/system/qemu-guest-agent.service \
           /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
    systemctl daemon-reload
    systemctl enable qemu-guest-agent.service 2>/dev/null || true
    say "单元是 static，已手动挂 multi-user.target.wants 软链"
fi

sleep 2
if systemctl is-active --quiet qemu-guest-agent; then
    say "qemu-guest-agent 运行中 (v$(qemu-guest-agent --version 2>/dev/null | head -1))"
else
    say "警告: qemu-guest-agent 没起来，检查 virtio-serial 通道"
fi
say "is-enabled = $(systemctl is-enabled qemu-guest-agent.service 2>/dev/null || true)"

# -------------------------------------------------------------- SSH 配置 ----
install -d -m 700 /root/.ssh

if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then
    say "把公钥装到 root 和默认用户"
    pubkey=$(cat "$KEY_FILE")
    for u in root "$CI_USER"; do
        id "$u" >/dev/null 2>&1 || continue
        home=$(getent passwd "$u" | cut -d: -f6) || continue
        [ -n "$home" ] && [ -d "$home" ] || continue
        install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
        touch "$home/.ssh/authorized_keys"
        grep -qxF "$pubkey" "$home/.ssh/authorized_keys" \
            || printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"
        chown "$u:$u" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        say "  $u 的 authorized_keys 就绪"
    done
fi

# root 允许用 key 登录（不给 root 设密码登录）
install -d -m 755 /etc/ssh/sshd_config.d
# sshd_config.d/*.conf 按 glob 顺序读取，【第一个取到的值生效】。
# Ubuntu cloud image 里有 cloud-init 每次开机重写的 50-cloud-init-settings.conf，
# 内容是 PasswordAuthentication no。所以这个文件必须排在 50 之前（用 05-），
# 否则密码登录会被 cloud-init 压掉 —— 用户明确要求 key + 固定密码双通道。
SSH_DROPIN=/etc/ssh/sshd_config.d/05-pve-template.conf
cat > "$SSH_DROPIN" <<'EOF'
# 由 pve-template provision 写入
# 排序必须在 50-cloud-init-settings.conf 之前才能生效
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding yes
ClientAliveInterval 120
ClientAliveCountMax 6
EOF
rm -f /etc/ssh/sshd_config.d/60-pve-template.conf
sshd -t && say "sshd 配置语法 OK" || { echo "sshd 配置有语法错误" >&2; exit 1; }
systemctl reload ssh || systemctl reload sshd

# 验证 sshd 实际生效的值（不是看文件，是问运行中的 sshd）
EFFECTIVE=$(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | tr '\n' ' ')
say "sshd 实际生效: $EFFECTIVE"
case "$EFFECTIVE" in
    *"passwordauthentication yes"*) say "密码登录已开启" ;;
    *) say "警告: 密码登录没生效，实际是 ${EFFECTIVE:-未知}" ;;
esac

# 默认 sudo 免密（cloud-init 建的用户通常已有 90-cloud-init-users，这里兜底）
if id "$CI_USER" >/dev/null 2>&1; then
    cat > /etc/sudoers.d/90-${CI_USER}-nopasswd <<EOF
${CI_USER} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
    chmod 440 "/etc/sudoers.d/90-${CI_USER}-nopasswd"
    if ! visudo -cf "/etc/sudoers.d/90-${CI_USER}-nopasswd" >/dev/null; then
        rm -f "/etc/sudoers.d/90-${CI_USER}-nopasswd"
        say "警告: sudoers 片段无效，已移除"
    fi
fi

# 固定密码
if [ -n "$PASSWORD" ]; then
    say "给 $CI_USER 设置固定密码（长度 ${#PASSWORD}）"
    chpasswd <<< "${CI_USER}:$PASSWORD"
fi

# ------------------------------------------------------------------ swap ----
# 模板默认不建 swap：磁盘 grow 时不干扰 fs resize
if [ "$SWAP_SIZE" != "0" ] && [ -n "$SWAP_SIZE" ]; then
    if ! swapon --show=NAME --noheadings | grep -q .; then
        say "创建 ${SWAP_SIZE} swap"
        fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap -q /swapfile
        swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# ------------------------------------------------------------- 系统调优 ----
say "系统调优"

# 日志限量，别把磁盘吃满
install -d -m 755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=300M
SystemKeepFree=1G
RuntimeMaxUse=100M
MaxRetentionSec=2week
EOF

# 内核参数：保守的高并发默认值
cat > /etc/sysctl.d/60-pve-template.conf <<'EOF'
# 由 pve-template provision 写入
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096
fs.file-max = 200000
# 需要做容器/路由时手动打开:
# net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# apt 缓存别无限涨
cat > /etc/apt/apt.conf.d/90pve-template <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::AutocleanInterval "7";
Binary::apt::Periodic::Automatic-Reboot "0";
EOF

# 每天 fstrim 一次（thin provisioning 需要）
systemctl enable --now fstrim.timer 2>/dev/null || true

# 不用要 systemd-resolved 之外的东西，先确保时间同步可用
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# ------------------------------------------------------------ 磁盘扩容 -----
# 确认 cloud-init 的 growpart 能把分区铺满整盘
if ! command -v growpart >/dev/null 2>&1; then
    say "警告: 找不到 growpart，磁盘自动扩容会失效"
fi
if ! grep -qs "resize_rootfs" /etc/cloud/cloud.cfg; then
    say "给 cloud.cfg 打开 resize_rootfs"
    sed -i '/^resize_rootfs/s/^/#/' /etc/cloud/cloud.cfg
    printf 'resize_rootfs: true\n' >> /etc/cloud/cloud.cfg
fi

# 让 systemd 服务少等 90 秒（无外设的 VM 上省开机时间）
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/60-pve-template.conf <<'EOF'
[Manager]
DefaultTimeoutStartSec=90s
DefaultTimeoutStopSec=30s
EOF
systemctl daemon-reexec 2>/dev/null || true

# ------------------------------------------------------------------ 完成 ----
say "provision 完成"
