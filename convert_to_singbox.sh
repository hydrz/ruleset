#!/bin/bash

readonly SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)
readonly RULESET_DIR="$SCRIPT_PATH/clash"
readonly OUTPUT_DIR="$SCRIPT_PATH/singbox"

# 颜色和日志
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 规则文件处理
process_file() {
    local file="$1"
    local name=$(basename "$file" .list)
    local json_file="$OUTPUT_DIR/${name}.json"

    [[ ! -f "$file" ]] && return 1

    # 如果目标文件存在且源文件未更新，则跳过
    if [[ -f "$json_file" && "$file" -ot "$json_file" ]]; then
        echo "未修改，跳过 $file"
        return 0
    fi

    # 检查是否有有效规则
    if ! grep -q '^[A-Z]' "$file" 2>/dev/null; then
        local empty_content='{"version":2,"rules":[]}'
        echo "$empty_content" >"$json_file"
        return 0
    fi

    # AWK脚本生成JSON内容
    local json_content
    json_content=$(awk -F',' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^DOMAIN-SUFFIX,/ { ds[++dsc] = $2; next }
        /^DOMAIN,/ { d[++dc] = $2; next }
        /^DOMAIN-KEYWORD,/ { dk[++dkc] = $2; next }
        /^IP-CIDR/ { ip[++ipc] = $2; next }
        /^PROCESS-NAME,/ { pn[++pnc] = $2; next }
        /^DST-PORT,/ {
            if ($2 ~ /^[0-9]+$/) port[++portc] = $2
            else port_range[++port_rangec] = $2
            next
        }
        /^SRC-PORT,/ {
            if ($2 ~ /^[0-9]+$/) src_port[++src_portc] = $2
            else src_port_range[++src_port_rangec] = $2
            next
        }
        END {
            print "{"
            print "  \"version\": 2,"
            print "  \"rules\": ["

            total = dc + dsc + dkc + ipc + pnc + portc + port_rangec + src_portc + src_port_rangec
            if (total == 0) {
                print "  ]"
                print "}"
                exit
            }

            print "    {"

            # 构建字段数组
            fields = 0

            if (dsc > 0) {
                field_names[++fields] = "domain_suffix"
                field_types[fields] = "string_array"
                field_counts[fields] = dsc
                for(i=1; i<=dsc; i++) field_values[fields,i] = ds[i]
            }

            if (dc > 0) {
                field_names[++fields] = "domain"
                field_types[fields] = "string_array"
                field_counts[fields] = dc
                for(i=1; i<=dc; i++) field_values[fields,i] = d[i]
            }

            if (dkc > 0) {
                field_names[++fields] = "domain_keyword"
                field_types[fields] = "string_array"
                field_counts[fields] = dkc
                for(i=1; i<=dkc; i++) field_values[fields,i] = dk[i]
            }

            if (ipc > 0) {
                field_names[++fields] = "ip_cidr"
                field_types[fields] = "string_array"
                field_counts[fields] = ipc
                for(i=1; i<=ipc; i++) field_values[fields,i] = ip[i]
            }

            if (pnc > 0) {
                field_names[++fields] = "process_name"
                field_types[fields] = "string_array"
                field_counts[fields] = pnc
                for(i=1; i<=pnc; i++) field_values[fields,i] = pn[i]
            }

            if (portc > 0) {
                field_names[++fields] = "port"
                field_types[fields] = "number_array"
                field_counts[fields] = portc
                for(i=1; i<=portc; i++) field_values[fields,i] = port[i]
            }

            if (port_rangec > 0) {
                field_names[++fields] = "port_range"
                field_types[fields] = "string_array"
                field_counts[fields] = port_rangec
                for(i=1; i<=port_rangec; i++) field_values[fields,i] = port_range[i]
            }

            if (src_portc > 0) {
                field_names[++fields] = "source_port"
                field_types[fields] = "number_array"
                field_counts[fields] = src_portc
                for(i=1; i<=src_portc; i++) field_values[fields,i] = src_port[i]
            }

            if (src_port_rangec > 0) {
                field_names[++fields] = "source_port_range"
                field_types[fields] = "string_array"
                field_counts[fields] = src_port_rangec
                for(i=1; i<=src_port_rangec; i++) field_values[fields,i] = src_port_range[i]
            }

            # 输出字段
            for(f=1; f<=fields; f++) {
                if (f > 1) print ","
                printf "      \"%s\": [", field_names[f]

                for(i=1; i<=field_counts[f]; i++) {
                    gsub(/[[:space:]]*#.*$/, "", field_values[f,i])
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", field_values[f,i])

                    if (field_types[f] == "string_array") {
                        printf "\n        \"%s\"", field_values[f,i]
                    } else {
                        printf "\n        %s", field_values[f,i]
                    }

                    if (i < field_counts[f]) printf ","
                }
                printf "\n      ]"
            }

            print ""
            print "    }"
            print "  ]"
            print "}"
        }' "$file")

    # 验证JSON格式
    if [[ -z "$json_content" ]]; then
        return 1
    fi

    # 写入新内容
    echo "$json_content" >"$json_file"
    return 0
}

# 进度显示函数
show_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r${BLUE}[进度]${NC} ["
    printf "%*s" "$filled" "" | tr ' ' '='
    printf "%*s" "$empty" ""
    printf "] %d/%d (%d%%)" "$current" "$total" "$percentage"
}

# 并行处理
process_worker() {
    local file="$1"

    if process_file "$file"; then
        echo "SUCCESS"
    else
        echo "FAILED"
    fi
}

# 主处理函数
process_all() {
    # 增加并行度
    local max_jobs=8
    if command -v nproc >/dev/null 2>&1; then
        max_jobs=$(($(nproc) * 2))
    elif command -v sysctl >/dev/null 2>&1; then
        max_jobs=$(($(sysctl -n hw.ncpu 2>/dev/null || echo 4) * 2))
    fi

    # 限制最大并行数
    ((max_jobs > 16)) && max_jobs=16
    ((max_jobs < 4)) && max_jobs=4

    # 文件列表收集
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$RULESET_DIR" -name "*.list" -type f -print0 2>/dev/null)

    local total=${#files[@]}
    if ((total == 0)); then
        log_warning "无文件需要处理"
        return
    fi

    log_info "处理 $total 个文件 (并行度: $max_jobs)"

    # 导出函数供子进程使用
    export -f process_file
    export OUTPUT_DIR

    # 创建命名管道用于进度跟踪
    local progress_pipe=$(mktemp -u)
    mkfifo "$progress_pipe"

    # 捕获中断信号，确保子进程和管道被清理
    cleanup() {
        [[ -n "$progress_pid" ]] && kill "$progress_pid" 2>/dev/null
        rm -f "$progress_pipe"
        exit 1
    }
    trap cleanup INT TERM

    # 后台进度监控
    (
        local count=0
        while IFS= read -r line; do
            ((count++))
            show_progress "$count" "$total"
        done <"$progress_pipe"
        echo # 换行
    ) &
    local progress_pid=$!

    # 使用xargs并行处理并收集结果
    local results
    results=$(printf '%s\0' "${files[@]}" | xargs -0 -P "$max_jobs" -I {} bash -c '
        result="FAILED"
        if process_file "$1"; then
            result="SUCCESS"
        fi
        echo "PROGRESS" > "'"$progress_pipe"'"
        echo "$result"
    ' _ {})

    # 关闭进度管道
    exec 3>"$progress_pipe"
    exec 3>&-
    wait "$progress_pid" 2>/dev/null
    rm -f "$progress_pipe"
    trap - INT TERM

    # 统计结果
    local success=0
    local failed=0
    local skipped=0
    if [[ -n "$results" ]]; then
        success=$(echo "$results" | grep -c "SUCCESS" 2>/dev/null)
        [[ -z "$success" ]] && success=0
        failed=$(echo "$results" | grep -c "FAILED" 2>/dev/null)
        [[ -z "$failed" ]] && failed=0
        skipped=$((total - success - failed))
    fi

    log_success "完成: $success/$total"
    ((failed > 0)) && log_warning "失败: $failed 个"
    ((skipped > 0)) && log_info "跳过: $skipped 个 (内容未变化)"
}

# 主函数
main() {
    printf "%s\n%s\n%s\n" "==================================================" "  转换为sing-box规则 $(date '+%H:%M:%S')" "=================================================="

    process_all

    printf "%s\n%s\n%s\n" "==================================================" "  转换完成" "=================================================="
}

main "$@"
