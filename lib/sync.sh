#!/bin/bash
# 同步逻辑模块：并行处理、扫描差异

# 重试单个仓库
# 参数: repo_full, repo_name, group_folder, total_count, current_index, error_log_ref
retry_repo_sync() {
    local repo_full=$1
    local repo_name=$2
    local group_folder=$3
    local total_count=$4
    local current_index=$5
    local error_log_ref=$6
    
    echo "" >&2
    print_info "[重试 $current_index/$total_count] 重试仓库: $repo_name"
    print_info "  完整仓库名: $repo_full"
    print_info "  分组文件夹: $group_folder"
    
    local retry_result
    sync_single_repo "$repo_full" "$repo_name" "$group_folder" "$current_index" "$total_count" "$error_log_ref"
    retry_result=$?
    
    if [ "$retry_result" -eq 0 ]; then
        # 注意：sync_single_repo 内部已经调用了 update_sync_statistics
        # 第一次失败时已经统计为失败，所以需要减少失败计数
        ((SYNC_STATS_FAIL--))
        print_success "  重试成功: $repo_name"
        return 0
    else
        print_error "  重试仍然失败: $repo_name"
        return 1
    fi
}

# 获取所有分组用于同步
get_all_groups_for_sync() {
    local all_groups=$(get_all_group_names)
    if [ -z "$all_groups" ]; then
        print_error "无法读取分组列表"
        return 1
    fi
    
    local groups_array
    string_to_array groups_array "$all_groups"
    
    if [ ${#groups_array[@]} -eq 0 ]; then
        print_error "配置文件中没有找到任何分组"
        return 1
    fi
    
    array_to_string "${groups_array[@]}"
    return 0
}

# 初始化同步环境
initialize_sync() {
    # 检查配置文件
    print_step "检查配置文件..."
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "分类文档不存在: $CONFIG_FILE"
        print_info "请参考 REPO-GROUPS.md.example 创建分类文档"
        print_info "或使用 PROMPT.md 中的 prompt 让 AI 生成"
        exit 1
    fi
    print_success "配置文件存在: $CONFIG_FILE"
    
    # 创建 repos 目录（如果不存在）
    if [ ! -d "repos" ]; then
        mkdir -p "repos"
        print_info "已创建 repos 目录"
    fi
    
    # 初始化 GitHub 连接
    init_github_connection
    
    # 显示同步信息
    echo "=================================================="
    echo "GitHub 仓库批量同步脚本"
    echo "=================================================="
    echo ""
    
    # 初始化统计变量
    init_sync_stats
}

# 构建同步仓库映射（用于清理检查）- 使用缓存优化
build_sync_repos_map() {
    local -n sync_repos_map_ref=$1
    
    # 从配置文件中的期望同步仓库列表构建映射（无需遍历文件系统）
    # 遍历所有分组和仓库，构建期望的路径映射
    local groups_array=("${ALL_GROUP_NAMES_CACHE[@]}")
    
    for group_name in "${groups_array[@]}"; do
        local group_folder=$(get_group_folder "$group_name")
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
            
            local repo_path="$group_folder/$repo_name"
            sync_repos_map_ref["$repo_path"]=1
        done
    done
}

# 同步单个分组的所有仓库
sync_group_repos_main() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    local error_log_ref=$4
    
    # 注册分组文件夹映射（用于清理）
    group_folders["$group_folder"]=1
    group_names["$group_folder"]="$group_name"
    
    # 将仓库列表转换为数组，便于计算总数和遍历
    local repos_array
    string_to_array repos_array "$group_repos"
    
    local total_count=${#repos_array[@]}
    
    # 记录失败的仓库（用于最后统一重试）
    local failed_repos=()
    
    print_step "开始同步分组 '$group_name'（共 $total_count 个仓库）..."
    print_info "分组文件夹: $group_folder"
    echo "" >&2
    
    # 创建分组文件夹（如果不存在）
    if [ ! -d "$group_folder" ]; then
        mkdir -p "$group_folder"
    fi
    
    # 第一步：分类仓库 - 区分需要克隆的（缺失）和需要更新的（已存在）
    local repos_to_clone=()  # 需要克隆的仓库（缺失的）
    local repos_to_update=() # 需要更新的仓库（已存在的）
    
    print_info "检查仓库状态，分类处理..."
    for repo_name in "${repos_array[@]}"; do
        if [ -z "$repo_name" ]; then
            continue
        fi
        
        # 查找仓库完整名称
        local repo_full=$(find_repo_full_name "$repo_name")
        
        if [ -z "$repo_full" ]; then
            echo "[错误] $repo_name - 远程仓库不存在" >&2
            record_error "$error_log_ref" "$repo_name" "错误" "远程仓库不存在"
            update_sync_statistics "" 1
            continue
        fi
        
        local repo_path="$group_folder/$repo_name"
        
        # 检查仓库是否存在
        if [ -d "$repo_path/.git" ]; then
            # 已存在 git 仓库，加入更新列表
            repos_to_update+=("$repo_full|$repo_name")
        elif [ -d "$repo_path" ]; then
            # 目录存在但不是 git 仓库，跳过
            echo "[跳过] $repo_name - 目录已存在但不是 git 仓库" >&2
            record_error "$error_log_ref" "$repo_name" "跳过" "目录已存在但不是 git 仓库"
            update_sync_statistics "$repo_path" 2
        else
            # 新仓库，加入克隆列表
            repos_to_clone+=("$repo_full|$repo_name")
        fi
    done
    
    local clone_count=${#repos_to_clone[@]}
    local update_count=${#repos_to_update[@]}
    
    echo "" >&2
    print_info "仓库分类完成："
    print_info "  - 需要克隆（缺失）: $clone_count 个"
    print_info "  - 需要更新（已存在）: $update_count 个"
    echo "" >&2
    
    # 第二步：优先处理需要克隆的仓库（缺失的）
    if [ "$clone_count" -gt 0 ]; then
        print_step "优先同步缺失的仓库（$clone_count 个）..."
        echo "" >&2
        
        local current_index=0
        for repo_info in "${repos_to_clone[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$repo_info"
            ((current_index++))
            
            echo "" >&2
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "处理仓库 [$current_index/$clone_count]: $repo_name [克隆]"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # 执行克隆
            local repo_path="$group_folder/$repo_name"
            local result
            clone_repo "$repo_full" "$repo_path" "$current_index" "$clone_count" "$error_log_ref"
            result=$?
            
            # 更新统计信息
            update_sync_statistics "$repo_path" "$result"
            
            # 记录失败的仓库（用于重试）
            if [ "$result" -ne 0 ]; then
                failed_repos+=("$repo_full|$repo_name")
            fi
        done
        
        echo "" >&2
        if [ "$clone_count" -gt 0 ]; then
            print_success "缺失仓库同步完成（$clone_count 个）"
            echo "" >&2
        fi
    fi
    
    # 第三步：处理需要更新的仓库（已存在的）
    if [ "$update_count" -gt 0 ]; then
        print_step "更新已存在的仓库（$update_count 个）..."
        echo "" >&2
        
        local current_index=0
        for repo_info in "${repos_to_update[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$repo_info"
            ((current_index++))
            
            echo "" >&2
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "处理仓库 [$current_index/$update_count]: $repo_name [更新]"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # 执行更新
            local repo_path="$group_folder/$repo_name"
            local result
            update_repo "$repo_full" "$repo_path" "$group_folder" "$current_index" "$update_count" "$error_log_ref"
            result=$?
            
            # 更新统计信息
            update_sync_statistics "$repo_path" "$result"
            
            # 记录失败的仓库（用于重试）
            if [ "$result" -ne 0 ] && [ "$result" -ne 2 ]; then
                failed_repos+=("$repo_full|$repo_name")
            fi
        done
        
        echo "" >&2
        if [ "$update_count" -gt 0 ]; then
            print_success "已存在仓库更新完成（$update_count 个）"
            echo "" >&2
        fi
    fi
    
    # 返回失败的仓库列表（用于最后统一重试）
    array_to_string "${failed_repos[@]}"
}

# 同步分组中的仓库（主入口）
sync_group_repos() {
    local group_name=$1
    local group_folder=$2
    local group_repos=$3
    local global_failed_array=${4:-""}
    local error_log_ref=${5:-""}
    
    # 同步分组的所有仓库
    local failed_repos_output=$(sync_group_repos_main "$group_name" "$group_folder" "$group_repos" "$error_log_ref")
    
    # 将输出转换为数组
    local failed_repos
    string_to_array failed_repos "$failed_repos_output"
    
    # 将失败的仓库添加到全局数组（用于最后统一重试）
    if [ ${#failed_repos[@]} -gt 0 ] && [ -n "$global_failed_array" ]; then
        local -n global_array_ref=$global_failed_array
        for failed_repo in "${failed_repos[@]}"; do
            IFS='|' read -r repo_full repo_name <<< "$failed_repo"
            global_array_ref+=("$repo_full|$repo_name|$group_folder")
        done
    fi
    
    if [ ${#failed_repos[@]} -gt 0 ]; then
        print_warning "分组 '$group_name' 同步完成，有 ${#failed_repos[@]} 个仓库失败，将在最后统一重试"
    else
        print_success "分组 '$group_name' 同步完成，所有仓库同步成功！"
    fi
}

# 全局扫描差异：找出所有缺失和需要更新的仓库
scan_global_diff() {
    local groups=("$@")
    
    # 存储全局的缺失和更新仓库列表（按分组组织）
    declare -gA global_repos_to_clone  # key: group_folder, value: "repo_full|repo_name repo_full|repo_name ..."
    declare -gA global_repos_to_update   # key: group_folder, value: "repo_full|repo_name repo_full|repo_name ..."
    
    print_step "全局扫描差异，分析所有仓库状态..."
    echo ""
    
    local total_expected=0
    local total_missing=0
    local total_to_update=0
    local total_skipped=0
    local total_not_found=0
    
    # 计算总仓库数（用于显示进度）
    local total_repos=0
    for input_group in "${groups[@]}"; do
        local group_name=$(find_group_name "$input_group")
        if [ -z "$group_name" ]; then
            continue
        fi
        local group_repos=$(get_group_repos "$group_name")
        if [ -z "$group_repos" ]; then
            continue
        fi
        local repos_array
        string_to_array repos_array "$group_repos"
        total_repos=$((total_repos + ${#repos_array[@]}))
    done
    
    print_info "📋 共需要检查 $total_repos 个仓库，开始扫描..."
    echo ""
    
    local current_repo_index=0
    local group_index=0
    
    # 遍历所有分组，收集缺失和更新的仓库
    for input_group in "${groups[@]}"; do
        local group_name=$(find_group_name "$input_group")
        
        if [ -z "$group_name" ]; then
            continue
        fi
        
        ((group_index++))
        local group_folder=$(get_group_folder "$group_name")
        local group_repos=$(get_group_repos "$group_name")
        
        if [ -z "$group_repos" ]; then
            continue
        fi
        
        # 创建分组文件夹（如果不存在）
        if [ ! -d "$group_folder" ]; then
            mkdir -p "$group_folder"
        fi
        
        # 注册分组文件夹映射
        group_folders["$group_folder"]=1
        group_names["$group_folder"]="$group_name"
        
        local repos_array
        string_to_array repos_array "$group_repos"
        
        local group_missing=()
        local group_to_update=()
        
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "检查分组 [$group_index/${#groups[@]}]: $group_name (${#repos_array[@]} 个仓库)"
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 检查每个仓库的状态
        local repo_in_group_index=0
        for repo_name in "${repos_array[@]}"; do
            if [ -z "$repo_name" ]; then
                continue
            fi
            
            ((current_repo_index++))
            ((repo_in_group_index++))
            ((total_expected++))
            
            # 显示检查进度
            echo -n "  [$current_repo_index/$total_repos] 检查: $repo_name ... " >&2
            
            # 查找仓库完整名称
            local repo_full=$(find_repo_full_name "$repo_name")
            
            if [ -z "$repo_full" ]; then
                echo "❌ 远程不存在" >&2
                ((total_not_found++))
                continue
            fi
            
            local repo_path="$group_folder/$repo_name"
            local old_repo_path="$repo_name"  # 检查根目录下的旧位置
            
            # 检查仓库是否存在（优先检查新位置，再检查旧位置）
            if [ -d "$repo_path/.git" ]; then
                # 已存在 git 仓库（新位置），加入更新列表
                group_to_update+=("$repo_full|$repo_name")
                ((total_to_update++))
                echo "✅ 已存在 (需更新)" >&2
            elif [ -d "$old_repo_path/.git" ]; then
                # 仓库在旧位置（根目录），需要移动到新位置
                print_info "  检测到仓库在旧位置: $old_repo_path，将移动到新位置: $repo_path"
                # 创建新位置的分组文件夹
                local parent_dir=$(dirname "$repo_path")
                if [ ! -d "$parent_dir" ]; then
                    mkdir -p "$parent_dir"
                fi
                # 移动仓库到新位置
                if mv "$old_repo_path" "$repo_path" 2>/dev/null; then
                    group_to_update+=("$repo_full|$repo_name")
                    ((total_to_update++))
                    echo "✅ 已移动并加入更新列表" >&2
                else
                    # 移动失败，仍然加入更新列表（尝试在新位置更新）
                    echo "⚠️  移动失败，但仍将尝试更新" >&2
                    group_to_update+=("$repo_full|$repo_name")
                    ((total_to_update++))
                fi
            elif [ -d "$repo_path" ]; then
                # 目录存在但不是 git 仓库，跳过
                echo "⚠️  目录存在但非 git 仓库 (跳过)" >&2
                ((total_skipped++))
                continue
            else
                # 新仓库，加入缺失列表
                group_missing+=("$repo_full|$repo_name")
                ((total_missing++))
                echo "🔴 缺失 (需克隆)" >&2
            fi
        done
        
        # 显示分组统计
        echo "" >&2
        if [ ${#group_missing[@]} -gt 0 ] || [ ${#group_to_update[@]} -gt 0 ]; then
            print_info "  分组 '$group_name' 统计："
            if [ ${#group_missing[@]} -gt 0 ]; then
                print_warning "    - 缺失: ${#group_missing[@]} 个"
            fi
            if [ ${#group_to_update[@]} -gt 0 ]; then
                print_info "    - 已存在: ${#group_to_update[@]} 个"
            fi
        fi
        echo "" >&2
        
        # 存储到全局数组
        if [ ${#group_missing[@]} -gt 0 ]; then
            global_repos_to_clone["$group_folder"]=$(printf '%s\n' "${group_missing[@]}")
        fi
        
        if [ ${#group_to_update[@]} -gt 0 ]; then
            global_repos_to_update["$group_folder"]=$(printf '%s\n' "${group_to_update[@]}")
        fi
    done
    
    echo ""
    echo "=================================================="
    print_info "📊 全局差异分析完成"
    echo "=================================================="
    echo ""
    print_info "总体统计："
    echo "  - 检查的仓库总数: $total_expected"
    echo "  - 🔴 缺失的仓库（需要克隆）: $total_missing 个"
    echo "  - ✅ 需要更新的仓库（已存在）: $total_to_update 个"
    if [ "$total_skipped" -gt 0 ]; then
        echo "  - ⚠️  跳过的仓库（非 git 仓库）: $total_skipped 个"
    fi
    if [ "$total_not_found" -gt 0 ]; then
        echo "  - ❌ 远程不存在的仓库: $total_not_found 个"
    fi
    echo ""
    
    if [ "$total_missing" -gt 0 ]; then
        print_warning "⚠️  发现 $total_missing 个缺失的仓库，将优先同步（优先级最高）"
        print_info "   执行顺序：先同步所有缺失的仓库 → 再更新所有已存在的仓库"
    elif [ "$total_to_update" -gt 0 ]; then
        print_info "✅ 所有仓库已存在，将执行更新操作"
    fi
    echo ""
}

# 执行同步操作（遍历所有分组）- 支持并行处理
execute_sync() {
    local groups=("$@")
    
    # 并行处理的并发数（默认 5，可通过环境变量 PARALLEL_JOBS 配置）
    local PARALLEL_JOBS=${PARALLEL_JOBS:-5}
    print_info "📊 并行处理模式：最多同时处理 $PARALLEL_JOBS 个仓库"
    print_info "💡 提示：网络带宽越高，并行化效果越好。如遇问题可设置 PARALLEL_JOBS=1 使用串行模式"
    echo ""
    
    # 记录所有失败的仓库（用于最后统一重试）
    declare -ga all_failed_repos=()
    # 记录所有失败的仓库和错误信息（用于最终日志）
    declare -ga all_failed_logs=()
    
    # 第一步：优先处理所有分组的缺失仓库（需要克隆的）
    local total_missing_count=0
    for group_folder in "${!global_repos_to_clone[@]}"; do
        local repos_list="${global_repos_to_clone[$group_folder]}"
        if [ -n "$repos_list" ]; then
            local repos_array
            string_to_array repos_array "$repos_list"
            total_missing_count=$((total_missing_count + ${#repos_array[@]}))
        fi
    done
    
    if [ "$total_missing_count" -gt 0 ]; then
        print_step "【优先级最高】同步所有缺失的仓库（共 $total_missing_count 个）..."
        print_info "   缺失的仓库将优先处理，完成后才会更新已存在的仓库"
        echo ""
        
        # 收集所有需要克隆的仓库信息（用于并行处理）
        local -a all_clone_tasks=()
        local global_index=0
        
        for group_folder in "${!global_repos_to_clone[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_clone[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            for repo_info in "${repos_array[@]}"; do
                ((global_index++))
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                all_clone_tasks+=("$repo_full|$repo_name|$group_folder|$group_name|$global_index")
            done
        done
        
        # 并行执行克隆任务
        local active_jobs=0
        local task_index=0
        local temp_dir=$(mktemp -d)
        local -a job_pids=()
        
        # 初始化进度显示系统
        init_progress_display
        
        print_info "开始并行克隆（并发数: $PARALLEL_JOBS）..."
        print_info "每个任务将显示在独立行，实时更新进度"
        echo ""
        
        while [ $task_index -lt ${#all_clone_tasks[@]} ] || [ $active_jobs -gt 0 ]; do
            # 更新活跃任务数（重新计算）
            active_jobs=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((active_jobs++))
                fi
            done
            # 启动新任务（如果还有待处理任务且未达到并发限制）
            while [ $active_jobs -lt $PARALLEL_JOBS ] && [ $task_index -lt ${#all_clone_tasks[@]} ]; do
                local task_info="${all_clone_tasks[$task_index]}"
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                
                local repo_path="$group_folder/$repo_name"
                local log_file="$temp_dir/clone_${task_index}.log"
                
                # 后台执行克隆任务（注意：在后台块中需要重新声明变量以确保正确传递）
                (
                    # 重新读取变量，确保在子shell中正确传递
                    local repo_full_var="$repo_full"
                    local group_folder_var="$group_folder"
                    local repo_name_var="$repo_name"
                    local group_name_var="$group_name"
                    local global_index_var="$global_index"
                    local total_missing_count_var="$total_missing_count"
                    
                    # 在子shell中重新构建路径，确保路径正确
                    local repo_path_var="$group_folder_var/$repo_name_var"
                    
                    # 注册进度任务并显示初始状态
                    local task_id="clone_${task_index}"
                    register_progress_task "$task_id" "$repo_name_var" >/dev/null
                    update_progress_line "$task_id" "[$global_index_var/$total_missing_count_var] 开始克隆: $repo_name_var (分组: $group_name_var)"
                    
                    # 使用 tee 同时输出到日志文件和终端，并解析进度
                    {
                        # 输出详细信息到日志（不显示在进度行）
                        echo "[$global_index_var/$total_missing_count_var] 开始克隆: $repo_name_var (分组: $group_name_var)" >> "$log_file"
                        echo "  目标路径: $repo_path_var" >> "$log_file"
                        # 执行克隆，实时解析并显示进度
                        clone_repo "$repo_full_var" "$repo_path_var" "$global_index_var" "$total_missing_count_var" "all_failed_logs" 2>&1 | \
                            while IFS= read -r line; do
                                # 解析 git 进度并更新显示
                                parse_git_progress "$line" "$task_id" "$repo_name_var" 2>/dev/null || true
                                # 同时输出到日志文件
                                echo "$line" >> "$log_file"
                            done
                        local result=${PIPESTATUS[0]}
                        echo "result:$result" >> "$log_file"
                        # 注意：统计更新在并行环境下可能有竞争，最后统一汇总
                        if [ "$result" -ne 0 ]; then
                            echo "failed:$repo_full_var|$repo_name_var|$group_folder_var" >> "$log_file"
                            update_progress_line "$task_id" "[$global_index_var/$total_missing_count_var] 克隆失败: $repo_name_var ✗"
                        else
                            update_progress_line "$task_id" "[$global_index_var/$total_missing_count_var] 克隆完成: $repo_name_var ✓"
                        fi
                    } >&2
                ) &
                
                local pid=$!
                job_pids+=($pid)
                ((active_jobs++))
                ((task_index++))
            done
            
            # 检查并更新活跃任务数（每次循环重新计算，确保准确）
            local new_active=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((new_active++))
                fi
            done
            active_jobs=$new_active
            
            # 如果达到并发上限，短暂等待
            if [ $active_jobs -ge $PARALLEL_JOBS ] && [ $task_index -lt ${#all_clone_tasks[@]} ]; then
                sleep 0.3
            fi
        done
        
        # 等待所有任务完成并汇总结果
        for pid in "${job_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        
        # 读取所有日志文件，汇总结果和失败信息
        # 注意：日志已经实时显示，这里只提取结果和失败信息，不再重复输出
        for log_file in "$temp_dir"/clone_*.log; do
            if [ -f "$log_file" ]; then
                # 提取结果并更新统计
                local result=$(grep "^result:" "$log_file" | sed 's/^result://' || echo "1")
                local file_idx=$(basename "$log_file" | sed -n 's/clone_\([0-9]*\)\.log/\1/p')
                if [ -n "$file_idx" ] && [ -n "${all_clone_tasks[$file_idx]}" ]; then
                    local task_info="${all_clone_tasks[$file_idx]}"
                    # 格式：repo_full|repo_name|group_folder|group_name|global_index
                    IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                    local repo_path="$group_folder/$repo_name"
                    update_sync_statistics "$repo_path" "$result"
                fi
                
                # 提取失败信息
                local failed_info=$(grep "^failed:" "$log_file" | sed 's/^failed://' || echo "")
                if [ -n "$failed_info" ]; then
                    all_failed_repos+=("$failed_info")
                fi
            fi
        done
        
        rm -rf "$temp_dir"
        
        # 清理进度显示
        cleanup_progress_display
        
        echo ""
        print_success "所有缺失仓库同步完成（$total_missing_count 个）"
        echo ""
    fi
    
    # 第二步：处理所有分组的更新仓库（已存在的）
    local total_update_count=0
    for group_folder in "${!global_repos_to_update[@]}"; do
        local repos_list="${global_repos_to_update[$group_folder]}"
        if [ -n "$repos_list" ]; then
            local repos_array
            string_to_array repos_array "$repos_list"
            total_update_count=$((total_update_count + ${#repos_array[@]}))
        fi
    done
    
        if [ "$total_update_count" -gt 0 ]; then
        if [ "$total_missing_count" -gt 0 ]; then
            print_step "【第二步】更新所有已存在的仓库（共 $total_update_count 个）..."
            print_info "   所有缺失的仓库已处理完成，开始更新已存在的仓库"
        else
            print_step "更新所有已存在的仓库（共 $total_update_count 个）..."
        fi
        echo ""
        
        # 收集所有需要更新的仓库信息（用于并行处理）
        local -a all_update_tasks=()
        local global_index=0
        
        for group_folder in "${!global_repos_to_update[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_update[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            for repo_info in "${repos_array[@]}"; do
                ((global_index++))
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                all_update_tasks+=("$repo_full|$repo_name|$group_folder|$group_name|$global_index")
            done
        done
        
        # 并行执行更新任务
        local active_jobs=0
        local task_index=0
        local temp_dir=$(mktemp -d)
        local -a job_pids=()
        
        print_info "开始并行更新（并发数: $PARALLEL_JOBS）..."
        echo ""
        
        while [ $task_index -lt ${#all_update_tasks[@]} ] || [ $active_jobs -gt 0 ]; do
            # 启动新任务（如果还有待处理任务且未达到并发限制）
            while [ $active_jobs -lt $PARALLEL_JOBS ] && [ $task_index -lt ${#all_update_tasks[@]} ]; do
                local task_info="${all_update_tasks[$task_index]}"
                # 格式：repo_full|repo_name|group_folder|group_name|global_index
                IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                
                local repo_path="$group_folder/$repo_name"
                local log_file="$temp_dir/update_${task_index}.log"
                
                # 后台执行更新任务（注意：在后台块中需要重新声明变量以确保正确传递）
                (
                    # 重新读取变量，确保在子shell中正确传递
                    local repo_full_var="$repo_full"
                    local repo_path_var="$repo_path"
                    local group_folder_var="$group_folder"
                    local repo_name_var="$repo_name"
                    local group_name_var="$group_name"
                    local global_index_var="$global_index"
                    local total_update_count_var="$total_update_count"
                    
                    # 注册进度任务并显示初始状态
                    local task_id="update_${task_index}"
                    register_progress_task "$task_id" "$repo_name_var" >/dev/null
                    update_progress_line "$task_id" "[$global_index_var/$total_update_count_var] 开始更新: $repo_name_var (分组: $group_name_var)"
                    
                    # 使用 tee 同时输出到日志文件和终端，并解析进度
                    {
                        # 输出详细信息到日志（不显示在进度行）
                        echo "[$global_index_var/$total_update_count_var] 开始更新: $repo_name_var (分组: $group_name_var)" >> "$log_file"
                        # 执行更新，实时解析并显示进度
                        update_repo "$repo_full_var" "$repo_path_var" "$group_folder_var" "$global_index_var" "$total_update_count_var" "all_failed_logs" 2>&1 | \
                            while IFS= read -r line; do
                                # 解析 git 进度并更新显示
                                parse_git_progress "$line" "$task_id" "$repo_name_var" 2>/dev/null || true
                                # 同时输出到日志文件
                                echo "$line" >> "$log_file"
                            done
                        local result=${PIPESTATUS[0]}
                        echo "result:$result" >> "$log_file"
                        if [ "$result" -ne 0 ] && [ "$result" -ne 2 ]; then
                            echo "failed:$repo_full_var|$repo_name_var|$group_folder_var" >> "$log_file"
                            update_progress_line "$task_id" "[$global_index_var/$total_update_count_var] 更新失败: $repo_name_var ✗"
                        else
                            update_progress_line "$task_id" "[$global_index_var/$total_update_count_var] 更新完成: $repo_name_var ✓"
                        fi
                    } >&2
                ) &
                
                local pid=$!
                job_pids+=($pid)
                ((active_jobs++))
                ((task_index++))
            done
            
            # 检查并更新活跃任务数（每次循环重新计算，确保准确）
            local new_active=0
            for pid in "${job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    ((new_active++))
                fi
            done
            active_jobs=$new_active
            
            # 如果达到并发上限，短暂等待（让已完成的任务有机会被检测到）
            if [ $active_jobs -ge $PARALLEL_JOBS ]; then
                sleep 0.3
            fi
        done
        
        # 等待所有任务完成并汇总结果
        for pid in "${job_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        
        # 读取所有日志文件，汇总结果和失败信息
        # 注意：日志已经实时显示，这里只提取结果和失败信息，不再重复输出
        for log_file in "$temp_dir"/update_*.log; do
            if [ -f "$log_file" ]; then
                # 提取结果并更新统计
                local result=$(grep "^result:" "$log_file" | sed 's/^result://' || echo "1")
                local file_idx=$(basename "$log_file" | sed -n 's/update_\([0-9]*\)\.log/\1/p')
                if [ -n "$file_idx" ] && [ -n "${all_update_tasks[$file_idx]}" ]; then
                    local task_info="${all_update_tasks[$file_idx]}"
                    # 格式：repo_full|repo_name|group_folder|group_name|global_index
                    IFS='|' read -r repo_full repo_name group_folder group_name global_index <<< "$task_info"
                    local repo_path="$group_folder/$repo_name"
                    update_sync_statistics "$repo_path" "$result"
                fi
                
                # 提取失败信息
                local failed_info=$(grep "^failed:" "$log_file" | sed 's/^failed://' || echo "")
                if [ -n "$failed_info" ]; then
                    all_failed_repos+=("$failed_info")
                fi
            fi
        done
        
        rm -rf "$temp_dir"
        
        # 清理进度显示
        cleanup_progress_display
        
        echo ""
        print_success "所有已存在仓库更新完成（$total_update_count 个）"
        echo ""
    fi
    
    # 最后统一重试：所有分组完成后，统一重试所有失败的仓库
    if [ ${#all_failed_repos[@]} -gt 0 ]; then
        echo ""
        echo "=================================================="
        print_info "所有分组同步完成，发现 ${#all_failed_repos[@]} 个失败的仓库，进行统一重试..."
        echo "=================================================="
        echo ""
        
        local retry_index=0
        local retry_success_count=0
        for failed_repo in "${all_failed_repos[@]}"; do
            IFS='|' read -r repo_full repo_name group_folder <<< "$failed_repo"
            ((retry_index++))
            
            if retry_repo_sync "$repo_full" "$repo_name" "$group_folder" "${#all_failed_repos[@]}" "$retry_index" "all_failed_logs"; then
                ((retry_success_count++))
            fi
        done
        
        # 更新失败统计（重试成功的应该从失败计数中减去）
        # 注意：retry_repo_sync 内部已经调用了 update_sync_statistics 来增加成功计数
        # 但第一次失败时已经统计为失败，所以需要减少失败计数
        if [ "$retry_success_count" -gt 0 ]; then
            SYNC_STATS_FAIL=$((SYNC_STATS_FAIL - retry_success_count))
            print_success "重试成功恢复 $retry_success_count 个仓库"
        fi
        
        local final_failed_count=$((${#all_failed_repos[@]} - retry_success_count))
        echo ""
        if [ "$final_failed_count" -gt 0 ]; then
            print_warning "重试完成，仍有 $final_failed_count 个仓库失败"
        else
            print_success "重试完成，所有仓库已成功同步"
        fi
        echo ""
    fi
    
    # 保存错误日志数组名供后续使用
    declare -g ALL_FAILED_LOGS_ARRAY=all_failed_logs
}

