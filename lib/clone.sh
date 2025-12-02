#!/bin/bash
# 仓库克隆模块：实现单个仓库的克隆操作
#
# 主要功能：
#   - clone_repo()：克隆单个仓库，使用 Git 并行传输参数和优化配置
#
# 特性：
#   - 自动选择最优协议（SSH 优先，回退到 HTTPS）
#   - Git 配置优化（网络、压缩、多线程）
#   - 直接克隆，不检查是否存在（覆盖）
#   - 失败时输出错误信息

# 检测并选择最优协议（SSH 优先，回退到 HTTPS）
get_repo_url() {
    local repo_full="$1"
    
    # 检测 SSH 是否可用（静默检测，避免输出干扰）
    if ssh -o BatchMode=yes -o ConnectTimeout=2 -T git@github.com 2>&1 | grep -q "successfully authenticated" 2>/dev/null; then
        echo "git@github.com:${repo_full}.git"
    else
        echo "https://github.com/${repo_full}.git"
    fi
}

# 获取 CPU 核心数
get_cpu_cores() {
    local cores
    if command -v nproc >/dev/null 2>&1; then
        cores=$(nproc)
    elif [[ -f /proc/cpuinfo ]]; then
        cores=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo 8)
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
    else
        cores=8  # 默认值
    fi
    # 确保至少为 1
    [[ $cores -lt 1 ]] && cores=8
    echo "$cores"
}

# 克隆单个仓库
# 参数：
#   $1: repo_full (格式：owner/repo)
#   $2: repo_name (仓库名)
#   $3: group_folder (目标文件夹路径)
#   $4: parallel_connections (并行连接数，默认 8)
clone_repo() {
    # 禁用错误退出，让调用者处理错误
    set +e
    local repo_full="$1"
    local repo_name="$2"
    local group_folder="$3"
    local parallel_connections="${4:-8}"
    
    if [[ -z "$repo_full" || -z "$repo_name" || -z "$group_folder" ]]; then
        log_error "clone_repo: 参数不完整"
        set -e
        return 1
    fi
    
    # 构建目标路径
    local target_path="${group_folder}/${repo_name}"
    
    # 如果目录已存在，先删除（直接覆盖）
    if [[ -d "$target_path" ]]; then
        log_info "删除已存在的目录: $target_path"
        rm -rf "$target_path"
    fi
    
    # 确保目标文件夹的父目录存在
    mkdir -p "$group_folder"
    
    # 获取最优仓库 URL（SSH 优先，回退到 HTTPS）
    local repo_url=$(get_repo_url "$repo_full")
    local cpu_cores=$(get_cpu_cores)
    
    # 执行克隆，使用优化的 Git 配置和并行传输参数
    log_info "开始克隆: $repo_full -> $target_path"
    
    # 使用优化的 Git 配置执行克隆
    # -c 参数临时设置配置，不影响全局 Git 配置
    if git -c http.postBuffer=524288000 \
           -c http.lowSpeedLimit=0 \
           -c http.lowSpeedTime=0 \
           -c http.version=HTTP/2 \
           -c pack.windowMemory=1073741824 \
           -c pack.threads="$cpu_cores" \
           -c core.compression=1 \
           clone --progress --jobs "$parallel_connections" "$repo_url" "$target_path"; then
        log_success "克隆成功: $repo_full"
        set -e
        return 0
    else
        log_error "克隆失败: $repo_full"
        # 如果克隆失败，清理不完整的目录
        if [[ -d "$target_path" ]]; then
            rm -rf "$target_path"
        fi
        set -e
        return 1
    fi
}
