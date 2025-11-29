#!/bin/bash
# GitHub 仓库按分组同步脚本

# ============================================
# 配置和常量定义
# ============================================
CONFIG_FILE="REPO-GROUPS.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# 日志输出函数
# ============================================

# 获取时间戳
_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 带时间戳的日志函数（输出到 stderr，避免被命令替换捕获）
print_info() {
    echo -e "[$(_get_timestamp)] ${BLUE}ℹ${NC} $1" >&2
}

print_warning() {
    echo -e "[$(_get_timestamp)] ${YELLOW}⚠${NC} $1" >&2
}

print_error() {
    echo -e "[$(_get_timestamp)] ${RED}✗${NC} $1" >&2
}

print_success() {
    echo -e "[$(_get_timestamp)] ${GREEN}✓${NC} $1" >&2
}

print_debug() {
    # Debug 模式已关闭
    :
}

print_step() {
    echo -e "[$(_get_timestamp)] ${BLUE}→${NC} $1" >&2
}

# 详细操作日志（带时间戳和操作类型）
print_operation_start() {
    local operation=$1
    local details=$2
    echo -e "[$(_get_timestamp)] ${BLUE}[开始]${NC} $operation ${details:+($details)}" >&2
}

print_operation_end() {
    local operation=$1
    local status=$2  # success/fail/skip/warning
    local duration=$3  # 耗时（秒）
    local details=$4
    
    case "$status" in
        "success")
            echo -e "[$(_get_timestamp)] ${GREEN}[完成]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "fail"|"failure")
            echo -e "[$(_get_timestamp)] ${RED}[失败]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "skip")
            echo -e "[$(_get_timestamp)] ${YELLOW}[跳过]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        "warning")
            echo -e "[$(_get_timestamp)] ${YELLOW}[警告]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
        *)
            echo -e "[$(_get_timestamp)] ${BLUE}[结束]${NC} $operation ${details:+($details)} ${duration:+[耗时: ${duration}秒]}" >&2
            ;;
    esac
}

# API 调用日志
print_api_call() {
    local api_name=$1
    local params=$2
    echo -e "[$(_get_timestamp)] ${BLUE}[API调用]${NC} $api_name ${params:+($params)}" >&2
}

# 命令执行日志
print_command() {
    local cmd=$1
    echo -e "[$(_get_timestamp)] ${BLUE}[执行命令]${NC} $cmd" >&2
}

# ============================================
# 统计管理函数
# ============================================

# 初始化全局统计变量
init_sync_stats() {
    declare -g SYNC_STATS_SUCCESS=0
    declare -g SYNC_STATS_UPDATE=0
    declare -g SYNC_STATS_FAIL=0
    declare -g CLEANUP_STATS_DELETE=0
    declare -gA group_folders
    declare -gA group_names
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
# 比较远程和本地差异，生成详细报告
compare_remote_local_diff() {
    local -n failed_logs_ref=$1
    
    echo ""
    echo "=================================================="
    echo "📊 远程与本地差异分析"
    echo "=================================================="
    echo ""
    
    # 获取所有应该同步的仓库列表
    local expected_repos=()
    declare -A expected_repos_map=()
    local repo_owner=$(get_github_username)
    
    # 遍历所有分组，收集应该同步的仓库
    local all_groups_output=$(get_all_groups_for_sync)
    local groups_array
    string_to_array groups_array "$all_groups_output"
    
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
            
            local repo_full=$(find_repo_full_name "$repo_name")
            if [ -n "$repo_full" ]; then
                expected_repos+=("$repo_full")
                expected_repos_map["$repo_full"]=1
            fi
        done
    done
    
    # 获取所有本地已存在的仓库
    local local_repos=()
    declare -A local_repos_map=()
    
    for group_folder in "${!group_folders[@]}"; do
        if [ -d "$group_folder" ]; then
            shopt -s nullglob
            for dir in "$group_folder"/*; do
                if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                    local repo_name=$(basename "$dir")
                    local repo_full=$(find_repo_full_name "$repo_name")
                    if [ -n "$repo_full" ]; then
                        local_repos+=("$repo_full")
                        local_repos_map["$repo_full"]=1
                    fi
                fi
            done
            shopt -u nullglob
        fi
    done
    
    # 分析差异
    local missing_repos=()      # 应该存在但本地缺失的
    local extra_repos=()         # 本地存在但不在同步列表中的
    local synced_repos=()        # 成功同步的
    
    # 找出缺失的仓库（应该存在但本地没有）
    for repo_full in "${expected_repos[@]}"; do
        if [ -z "${local_repos_map[$repo_full]}" ]; then
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
            echo "  [$index] $repo_full"
            ((index++))
        done
        echo ""
    fi
    
    # 显示多余的仓库详情（如果数量不多）
    if [ "$total_extra" -gt 0 ] && [ "$total_extra" -le 20 ]; then
        print_info "ℹ️  本地多余的仓库（$total_extra 个，不在同步列表中）："
        local index=1
        for repo_full in "${extra_repos[@]}"; do
            echo "  [$index] $repo_full"
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

# ============================================
# 重试机制函数
# ============================================

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

# ============================================
# 配置解析函数
# ============================================

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

# 获取所有分组名称
get_all_group_names() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    
    grep "^## " "$CONFIG_FILE" | sed 's/^## //' | sed 's/ <!--.*//'
}

# 根据输入查找分组名称（支持部分匹配）
find_group_name() {
    local input=$1
    local all_groups=$(get_all_group_names)
    
    # 精确匹配
    if echo "$all_groups" | grep -qFx "$input"; then
        echo "$input"
        return 0
    fi
    
    # 部分匹配（不区分大小写）
    local matched=$(echo "$all_groups" | grep -i "$input" | head -n 1)
    if [ -n "$matched" ]; then
        echo "$matched"
        return 0
    fi
    
    return 1
}

# 获取分组的高地编号
get_group_highland() {
    local group_name=$1
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    
    # 查找分组行并提取高地编号
    local line=$(grep "^## $group_name" "$CONFIG_FILE" | head -n 1)
    if [ -z "$line" ]; then
        return 1
    fi
    
    # 提取 HTML 注释中的高地编号（支持中文字符）
    local highland=$(echo "$line" | sed -n 's/.*<!--[[:space:]]*\(.*\)[[:space:]]*-->.*/\1/p')
    if [ -z "$highland" ]; then
        return 1
    fi
    
    # 去除首尾空白
    highland=$(echo "$highland" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # 如果格式是"数字高地"，自动加上"号"字变成"数字号高地"
    # 例如：397.8高地 → 397.8号高地，382高地 → 382号高地
    if echo "$highland" | grep -qE '^[0-9]+\.?[0-9]*高地$'; then
        highland=$(echo "$highland" | sed 's/高地$/号高地/')
    fi
    
    echo "$highland"
}

# 获取分组文件夹名称（组名 + 高地编号）
get_group_folder() {
    local group_name=$1
    local highland=$(get_group_highland "$group_name")
    
    if [ -n "$highland" ]; then
        echo "$group_name ($highland)"
    else
        echo "$group_name"
    fi
}

# 获取分组下的所有仓库名称
get_group_repos() {
    local group_name=$1
    local in_group=false
    local repos=""
    
    while IFS= read -r line; do
        # 检查是否是目标分组（支持带高地编号的格式）
        if echo "$line" | grep -qE "^## $group_name( <!--|$|\s)"; then
            in_group=true
            continue
        fi
        
        # 如果遇到下一个分组，停止
        if echo "$line" | grep -q "^## "; then
            if [ "$in_group" = true ]; then
                break
            fi
            in_group=false
            continue
        fi
        
        # 如果在目标分组内，提取仓库名
        if [ "$in_group" = true ]; then
            local repo=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [ -n "$repo" ]; then
                if [ -z "$repos" ]; then
                    repos="$repo"
                else
                    repos="$repos"$'\n'"$repo"
                fi
            fi
        fi
    done < "$CONFIG_FILE"
    
    echo "$repos"
}

# ============================================
# GitHub API 操作函数
# ============================================

# 缓存 GitHub 用户名（避免重复调用 API）
_GITHUB_USER_CACHE=""

# 获取 GitHub 用户名（带缓存）
get_github_username() {
    if [ -z "$_GITHUB_USER_CACHE" ]; then
        _GITHUB_USER_CACHE=$(gh api user --jq '.login' 2>/dev/null || echo "")
    fi
    echo "$_GITHUB_USER_CACHE"
}

# 初始化 GitHub 连接
init_github_connection() {
    # 添加 GitHub 主机密钥（如果需要）
    if [ ! -f ~/.ssh/known_hosts ] || ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        mkdir -p ~/.ssh
        ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
    fi
    
    # 配置 Git 加速选项
    git config --global http.postBuffer 524288000 2>/dev/null || true
    git config --global http.lowSpeedLimit 0 2>/dev/null || true
    git config --global http.lowSpeedTime 0 2>/dev/null || true
    git config --global core.preloadindex true 2>/dev/null || true
    git config --global core.fscache true 2>/dev/null || true
}

# 获取所有远程仓库列表
fetch_remote_repos() {
    print_step "通过 GitHub CLI 获取仓库列表..."
    local all_repos=$(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    
    if [ $? -ne 0 ]; then
        print_error "无法获取仓库列表。请确保已登录 GitHub CLI (运行: gh auth login)"
        exit 1
    fi
    
    local repo_count=$(echo "$all_repos" | wc -l | tr -d ' ')
    print_success "成功获取 $repo_count 个远程仓库"
    print_debug "远程仓库列表: $(echo "$all_repos" | head -5 | tr '\n' ', ')..."
    
    echo "$all_repos"
}

# 查找仓库的完整名称（owner/repo）
find_repo_full_name() {
    local repo_name=$1
    local repo_owner=$(get_github_username)
    
    if [ -z "$repo_owner" ]; then
        return 1
    fi
    
    local repo_full="$repo_owner/$repo_name"
    if gh repo view "$repo_full" &>/dev/null; then
        echo "$repo_full"
        return 0
    else
        return 1
    fi
}

# ============================================
# 仓库操作函数：同步和清理
# ============================================

# 克隆仓库
clone_repo() {
    local repo=$1
    local repo_path=$2
    local current_index=$3
    local total_sync=$4
    local error_log_ref=${5:-""}
    
    echo "[$current_index/$total_sync] [克隆] $repo -> $(dirname "$repo_path")/..." >&2
    print_info "  正在克隆仓库: $repo"
    print_info "  目标路径: $repo_path"
    
    local repo_url="https://github.com/$repo.git"
    print_info "  仓库 URL: $repo_url"
    
    # 直接执行 git clone
    git clone "$repo_url" "$repo_path"
    local clone_exit_code=$?
    local clone_duration=0
    
    # 如果失败，获取错误信息
    local clone_output=""
    if [ "$clone_exit_code" -ne 0 ]; then
        # 失败时尝试获取错误信息（但可能已经输出到终端了）
        clone_output="克隆失败，退出代码: $clone_exit_code"
    fi
    
    if [ "$clone_exit_code" -eq 0 ]; then
        echo "✓ 成功（耗时 ${clone_duration}秒）" >&2
        print_success "  克隆成功: $repo_path"
        return 0
    else
        echo "✗ 失败（耗时 ${clone_duration}秒）" >&2
        # 错误信息已经在终端显示了，这里只记录基本错误
        local error_msg="${clone_output:-克隆失败，退出代码: $clone_exit_code}"
        print_error "  克隆失败: $error_msg"
        print_error "  请查看上方的错误信息"
        # 记录失败日志
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

# 执行 Git 拉取操作（带重试机制）
execute_git_pull() {
    local branch=$1
    local pull_exit_code=1
    
    # 尝试拉取（输出重定向到 stderr，避免被 $() 捕获）
    git pull --no-edit --rebase origin "$branch" >&2
    pull_exit_code=$?
    
    # 如果失败，尝试普通 pull
    if [ "$pull_exit_code" -ne 0 ]; then
        [ -f ".git/REBASE_HEAD" ] && git rebase --abort >/dev/null 2>&1
        git pull --no-edit origin "$branch" >&2
        pull_exit_code=$?
    fi
    
    # 如果还是失败，尝试直接拉取
    if [ "$pull_exit_code" -ne 0 ]; then
        [ -f ".git/MERGE_HEAD" ] && git merge --abort >/dev/null 2>&1
        git pull --no-edit >&2
        pull_exit_code=$?
    fi
    
    echo "$pull_exit_code"
}

# 更新已有仓库
update_repo() {
    local repo=$1
    local repo_path=$2
    local group_folder=$3
    local current_index=$4
    local total_sync=$5
    local error_log_ref=${6:-""}
    
    echo -n "[$current_index/$total_sync] [更新] $repo ($group_folder)... " >&2
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
    
    # 执行拉取
    local pull_exit_code=$(execute_git_pull "$branch")
    
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
            if [ -n "$repo_owner" ]; then
                print_info "  检查远程仓库是否存在: $repo_owner/$repo_name"
                if gh repo view "$repo_owner/$repo_name" &>/dev/null; then
                    print_info "  仓库 $repo_name 还在远程，只是不在当前同步的分组中，保留"
                    continue
                else
                    print_warning "  仓库 $repo_name 在远程已不存在"
                fi
            else
                print_warning "  无法检查远程仓库状态，但仓库不在同步列表中"
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

# ============================================
# 工作流程辅助函数
# ============================================

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
    
    # 初始化 GitHub 连接
    init_github_connection
    
    # 显示同步信息
    echo "=================================================="
    echo "GitHub 仓库分组同步工具"
    echo "=================================================="
    echo ""
    
    # 初始化统计变量
    init_sync_stats
}

# 构建同步仓库映射（用于清理检查）
build_sync_repos_map() {
    local -n sync_repos_map_ref=$1
    
    for group_folder in "${!group_folders[@]}"; do
        if [ -d "$group_folder" ]; then
            # 使用 nullglob 处理空目录情况
            shopt -s nullglob
            for dir in "$group_folder"/*; do
                if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
                    local repo_name=$(basename "$dir")
                    sync_repos_map_ref["$group_folder/$repo_name"]=1
                fi
            done
            shopt -u nullglob
        fi
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
            
            # 检查仓库是否存在
            if [ -d "$repo_path/.git" ]; then
                # 已存在 git 仓库，加入更新列表
                group_to_update+=("$repo_full|$repo_name")
                ((total_to_update++))
                echo "✅ 已存在 (需更新)" >&2
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

# 执行同步操作（遍历所有分组）
execute_sync() {
    local groups=("$@")
    
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
        
        local global_index=0
        for group_folder in "${!global_repos_to_clone[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_clone[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            if [ ${#repos_array[@]} -eq 0 ]; then
                continue
            fi
            
            print_info "处理分组 '$group_name' 的缺失仓库（${#repos_array[@]} 个）..."
            
            for repo_info in "${repos_array[@]}"; do
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                ((global_index++))
                
                echo "" >&2
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info "处理仓库 [$global_index/$total_missing_count]: $repo_name [克隆] (分组: $group_name)"
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                
                local repo_path="$group_folder/$repo_name"
                local result
                clone_repo "$repo_full" "$repo_path" "$global_index" "$total_missing_count" "all_failed_logs"
                result=$?
                
                update_sync_statistics "$repo_path" "$result"
                
                if [ "$result" -ne 0 ]; then
                    all_failed_repos+=("$repo_full|$repo_name|$group_folder")
                fi
            done
        done
        
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
        
        local global_index=0
        for group_folder in "${!global_repos_to_update[@]}"; do
            local group_name="${group_names[$group_folder]}"
            local repos_list="${global_repos_to_update[$group_folder]}"
            
            if [ -z "$repos_list" ]; then
                continue
            fi
            
            local repos_array
            string_to_array repos_array "$repos_list"
            
            if [ ${#repos_array[@]} -eq 0 ]; then
                continue
            fi
            
            print_info "处理分组 '$group_name' 的更新仓库（${#repos_array[@]} 个）..."
            
            for repo_info in "${repos_array[@]}"; do
                IFS='|' read -r repo_full repo_name <<< "$repo_info"
                ((global_index++))
                
                echo "" >&2
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info "处理仓库 [$global_index/$total_update_count]: $repo_name [更新] (分组: $group_name)"
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                
                local repo_path="$group_folder/$repo_name"
                local result
                update_repo "$repo_full" "$repo_path" "$group_folder" "$global_index" "$total_update_count" "all_failed_logs"
                result=$?
                
                update_sync_statistics "$repo_path" "$result"
                
                if [ "$result" -ne 0 ] && [ "$result" -ne 2 ]; then
                    all_failed_repos+=("$repo_full|$repo_name|$group_folder")
                fi
            done
        done
        
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

# ============================================
# 主函数
# ============================================

main() {
    # 1. 初始化同步环境
    initialize_sync
    
    # 2. 列出所有可用分组
    echo ""
    list_groups
    echo ""
    
    # 3. 获取所有分组用于同步
    print_info "准备同步所有分组..."
    local all_groups_output=$(get_all_groups_for_sync)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    local groups_array
    string_to_array groups_array "$all_groups_output"
    
    if [ ${#groups_array[@]} -eq 0 ]; then
        print_error "没有找到任何分组"
        exit 1
    fi
    
    print_info "找到 ${#groups_array[@]} 个分组，开始同步..."
    echo ""
    
    # 4. 全局扫描差异，分析所有仓库状态
    scan_global_diff "${groups_array[@]}"
    
    # 5. 执行同步（优先处理缺失的仓库，再处理更新的）
    execute_sync "${groups_array[@]}"
    
    # 6. 构建同步仓库映射（用于清理检查）
    declare -A sync_repos_map
    build_sync_repos_map sync_repos_map
    
    # 7. 清理删除远程已不存在的本地仓库
    cleanup_deleted_repos group_folders sync_repos_map
    
    # 8. 输出最终统计
    print_final_summary
    
    # 9. 显示失败仓库详情
    if [ -n "$ALL_FAILED_LOGS_ARRAY" ]; then
        local -n failed_logs=$ALL_FAILED_LOGS_ARRAY
        print_failed_repos_details failed_logs
    fi
    
    # 10. 比较远程和本地差异，生成详细报告
    if [ -n "$ALL_FAILED_LOGS_ARRAY" ]; then
        local -n failed_logs=$ALL_FAILED_LOGS_ARRAY
        compare_remote_local_diff failed_logs
    else
        declare -a empty_failed_logs=()
        compare_remote_local_diff empty_failed_logs
    fi
}

# 执行主函数
main "$@"
