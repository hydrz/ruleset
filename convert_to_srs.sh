#!/bin/bash

set -ex

path=$(cd "$(dirname "$0")" && pwd)


# 设置工作目录和输出目录
RULESET_DIR="$path/clash"
OUTPUT_DIR="$path/singbox"

# 创建输出目录（如果不存在）
mkdir -p "$OUTPUT_DIR"

SINGBOX="$path/sing-box"

# 检查sing-box是否存在
if command -v $SINGBOX &> /dev/null; then
    echo "sing-box found at $SINGBOX"
else
    echo "sing-box not found, installing..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # 检测架构并设置正确的下载参数
    if [[ "$ARCH" == "x86_64" ]]; then
        if [[ "$OS" == "darwin" ]]; then
            ARCH="amd64-legacy"
        else
            ARCH="amd64"
        fi
    elif [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    # 获取最新版本号（macOS和Linux兼容方式）
    SINGBOX_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | 
                      sed -n 's/.*"tag_name": "\(.*\)".*/\1/p' | head -n 1)
    
    if [[ -z "$SINGBOX_VERSION" ]]; then
        echo "Failed to get latest sing-box version"
        exit 1
    fi
    
    echo "Installing sing-box version: $SINGBOX_VERSION"
    
    # 构建下载URL并下载
    SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION#v}-${OS}-${ARCH}.tar.gz"
    echo "Downloading from: $SINGBOX_URL"
    
    if ! curl -L --retry 3 -o sing-box.tar.gz "$SINGBOX_URL"; then
        echo "Failed to download sing-box"
        exit 1
    fi
    
    # 创建临时目录进行解压，避免文件冲突
    TMP_DIR=$(mktemp -d)
    tar -xzf sing-box.tar.gz -C "$TMP_DIR"
    
    # 移动二进制文件到当前目录
    find "$TMP_DIR" -name "sing-box" -type f -exec cp {} "$SINGBOX" \;
    
    # 清理
    rm -f sing-box.tar.gz
    rm -rf "$TMP_DIR"
    
    if [[ ! -f "$SINGBOX" ]]; then
        echo "Failed to extract sing-box binary"
        exit 1
    fi
    
    chmod +x "$SINGBOX"
    echo "sing-box successfully installed at $SINGBOX"
    echo "sing-box version: $($SINGBOX version)"
fi

# 处理每一个list文件
process_list_file() {
    list_file="$1"
    filename=$(basename "$list_file" .list)
    json_file="$OUTPUT_DIR/${filename}.json"
    srs_file="$OUTPUT_DIR/${filename}.srs"
    
    echo "处理文件: $list_file"
    
    # 初始化JSON结构
    echo '{
  "version": 2,
  "rules": [
' > "$json_file.tmp"
    
    # 解析list文件，转换为JSON格式
    domain_list=()
    domain_suffix_list=()
    domain_keyword_list=()
    ip_cidr_list=()
    ip_cidr6_list=()
    
    while IFS= read -r line; do
        # 跳过注释行和空行
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        # 提取规则类型和值
        if [[ "$line" =~ ^(DOMAIN-SUFFIX|HOST-SUFFIX|host-suffix|DOMAIN|HOST|host|DOMAIN-KEYWORD|HOST-KEYWORD|host-keyword|IP-CIDR|ip-cidr|IP-CIDR6|IP6-CIDR)([,[:space:]]+)(.+)$ ]]; then
            rule_type="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[3]}"
            
            # 去除可能的注释和额外参数
            value=$(echo "$value" | cut -d',' -f1 | cut -d' ' -f1)
            
            # 根据规则类型分类
            case "$rule_type" in
                DOMAIN-SUFFIX|HOST-SUFFIX|host-suffix)
                    domain_suffix_list+=("$value")
                    ;;
                DOMAIN|HOST|host)
                    domain_list+=("$value")
                    ;;
                DOMAIN-KEYWORD|HOST-KEYWORD|host-keyword)
                    domain_keyword_list+=("$value")
                    ;;
                IP-CIDR|ip-cidr)
                    ip_cidr_list+=("$value")
                    ;;
                IP-CIDR6|IP6-CIDR)
                    ip_cidr6_list+=("$value")
                    ;;
            esac
        fi
    done < "$list_file"
    
    # 生成JSON格式的规则
    rules_added=0
    
    # 添加domain规则
    if [ ${#domain_list[@]} -gt 0 ]; then
        if [ $rules_added -gt 0 ]; then
            echo '    },' >> "$json_file.tmp"
        fi
        echo '    {
      "domain": [' >> "$json_file.tmp"
        for ((i=0; i<${#domain_list[@]}; i++)); do
            if [ $i -lt $((${#domain_list[@]}-1)) ]; then
                echo "        \"${domain_list[$i]}\"," >> "$json_file.tmp"
            else
                echo "        \"${domain_list[$i]}\"" >> "$json_file.tmp"
            fi
        done
        echo '      ]' >> "$json_file.tmp"
        rules_added=1
    fi
    
    # 添加domain_suffix规则
    if [ ${#domain_suffix_list[@]} -gt 0 ]; then
        if [ $rules_added -gt 0 ]; then
            echo '    },' >> "$json_file.tmp"
        fi
        echo '    {
      "domain_suffix": [' >> "$json_file.tmp"
        for ((i=0; i<${#domain_suffix_list[@]}; i++)); do
            if [ $i -lt $((${#domain_suffix_list[@]}-1)) ]; then
                echo "        \"${domain_suffix_list[$i]}\"," >> "$json_file.tmp"
            else
                echo "        \"${domain_suffix_list[$i]}\"" >> "$json_file.tmp"
            fi
        done
        echo '      ]' >> "$json_file.tmp"
        rules_added=1
    fi
    
    # 添加domain_keyword规则
    if [ ${#domain_keyword_list[@]} -gt 0 ]; then
        if [ $rules_added -gt 0 ]; then
            echo '    },' >> "$json_file.tmp"
        fi
        echo '    {
      "domain_keyword": [' >> "$json_file.tmp"
        for ((i=0; i<${#domain_keyword_list[@]}; i++)); do
            if [ $i -lt $((${#domain_keyword_list[@]}-1)) ]; then
                echo "        \"${domain_keyword_list[$i]}\"," >> "$json_file.tmp"
            else
                echo "        \"${domain_keyword_list[$i]}\"" >> "$json_file.tmp"
            fi
        done
        echo '      ]' >> "$json_file.tmp"
        rules_added=1
    fi
    
    # 添加ip_cidr规则
    if [ ${#ip_cidr_list[@]} -gt 0 ] || [ ${#ip_cidr6_list[@]} -gt 0 ]; then
        if [ $rules_added -gt 0 ]; then
            echo '    },' >> "$json_file.tmp"
        fi
        echo '    {
      "ip_cidr": [' >> "$json_file.tmp"
        
        # 合并IPv4和IPv6列表
        combined_list=("${ip_cidr_list[@]}" "${ip_cidr6_list[@]}")
        
        for ((i=0; i<${#combined_list[@]}; i++)); do
            if [ $i -lt $((${#combined_list[@]}-1)) ]; then
                echo "        \"${combined_list[$i]}\"," >> "$json_file.tmp"
            else
                echo "        \"${combined_list[$i]}\"" >> "$json_file.tmp"
            fi
        done
        echo '      ]' >> "$json_file.tmp"
        rules_added=1
    fi
    
    # 完成JSON文件
    if [ $rules_added -gt 0 ]; then
        echo '    }' >> "$json_file.tmp"
    fi
    echo '  ]
}' >> "$json_file.tmp"

    # 移动临时文件到最终文件
    mv "$json_file.tmp" "$json_file"
    
    # 使用sing-box编译为srs文件
    echo "编译 $filename 为 .srs 文件"
    $SINGBOX rule-set compile --output "$srs_file" "$json_file"
    echo "处理完成: $filename"
}

# 主处理流程
echo "开始处理ruleset文件..."

# 查找所有.list文件并处理
find "$RULESET_DIR" -type f -name "*.list" | while read -r list_file; do
    process_list_file "$list_file"
done

echo "所有文件处理完成。"
