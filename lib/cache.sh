#!/bin/bash
# 缓存初始化模块

# 初始化配置文件缓存（一次性解析配置文件）
init_config_cache() {
    if [ "$CONFIG_FILE_CACHE_LOADED" -eq 1 ]; then
        return 0  # 已加载，直接返回
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    print_step "解析配置文件并建立缓存..."
    local current_group=""
    local current_highland=""
    local repos_for_group=""
    
    # 清空缓存
    GROUP_REPOS_CACHE=()
    GROUP_HIGHLAND_CACHE=()
    ALL_GROUP_NAMES_CACHE=()
    
    while IFS= read -r line; do
        # 检查是否是分组标题（使用 bash 模式匹配，比 grep 快）
        if [[ "$line" =~ ^##[[:space:]] ]]; then
            # 保存上一个分组
            if [ -n "$current_group" ]; then
                GROUP_REPOS_CACHE["$current_group"]="$repos_for_group"
                if [ -n "$current_highland" ]; then
                    GROUP_HIGHLAND_CACHE["$current_group"]="$current_highland"
                fi
                ALL_GROUP_NAMES_CACHE+=("$current_group")
            fi
            
            # 解析新分组（合并 sed 操作）
            current_group=$(echo "$line" | sed -E 's/^## //;s/ <!--.*//')
            current_highland=$(echo "$line" | sed -En 's/.*<!--[[:space:]]*([^[:space:]].*[^[:space:]])[[:space:]]*-->.*/\1/p')
            
            # 处理高地编号格式（使用 bash 模式匹配）
            if [ -n "$current_highland" ] && [[ "$current_highland" =~ ^[0-9]+\.?[0-9]*高地$ ]]; then
                current_highland="${current_highland/高地/号高地}"
            fi
            
            repos_for_group=""
            continue
        fi
        
        # 如果在分组内，提取仓库名
        if [ -n "$current_group" ]; then
            # 提取仓库名（合并 sed 操作，优化字符串处理）
            local repo=$(echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$repo" ]; then
                # 使用数组存储，最后再 join（更高效）
                if [ -z "$repos_for_group" ]; then
                    repos_for_group="$repo"
                else
                    repos_for_group="$repos_for_group"$'\n'"$repo"
                fi
            fi
        fi
    done < "$CONFIG_FILE"
    
    # 保存最后一个分组
    if [ -n "$current_group" ]; then
        GROUP_REPOS_CACHE["$current_group"]="$repos_for_group"
        if [ -n "$current_highland" ]; then
            GROUP_HIGHLAND_CACHE["$current_group"]="$current_highland"
        fi
        ALL_GROUP_NAMES_CACHE+=("$current_group")
    fi
    
    CONFIG_FILE_CACHE_LOADED=1
    print_success "配置文件缓存已建立，共 ${#ALL_GROUP_NAMES_CACHE[@]} 个分组"
}

# 初始化仓库名称缓存（批量获取所有仓库）
init_repo_cache() {
    print_step "批量获取所有远程仓库并建立缓存..."
    
    # 检查 gh 命令是否可用
    if ! command -v gh >/dev/null 2>&1; then
        print_error "GitHub CLI (gh) 未安装。请先安装: https://cli.github.com/"
        return 1
    fi
    
    # 检查是否已登录
    if ! gh auth status &>/dev/null; then
        print_error "未登录 GitHub CLI。请运行: gh auth login"
        return 1
    fi
    
    # 获取所有仓库（使用日志和计时）
    local all_repos
    all_repos=$(log_api_call "批量获取远程仓库列表" gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    local gh_exit_code=$?
    
    if [ $gh_exit_code -ne 0 ]; then
        print_error "无法获取仓库列表 (退出码: $gh_exit_code)"
        print_info "请确保已登录 GitHub CLI (运行: gh auth login)"
        return 1
    fi
    
    # 检查是否返回了空结果
    if [ -z "$all_repos" ]; then
        print_warning "未获取到任何仓库，可能是用户没有仓库或权限不足"
        print_info "将使用逐个查找模式（速度较慢）"
        # 不返回错误，允许继续执行（使用逐个查找）
        REPO_FULL_NAME_CACHE=()
        return 0
    fi
    
    # 清空缓存
    REPO_FULL_NAME_CACHE=()
    
    # 建立映射：repo_name -> repo_full
    local repo_count=0
    while IFS= read -r repo_full; do
        if [ -z "$repo_full" ]; then
            continue
        fi
        local repo_name=$(basename "$repo_full")
        REPO_FULL_NAME_CACHE["$repo_name"]="$repo_full"
        ((repo_count++))
    done <<< "$all_repos"
    
    print_success "已缓存 $repo_count 个远程仓库"
    
    # 如果缓存为空，给出警告
    if [ $repo_count -eq 0 ]; then
        print_warning "缓存为空，查找仓库时将使用逐个 API 调用（速度较慢）"
    fi
}

# 初始化本地仓库缓存（扫描本地所有仓库）
init_local_repo_cache() {
    if [ "$LOCAL_REPOS_CACHE_LOADED" -eq 1 ]; then
        return 0  # 已加载，直接返回
    fi
    
    print_step "扫描本地仓库并建立缓存..."
    
    # 清空缓存
    LOCAL_REPOS_CACHE=()
    LOCAL_REPOS_MAP=()
    
    # 遍历所有分组文件夹
    for group_folder in "${!group_folders[@]}"; do
        if [ ! -d "$group_folder" ]; then
            continue
        fi
        
        shopt -s nullglob
        for dir in "$group_folder"/*; do
            if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                local repo_name=$(basename "$dir")
                # 从缓存中查找完整名称
                if [ -n "${REPO_FULL_NAME_CACHE[$repo_name]}" ]; then
                    local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
                    LOCAL_REPOS_CACHE+=("$repo_full")
                    LOCAL_REPOS_MAP["$repo_full"]=1
                fi
            fi
        done
        shopt -u nullglob
    done
    
    LOCAL_REPOS_CACHE_LOADED=1
    print_success "本地仓库缓存已建立，共 ${#LOCAL_REPOS_CACHE[@]} 个仓库"
}

