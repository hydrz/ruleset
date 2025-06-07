#!/bin/bash

# 同步 blackmatrix7/ios_rule_script 中的规则到本地 ruleset 目录
# https://github.com/blackmatrix7/ios_rule_script

readonly SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)

# 检测操作系统
case "$(uname)" in
Darwin) SED_INPLACE="sed -i ''" ;;
Linux) SED_INPLACE="sed -i" ;;
*)
    echo "不支持的操作系统: $(uname)"
    SED_INPLACE="sed -i" # 默认值，继续执行
    ;;
esac

# 定义常量
readonly SRC_DIR="$SCRIPT_PATH/ios_rule_script"
readonly RULES_DIR="$SRC_DIR/rule/Clash"
readonly DEST_DIR="$SCRIPT_PATH/clash"
readonly CUSTOM_RULES_FILE="$SCRIPT_PATH/custom-rules.txt"
readonly README="$SCRIPT_PATH/RULESET.md"
readonly REPO_URL="https://github.com/blackmatrix7/ios_rule_script.git"
readonly LOG_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 颜色和统计
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
TOTAL_RULES_COPIED=0
CUSTOM_RULES_APPLIED=0
CUSTOM_RULES_ERRORS=0

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 清理备份文件
cleanup_backups() {
    find "$DEST_DIR" -name "*.bak" -type f -delete 2>/dev/null || {
        find "$DEST_DIR" -name "*.bak" -type f -exec rm -f {} \; 2>/dev/null || true
    }
}

trap cleanup_backups EXIT

# 验证依赖
check_dependencies() {
    local missing=()
    for dep in git find grep sed; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_error "缺少依赖: ${missing[*]}"
        return 1
    fi
    return 0
}

# 更新仓库
update_repository() {
    local needs_clone=false

    if [[ -d "$SRC_DIR/.git" ]]; then
        if ! git -C "$SRC_DIR" pull --quiet --ff-only 2>/dev/null; then
            log_warning "更新失败，重新克隆"
            rm -rf "$SRC_DIR" 2>/dev/null || true
            needs_clone=true
        fi
    else
        needs_clone=true
    fi

    if [[ "$needs_clone" == "true" ]]; then
        log_info "克隆仓库..."
        if ! git clone --depth 1 --single-branch --no-tags --quiet "$REPO_URL" "$SRC_DIR" 2>/dev/null; then
            log_error "克隆失败"
            return 1
        fi
    fi

    if [[ ! -d "$RULES_DIR" ]]; then
        log_error "规则目录不存在: $RULES_DIR"
        return 1
    fi

    # 检查是否有规则文件
    local rule_count=$(find "$RULES_DIR" -name "*.list" 2>/dev/null | wc -l)
    if ((rule_count == 0)); then
        log_error "规则目录无效，未找到规则文件"
        return 1
    fi

    log_success "仓库准备完成"
    return 0
}

# 复制规则文件（平铺，保留时间戳，批量cp加速）
copy_rules() {
    log_info "同步规则文件..."
    mkdir -p "$DEST_DIR" 2>/dev/null || true

    # 清理旧文件
    find "$DEST_DIR" -name "*.list" -delete 2>/dev/null || true

    # 获取 CPU 核心数，设置合理的并行数
    local cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
    local parallel_jobs=$((cpu_cores > 8 ? 8 : cpu_cores))

    # 并行复制，每个进程处理多个文件
    find "$RULES_DIR" -name "*.list" -type f -print0 |
        xargs -0 -n 10 -P "$parallel_jobs" sh -c '
            for file do
                [[ -f "$file" ]] && cp -p "$file" "$1/$(basename "$file")"
            done
        ' _ "$DEST_DIR"

    TOTAL_RULES_COPIED=$(find "$DEST_DIR" -name "*.list" 2>/dev/null | wc -l)
    log_success "复制 $TOTAL_RULES_COPIED 个文件（并行度: $parallel_jobs）"
}

# 验证规则格式
validate_rule() {
    [[ "$1" =~ ^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|DST-PORT|SRC-PORT|PROCESS-NAME|RULE-SET), ]]
}

# 标准化路径
normalize_path() {
    local path="${1#$DEST_DIR/}"
    path="${path#./}"
    if [[ ! "$path" =~ \.list$ ]]; then
        path="$path.list"
    fi
    echo "$path"
}

# 处理自定义规则
apply_custom_rules() {
    if [[ ! -f "$CUSTOM_RULES_FILE" ]]; then
        log_info "跳过自定义规则"
        return 0
    fi


    log_info "应用自定义规则..."

    local modified=0 total=0 errors=0


    # 确保读取最后一行（即使没有换行符）
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释和空行
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
            continue
        fi

        if [[ $line =~ ^([^[:space:]]+)[[:space:]]+([+-])[[:space:]]+(.+)$ ]]; then
            local file_path operation rule_content
            file_path=$(normalize_path "${BASH_REMATCH[1]}")
            operation="${BASH_REMATCH[2]}"
            rule_content="${BASH_REMATCH[3]}"
            local full_path="$DEST_DIR/$file_path"

            # 验证规则
            if ! validate_rule "$rule_content"; then
                ((errors++))
                continue
            fi

            # 确保文件存在
            if [[ ! -f "$full_path" ]]; then
                mkdir -p "$(dirname "$full_path")" 2>/dev/null || true
                {
                    printf "# Custom rules for %s\n" "$(basename "$file_path" .list)"
                    printf "# Generated at %s\n\n" "$LOG_TIMESTAMP"
                } >"$full_path" 2>/dev/null || true
            fi

            ((total++))
            local escaped_rule=$(printf '%s' "$rule_content" | sed 's/[[\.*^$()+?{|]/\\&/g')

            case "$operation" in
            +)
                log_info "添加规则: $rule_content 到 $full_path"
                if ! grep -q "^$escaped_rule$" "$full_path" 2>/dev/null; then
                    if echo "$rule_content" >>"$full_path" 2>/dev/null; then
                        ((modified++))
                        log_success "规则添加成功"
                    else
                        log_error "规则添加失败"
                    fi
                else
                    log_warning "规则已存在，跳过"
                fi
                ;;
            -)
                if grep -q "^$escaped_rule$" "$full_path" 2>/dev/null; then
                    if eval "$SED_INPLACE \"/^$escaped_rule\$/d\" \"$full_path\"" 2>/dev/null; then
                        ((modified++))
                    fi
                    [[ -f "$full_path.bak" ]] && rm -f "$full_path.bak" 2>/dev/null
                fi
                ;;
            *)
                ((errors++))
                ;;
            esac
        else
            ((errors++))
        fi
    done <"$CUSTOM_RULES_FILE"

    CUSTOM_RULES_APPLIED=$modified
    CUSTOM_RULES_ERRORS=$errors

    if ((total > 0)); then
        log_success "处理 $total 条规则，修改 $modified 处"
        if ((errors > 0)); then
            log_warning "错误: $errors 个"
        fi
    fi
}

# 更新README
update_readme() {
    local src="$SRC_DIR/rule/Clash/README.md"
    if [[ ! -f "$src" ]]; then
        log_warning "源README不存在"
        return 1
    fi

    log_info "更新README..."
    {
        printf "# Ruleset\n\n"
        printf "> 同步时间: %s\n" "$LOG_TIMESTAMP"
        printf "> 规则文件: %d 个\n" "$TOTAL_RULES_COPIED"
        printf "> 自定义规则: %d 个\n\n" "$CUSTOM_RULES_APPLIED"
        printf "%s\n\n" "---"
        tail -n +2 "$src" 2>/dev/null || echo "README内容获取失败"
    } >"$README" 2>/dev/null || {
        log_warning "README更新失败"
        return 1
    }

    # 更新链接
    if eval "$SED_INPLACE 's|https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash/\([^)]*\)|https://github.com/hydrz/ruleset/tree/main/clash/\1.list|g' \"$README\"" 2>/dev/null; then
        [[ -f "$README.bak" ]] && rm -f "$README.bak" 2>/dev/null
        log_success "README已更新"
    else
        log_warning "README链接更新失败"
    fi
}

# 显示摘要
show_summary() {
    printf "\n%s\n%s\n%s\n" "========================================" "           同步完成摘要" "========================================"
    printf "时间: %s\n" "$LOG_TIMESTAMP"
    printf "规则: %d 个\n" "$TOTAL_RULES_COPIED"
    printf "自定义: %d 个\n" "$CUSTOM_RULES_APPLIED"
    if ((CUSTOM_RULES_ERRORS > 0)); then
        printf "错误: %d 个\n" "$CUSTOM_RULES_ERRORS"
    fi
    printf "%s\n" "========================================"
}

# 主函数
main() {
    printf "%s\n%s\n%s\n" "========================================" "    规则同步工具 $LOG_TIMESTAMP" "========================================"

    if ! check_dependencies; then
        exit 1
    fi

    if ! update_repository; then
        exit 1
    fi

    copy_rules
    apply_custom_rules
    update_readme
    show_summary

    log_success "同步完成!"
}

main "$@"
