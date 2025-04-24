#!/bin/bash

# https://github.com/blackmatrix7/ios_rule_script
# This script is used to synchronize the rules from the rules directory to the ruleset directory.

set -ex

path=$(cd "$(dirname "$0")" && pwd)

src_dir="$path/ios_rule_script"
rules_dir="$src_dir/rule/Clash"
dest_dir="$path/clash"
readme="$path/RULESET.md"

if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir"
fi

if [ ! -d "$src_dir" ]; then
    git clone --depth 1 https://github.com/blackmatrix7/ios_rule_script.git "$src_dir" || {
        echo "Failed to clone ios_rule_script repository. Please check your internet connection."
        exit 1
    }
else
    git -C "$src_dir" pull || {
        echo "Failed to update ios_rule_script repository. Please check your internet connection."
        exit 1
    }
fi

if [ ! -d "$rules_dir" ]; then
    echo "The rules directory does not exist. Please check the ios_rule_script repository."
    exit 1
fi

# 迭代遍历目录，查找.list文件，并复制到目标目录
walk() {
    local dir="$1"
    local rules=()

    for file in "$dir"/*; do
        if [ -d "$file" ]; then
            walk "$file"
        elif [[ "$file" == *.list ]]; then
            rules+=("$file")
        fi
    done

    for rule in "${rules[@]}"; do
        cp "$rule" "$dest_dir/"
    done
}

walk "$rules_dir"

# 复制README.md文件
cp "$src_dir/rule/Clash/README.md" $readme

# 替换README.md文件中的链接地址
src_prefix="https://github.com/blackmatrix7/ios_rule_script/tree/master/rule/Clash/"
dest_prefix="https://github.com/hydrz/ruleset/tree/main/clash/"
# 正则替换README.md文件中的链接地址，结尾添加 .list
sed -i.bak "s|${src_prefix}\([^)]*\)|${dest_prefix}\1.list|g" $readme && rm $readme.bak

echo "规则同步完成！请检查 $readme"
