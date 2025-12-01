#!/bin/bash
# 统计和报告模块

# 初始化全局统计变量
init_sync_stats() {
    declare -g SYNC_STATS_SUCCESS=0
    declare -g SYNC_STATS_UPDATE=0
    declare -g SYNC_STATS_FAIL=0
    declare -g CLEANUP_STATS_DELETE=0
    declare -gA group_folders
    declare -gA group_names
    
    # 初始化缓存标记
    CONFIG_FILE_CACHE_LOADED=0
    LOCAL_REPOS_CACHE_LOADED=0
}

# 更新统计信息（简化版）
update_sync_statistics() {
    local repo_path=$1
    local result=$2
    
    case $result in
        0)
            # 成功：简单判断，如果目录已存在则是更新，否则是新增
            if [ -d "$repo_path/.git" ]; then
                ((SYNC_STATS_UPDATE++))
            else
                ((SYNC_STATS_SUCCESS++))
            fi
            ;;
        2)
            # 跳过，不统计
            ;;
        *)
            # 失败
            ((SYNC_STATS_FAIL++))
            ;;
    esac
}

# 记录错误日志（统一格式）
record_error() {
    local error_log_ref=$1
    local repo=$2
    local error_type=$3
    local error_msg=$4
    
    if [ -n "$error_log_ref" ]; then
        # 使用 nameref 安全地添加元素
        local -n error_log_array=$error_log_ref
        error_log_array+=("$repo|$error_type|$error_msg")
    fi
}

# 输出最终统计信息
print_final_summary() {
    echo ""
    echo "=================================================="
    echo "✅ 同步完成！"
    echo "新增: ${SYNC_STATS_SUCCESS:-0}"
    echo "更新: ${SYNC_STATS_UPDATE:-0}"
    echo "删除: ${CLEANUP_STATS_DELETE:-0}"
    echo "失败: ${SYNC_STATS_FAIL:-0}"
    echo "=================================================="
}

# 显示失败仓库详情（简化版）
print_failed_repos_details() {
    local -n failed_logs_ref=$1
    
    if [ ${#failed_logs_ref[@]} -eq 0 ]; then
        return
    fi
    
    echo ""
    echo "=================================================="
    echo "❌ 失败仓库详情："
    echo "=================================================="
    local log_index=1
    
    for failed_log in "${failed_logs_ref[@]}"; do
        IFS='|' read -r repo_identifier error_type error_msg <<< "$failed_log"
        
        # 判断是完整仓库名（owner/repo）还是仓库名
        local repo_full="$repo_identifier"
        if [[ "$repo_identifier" != *"/"* ]]; then
            repo_full="未知/$repo_identifier"
        fi
        
        echo ""
        echo "[$log_index] $repo_full"
        echo "    类型: $error_type"
        echo "    原因: $error_msg"
        ((log_index++))
    done
    
    echo ""
    echo "=================================================="
}

# 比较远程和本地差异，生成详细报告（使用缓存优化）
compare_remote_local_diff() {
    local -n failed_logs_ref=$1
    
    echo ""
    echo "=================================================="
    echo "📊 远程与本地差异分析"
    echo "=================================================="
    echo ""
    
    # 确保缓存已加载
    if [ "$LOCAL_REPOS_CACHE_LOADED" -eq 0 ]; then
        init_local_repo_cache
    fi
    
    # 获取所有应该同步的仓库列表（使用缓存）
    local expected_repos=()
    declare -A expected_repos_map=()
    
    # 从缓存中获取所有分组名称
    local groups_array=("${ALL_GROUP_NAMES_CACHE[@]}")
    
    for group_name in "${groups_array[@]}"; do
        local group_repos=$(get_group_repos "$group_name")
        if [ -z "$group_repos" ]; then
            continue
        fi
        
        local repos_array
        string_to_array repos_array "$group_repos"
        
        for repo_name in "${repos_array[@]}"; do
            if [ -z "$repo_name" ]; then
                continue
            fi
            
            # 从缓存中查找（无需 API 调用）
            local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
            if [ -n "$repo_full" ]; then
                expected_repos+=("$repo_full")
                expected_repos_map["$repo_full"]=1
            fi
        done
    done
    
    # 使用缓存的本地仓库列表（无需重新扫描）
    local local_repos=("${LOCAL_REPOS_CACHE[@]}")
    # 直接使用全局缓存映射（无需重新创建）
    # LOCAL_REPOS_MAP 已在 init_local_repo_cache 中建立
    
    # 分析差异
    local missing_repos=()      # 应该存在但本地缺失的
    local extra_repos=()         # 本地存在但不在同步列表中的
    local synced_repos=()        # 成功同步的
    
    # 找出缺失的仓库（应该存在但本地没有）
    # 使用全局缓存映射 LOCAL_REPOS_MAP
    for repo_full in "${expected_repos[@]}"; do
        if [ -z "${LOCAL_REPOS_MAP[$repo_full]}" ]; then
            missing_repos+=("$repo_full")
        else
            synced_repos+=("$repo_full")
        fi
    done
    
    # 找出多余的仓库（本地存在但不在同步列表中）
    for repo_full in "${local_repos[@]}"; do
        if [ -z "${expected_repos_map[$repo_full]}" ]; then
            extra_repos+=("$repo_full")
        fi
    done
    
    # 统计失败但已记录的仓库
    local failed_repos_count=0
    if [ ${#failed_logs_ref[@]} -gt 0 ]; then
        failed_repos_count=${#failed_logs_ref[@]}
    fi
    
    # 输出统计信息
    local total_expected=${#expected_repos[@]}
    local total_local=${#local_repos[@]}
    local total_synced=${#synced_repos[@]}
    local total_missing=${#missing_repos[@]}
    local total_extra=${#extra_repos[@]}
    
    print_info "📈 总体统计："
    echo "  - 应该同步的仓库总数: $total_expected"
    echo "  - 本地已存在的仓库总数: $total_local"
    echo "  - 成功同步的仓库: $total_synced"
    echo "  - 缺失的仓库（应该存在但本地没有）: $total_missing"
    echo "  - 多余的仓库（本地有但不在同步列表）: $total_extra"
    echo "  - 同步失败的仓库: $failed_repos_count"
    echo ""
    
    # 计算同步率
    if [ "$total_expected" -gt 0 ]; then
        local sync_rate=$((total_synced * 100 / total_expected))
        echo "  - 同步成功率: ${sync_rate}%"
        echo ""
    fi
    
    # 显示缺失的仓库详情
    if [ "$total_missing" -gt 0 ]; then
        print_warning "⚠️  缺失的仓库（$total_missing 个）："
        local index=1
        for repo_full in "${missing_repos[@]}"; do
            local repo_info=$(get_repo_info "$repo_full")
            local repo_desc=""
            local repo_lang=""
            local repo_stars=""
            if [ -n "$repo_info" ]; then
                repo_desc=$(extract_json_field "$repo_info" "description")
                repo_lang=$(extract_json_field "$repo_info" "language")
                repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
            fi
            echo "  [$index] $repo_full"
            if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ -n "$repo_lang" ]; then
                echo "      语言: $repo_lang"
            fi
            if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
                echo "      ⭐ Stars: $repo_stars"
            fi
            if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ] && [ -n "$repo_desc" ]; then
                # 限制描述长度
                if [ ${#repo_desc} -gt 60 ]; then
                    repo_desc="${repo_desc:0:57}..."
                fi
                echo "      描述: $repo_desc"
            fi
            ((index++))
        done
        echo ""
    fi
    
    # 显示多余的仓库详情（如果数量不多）
    if [ "$total_extra" -gt 0 ] && [ "$total_extra" -le 20 ]; then
        print_info "ℹ️  本地多余的仓库（$total_extra 个，不在同步列表中）："
        local index=1
        for repo_full in "${extra_repos[@]}"; do
            local repo_info=$(get_repo_info "$repo_full")
            local repo_desc=""
            local repo_lang=""
            local repo_stars=""
            if [ -n "$repo_info" ]; then
                repo_desc=$(extract_json_field "$repo_info" "description")
                repo_lang=$(extract_json_field "$repo_info" "language")
                repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
            fi
            echo "  [$index] $repo_full"
            if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ -n "$repo_lang" ]; then
                echo "      语言: $repo_lang"
            fi
            if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
                echo "      ⭐ Stars: $repo_stars"
            fi
            ((index++))
        done
        echo ""
    elif [ "$total_extra" -gt 20 ]; then
        print_info "ℹ️  本地多余的仓库: $total_extra 个（数量较多，已省略详情）"
        echo ""
    fi
    
    # 同步状态总结
    echo "=================================================="
    if [ "$total_missing" -eq 0 ] && [ "$failed_repos_count" -eq 0 ]; then
        print_success "✅ 所有仓库已成功同步！"
    elif [ "$total_missing" -gt 0 ] || [ "$failed_repos_count" -gt 0 ]; then
        print_warning "⚠️  同步未完全完成，存在缺失或失败的仓库"
    fi
    echo "=================================================="
}

