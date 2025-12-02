#!/bin/bash
# GitHub API 查询模块：提供 GitHub API 相关的查询功能
#
# 主要功能：
#   - get_github_username()：获取 GitHub 用户名（带缓存）
#   - init_github_connection()：初始化 GitHub 连接（SSH、Git 配置优化）
#   - find_repo_full_name()：查找仓库完整名称（使用缓存优化）
#
# 优化特性：
#   - Git 配置优化：针对高并发和快速克隆进行优化
#   - 并行传输配置：充分利用 CPU 和网络带宽
#   - 参考 Cursor IDE 的快速同步技术进行优化
#   - 用户名缓存：避免重复 API 调用

# 缓存 GitHub 用户名（避免重复调用 API）
_GITHUB_USER_CACHE=""

# 获取 GitHub 用户名（带缓存）
get_github_username() {
    if [ -z "$_GITHUB_USER_CACHE" ]; then
        _GITHUB_USER_CACHE=$(log_api_call "获取 GitHub 用户信息" gh api user --jq '.login' 2>/dev/null || echo "")
    fi
    echo "$_GITHUB_USER_CACHE"
}

# 常量定义
readonly GIT_POST_BUFFER_SIZE=524288000      # HTTP POST 缓冲区大小（500MB）
readonly GIT_PACK_WINDOW_MEMORY=1073741824   # Pack 窗口内存（1GB）
readonly GIT_DEFAULT_CPU_CORES=4             # 默认 CPU 核心数（如果无法检测）

# 初始化 GitHub 连接（配置 SSH 密钥和 Git 网络优化）
init_github_connection() {
    # 添加 GitHub 主机密钥（如果需要）
    if [ ! -f ~/.ssh/known_hosts ] || ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        mkdir -p ~/.ssh
        ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true
    fi
    
    # Git 网络优化配置（针对高带宽环境）
    # 这些配置可以显著提升克隆速度，特别是在高带宽环境下
    print_info "配置 Git 网络优化参数..."
    
    # http.postBuffer: 增加 HTTP POST 缓冲区大小（默认 1MB，增加到 500MB）
    # 对于大仓库，更大的缓冲区可以减少网络往返次数，提升传输效率
    local post_buffer_mb=$((GIT_POST_BUFFER_SIZE / 1024 / 1024))
    git config --global http.postBuffer "$GIT_POST_BUFFER_SIZE" 2>/dev/null || true
    print_info "  - http.postBuffer: ${post_buffer_mb}MB"
    
    # http.lowSpeedLimit 和 http.lowSpeedTime: 降低低速传输阈值
    # 避免在高速网络下被误判为低速连接而中断
    git config --global http.lowSpeedLimit 0 2>/dev/null || true
    git config --global http.lowSpeedTime 0 2>/dev/null || true
    print_info "  - http.lowSpeedLimit: 0"
    print_info "  - http.lowSpeedTime: 0"
    
    # http.version: 使用 HTTP/2（如果支持）
    # HTTP/2 支持多路复用，可以更高效地利用带宽
    git config --global http.version HTTP/2 2>/dev/null || true
    print_info "  - http.version: HTTP/2"
    
    # pack.windowMemory: 增加 pack 窗口内存（默认 256MB，增加到 1GB）
    # 更大的窗口可以更高效地压缩和传输数据
    local window_memory_gb=$((GIT_PACK_WINDOW_MEMORY / 1024 / 1024 / 1024))
    git config --global pack.windowMemory "$GIT_PACK_WINDOW_MEMORY" 2>/dev/null || true
    print_info "  - pack.windowMemory: ${window_memory_gb}GB"
    
    # pack.threads: 使用多线程进行 pack 操作（默认自动，显式设置为 CPU 核心数）
    # 充分利用多核 CPU 加速压缩和解压
    local cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "$GIT_DEFAULT_CPU_CORES")
    git config --global pack.threads "$cpu_cores" 2>/dev/null || true
    print_info "  - pack.threads: $cpu_cores"
    
    # core.compression: 使用更快的压缩级别（0-9，默认 6，改为 1 以速度优先）
    # 在高速网络下，压缩时间可能成为瓶颈，降低压缩级别可以提升速度
    git config --global core.compression 1 2>/dev/null || true
    print_info "  - core.compression: 1"
    
    print_success "Git 网络优化配置完成"
}

# 查找仓库的完整名称（owner/repo）- 使用缓存优化
find_repo_full_name() {
    local repo_name=$1
    
    # 先查缓存
    if [ -n "${REPO_FULL_NAME_CACHE[$repo_name]}" ]; then
        echo "${REPO_FULL_NAME_CACHE[$repo_name]}"
        return 0
    fi
    
    # 缓存未命中，尝试通过 API 查找（应该很少发生）
    local repo_owner=$(get_github_username)
    
    if [ -z "$repo_owner" ]; then
        return 1
    fi
    
    local repo_full="$repo_owner/$repo_name"
    # 使用日志记录 API 调用
    if log_api_call "查找仓库完整名称: $repo_name" gh repo view "$repo_full" &>/dev/null; then
        # 缓存结果
        REPO_FULL_NAME_CACHE["$repo_name"]="$repo_full"
        echo "$repo_full"
        return 0
    else
        return 1
    fi
}

# 获取仓库大小（KB）- 使用缓存优化
# 参数：
#   $1: 仓库完整名称（owner/repo）
# 返回：
#   仓库大小（KB），如果获取失败则返回 0
get_repo_size() {
    local repo_full=$1
    
    # 先查缓存（如果存在）
    if [ -n "${REPO_SIZE_CACHE[$repo_full]}" ]; then
        echo "${REPO_SIZE_CACHE[$repo_full]}"
        return 0
    fi
    
    # 通过 API 获取仓库大小（单位：KB）
    local size=$(log_api_call "获取仓库大小: $repo_full" \
        gh api "repos/$repo_full" --jq '.size' 2>/dev/null || echo "0")
    
    # 验证大小是否为有效数字
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 0 ]; then
        # 缓存结果
        REPO_SIZE_CACHE["$repo_full"]="$size"
        echo "$size"
        return 0
    else
        # 获取失败，返回 0
        echo "0"
        return 1
    fi
}

# 格式化仓库大小显示
# 参数：
#   $1: 大小（KB）
# 返回：
#   格式化后的大小字符串（如 "1.5 GB"、"500 MB"）
format_repo_size() {
    local size_kb=$1
    
    if [ -z "$size_kb" ] || [ "$size_kb" -eq 0 ]; then
        echo "0 MB"
        return 0
    fi
    
    # 转换为 MB 和 GB
    local size_mb=$((size_kb / 1024))
    local size_gb=$((size_kb / 1024 / 1024))
    
    if [ "$size_gb" -ge 1 ]; then
        # 显示 GB（保留 2 位小数）
        local gb_decimal=$(awk "BEGIN {printf \"%.2f\", $size_kb / 1024 / 1024}")
        echo "${gb_decimal} GB"
    else
        # 显示 MB（保留 2 位小数）
        local mb_decimal=$(awk "BEGIN {printf \"%.2f\", $size_kb / 1024}")
        echo "${mb_decimal} MB"
    fi
}


