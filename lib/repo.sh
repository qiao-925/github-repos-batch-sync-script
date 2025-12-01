#!/bin/bash
# 仓库操作模块：克隆、更新、清理

# 克隆仓库
clone_repo() {
    local repo=$1
    local repo_path=$2
    local current_index=$3
    local total_sync=$4
    local error_log_ref=${5:-""}
    
    # 切换到脚本目录，确保相对路径正确
    cd "$SCRIPT_DIR" || {
        print_error "  错误: 无法切换到脚本目录: $SCRIPT_DIR"
        return 1
    }
    
    print_highlight "[$current_index/$total_sync] [克隆] $repo -> $(dirname "$repo_path")/..."
    print_info "  正在克隆仓库: $repo"
    print_info "  目标路径: $repo_path"
    
    # 创建父目录（分组文件夹），确保目录存在
    local parent_dir=$(dirname "$repo_path")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir"
        print_info "  已创建分组文件夹: $parent_dir"
    fi
    
    # 获取仓库信息（用于显示）
    local repo_info=$(get_repo_info "$repo")
    if [ -n "$repo_info" ]; then
        local repo_desc=$(extract_json_field "$repo_info" "description")
        local repo_lang=$(extract_json_field "$repo_info" "language")
        local repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
        if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ]; then
            print_info "  描述: $repo_desc"
        fi
        if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ "$repo_lang" != "未知" ]; then
            print_info "  语言: $repo_lang"
        fi
        if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
            print_info "  ⭐ Stars: $repo_stars"
        fi
    fi
    
    # 使用 gh repo clone（自动处理协议选择，更好的错误处理）
    # 使用 --progress 强制显示进度条，即使输出被重定向
    # 设置 GIT_PROGRESS_DELAY=0 立即显示进度（不延迟）
    print_info "🌐 [外部调用] 开始: 克隆仓库 $repo 到 $repo_path"
    local clone_start_time=$(date +%s)
    GIT_PROGRESS_DELAY=0 gh repo clone "$repo" "$repo_path" -- --progress 2>&1
    local clone_exit_code=$?
    local clone_end_time=$(date +%s)
    local clone_duration=$((clone_end_time - clone_start_time))
    
    if [ "$clone_exit_code" -eq 0 ]; then
        print_success "✅ [外部调用] 完成: 克隆仓库 $repo (耗时: ${clone_duration}秒)"
    else
        print_error "❌ [外部调用] 失败: 克隆仓库 $repo (耗时: ${clone_duration}秒, 退出码: $clone_exit_code)"
    fi
    
    # 如果失败，获取错误信息
    local clone_output=""
    if [ "$clone_exit_code" -ne 0 ]; then
        clone_output="克隆失败，退出代码: $clone_exit_code"
    fi
    
    if [ "$clone_exit_code" -eq 0 ]; then
        echo "✓ 成功（耗时 ${clone_duration}秒）" >&2
        print_success "  克隆成功: $repo_path"
        return 0
    else
        echo "✗ 失败（耗时 ${clone_duration}秒）" >&2
        local error_msg="${clone_output:-克隆失败，退出代码: $clone_exit_code}"
        print_error "  克隆失败: $error_msg"
        print_error "  请查看上方的错误信息"
        record_error "$error_log_ref" "$repo" "克隆失败" "$error_msg"
        return 1
    fi
}

# 准备仓库更新环境（检查分支、处理冲突）
prepare_repo_for_update() {
    # 检查并处理分支状态
    local current_branch=$(git symbolic-ref -q HEAD 2>/dev/null || echo "")
    if [ -z "$current_branch" ]; then
        # detached HEAD，尝试切换到默认分支
        local default_branch=$(git remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/.*: //' || echo "main")
        git checkout -b "$default_branch" >/dev/null 2>&1 || git checkout "$default_branch" >/dev/null 2>&1
    fi
    
    # 获取当前分支名
    local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    
    # 处理未提交的更改和冲突状态
    local uncommitted_changes=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$uncommitted_changes" -gt 0 ]; then
        git stash >/dev/null 2>&1
    fi
    
    # 清理未完成的合并/变基
    [ -f ".git/MERGE_HEAD" ] && git merge --abort >/dev/null 2>&1
    [ -f ".git/CHERRY_PICK_HEAD" ] && git cherry-pick --abort >/dev/null 2>&1
    [ -f ".git/REBASE_HEAD" ] && git rebase --abort >/dev/null 2>&1
    
    echo "$branch|$uncommitted_changes"
}

# 执行仓库同步操作（优先使用 gh repo sync，回退到 git pull）
execute_repo_sync() {
    local repo_full=$1
    local repo_path=$2
    local branch=$3
    local sync_exit_code=1
    
    # 检查是否是 fork 仓库（有 upstream remote）
    local has_upstream=$(cd "$repo_path" && git remote get-url upstream 2>/dev/null || echo "")
    
    if [ -n "$has_upstream" ]; then
        # 如果是 fork 仓库，使用 gh repo sync（同步到上游）
        print_info "    检测到 fork 仓库，使用 gh repo sync 同步到上游..."
        print_info "🌐 [外部调用] 开始: 同步 fork 仓库 $repo_full (分支: $branch)"
        local sync_start_time=$(date +%s)
        cd "$repo_path" && gh repo sync --branch "$branch" >&2 2>&1
        sync_exit_code=$?
        local sync_end_time=$(date +%s)
        local sync_duration=$((sync_end_time - sync_start_time))
        
        if [ "$sync_exit_code" -eq 0 ]; then
            print_success "✅ [外部调用] 完成: 同步 fork 仓库 $repo_full (耗时: ${sync_duration}秒)"
        else
            print_error "❌ [外部调用] 失败: 同步 fork 仓库 $repo_full (耗时: ${sync_duration}秒, 退出码: $sync_exit_code)"
        fi
    fi
    
    # 如果不是 fork 或 sync 失败，使用 git pull
    if [ "$sync_exit_code" -ne 0 ] || [ -z "$has_upstream" ]; then
        # 尝试拉取（输出重定向到 stderr，避免被 $() 捕获）
        # 使用 --progress 强制显示进度条
        print_info "🌐 [外部调用] 开始: 拉取仓库更新 $repo_full (分支: $branch, 使用 rebase)"
        local pull_start_time=$(date +%s)
        cd "$repo_path" && GIT_PROGRESS_DELAY=0 git pull --progress --no-edit --rebase origin "$branch" >&2
        sync_exit_code=$?
        local pull_end_time=$(date +%s)
        local pull_duration=$((pull_end_time - pull_start_time))
        
        if [ "$sync_exit_code" -eq 0 ]; then
            print_success "✅ [外部调用] 完成: 拉取仓库更新 $repo_full (耗时: ${pull_duration}秒)"
        else
            print_error "❌ [外部调用] 失败: 拉取仓库更新 $repo_full (耗时: ${pull_duration}秒, 退出码: $sync_exit_code)"
        fi
        
        # 如果失败，尝试普通 pull
        if [ "$sync_exit_code" -ne 0 ]; then
            [ -f "$repo_path/.git/REBASE_HEAD" ] && cd "$repo_path" && git rebase --abort >/dev/null 2>&1
            print_info "🌐 [外部调用] 开始: 重试拉取仓库更新 $repo_full (分支: $branch, 不使用 rebase)"
            pull_start_time=$(date +%s)
            cd "$repo_path" && GIT_PROGRESS_DELAY=0 git pull --progress --no-edit origin "$branch" >&2
            sync_exit_code=$?
            pull_end_time=$(date +%s)
            pull_duration=$((pull_end_time - pull_start_time))
            
            if [ "$sync_exit_code" -eq 0 ]; then
                print_success "✅ [外部调用] 完成: 重试拉取仓库更新 $repo_full (耗时: ${pull_duration}秒)"
            else
                print_error "❌ [外部调用] 失败: 重试拉取仓库更新 $repo_full (耗时: ${pull_duration}秒, 退出码: $sync_exit_code)"
            fi
        fi
        
        # 如果还是失败，尝试直接拉取
        if [ "$sync_exit_code" -ne 0 ]; then
            [ -f "$repo_path/.git/MERGE_HEAD" ] && cd "$repo_path" && git merge --abort >/dev/null 2>&1
            print_info "🌐 [外部调用] 开始: 最后尝试拉取仓库更新 $repo_full (使用默认分支)"
            pull_start_time=$(date +%s)
            cd "$repo_path" && GIT_PROGRESS_DELAY=0 git pull --progress --no-edit >&2
            sync_exit_code=$?
            pull_end_time=$(date +%s)
            pull_duration=$((pull_end_time - pull_start_time))
            
            if [ "$sync_exit_code" -eq 0 ]; then
                print_success "✅ [外部调用] 完成: 最后尝试拉取仓库更新 $repo_full (耗时: ${pull_duration}秒)"
            else
                print_error "❌ [外部调用] 失败: 最后尝试拉取仓库更新 $repo_full (耗时: ${pull_duration}秒, 退出码: $sync_exit_code)"
            fi
        fi
    fi
    
    echo "$sync_exit_code"
}

# 更新已有仓库
update_repo() {
    local repo=$1
    local repo_path=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local error_log_ref=${6:-""}
    
    # 切换到脚本目录，确保相对路径正确
    cd "$SCRIPT_DIR" || {
        print_error "  错误: 无法切换到脚本目录: $SCRIPT_DIR"
        return 1
    }
    
    print_highlight -n "[$current_index/$total_sync] [更新] $repo ($group_folder)... "
    print_info "  正在更新仓库: $repo"
    print_info "  仓库路径: $repo_path"
    
    # 保存当前目录
    local original_dir=$(pwd)
    
    cd "$repo_path" || {
        local error_msg="无法进入仓库目录: $repo_path"
        print_error "  错误: $error_msg"
        record_error "$error_log_ref" "$repo" "更新失败" "$error_msg"
        return 1
    }
    
    # 准备更新环境
    local prep_result=$(prepare_repo_for_update)
    IFS='|' read -r branch uncommitted_changes <<< "$prep_result"
    
    # 获取拉取前的提交哈希
    local before_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
    local pull_start_time=$(date +%s)
    
    # 获取仓库信息（用于显示）
    local repo_info=$(get_repo_info "$repo")
    if [ -n "$repo_info" ]; then
        local repo_desc=$(extract_json_field "$repo_info" "description")
        local repo_lang=$(extract_json_field "$repo_info" "language")
        local repo_stars=$(extract_json_number "$repo_info" "stargazerCount")
        if [ -n "$repo_desc" ] && [ "$repo_desc" != "null" ]; then
            print_info "  描述: $repo_desc"
        fi
        if [ -n "$repo_lang" ] && [ "$repo_lang" != "null" ] && [ "$repo_lang" != "未知" ]; then
            print_info "  语言: $repo_lang"
        fi
        if [ -n "$repo_stars" ] && [ "$repo_stars" != "null" ] && [ "$repo_stars" != "0" ]; then
            print_info "  ⭐ Stars: $repo_stars"
        fi
    fi
    
    # 执行同步（优先使用 gh repo sync，回退到 git pull）
    local pull_exit_code=$(execute_repo_sync "$repo" "$repo_path" "$branch")
    
    local pull_end_time=$(date +%s)
    local pull_duration=$((pull_end_time - pull_start_time))
    
    # 如果失败，获取错误信息
    local pull_output=""
    if [ "$pull_exit_code" -ne 0 ]; then
        pull_output="拉取失败，退出代码: $pull_exit_code"
    fi
    
    # 恢复暂存的更改（如果有）
    if [ "$uncommitted_changes" -gt 0 ] || [ -n "$(git stash list 2>/dev/null | head -n 1)" ]; then
        git stash pop >/dev/null 2>&1
    fi
    
    if [ "$pull_exit_code" -eq 0 ]; then
        local after_hash=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ "$before_hash" != "$after_hash" ] && [ -n "$before_hash" ] && [ -n "$after_hash" ]; then
            print_info "    仓库已更新（${before_hash:0:8} -> ${after_hash:0:8}）"
        fi
        echo "✓ 成功（耗时 ${pull_duration}秒）" >&2
        cd "$original_dir" || true
        return 0
    else
        echo "✗ 失败（耗时 ${pull_duration}秒）" >&2
        # 错误信息已经在终端显示了，这里只记录基本错误
        local error_msg="${pull_output:-拉取失败，退出代码: $pull_exit_code}"
        print_error "  拉取失败: $error_msg"
        print_error "  请查看上方的错误信息"
        print_error "  可能原因: 网络问题、权限问题、或需要手动解决的冲突"
        # 记录失败日志
        record_error "$error_log_ref" "$repo" "更新失败" "$error_msg"
        cd "$original_dir" || true
        return 1
    fi
}

# 同步单个仓库（克隆或更新）
sync_single_repo() {
    local repo=$1
    local repo_name=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local error_log_ref=${6:-""}
    
    # 创建分组文件夹
    if [ ! -d "$group_folder" ]; then
        mkdir -p "$group_folder"
    fi
    
    local repo_path="$group_folder/$repo_name"
    
    # 检查是否已存在
    if [ -d "$repo_path/.git" ]; then
        # 已存在 git 仓库，执行更新
        update_repo "$repo" "$repo_path" "$group_folder" "$current_index" "$total_sync" "$error_log_ref"
        return $?
    elif [ -d "$repo_path" ]; then
        # 目录存在但不是 git 仓库，跳过
        echo "[$current_index/$total_sync] [跳过] $repo - 目录已存在但不是 git 仓库" >&2
        record_error "$error_log_ref" "$repo" "跳过" "目录已存在但不是 git 仓库"
        return 2
    else
        # 新仓库，执行克隆
        clone_repo "$repo" "$repo_path" "$current_index" "$total_sync" "$error_log_ref"
        return $?
    fi
}

# 清理远程已删除的本地仓库
cleanup_deleted_repos() {
    local -n group_folders_ref=$1
    local -n sync_repos_map_ref=$2
    
    print_step "检查需要删除的本地仓库（远程已不存在）..."
    local delete_count=0
    
    # 获取仓库所有者（用于检查远程仓库是否存在）
    local repo_owner=$(get_github_username)
    if [ -n "$repo_owner" ]; then
        print_info "仓库所有者: $repo_owner"
    else
        print_warning "无法获取仓库所有者信息，将跳过远程仓库存在性检查"
    fi
    
    # 遍历所有分组文件夹
    local check_dirs=()
    for group_folder in "${!group_folders_ref[@]}"; do
        if [ -d "$group_folder" ]; then
            print_debug "检查分组文件夹: $group_folder"
            # 使用 nullglob 处理空目录情况
            shopt -s nullglob
            for dir in "$group_folder"/*; do
                [ -d "$dir" ] && check_dirs+=("$dir")
            done
            shopt -u nullglob
        fi
    done
    
    print_info "找到 ${#check_dirs[@]} 个本地目录需要检查"
    
    if [ ${#check_dirs[@]} -eq 0 ]; then
        print_info "没有需要检查的本地目录"
        CLEANUP_STATS_DELETE=0
        return 0
    fi
    
    echo ""
    # 遍历目录
    for local_dir in "${check_dirs[@]}"; do
        # 规范化路径（去除尾部斜杠）
        local normalized_dir="${local_dir%/}"
        
        # 跳过非目录或非 git 仓库
        [ ! -d "$normalized_dir" ] && continue
        [ ! -d "$normalized_dir/.git" ] && continue
        
        local repo_name=$(basename "$normalized_dir")
        local repo_path="$normalized_dir"
        
        print_debug "检查本地仓库: $repo_path"
        
        # 检查是否在要同步的仓库列表中
        if [ -z "${sync_repos_map_ref[$repo_path]}" ]; then
            # 如果不在要同步的分组中，检查是否在远程还存在
            # 使用缓存检查，避免 API 调用
            local repo_full="${REPO_FULL_NAME_CACHE[$repo_name]}"
            if [ -n "$repo_full" ]; then
                # 仓库在缓存中存在，说明远程还存在，只是不在当前同步的分组中
                print_info "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，保留"
                continue
            else
                # 不在缓存中，说明远程可能不存在（但可能不在前1000个仓库中，保守处理）
                print_warning "  仓库 $repo_name 不在仓库列表中（可能已删除或不在前1000个仓库）"
                # 如果需要精确检查，可以使用 API（但会慢一些）
                if [ -n "$repo_owner" ]; then
                    print_info "  检查远程仓库是否存在: $repo_owner/$repo_name"
                    if log_api_call "检查仓库是否仍存在于远程: $repo_name" gh repo view "$repo_owner/$repo_name" &>/dev/null; then
                        print_info "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，保留"
                        continue
                    else
                        print_warning "  仓库 $repo_name 在远程已不存在"
                    fi
                fi
            fi
            
            # 仓库已不存在，删除
            echo -n "[删除] $repo_path (远程仓库已不存在)... "
            print_info "  正在删除: $repo_path"
            local rm_output=$(rm -rf "$repo_path" 2>&1)
            local rm_exit=$?
            
            if [ "$rm_exit" -eq 0 ]; then
                echo "✓ 已删除"
                ((delete_count++))
                print_success "  已成功删除: $repo_path"
            else
                echo "✗ 删除失败"
                print_error "  删除失败: $repo_path"
                if [ -n "$rm_output" ]; then
                    print_error "  错误信息: $rm_output"
                fi
            fi
        else
            print_info "  仓库 $repo_name 在同步列表中，保留"
        fi
    done
    
    if [ "$delete_count" -eq 0 ]; then
        print_info "没有需要删除的本地仓库。"
    else
        echo ""
        print_info "已删除 $delete_count 个本地仓库（远程已不存在）。"
    fi
    
    CLEANUP_STATS_DELETE=$delete_count
}

