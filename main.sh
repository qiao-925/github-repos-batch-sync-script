#!/bin/bash
# GitHub 仓库按分组同步脚本 - 主入口

# ============================================
# 配置和常量定义
# ============================================
CONFIG_FILE="REPO-GROUPS.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 切换到脚本目录，确保相对路径正确
cd "$SCRIPT_DIR" || {
    echo "错误: 无法切换到脚本目录: $SCRIPT_DIR" >&2
    exit 1
}

# ============================================
# 加载所有模块
# ============================================
# 按依赖顺序加载模块
source "$SCRIPT_DIR/lib/logger.sh"      # 日志输出（无依赖）
source "$SCRIPT_DIR/lib/utils.sh"       # 工具函数（无依赖）
source "$SCRIPT_DIR/lib/progress.sh"    # 进度显示（无依赖）
source "$SCRIPT_DIR/lib/config.sh"      # 配置解析（依赖 logger, utils）
source "$SCRIPT_DIR/lib/cache.sh"       # 缓存初始化（依赖 logger, config）
source "$SCRIPT_DIR/lib/github.sh"      # GitHub API（依赖 logger）
source "$SCRIPT_DIR/lib/repo.sh"        # 仓库操作（依赖 logger, github, utils）
source "$SCRIPT_DIR/lib/stats.sh"       # 统计和报告（依赖 logger, github, repo）
source "$SCRIPT_DIR/lib/sync.sh"        # 同步逻辑（依赖所有其他模块）

# ============================================
# 主函数
# ============================================

main() {
    # 1. 初始化同步环境
    initialize_sync
    
    # 2. 初始化缓存（性能优化：一次性加载所有数据）
    echo ""
    print_step "初始化缓存系统..."
    init_config_cache || exit 1
    init_repo_cache || exit 1
    echo ""
    
    # 3. 列出所有可用分组
    list_groups
    echo ""
    
    # 4. 获取所有分组用于同步（使用缓存）
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
    
    # 5. 全局扫描差异，分析所有仓库状态
    scan_global_diff "${groups_array[@]}"
    
    # 6. 初始化本地仓库缓存（用于后续清理和报告）
    init_local_repo_cache
    
    # 7. 执行同步（优先处理缺失的仓库，再处理更新的）
    execute_sync "${groups_array[@]}"
    
    # 8. 构建同步仓库映射（用于清理检查，使用缓存）
    declare -A sync_repos_map
    build_sync_repos_map sync_repos_map
    
    # 9. 清理删除远程已不存在的本地仓库（使用缓存）
    cleanup_deleted_repos group_folders sync_repos_map
    
    # 10. 输出最终统计
    print_final_summary
    
    # 11. 显示失败仓库详情
    if [ -n "$ALL_FAILED_LOGS_ARRAY" ]; then
        local -n failed_logs=$ALL_FAILED_LOGS_ARRAY
        print_failed_repos_details failed_logs
    fi
    
    # 12. 比较远程和本地差异，生成详细报告
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

