#!/bin/bash
# 工具函数模块

# 将多行字符串转换为数组
string_to_array() {
    local -n arr_ref=$1
    local input=$2
    arr_ref=()
    while IFS= read -r line; do
        [ -n "$line" ] && arr_ref+=("$line")
    done <<< "$input"
}

# 将数组输出为多行字符串
array_to_string() {
    local arr=("$@")
    printf '%s\n' "${arr[@]}"
}

