#!/bin/bash
# GitHub 仓库批量克隆脚本：极简设计，专注于核心功能
#
# 主要功能：
#   - 解析命令行参数（-t 并行任务数，-c 并行传输数）
#   - 读取并解析 REPO-GROUPS.md 配置文件
#   - 并行批量克隆所有仓库
#   - 输出最终统计报告
#
# 执行流程：
#   1. 解析命令行参数
#   2. 加载配置文件
#   3. 构建克隆任务列表
#   4. 并行执行克隆
#   5. 输出统计报告
#
# 特性：
#   - 双重并行：应用层并行（-t） + Git 层并行传输（-c）
#   - 直接覆盖：不检查仓库是否存在，直接克隆

set -euo pipefail

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 加载模块
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/clone.sh"

# 默认参数
PARALLEL_TASKS=5      # 并行任务数（应用层）
PARALLEL_CONNECTIONS=8 # 并行传输数（Git 层）

# 任务列表文件（可选）
TASK_LIST_FILE=""     # 如果指定，从文件读取任务列表；否则从 REPO-GROUPS.md 解析
FAILED_REPOS_FILE="${SCRIPT_DIR}/failed-repos.txt"  # 失败列表文件

# 统计变量
TOTAL_REPOS=0
SUCCESS_COUNT=0
FAIL_COUNT=0
START_TIME=$(date +%s)

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--tasks)
                PARALLEL_TASKS="$2"
                shift 2
                ;;
            -c|--connections)
                PARALLEL_CONNECTIONS="$2"
                shift 2
                ;;
            -f|--file)
                TASK_LIST_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 验证参数
    if ! [[ "$PARALLEL_TASKS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_TASKS" -lt 1 ]]; then
        log_error "并行任务数必须是正整数: $PARALLEL_TASKS"
        exit 1
    fi
    
    if ! [[ "$PARALLEL_CONNECTIONS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_CONNECTIONS" -lt 1 ]]; then
        log_error "并行传输数必须是正整数: $PARALLEL_CONNECTIONS"
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
GitHub 仓库批量克隆脚本

用法: $0 [选项]

选项:
  -t, --tasks NUM          并行任务数（同时克隆的仓库数量，默认: 5）
  -c, --connections NUM    并行传输数（每个仓库的 Git 连接数，默认: 8）
  -f, --file FILE          指定任务列表文件（REPO-GROUPS.md 格式）
                           如果不指定，默认从 REPO-GROUPS.md 解析
  -h, --help               显示此帮助信息

示例:
  $0                        # 使用默认参数，从 REPO-GROUPS.md 解析所有仓库
  $0 -t 10 -c 16            # 并行任务数 10，并行传输数 16
  $0 -f failed-repos.txt    # 从失败列表文件重新执行失败的仓库
  $0 -f custom-list.txt     # 从自定义列表文件执行

任务列表文件格式（REPO-GROUPS.md 格式）:
  # GitHub 仓库分组
  仓库所有者: owner
  ## 分组名 <!-- 高地编号 -->
  - 仓库名1
  - 仓库名2

执行完成后，失败的仓库会自动保存到 failed-repos.txt（REPO-GROUPS.md 格式）
EOF
}

# 执行单个克隆任务（用于并行调用）
execute_clone_task() {
    # 在子shell中执行，禁用错误退出，避免影响主进程
    set +e
    local task="$1"
    local parallel_connections="$2"
    
    # 解析任务：repo_full|repo_name|group_folder|group_name
    IFS='|' read -r repo_full repo_name group_folder group_name <<< "$task"
    
    # 执行克隆，日志会直接输出
    if clone_repo "$repo_full" "$repo_name" "$group_folder" "$parallel_connections"; then
        return 0
    else
        return 1
    fi
}

# 并行执行克隆任务
execute_parallel_clone() {
    local tasks=("$@")
    local total="${#tasks[@]}"
    
    if [[ $total -eq 0 ]]; then
        log_warning "没有需要克隆的仓库"
        return 0
    fi
    
    log_info "开始批量克隆，共 $total 个仓库"
    log_info "并行任务数: $PARALLEL_TASKS, 并行传输数: $PARALLEL_CONNECTIONS"
    
    # 使用结果文件收集所有任务的结果
    # Windows 兼容：使用环境变量或项目目录
    local tmp_dir="${TMP:-${TEMP:-/tmp}}"
    if [[ ! -d "$tmp_dir" ]]; then
        tmp_dir="${SCRIPT_DIR}/.tmp"
        mkdir -p "$tmp_dir"
    fi
    local result_file="${tmp_dir}/clone_results_$$.txt"
    > "$result_file"  # 清空结果文件
    
    # 使用后台进程 + wait 实现并行控制
    local running=0
    local task_index=0
    local pids=()
    
    # 临时禁用错误退出，避免算术运算失败导致脚本退出
    set +e
    
    while [[ $task_index -lt $total ]] || [[ $running -gt 0 ]]; do
        # 启动新任务（如果还有未处理的任务且未达到并发限制）
        while [[ $running -lt $PARALLEL_TASKS ]] && [[ $task_index -lt $total ]]; do
            local task="${tasks[$task_index]}"
            
            # 在后台执行克隆任务
            # 使用子shell并禁用错误退出，避免后台进程错误导致主脚本退出
            # 直接执行，不使用命令替换，让 Git 的输出实时显示
            # 注意：后台进程的输出会直接显示在终端，但可能因为并行执行而交错
            (
                set +e
                # 捕获当前任务索引和任务信息（在子shell启动时）
                local current_index=$task_index
                local current_task="$task"
                # 直接执行，输出直接到终端（实时显示）
                # 不重定向任何输出，让 Git 的 stdout 和 stderr 都正常显示
                execute_clone_task "$current_task" "$PARALLEL_CONNECTIONS"
                local exit_code=$?
                # 写入结果时包含任务索引和任务信息，格式：索引|结果|任务信息
                if [[ $exit_code -eq 0 ]]; then
                    echo "${current_index}|SUCCESS|${current_task}" >> "$result_file"
                else
                    echo "${current_index}|FAIL|${current_task}" >> "$result_file"
                fi
            ) &
            
            local pid=$!
            pids+=("$pid")
            ((task_index++)) || true
            ((running++)) || true
        done
        
        # 检查已完成的任务
        local new_pids=()
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            else
                # 任务完成
                wait "$pid" 2>/dev/null || true
                ((running--)) || running=0
            fi
        done
        pids=("${new_pids[@]}")
        
        # 短暂休眠，避免 CPU 占用过高
        sleep 0.1
    done
    
    # 等待所有任务完成
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    # 恢复错误退出
    set -e
    
    # 统计结果并记录失败的仓库（保存为 REPO-GROUPS.md 格式）
    if [[ -f "$result_file" ]]; then
        > "$FAILED_REPOS_FILE"  # 清空失败列表
        
        # 使用关联数组按分组组织失败的仓库
        declare -A group_highlands  # 分组 -> 高地编号
        declare -A group_repos     # 分组 -> 仓库列表（用换行符分隔）
        
        # 创建临时文件存储排序后的结果
        local sorted_result_file="${tmp_dir}/clone_results_sorted_$$.txt"
        # 按第一列（任务索引）排序
        if sort -t'|' -k1 -n "$result_file" > "$sorted_result_file" 2>/dev/null; then
            # 如果排序成功，使用排序后的文件
            local result_source="$sorted_result_file"
        else
            # 如果排序失败，直接使用原文件（兼容旧格式）
            local result_source="$result_file"
        fi
        
        # 按任务索引顺序统计
        while IFS='|' read -r task_idx result task_info; do
            # 兼容处理：如果读取的格式不对（可能是旧格式只有结果），重新解析
            # 新格式应该是：数字|SUCCESS|... 或 数字|FAIL|...
            # 旧格式可能是：SUCCESS 或 FAIL
            if [[ "$task_idx" == "SUCCESS" || "$task_idx" == "FAIL" ]]; then
                # 这是旧格式，只有结果，没有索引和任务信息
                result="$task_idx"
                task_idx=""
                task_info=""
            fi
            
            if [[ "$result" == "SUCCESS" ]]; then
                ((SUCCESS_COUNT++)) || true
            elif [[ "$result" == "FAIL" ]]; then
                ((FAIL_COUNT++)) || true
                # 解析失败的仓库信息
                if [[ -n "$task_info" ]]; then
                    # 使用任务信息中的完整信息
                    IFS='|' read -r repo_full repo_name group_folder group_name <<< "$task_info"
                    
                    # 如果 REPO_OWNER 未设置，从 repo_full 中提取
                    if [[ -z "${REPO_OWNER:-}" ]] && [[ "$repo_full" =~ ^([^/]+)/ ]]; then
                        REPO_OWNER="${BASH_REMATCH[1]}"
                    fi
                    
                    # 从 group_folder 中提取高地编号
                    local highland=""
                    local highland_pattern='\(([^)]+)\)'
                    if [[ "$group_folder" =~ $highland_pattern ]]; then
                        highland="${BASH_REMATCH[1]}"
                    fi
                    
                    # 存储分组信息
                    if [[ -z "${group_highlands[$group_name]:-}" ]]; then
                        group_highlands[$group_name]="$highland"
                    fi
                    
                    # 添加仓库到分组
                    if [[ -z "${group_repos[$group_name]:-}" ]]; then
                        group_repos[$group_name]="$repo_name"
                    else
                        group_repos[$group_name]="${group_repos[$group_name]}"$'\n'"$repo_name"
                    fi
                elif [[ -n "$task_idx" ]] && [[ "$task_idx" =~ ^[0-9]+$ ]] && [[ $task_idx -lt $total ]]; then
                    # 兼容处理：如果有索引但没有任务信息，从任务数组获取
                    local task="${tasks[$task_idx]}"
                    IFS='|' read -r repo_full repo_name group_folder group_name <<< "$task"
                    
                    # 如果 REPO_OWNER 未设置，从 repo_full 中提取
                    if [[ -z "${REPO_OWNER:-}" ]] && [[ "$repo_full" =~ ^([^/]+)/ ]]; then
                        REPO_OWNER="${BASH_REMATCH[1]}"
                    fi
                    
                    # 从 group_folder 中提取高地编号
                    local highland=""
                    local highland_pattern='\(([^)]+)\)'
                    if [[ "$group_folder" =~ $highland_pattern ]]; then
                        highland="${BASH_REMATCH[1]}"
                    fi
                    
                    # 存储分组信息
                    if [[ -z "${group_highlands[$group_name]:-}" ]]; then
                        group_highlands[$group_name]="$highland"
                    fi
                    
                    # 添加仓库到分组
                    if [[ -z "${group_repos[$group_name]:-}" ]]; then
                        group_repos[$group_name]="$repo_name"
                    else
                        group_repos[$group_name]="${group_repos[$group_name]}"$'\n'"$repo_name"
                    fi
                fi
            fi
        done < "$result_source"
        
        # 清理临时文件
        if [[ "$sorted_result_file" != "$result_file" ]] && [[ -f "$sorted_result_file" ]]; then
            rm -f "$sorted_result_file"
        fi
        rm -f "$result_file"
        
        # 如果有失败的仓库，生成 REPO-GROUPS.md 格式的文件
        if [[ $FAIL_COUNT -gt 0 ]] && [[ ${#group_repos[@]} -gt 0 ]]; then
            # 写入文件头部
            echo "# GitHub 仓库分组" >> "$FAILED_REPOS_FILE"
            echo "" >> "$FAILED_REPOS_FILE"
            echo "仓库所有者: ${REPO_OWNER:-qiao-925}" >> "$FAILED_REPOS_FILE"
            echo "" >> "$FAILED_REPOS_FILE"
            
            # 按分组输出
            for group_name in "${!group_repos[@]}"; do
                local highland="${group_highlands[$group_name]}"
                
                # 输出分组标题
                if [[ -n "$highland" ]]; then
                    echo "## $group_name <!-- $highland -->" >> "$FAILED_REPOS_FILE"
                else
                    echo "## $group_name" >> "$FAILED_REPOS_FILE"
                fi
                
                # 输出仓库列表
                IFS=$'\n' read -ra repo_array <<< "${group_repos[$group_name]}"
                for repo in "${repo_array[@]}"; do
                    if [[ -n "$repo" ]]; then
                        echo "- $repo" >> "$FAILED_REPOS_FILE"
                    fi
                done
                echo "" >> "$FAILED_REPOS_FILE"
            done
            
            log_warning "有 $FAIL_COUNT 个仓库克隆失败"
            log_info "失败列表已保存到: $FAILED_REPOS_FILE（REPO-GROUPS.md 格式）"
            log_info "可以使用以下命令重新执行失败的仓库:"
            log_info "  bash main.sh -f $FAILED_REPOS_FILE"
        fi
    else
        log_warning "结果文件不存在: $result_file"
    fi
    
    log_info "并行克隆执行完成，成功: $SUCCESS_COUNT, 失败: $FAIL_COUNT"
}

# 输出最终统计
print_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    echo ""
    log_info "========== 克隆完成 =========="
    log_info "总仓库数: $TOTAL_REPOS"
    log_success "成功: $SUCCESS_COUNT"
    
    if [[ $FAIL_COUNT -gt 0 ]]; then
        log_error "失败: $FAIL_COUNT"
    else
        log_info "失败: $FAIL_COUNT"
    fi
    
    log_info "耗时: ${hours}小时 ${minutes}分钟 ${seconds}秒"
    log_info "=============================="
}

# 主函数
main() {
    log_info "GitHub 仓库批量克隆脚本启动"
    
    # 解析命令行参数
    parse_args "$@"
    
    # 获取任务列表
    local tasks
    
    if [[ -n "$TASK_LIST_FILE" ]]; then
        # 从指定文件读取任务列表（统一用 parse_repo_groups 解析 REPO-GROUPS.md 格式）
        if [[ ! -f "$TASK_LIST_FILE" ]]; then
            log_error "任务列表文件不存在: $TASK_LIST_FILE"
            exit 1
        fi
        log_info "从文件读取任务列表: $TASK_LIST_FILE"
        mapfile -t tasks < <(parse_repo_groups "$TASK_LIST_FILE")
    else
        # 默认从配置文件解析
        log_info "解析配置文件: $CONFIG_FILE"
        mapfile -t tasks < <(parse_repo_groups)
    fi
    
    if [[ ${#tasks[@]} -eq 0 ]]; then
        log_error "未找到任何仓库任务"
        exit 1
    fi
    
    TOTAL_REPOS=${#tasks[@]}
    log_info "找到 $TOTAL_REPOS 个仓库任务"
    
    # 执行并行克隆
    execute_parallel_clone "${tasks[@]}"
    
    # 输出统计
    print_summary
    
    # 返回退出码
    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# 执行主函数
main "$@"

