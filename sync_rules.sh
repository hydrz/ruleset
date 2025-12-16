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
readonly DEST_YAML_DIR="$SCRIPT_PATH/clash-yaml"
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

die() {
    log_error "$*"
    exit 1
}

# 检查依赖
! type git >/dev/null 2>&1 && die "缺少依赖: git"
! type find >/dev/null 2>&1 && die "缺少依赖: find"
! type grep >/dev/null 2>&1 && die "缺少依赖: grep"
! type sed >/dev/null 2>&1 && die "缺少依赖: sed"

# 强化脚本安全性：未设置变量即报错
set -u

# 安全的 in-place sed 替代函数
# 避免直接使用 sed -i / eval，统一使用临时文件并尽量保留文件元数据
sed_inplace() {
    local sed_expr="$1"
    local file="$2"

    # 如果目标文件不存在，返回失败
    [[ -f "$file" ]] || return 1

    local tmpbak
    tmpbak=$(mktemp "${file}.tmp.XXXXXX") || return 1

    # 使用 sed 将处理结果写入临时文件，然后原子替换
    if sed "$sed_expr" "$file" >"$tmpbak" 2>/dev/null; then
        # 尝试保留原始文件属性（宽松处理，若失败则忽略）
        cp -p "$file" "${file}.bak" 2>/dev/null || true
        mv "$tmpbak" "$file"
        # 清理临时备份（保留 .bak 不再强制删除，便于排错）
        return 0
    else
        rm -f "$tmpbak" 2>/dev/null || true
        return 1
    fi
}

# 更新仓库
update_repository() {
    local needs_clone=false

    if [[ -d "$SRC_DIR/.git" ]]; then
        if ! git -C "$SRC_DIR" pull --ff-only 2>/dev/null; then
            log_warning "更新失败，重新克隆"
            rm -rf "$SRC_DIR" 2>/dev/null || true
            needs_clone=true
        fi
    else
        needs_clone=true
    fi

    if [[ "$needs_clone" == "true" ]]; then
        log_info "克隆仓库..."
        if ! git clone --depth 1 --single-branch --no-tags "$REPO_URL" "$SRC_DIR" 2>/dev/null; then
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
	mkdir -p "$DEST_YAML_DIR" 2>/dev/null || true

    # 清理旧文件
    find "$DEST_DIR" -name "*.list" -delete 2>/dev/null || true
    find "$DEST_YAML_DIR" -name "*.yaml" -delete 2>/dev/null || true

    # 获取 CPU 核心数，设置合理的并行数
    local cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
    local parallel_jobs=$((cpu_cores > 8 ? 8 : cpu_cores))

    # 并行复制 .list与.yaml，每个进程处理多个文件
    find "$RULES_DIR" -name "*.list" -type f -print0 |
        xargs -0 -n 10 -P "$parallel_jobs" sh -c '
            for file do
                [ -f "$file" ] && cp -p "$file" "$1/$(basename "$file")"
            done
        ' _ "$DEST_DIR"
	find "$RULES_DIR" -name "*.yaml" -type f -print0 |
		xargs -0 -n 10 -P "$parallel_jobs" sh -c '
			for file do
				[ -f "$file" ] && cp -p "$file" "$1/$(basename "$file")"
			done
		' _ "$DEST_YAML_DIR"

    local list_count=$(find "$DEST_DIR" -name "*.list" 2>/dev/null | wc -l)
    local yaml_count=$(find "$DEST_YAML_DIR" -name "*.yaml" 2>/dev/null | wc -l)
    # 使用默认值防止在 set -u 下未绑定变量导致脚本退出
    log_success "复制 $list_count 个 .list 文件, $yaml_count 个 .yaml 文件（并行度: ${parallel_jobs:-1}）"
}

# 验证规则格式
validate_rule() {
    [[ "$1" =~ ^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|DST-PORT|SRC-PORT|PROCESS-NAME|RULE-SET), ]]
}

# 标准化路径：支持 .list 或 .yaml
normalize_path() {
	local base_name="${1##*/}"
	base_name="${base_name%.*}"
	echo "$base_name"
}

# 处理自定义规则（增强：同时作用于 .yaml 和 .list，支持 _No_Resolve 变体）
apply_custom_rules() {
    if [[ ! -f "$CUSTOM_RULES_FILE" ]]; then
        log_info "跳过自定义规则"
        return 0
    fi

    log_info "应用自定义规则..."

    local modified=0 total=0 errors=0

    # 逐行读取，包括最后一行无换行符的情况
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释和空行
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
            continue
        fi

        if [[ $line =~ ^([^[:space:]]+)[[:space:]]+([+-])[[:space:]]+(.+)$ ]]; then
            local input_name operation rule_content
            input_name="${BASH_REMATCH[1]}"
            operation="${BASH_REMATCH[2]}"
            rule_content="${BASH_REMATCH[3]}"

            # 验证规则
            if ! validate_rule "$rule_content"; then
                ((errors++))
                continue
            fi

            ((total++))

            # 规范化输入名，去掉路径和前缀后缀
            local base_input
            base_input="${input_name##*/}"
            base_input="${base_input%.*}"

            # 生成要处理的 base 列表：原名、带/不带 _No_Resolve 的变体（避免重复）
            local targets=""
            add_target() {
                local t="$1"
                for existing in $targets; do
                    [[ "$existing" == "$t" ]] && return
                done
                targets="$targets $t"
            }

            add_target "$base_input"
            if [[ "$base_input" =~ _No_Resolve$ ]]; then
                add_target "${base_input%_No_Resolve}"
            else
                add_target "${base_input}_No_Resolve"
            fi

            # 对每个 target 处理 .yaml 与 .list
            for tgt in $targets; do
                local target_list="$DEST_DIR/${tgt}.list"
                local target_yaml="$DEST_YAML_DIR/${tgt}.yaml"

                # 确保目录存在
                mkdir -p "$(dirname "$target_yaml")" 2>/dev/null || true

                # 处理 YAML
                local grep_line="  - $rule_content"
                if [[ "$operation" == "+" ]]; then
                    # 创建模板（如果不存在）
                    if [[ ! -f "$target_yaml" ]]; then
                        {
                            printf "# Custom rules for %s\n" "$tgt"
                            printf "# Generated at %s\n" "$LOG_TIMESTAMP"
                            printf "payload:\n"
                        } >"$target_yaml" 2>/dev/null || true
                    fi

                    if [[ -f "$target_yaml" ]] && ! grep -Fxq "$grep_line" "$target_yaml" 2>/dev/null; then
                        if ! grep -q "^payload:[[:space:]]*$" "$target_yaml" 2>/dev/null; then
                            printf "\npayload:\n" >>"$target_yaml" 2>/dev/null || true
                        fi
                        printf "  - %s\n" "$rule_content" >>"$target_yaml" 2>/dev/null && ((modified++)) || ((errors++))
                        log_info "YAML 添加: $rule_content -> ${tgt}.yaml"
                    fi

                    # 添加到 .list
                    if [[ ! -f "$target_list" ]]; then
                        mkdir -p "$(dirname "$target_list")" 2>/dev/null || true
                        {
                            printf "# Custom rules for %s\n" "$tgt"
                            printf "# Generated at %s\n\n" "$LOG_TIMESTAMP"
                        } >"$target_list" 2>/dev/null || true
                    fi

                    local escaped_rule
                    escaped_rule=$(printf '%s' "$rule_content" | sed 's/[]\\.*^$()+?{|]/\\&/g')
                    if [[ -f "$target_list" ]] && ! grep -q "^$escaped_rule$" "$target_list" 2>/dev/null; then
                        echo "$rule_content" >>"$target_list" 2>/dev/null && ((modified++)) || ((errors++))
                        log_info "LIST 添加: $rule_content -> ${tgt}.list"
                    fi

                else
                    # 删除操作：从 YAML 和 list 删除
                    if [[ -f "$target_yaml" ]]; then
                        local escaped
                        escaped=$(printf '%s' "$rule_content" | sed 's/[\/&]/\\&/g')
                        if sed_inplace "s/^[[:space:]]*-[[:space:]]*${escaped}[[:space:]]*$//" "$target_yaml"; then
                            sed_inplace '/^payload:[[:space:]]*$/d' "$target_yaml" || true
                            ((modified++))
                            log_info "YAML 删除: $rule_content -> ${tgt}.yaml"
                        fi
                    fi

                    if [[ -f "$target_list" ]]; then
                        local escaped_rule_del
                        escaped_rule_del=$(printf '%s' "$rule_content" | sed 's/[]\\.*^$()+?{|]/\\&/g')
                        if sed_inplace "/^$escaped_rule_del$/d" "$target_list"; then
                            ((modified++))
                            log_info "LIST 删除: $rule_content -> ${tgt}.list"
                        fi
                    fi
                fi
            done

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

    # 更新链接（使用安全封装，避免 eval）
    if sed_inplace "s|https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash/\([^)]*\)|https://github.com/hydrz/ruleset/tree/main/clash/\1.list|g" "$README"; then
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
