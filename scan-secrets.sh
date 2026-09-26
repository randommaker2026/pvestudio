#!/usr/bin/env bash
# ==============================================================================
#  scan-secrets.sh —— 提交前自查：pvestudio 里有没有会泄漏的凭据
#
#  背景: 仓库根目录的 .gitignore 只忽略 .env / *.key / id_rsa 等，
#        覆盖不到 pvestudio/conf.env。所以 pvestudio 自己加了 .gitignore，
#        但 .gitignore 是按【文件名】匹配的 —— 文件名没问题的文件里
#        照样可能写着密码（比如曾经有人在 README 里贴过明文口令）。
#        这个脚本扫的是【内容】。
#
#  用法:
#     ./scan-secrets.sh              # 扫 pvestudio 目录
#     ./scan-secrets.sh --staged     # 只扫 git 暂存区的内容（提交前最该跑）
#     ./scan-secrets.sh --path <dir> # 扫别的目录
# ==============================================================================
set -euo pipefail

# 这个脚本刻意【不】source lib/common.sh —— 提交前自查的工具不该依赖
# conf.env 或 PVE 环境，在任何机器上（包括没装 PVE 的开发机）都能跑。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[31m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_R=; C_Y=; C_D=; C_0=
fi
info() { printf '%s  › %s%s\n' "$C_D" "$*" "$C_0"; }
warn() { printf '%s  ! %s%s\n' "$C_Y" "$*" "$C_0"; }
err()  { printf '%s  ✘ %s%s\n' "$C_R" "$*" "$C_0"; }
ok()   { printf '%s  ✔ %s%s\n' "$C_D" "$*" "$C_0"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="dir"
TARGET="$SCRIPT_DIR"

case "${1:-}" in
    --staged) MODE="staged" ;;
    --self-test) MODE="selftest" ;;
    --path)   MODE="path"; TARGET="${2:?--path 需要给目录}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "未知参数 $1" >&2; exit 1 ;;
esac

# 规则用三个【并行数组】存，不用分隔符拼一行 ——
# 之前用 ':' 拼，结果正则里自带的冒号（cipassword: ... / Authorization: ...）
# 把分隔符提前吃掉了，规则全被截断，扫出一堆假警报。
RULE_RE=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'cipassword: \$[0-9]\$'
  'password[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9@!#$%^&*_+-]{6,}'
  'api[_-]?key[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]{16,}'
  'Authorization:[[:space:]]*(Bearer|Basic)[[:space:]]+[A-Za-z0-9+/=]{8,}'
  'ssh-rsa [A-Za-z0-9+/]{60,}'
  'ssh-ed25519 [A-Za-z0-9+/]{40,}'
)
RULE_DESC=(
  '私钥 PEM 块'
  'cloud-init 口令的哈希值'
  '疑似明文口令赋值'
  '疑似 API key'
  'HTTP 认证头'
  'SSH 公钥（本身不秘密，确认是否想入库）'
  'SSH 公钥（同上）'
)
RULE_LVL=(致命 致命 致命 致命 致命 警告 警告)

# 匹配时有两个必须加的东西，都是踩过的坑:
#   -i   grep -E 默认区分大小写，API_KEY 匹配不上 api[_-]?key
#   --   模式以 ----- 开头时，grep 会把它当成命令行选项，整条规则静默失效
#        （之前还配了 2>/dev/null，把 grep 的报错也一起吞了，所以看不出问题）
scan_one() {  # scan_one <显示名> <文件路径>
    local name="$1" file="$2" i m err
    for i in "${!RULE_RE[@]}"; do
        m=$(grep -inE -- "${RULE_RE[$i]}" "$file" 2>/tmp/.scan_err | head -1) || true
        if [ -s /tmp/.scan_err ]; then
            # 规则本身写错了（正则非法之类）—— 这比漏报更该报出来
            err "规则「${RULE_DESC[$i]}」执行出错: $(head -1 /tmp/.scan_err)"
            RULE_BROKEN=$((RULE_BROKEN + 1))
        fi
        [ -n "$m" ] || continue
        # 展示时截断，避免这个脚本自己变成泄漏源
        report "$name" "${RULE_DESC[$i]}" "${RULE_LVL[$i]}" "$m"
    done
    rm -f /tmp/.scan_err
    return 0
}

# 自检: 往临时目录里种一份"每个规则都能命中一次"的样本，确认规则本身没坏。
# 没有这一步的话，规则静默失效时脚本会报"干净"，给出假安全感。
self_test() {
    local d rc=0 i
    d=$(mktemp -d)
    cat > "$d/planted" <<'PLANTED'
cipassword: $5$abcdefgh$UVG8/9mQKx3vNp2wR7tYsZ1aBcDeFgHiJkLmNoP
password = "SuperSecret123"
API_KEY = "AKIA1234567890ABCDEF"
api-key: abcdefghijklmnopqrstuvwx
Authorization: Bearer abcdefghijklmnop
-----BEGIN OPENSSH PRIVATE KEY-----
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDBCGCGLU2j0m4sKIk2tOj2gPVdzYPPlMSl6iX8LLtbZZnumE2ZhOUkpWgfUauP8isduWaw5AWbCza
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9m9Q2mVSV1k8j1k1k1k1k1k1k1k1k1k1k
-----END OPENSSH PRIVATE KEY-----
PLANTED

    for i in "${!RULE_RE[@]}"; do
        if grep -qiE -- "${RULE_RE[$i]}" "$d/planted"; then
            printf '  ✔ %s\n' "${RULE_DESC[$i]}"
        else
            printf '  ✘ %s —— 规则没命中，自检失败\n' "${RULE_DESC[$i]}"
            rc=1
        fi
    done
    rm -rf "$d"
    return $rc
}

# 该跳过哪些文件:
#   conf.env / .env*  —— 凭据文件，靠 .gitignore 保护，不该出现在扫描结果里
#   scan-secrets.sh   —— 本文件自身。里面既有规则正则、也有自检用的假样本，
#                        不跳过就会把自己报成泄漏，久了人就忽略这个工具的输出了。
#
# 这里必须用【字面量】写在 case 里，不能用变量。
# bash 的 case 模式虽然支持 | 分支，但从变量展开来的 | 不被当成分支分隔符 ——
# 实测 $PAT='a|b' 匹配 'a' 会失败，而字面量 'a|b' 匹配 'a' 正常。
# （另外更早一版这里写的是正则 (^|/)(conf\.env|...)$，在 case 里 ( 和 | 是字面字符，
#   同样失效。踩了两次，根因都是 case 走 glob 不走正则。）
skip_reason() {  # skip_reason <相对路径>；返回 0 表示应跳过，并打印原因
    case "${1##*/}" in
        conf.env|.env|.env.*)
            info "跳过 ${1} —— 凭据文件，由 .gitignore 保护"
            return 0 ;;
        scan-secrets.sh)
            info "跳过 ${1} —— 扫描器自身（含规则与自检样本）"
            return 0 ;;
    esac
    return 1
}

hits=0
fatal=0
RULE_BROKEN=0

report() {  # report <file> <说明> <级别> <匹配内容>
    local file="$1" desc="$2" level="$3" match="$4"
    # 展示时把敏感值截断，避免这个脚本自己变成泄漏源
    local short
    short=$(printf '%s' "$match" | cut -c1-40)
    case "$level" in
        致命) err  "$file —— $desc"; printf '        %s…\n' "$short" ;;
        *)     warn "$file —— $desc"; printf '        %s…\n' "$short" ;;
    esac
    hits=$((hits + 1))
    [ "$level" = "致命" ] && fatal=$((fatal + 1))
    return 0
}

if [ "$MODE" = "selftest" ]; then
    echo "规则自检（每条规则都应命中一次）:"
    st=0
    self_test || st=$?
    echo
    if [ "$st" -eq 0 ]; then
        ok "${#RULE_RE[@]} 条规则全部有效"
    else
        err "有规则失效，扫描结果不可信"
    fi
    exit "$st"
fi

if [ "$MODE" = "staged" ]; then
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "不在 git 仓库里" >&2; exit 1
    fi
    FILES=$(git diff --cached --name-only --diff-filter=ACM)
    [ -z "$FILES" ] && { ok "暂存区为空，没东西可扫"; exit 0; }
    echo "扫描暂存区 $(printf '%s\n' "$FILES" | wc -l) 个文件的内容…"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        skip_reason "$f" && continue
        scan_one "$f" "$f"
    done <<< "$FILES"
else
    COUNT=$(find "$TARGET" -type f \
        ! -path '*/.git/*' ! -name '*.log' 2>/dev/null | wc -l)
    echo "扫描 $TARGET 下 $COUNT 个文件的内容…"
    while IFS= read -r f; do
        rel="${f#$TARGET/}"
        skip_reason "$rel" && continue
        scan_one "$rel" "$f"
    done < <(find "$TARGET" -type f ! -path '*/.git/*' ! -name '*.log' 2>/dev/null)
fi

echo
if [ "$RULE_BROKEN" -gt 0 ]; then
    err "$RULE_BROKEN 条规则执行出错，扫描结果不可信"
    exit 2
elif [ "$fatal" -gt 0 ]; then
    err "$fatal 处致命泄漏 / 共 $hits 处命中 —— 不要提交"
    exit 1
elif [ "$hits" -gt 0 ]; then
    warn "$hits 处警告（无致命项）—— 逐条确认是否有意为之"
    exit 0
else
    ok "干净：没扫到凭据"
    exit 0
fi
