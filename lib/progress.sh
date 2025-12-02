#!/bin/bash
# 进度显示模块：提供简单的进度输出功能
#
# 主要功能：
#   - update_progress_line()：更新任务进度显示（带颜色）

# 注意：颜色常量在 logger.sh 中定义，这里直接使用

# 更新任务进度（自动为"完成"和"失败"添加颜色）
# 参数：
#   $1: status_text（状态文本）
update_progress_line() {
    local status_text=$1
    
    # 确保颜色常量已定义（从 logger.sh 加载）
    local color_reset=${COLOR_RESET:-'\033[0m'}
    local color_green=${COLOR_GREEN:-'\033[0;32m'}
    local color_red=${COLOR_RED:-'\033[0;31m'}
    
    # 检查是否需要添加颜色（整行着色）
    local colored_text="$status_text"
    if [[ "$status_text" =~ 完成: ]] || [[ "$status_text" =~ ✓ ]]; then
        # 整行标为绿色
        colored_text="${color_green}${status_text}${color_reset}"
    elif [[ "$status_text" =~ 失败: ]] || [[ "$status_text" =~ ✗ ]]; then
        # 整行标为红色
        colored_text="${color_red}${status_text}${color_reset}"
    fi
    
    # 直接输出状态信息
    echo -e "$colored_text" >&2
}


