#!/bin/bash

# 同步 blackmatrix7/ios_rule_script 中的规则到本地 ruleset 目录
# https://github.com/blackmatrix7/ios_rule_script

# 启用严格模式，提高脚本可靠性
set -euo pipefail

# 获取脚本所在目录的绝对路径
readonly SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)

# 定义常量，提高可维护性
readonly SRC_DIR="$SCRIPT_PATH/ios_rule_script"
readonly RULES_DIR="$SRC_DIR/rule/Clash"
readonly DEST_DIR="$SCRIPT_PATH/clash"
readonly README="$SCRIPT_PATH/RULESET.md"
readonly REPO_URL="https://github.com/blackmatrix7/ios_rule_script.git"
readonly SRC_PREFIX="https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash/"
readonly DEST_PREFIX="https://github.com/hydrz/ruleset/tree/main/clash/"

# 颜色定义，提高日志可读性
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "[INFO] $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 创建目标目录
create_directories() {
    log_info "创建目标目录..."
    mkdir -p "$DEST_DIR"
}

# 克隆或更新仓库
update_repository() {
    if [ -d "$SRC_DIR/.git" ]; then
        log_info "正在更新 ios_rule_script 仓库..."
        if git -C "$SRC_DIR" pull --quiet; then
            log_success "仓库更新成功!"
        else
            log_warning "仓库更新失败，尝试重新克隆..."
            rm -rf "$SRC_DIR"
            clone_repository
        fi
    else
        clone_repository
    fi
}

# 克隆仓库
clone_repository() {
    log_info "正在克隆 ios_rule_script 仓库..."
    if git clone --depth 1 --quiet "$REPO_URL" "$SRC_DIR"; then
        log_success "仓库克隆成功!"
    else
        log_error "仓库克隆失败，请检查网络连接!"
        exit 1
    fi
}

# 验证仓库结构
validate_repository() {
    log_info "验证仓库结构..."
    if [ ! -d "$RULES_DIR" ]; then
        log_error "规则目录不存在，请检查仓库结构是否已更改!"
        exit 1
    fi
    log_success "仓库结构验证通过!"
}

# 复制规则文件
copy_rules() {
    log_info "开始同步规则文件..."

    # 计算文件总数
    local total_files=$(find "$RULES_DIR" -type f -name "*.list" | wc -l)
    log_info "找到 $total_files 个规则文件"

    # 复制规则文件
    log_info "复制规则文件..."
    find "$RULES_DIR" -type f -name "*.list" -exec cp {} "$DEST_DIR/" \;

    # 验证复制结果
    local copied_files=$(find "$DEST_DIR" -type f -name "*.list" | wc -l)
    log_success "成功复制 $copied_files 个规则文件!"
}

# 更新 README 文件
update_readme() {
    log_info "更新 README 文件..."

    # 复制原始 README 文件
    cp "$SRC_DIR/rule/Clash/README.md" "$README"

    # 更新链接
    sed -i.bak "s|${SRC_PREFIX}\([^)]*\)|${DEST_PREFIX}\1.list|g" "$README" && rm "$README.bak"

    # 添加同步时间信息到 README
    local sync_date=$(date "+%Y-%m-%d %H:%M:%S")
    sed -i.bak "1i# Ruleset\n\n> 最后同步时间: $sync_date\n\n" "$README" && rm "$README.bak"

    log_success "README 文件已更新!"
}

# 主函数
main() {
    echo "========================================"
    echo "      规则同步工具 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"

    create_directories
    update_repository
    validate_repository
    copy_rules
    update_readme

    echo "========================================"
    log_success "规则同步完成! 请查看 $README"
    echo "========================================"
}

# 执行主函数
main "$@"
