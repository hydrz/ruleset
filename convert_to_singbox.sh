#!/bin/bash

readonly SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)
readonly RULESET_DIR="$SCRIPT_PATH/clash"
readonly OUTPUT_DIR="$SCRIPT_PATH/singbox"

# Colors and logging
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Safe integer validation and conversion
validate_integer() {
    local value="$1"
    local default="${2:-0}"

    # Remove any whitespace and newlines
    value=$(echo "$value" | tr -d '[:space:]')

    # Check if it's a valid integer
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Process rule files
process_file() {
    local file="$1"
    local name=$(basename "$file" .list)
    local json_file="$OUTPUT_DIR/${name}.json"

    [[ ! -f "$file" ]] && return 1

    # Skip if target file exists and source file is not updated
    if [[ -f "$json_file" && "$file" -ot "$json_file" ]]; then
        return 0
    fi

    # Check if there are valid rules
    if ! grep -q '^[A-Z]' "$file" 2>/dev/null; then
        local empty_content='{"version":2,"rules":[]}'
        echo "$empty_content" >"$json_file"
        return 0
    fi

    # AWK script to generate JSON content
    local json_content
    json_content=$(timeout 30 awk -F',' '
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

            # Build field arrays
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

            # Output fields
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
        }' "$file" 2>/dev/null)

    # Validate JSON format
    if [[ -z "$json_content" ]]; then
        return 1
    fi

    # Write new content
    echo "$json_content" >"$json_file"
    return 0
}

# Progress display function with safe numeric handling
show_progress() {
    local current="$1"
    local total="$2"

    # Validate and clean input parameters
    current=$(validate_integer "$current" 0)
    total=$(validate_integer "$total" 1)

    if ((total == 0)); then
        return 1
    fi

    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r${BLUE}[进度]${NC} ["
    printf "%*s" "$filled" "" | tr ' ' '='
    printf "%*s" "$empty" ""
    printf "] %d/%d (%d%%)" "$current" "$total" "$percentage"
}

# Safe numeric read function
read_counter() {
    local file="$1"
    local default_value="${2:-0}"

    if [[ -f "$file" ]]; then
        local value
        value=$(cat "$file" 2>/dev/null)
        validate_integer "$value" "$default_value"
    else
        echo "$default_value"
    fi
}

# Improved parallel processing with better error handling
process_all() {
    local max_jobs=8
    if command -v nproc >/dev/null 2>&1; then
        max_jobs=$(($(nproc) * 2))
    elif command -v sysctl >/dev/null 2>&1; then
        max_jobs=$(($(sysctl -n hw.ncpu 2>/dev/null || echo 4) * 2))
    fi

    # Limit max parallel jobs
    ((max_jobs > 16)) && max_jobs=16
    ((max_jobs < 4)) && max_jobs=4

    # Collect file list
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

    # Create temporary directory for progress tracking
    local temp_dir
    temp_dir=$(mktemp -d) || {
        log_error "无法创建临时目录"
        return 1
    }

    local progress_file="$temp_dir/progress"
    local result_file="$temp_dir/results"

    # Initialize counters with proper validation
    echo "0" > "$progress_file" || {
        log_error "无法初始化进度文件"
        rm -rf "$temp_dir"
        return 1
    }
    touch "$result_file"

    # Cleanup function
    cleanup() {
        # Kill all child processes
        local job_pids
        job_pids=$(jobs -p 2>/dev/null)
        if [[ -n "$job_pids" ]]; then
            echo "$job_pids" | xargs -r kill 2>/dev/null
        fi
        wait 2>/dev/null
        rm -rf "$temp_dir"
        echo # Newline after progress bar
        exit 1
    }
    trap cleanup INT TERM

    # Process files with progress tracking
    local pids=()

    for file in "${files[@]}"; do
        # Wait if we've reached the max number of jobs
        while ((${#pids[@]} >= max_jobs)); do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[i]}" 2>/dev/null; then
                    wait "${pids[i]}" 2>/dev/null
                    unset "pids[i]"
                fi
            done
            pids=("${pids[@]}") # Reindex array
            sleep 0.05
        done

        # Start new job
        (
            local result="FAILED"
            if process_file "$file"; then
                result="SUCCESS"
            fi

            # Atomic progress update with error handling
            (
                if flock -x -w 5 200; then
                    local current
                    current=$(read_counter "$progress_file" 0)
                    echo $((current + 1)) > "$progress_file"
                    echo "$result" >> "$result_file"
                fi
            ) 200>"$progress_file.lock" 2>/dev/null
        ) &

        pids+=($!)
    done

    # Monitor progress with improved error handling
    local last_progress=0
    while ((${#pids[@]} > 0)); do
        # Check for completed jobs
        for i in "${!pids[@]}"; do
            if ! kill -0 "${pids[i]}" 2>/dev/null; then
                wait "${pids[i]}" 2>/dev/null
                unset "pids[i]"
            fi
        done
        pids=("${pids[@]}") # Reindex array

        # Update progress display with safe numeric handling
        local current
        current=$(read_counter "$progress_file" 0)
        if ((current != last_progress && current <= total)); then
            show_progress "$current" "$total"
            last_progress=$current
        fi

        sleep 0.1
    done

    # Final progress update
    show_progress "$total" "$total"
    echo # Newline after progress bar

    # Calculate statistics with safe counting and validation
    local success_raw failed_raw
    if [[ -f "$result_file" ]]; then
        success_raw=$(grep -c "SUCCESS" "$result_file" 2>/dev/null || echo "0")
        failed_raw=$(grep -c "FAILED" "$result_file" 2>/dev/null || echo "0")
    else
        success_raw="0"
        failed_raw="0"
    fi

    # Validate and sanitize all numeric values
    local success failed skipped
    success=$(validate_integer "$success_raw" 0)
    failed=$(validate_integer "$failed_raw" 0)

    # Safe calculation of skipped files
    local processed=$((success + failed))
    if ((processed <= total)); then
        skipped=$((total - processed))
    else
        skipped=0
    fi

    # Cleanup
    rm -rf "$temp_dir"
    trap - INT TERM

    log_success "完成: $success/$total"
    ((failed > 0)) && log_warning "失败: $failed 个"
    ((skipped > 0)) && log_info "跳过: $skipped 个 (内容未变化)"
}

# Main function
main() {
    printf "%s\n%s\n%s\n" "==================================================" "  转换为sing-box规则 $(date '+%H:%M:%S')" "=================================================="

    process_all

    printf "%s\n%s\n%s\n" "==================================================" "  转换完成" "=================================================="
}

main "$@"