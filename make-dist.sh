#!/usr/bin/env bash
# ==============================================================================
#  make-dist.sh —— 同步仓库里的派生产物
#
#  仓库里有三类文件是【由别处生成的】，手改会在下次同步时被覆盖，
#  不生成又会和现实脱节：
#
#    conf.env                      → conf.env.example        （脱敏后的配置模板）
#    /etc/pve/qemu-server/<id>.conf → reference/expected-9000.conf
#    /etc/pve/nodes/<node>/config  → reference/expected-node-config
#
#  改完 conf.env 或重建模板后跑一次这个，三个文件就都同步了。
#
#  用法:
#     ./make-dist.sh              # 生成并自动提交
#     ./make-dist.sh --check      # 只看有没有过期，不写不提交
#     ./make-dist.sh --no-commit  # 生成但不提交
# ==============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODE="commit"
case "${1:-}" in
    --check)     MODE="check" ;;
    --no-commit) MODE="nogen-commit" ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) die "未知参数 $1（-h 看用法）" ;;
esac

require_root
[ -f "$CONF_FILE" ] || die "找不到 $CONF_FILE"

# ---------- 脱敏规则 ----------
# 只脱敏确实敏感的两类，其它一律原样保留（保留可读性才有参考价值）
sanitize_conf_env() {
    sed -E \
        -e "s/^(CI_PASSWORD=).*/\1<改成你自己的密码>/" \
        -e "s/^(SSH_KEY_FILE=).*/\1<你的 SSH 私钥路径>/" \
        -e "s|^(SSH_PUBKEY_FILE=).*|\1<你的 SSH 公钥路径>|" \
        "$CONF_FILE"
}

sanitize_vm_conf() {
    sed -E \
        -e "s/^(cipassword:).*/\1 <hidden>/" \
        -e "s/^(sshkeys:).*/\1 <hidden>/" \
        "$1"
}

# ---------- 逐个生成 ----------
# 本次校验过的派生产物。提交与否看它们和 git HEAD 是否一致，
# 而不是"本次有没有写过文件" —— 文件可能早就被别人改对了，
# 但还没提交，那次跑 make-dist 就该把它带上。
declare -a CHANGED=()
declare -a STALE=()
declare -a GENERATED=()

gen() {  # gen <目标文件> <生成命令...>
    local out="$1"; shift
    GENERATED+=("$out")
    local tmp; tmp=$(mktemp)
    if ! "$@" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        warn "生成 $out 失败，已跳过"
        return 1
    fi
    if [ -f "$out" ] && diff -q "$out" "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        printf '    %-40s 无变化\n' "${out#$SCRIPT_DIR/}"
        return 0
    fi
    # --check 必须是只读的。之前这里无条件 cp，把"检查"变成了"顺手改掉"，
    # 结果退出码说"已过期"但文件其实已经被改了。
    if [ "$MODE" = "check" ]; then
        rm -f "$tmp"
        printf '    %-40s 已过期\n' "${out#$SCRIPT_DIR/}"
        STALE+=("$out")
        return 0
    fi
    cp "$tmp" "$out"
    rm -f "$tmp"
    printf '    %-40s 已更新\n' "${out#$SCRIPT_DIR/}"
    CHANGED+=("$out")
    return 0
}

step "1/4  conf.env → conf.env.example"
gen "$SCRIPT_DIR/conf.env.example" sanitize_conf_env

step "2/4  模板配置 → reference/expected-$TPL_VMID.conf"
VMCONF="/etc/pve/qemu-server/$TPL_VMID.conf"
if [ -f "$VMCONF" ]; then
    gen "$SCRIPT_DIR/reference/expected-$TPL_VMID.conf" sanitize_vm_conf "$VMCONF"
else
    warn "模板 $TPL_VMID 还没建（$VMCONF 不存在），跳过。先跑 build-template.sh"
fi

step "3/4  节点配置 → reference/expected-node-config"
NODECONF="/etc/pve/nodes/$PVE_NODE/config"
if [ -f "$NODECONF" ]; then
    gen "$SCRIPT_DIR/reference/expected-node-config" cat "$NODECONF"
else
    warn "节点配置 $NODECONF 不存在，跳过（tune-host.sh 会创建它）"
fi

if [ "$MODE" = "check" ]; then step "4/4  检查结果"; else step "4/4  提交"; fi
if [ "$MODE" = "check" ]; then
    if [ "${#STALE[@]}" -eq 0 ]; then
        ok "派生产物都是最新的（本次检查未改动任何文件）"
        exit 0
    fi
    echo
    warn "${#STALE[@]} 个派生产物已过期:"
    for f in "${STALE[@]}"; do printf '      %s\n' "${f#$SCRIPT_DIR/}"; done
    echo
    warn "跑 ./make-dist.sh 同步"
    exit 1
fi

DIRTY=()
for f in "${GENERATED[@]}"; do
    [ -f "$f" ] || continue
    git -C "$SCRIPT_DIR" diff --quiet -- "$f" 2>/dev/null || DIRTY+=("$f")
    git -C "$SCRIPT_DIR" diff --cached --quiet -- "$f" 2>/dev/null || DIRTY+=("$f")
done

if [ "${#DIRTY[@]}" -eq 0 ]; then
    ok "派生产物已与 git HEAD 一致，无需提交"
    exit 0
fi

printf '    待提交:\n'
for f in "${DIRTY[@]}"; do printf '      %s\n' "${f#$SCRIPT_DIR/}"; done

if [ "$MODE" = "nogen-commit" ]; then
    echo
    info "已生成，未提交（--no-commit）"
    exit 0
fi

cd "$SCRIPT_DIR"
git add -A
if git -c core.hooksPath=/dev/null commit -q -m "同步派生产物: conf.env.example + reference/*

由 make-dist.sh 生成，不要手工编辑这三个文件:
  conf.env.example
  reference/expected-*.conf

对应的来源:
  conf.env
  /etc/pve/qemu-server/$TPL_VMID.conf
  /etc/pve/nodes/$PVE_NODE/config"; then
    ok "已提交 $(git rev-parse --short HEAD)"
    echo
    info "推送: git push"
else
    warn "提交失败（可能没有 git 仓库或没有变更）"
fi
