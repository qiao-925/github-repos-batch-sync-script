#!/bin/bash
# 配置解析模块

# 全局缓存变量声明（性能优化）
# 仓库名称映射缓存：repo_name -> repo_full (owner/repo)
declare -gA REPO_FULL_NAME_CACHE

# 配置文件解析缓存
declare -gA GROUP_REPOS_CACHE        # group_name -> 仓库列表（多行字符串）
declare -gA GROUP_HIGHLAND_CACHE     # group_name -> 高地编号
declare -ga ALL_GROUP_NAMES_CACHE    # 所有分组名数组
declare -g CONFIG_FILE_CACHE_LOADED=0  # 配置文件是否已加载缓存

# 本地仓库缓存
declare -ga LOCAL_REPOS_CACHE        # 本地仓库完整名称列表
declare -gA LOCAL_REPOS_MAP          # repo_full -> 1 (快速查找)
declare -g LOCAL_REPOS_CACHE_LOADED=0  # 本地仓库缓存是否已加载

# 列出所有分组名称（带高地编号）
list_groups() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    echo "可用分组:"
    echo ""
    
    # 获取所有分组名称
    local all_groups=$(get_all_group_names)
    local index=1
    
    # 遍历每个分组，显示分组名 + 高地编号
    while IFS= read -r group_name; do
        if [ -z "$group_name" ]; then
            continue
        fi
        
        local highland=$(get_group_highland "$group_name")
        if [ -n "$highland" ]; then
            printf "%2d. %s (%s)\n" "$index" "$group_name" "$highland"
        else
            printf "%2d. %s\n" "$index" "$group_name"
        fi
        ((index++))
    done <<< "$all_groups"
}

# 确保配置缓存已加载（辅助函数）
_ensure_config_cache() {
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 0 ]; then
        init_config_cache || return 1
    fi
}

# 获取所有分组名称（使用缓存）
get_all_group_names() {
    _ensure_config_cache || return 1
    printf '%s\n' "${ALL_GROUP_NAMES_CACHE[@]}"
}

# 根据输入查找分组名称（支持部分匹配）- 使用缓存优化
find_group_name() {
    local input=$1
    _ensure_config_cache || return 1
    
    # 在一次遍历中完成精确匹配和部分匹配
    local input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    for group_name in "${ALL_GROUP_NAMES_CACHE[@]}"; do
        # 精确匹配
        if [ "$group_name" = "$input" ]; then
            echo "$group_name"
            return 0
        fi
        
        # 部分匹配（不区分大小写）
        local group_lower=$(echo "$group_name" | tr '[:upper:]' '[:lower:]')
        if [[ "$group_lower" == *"$input_lower"* ]]; then
            echo "$group_name"
            return 0
        fi
    done
    
    return 1
}

# 获取分组的高地编号（使用缓存）
get_group_highland() {
    local group_name=$1
    _ensure_config_cache || return 1
    
    if [ -n "${GROUP_HIGHLAND_CACHE[$group_name]}" ]; then
        echo "${GROUP_HIGHLAND_CACHE[$group_name]}"
        return 0
    fi
    return 1
}

# 获取分组文件夹名称（组名 + 高地编号）
get_group_folder() {
    local group_name=$1
    local highland=$(get_group_highland "$group_name")
    
    # 新的目录结构：repos/分组名 (高地编号)
    if [ -n "$highland" ]; then
        echo "repos/$group_name ($highland)"
    else
        echo "repos/$group_name"
    fi
}

# 获取分组下的所有仓库名称（使用缓存）
get_group_repos() {
    local group_name=$1
    _ensure_config_cache || return 1
    
    if [ -n "${GROUP_REPOS_CACHE[$group_name]}" ]; then
        echo "${GROUP_REPOS_CACHE[$group_name]}"
        return 0
    fi
    return 1
}

