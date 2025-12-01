#!/bin/bash
# 多行进度条显示模块 - 简化版，兼容 Windows

# 进度显示状态
declare -A PROGRESS_LINES=()  # 任务ID -> 行号
declare -A PROGRESS_STATUS=()  # 任务ID -> 状态文本
declare PROGRESS_NEXT_LINE=0   # 下一个可用行号
declare PROGRESS_ENABLED=1     # 是否启用进度显示

# 初始化进度显示系统
init_progress_display() {
    # 清空之前的状态
    PROGRESS_LINES=()
    PROGRESS_STATUS=()
    PROGRESS_NEXT_LINE=0
    
    # 检查是否在终端中运行（支持进度显示）
    if [ ! -t 2 ]; then
        PROGRESS_ENABLED=0
        return 1
    fi
    
    return 0
}

# 注册一个新任务，返回分配的行号
register_progress_task() {
    local task_id=$1
    local task_name=$2
    
    if [ -z "${PROGRESS_LINES[$task_id]}" ]; then
        PROGRESS_LINES[$task_id]=$PROGRESS_NEXT_LINE
        PROGRESS_STATUS[$task_id]="等待中: $task_name"
        ((PROGRESS_NEXT_LINE++))
    fi
    
    echo "${PROGRESS_LINES[$task_id]}"
}

# 更新任务进度（简化版：使用行号前缀）
update_progress_line() {
    local task_id=$1
    local status_text=$2
    local line_num="${PROGRESS_LINES[$task_id]}"
    
    if [ -z "$line_num" ]; then
        # 如果没有注册，直接输出
        echo "$status_text" >&2
        return
    fi
    
    # 更新状态
    PROGRESS_STATUS[$task_id]="$status_text"
    
    # 使用行号前缀格式化输出（兼容 Windows）
    # 格式: [任务1] 状态信息
    # 注意：每次只输出当前任务的状态，不重新显示所有任务（避免输出过多）
    printf "[任务%02d] %s\n" "$((line_num + 1))" "$status_text" >&2
}

# 显示所有任务的状态（用于调试或最终汇总）
show_all_progress() {
    if [ ${#PROGRESS_STATUS[@]} -eq 0 ]; then
        return
    fi
    
    # 按行号排序显示所有任务状态
    local sorted_task_ids=($(
        for task_id in "${!PROGRESS_LINES[@]}"; do
            echo "${PROGRESS_LINES[$task_id]}|$task_id"
        done | sort -t'|' -k1 -n | cut -d'|' -f2
    ))
    
    for task_id in "${sorted_task_ids[@]}"; do
        local line_num="${PROGRESS_LINES[$task_id]}"
        local status="${PROGRESS_STATUS[$task_id]}"
        if [ -n "$status" ]; then
            printf "[任务%02d] %s\n" "$((line_num + 1))" "$status" >&2
        fi
    done
}

# 解析 git clone/pull 输出，提取进度信息并格式化显示
parse_git_progress() {
    local line="$1"
    local task_id="$2"
    local repo_name="${3:-仓库}"
    
    # 匹配 git clone 进度：Receiving objects: XX% (XX/XX), XX MiB | XX MiB/s
    if [[ "$line" =~ Receiving\ objects:\ ([0-9]+)% ]]; then
        local percent="${BASH_REMATCH[1]}"
        # 提取速度和大小信息
        local size_info=""
        if [[ "$line" =~ ([0-9]+\.[0-9]+\ [KMGT]?i?B) ]]; then
            size_info=" - ${BASH_REMATCH[1]}"
        fi
        update_progress_line "$task_id" "[克隆] ${repo_name}: ${percent}%${size_info}"
        return 0
    fi
    
    # 匹配 git pull 进度：Updating XX..XX
    if [[ "$line" =~ Updating\ ([a-f0-9]+)\.\.([a-f0-9]+) ]]; then
        local from_hash="${BASH_REMATCH[1]:0:8}"
        local to_hash="${BASH_REMATCH[2]:0:8}"
        update_progress_line "$task_id" "[更新] ${repo_name}: ${from_hash}..${to_hash}"
        return 0
    fi
    
    # 匹配 "Cloning into..."
    if [[ "$line" =~ Cloning\ into ]]; then
        update_progress_line "$task_id" "[克隆] ${repo_name}: 开始克隆..."
        return 0
    fi
    
    # 匹配 "remote: Enumerating objects"
    if [[ "$line" =~ remote:\ Enumerating\ objects ]]; then
        update_progress_line "$task_id" "[克隆] ${repo_name}: 枚举对象..."
        return 0
    fi
    
    # 匹配 "remote: Counting objects: XX%"
    if [[ "$line" =~ remote:\ Counting\ objects:\ ([0-9]+)% ]]; then
        local percent="${BASH_REMATCH[1]}"
        update_progress_line "$task_id" "[克隆] ${repo_name}: 计数对象 ${percent}%"
        return 0
    fi
    
    # 匹配 "remote: Compressing objects: XX%"
    if [[ "$line" =~ remote:\ Compressing\ objects:\ ([0-9]+)% ]]; then
        local percent="${BASH_REMATCH[1]}"
        update_progress_line "$task_id" "[克隆] ${repo_name}: 压缩对象 ${percent}%"
        return 0
    fi
    
    return 1
}

# 实时解析并显示 git 输出进度（用于管道处理）
process_git_output_with_progress() {
    local task_id=$1
    local repo_name=$2
    
    # 注册任务（如果还没注册）
    if [ -z "${PROGRESS_LINES[$task_id]}" ]; then
        register_progress_task "$task_id" "$repo_name" >/dev/null
    fi
    
    # 逐行读取并解析
    while IFS= read -r line || [ -n "$line" ]; do
        # 尝试解析进度信息
        if ! parse_git_progress "$line" "$task_id" "$repo_name" 2>/dev/null; then
            # 如果不是进度信息，也尝试匹配其他 git 输出
            if [[ "$line" =~ ^(Cloning|remote:|Receiving|Updating|From|Already|Fast-forward) ]]; then
                parse_git_progress "$line" "$task_id" "$repo_name" 2>/dev/null || true
            fi
        fi
        # 同时输出原始行（用于日志）
        echo "$line"
    done
}

# 清理进度显示（所有任务完成后调用）
cleanup_progress_display() {
    # 清空状态
    PROGRESS_LINES=()
    PROGRESS_STATUS=()
    PROGRESS_NEXT_LINE=0
}

