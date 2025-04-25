#!/bin/bash

# 启用严格模式
set -euo pipefail

readonly SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)

# 配置目录
readonly RULESET_DIR="$SCRIPT_PATH/clash"
readonly OUTPUT_DIR="$SCRIPT_PATH/singbox"
readonly SINGBOX="$SCRIPT_PATH/sing-box"

# 创建临时目录并设置退出时清理
readonly TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 颜色定义，提高可读性
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 初始化函数
init() {
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    log_info "初始化完成，输出目录: $OUTPUT_DIR"
}

# 安装 sing-box
install_singbox() {
    local os arch singbox_version singbox_url

    log_info "检测 sing-box..."

    if [[ -x "$SINGBOX" ]]; then
        log_success "sing-box 已安装: $SINGBOX"
        log_info "sing-box 版本: $($SINGBOX version)"
        return 0
    fi

    log_info "未找到 sing-box，正在安装..."

    # 检测系统和架构
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)

    # 确定架构参数
    case "$arch" in
    x86_64)
        [[ "$os" == "darwin" ]] && arch="amd64-legacy" || arch="amd64"
        ;;
    arm64 | aarch64)
        arch="arm64"
        ;;
    *)
        log_error "不支持的架构: $arch"
        return 1
        ;;
    esac

    # 获取最新版本号
    log_info "获取最新版本..."
    singbox_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest |
        grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)

    if [[ -z "$singbox_version" ]]; then
        log_error "无法获取最新版本"
        return 1
    fi

    log_info "安装 sing-box 版本: $singbox_version"

    # 构建下载 URL 并下载
    singbox_url="https://github.com/SagerNet/sing-box/releases/download/${singbox_version}/sing-box-${singbox_version#v}-${os}-${arch}.tar.gz"
    log_info "从以下地址下载: $singbox_url"

    if ! curl -L --retry 5 --retry-delay 2 -o sing-box.tar.gz "$singbox_url"; then
        log_error "下载 sing-box 失败"
        return 1
    fi

    # 提取二进制文件
    tar -xzf sing-box.tar.gz -C "$TMP_DIR"

    # 移动二进制文件到目标位置
    find "$TMP_DIR" -name "sing-box" -type f -exec cp {} "$SINGBOX" \;

    if [[ ! -f "$SINGBOX" ]]; then
        log_error "提取 sing-box 二进制文件失败"
        return 1
    fi

    chmod +x "$SINGBOX"
    log_success "sing-box 成功安装到 $SINGBOX"
    log_info "sing-box 版本: $($SINGBOX version)"
    return 0
}

# 处理规则列表文件
process_list_file() {
    local list_file="$1"
    local filename=$(basename "$list_file" .list)
    local json_file="$OUTPUT_DIR/${filename}.json"
    local srs_file="$OUTPUT_DIR/${filename}.srs"

    # 一次性预处理文件并过滤注释和空行
    local filtered_content=$(grep -v "^[[:space:]]*#" "$list_file" | grep -v "^[[:space:]]*$")

    # 使用 awk 更高效地处理匹配和分类
    awk_script='
    BEGIN { FS="[, ]+" }
    /^(DOMAIN-SUFFIX|HOST-SUFFIX|host-suffix)/ { suffix_rules[++s_count]=$2; next }
    /^(DOMAIN|HOST|host)/ { domain_rules[++d_count]=$2; next }
    /^(DOMAIN-KEYWORD|HOST-KEYWORD|host-keyword)/ { keyword_rules[++k_count]=$2; next }
    /^(IP-CIDR|ip-cidr)/ { ipv4_rules[++i4_count]=$2; next }
    /^(IP-CIDR6|IP6-CIDR)/ { ipv6_rules[++i6_count]=$2; next }
    END {
        printf "\"domain\":["
        for (i=1; i<=d_count; i++) 
            printf "%s\"%s\"", (i>1?",":""), domain_rules[i]
        printf "],"

        printf "\"domain_suffix\":["
        for (i=1; i<=s_count; i++) 
            printf "%s\"%s\"", (i>1?",":""), suffix_rules[i]
        printf "],"

        printf "\"domain_keyword\":["
        for (i=1; i<=k_count; i++) 
            printf "%s\"%s\"", (i>1?",":""), keyword_rules[i]
        printf "],"

        printf "\"ip_cidr\":["
        for (i=1; i<=i4_count; i++) 
            printf "%s\"%s\"", (i>1?",":""), ipv4_rules[i]
        for (i=1; i<=i6_count; i++) 
            printf "%s\"%s\"", ((i>1||i4_count>0)?",":""), ipv6_rules[i]
        printf "]"
    }'

    # 使用 awk 处理规则分类并生成 JSON 部分
    local rules_data=$(echo "$filtered_content" | awk "$awk_script")

    # 生成完整 JSON 文件
    cat >"$json_file" <<EOF
{
  "version": 2,
  "rules": [
    {
      $(echo "$rules_data" | sed 's/,$//')
    }
  ]
}
EOF

    # 使用 sing-box 编译 srs 文件
    if "$SINGBOX" rule-set compile --output "$srs_file" "$json_file" >/dev/null 2>&1; then
        rm -f "$json_file"
        return 0
    else
        rm -f "$json_file"
        return 1
    fi
}

# 并行处理所有规则列表文件
process_all_files() {
    local cpu_count max_jobs total_files processed failed
    local list_files=()
    local failed_files=()

    # 获取可用 CPU 核心数
    cpu_count=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

    # 为系统稳定性，设置最大并行任务数为 CPU 核心数
    max_jobs=$cpu_count
    log_info "检测到 $cpu_count 个 CPU 核心，将使用最多 $max_jobs 个并行任务"

    # 查找所有 .list 文件
    mapfile -t list_files < <(find "$RULESET_DIR" -type f -name "*.list")
    total_files=${#list_files[@]}
    log_info "找到 $total_files 个文件需要处理"

    # 初始化计数器
    processed=0
    failed=0

    # 定义处理跟踪函数
    update_progress() {
        processed=$((processed + 1))
        local percent=$((100 * processed / total_files))
        printf "\r处理进度: %d/%d (%d%%)" "$processed" "$total_files" "$percent"
    }

    # 检查是否有 GNU Parallel 可用
    if command -v parallel &>/dev/null; then
        log_info "使用 GNU Parallel 进行并行处理"

        # 临时文件用于收集失败的文件
        local temp_failed="$TMP_DIR/failed_files"
        touch "$temp_failed"

        # 导出函数以便子进程使用
        export -f process_list_file
        export -f log_info log_success log_warning log_error
        export SINGBOX OUTPUT_DIR RED GREEN YELLOW BLUE NC

        parallel --bar --jobs "$max_jobs" \
            "if ! process_list_file {}; then echo {} >> $temp_failed; fi" \
            ::: "${list_files[@]}"

        # 检查处理失败的文件
        if [[ -s "$temp_failed" ]]; then
            mapfile -t failed_files <"$temp_failed"
            failed=${#failed_files[@]}
        fi
    else
        # 如果 GNU Parallel 不可用，使用自定义并行逻辑
        log_info "未检测到 GNU Parallel，使用内置并行逻辑"

        # 使用控制变量跟踪运行中的作业
        local running=0
        local pids=()

        for file in "${list_files[@]}"; do
            # 当达到最大作业数时，等待任一子进程结束
            while [[ $running -ge $max_jobs ]]; do
                local alive_pids=()
                for pid in "${pids[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        alive_pids+=("$pid")
                    fi
                done
                pids=("${alive_pids[@]}")
                running=${#pids[@]}

                [[ $running -ge $max_jobs ]] && sleep 0.1
            done

            # 启动新的后台作业
            (
                if ! process_list_file "$file"; then
                    echo "$file" >>"$TMP_DIR/failed_$processed"
                fi
            ) &

            # 存储 PID 和更新运行中的作业计数
            pids+=($!)
            running=$((running + 1))

            # 更新进度
            update_progress
        done

        # 等待所有后台作业完成
        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done

        # 收集失败的文件
        for i in $(seq 0 $((total_files - 1))); do
            if [[ -f "$TMP_DIR/failed_$i" ]]; then
                failed_files+=("$(cat "$TMP_DIR/failed_$i")")
            fi
        done
        failed=${#failed_files[@]}

        echo # 添加换行以便更好的显示最终结果
    fi

    # 显示处理结果
    log_info "所有文件处理完成"
    log_success "成功: $((total_files - failed)) 个文件"

    # 显示失败的文件列表
    if [[ $failed -gt 0 ]]; then
        log_error "失败: $failed 个文件"
        log_error "以下文件处理失败:"
        for file in "${failed_files[@]}"; do
            log_error "  - $(basename "$file")"
        done
    fi
}

# 主流程
main() {
    echo "=================================================="
    echo "  SingBox 规则集转换工具"
    echo "  $(date)"
    echo "=================================================="

    # 初始化
    init

    # 确保 sing-box 存在
    if ! install_singbox; then
        log_error "sing-box 安装失败，退出"
        exit 1
    fi

    # 处理所有文件
    process_all_files

    echo "=================================================="
    echo "  转换完成"
    echo "=================================================="

    return 0
}

# 执行主函数
main "$@"
