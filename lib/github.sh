#!/bin/bash
# GitHub API 操作模块

# 缓存 GitHub 用户名（避免重复调用 API）
_GITHUB_USER_CACHE=""

# 获取 GitHub 用户名（带缓存）
get_github_username() {
    if [ -z "$_GITHUB_USER_CACHE" ]; then
        _GITHUB_USER_CACHE=$(log_api_call "获取 GitHub 用户信息" gh api user --jq '.login' 2>/dev/null || echo "")
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

# 获取仓库详细信息（返回 JSON 字符串）
get_repo_info() {
    local repo_full=$1
    # 使用 gh repo view 获取仓库信息，失败时返回空
    log_api_call "获取仓库详细信息: $repo_full" gh repo view "$repo_full" --json \
        name,description,language,stargazerCount,forkCount,updatedAt,isArchived,isPrivate 2>/dev/null || echo ""
}

# 从 JSON 中提取字段值（支持字符串和数字）
extract_json_field() {
    local json=$1
    local field=$2
    
    # 优先使用 jq（如果可用）
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r ".$field // empty" 2>/dev/null && return 0
    fi
    
    # 回退到简单的字符串匹配（提取字符串值）
    local value=$(echo "$json" | grep -o "\"$field\":\"[^\"]*\"" | sed "s/\"$field\":\"\([^\"]*\)\"/\1/" 2>/dev/null)
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    # 尝试提取数字字段
    value=$(echo "$json" | grep -o "\"$field\":[0-9]*" | sed "s/\"$field\":\([0-9]*\)/\1/" 2>/dev/null)
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    # 尝试提取 null
    echo "$json" | grep -o "\"$field\":null" >/dev/null 2>&1 && echo "" && return 0
    
    echo ""
}

# 从 JSON 中提取数字字段值（兼容函数，内部调用 extract_json_field）
extract_json_number() {
    local json=$1
    local field=$2
    local value=$(extract_json_field "$json" "$field")
    echo "${value:-0}"
}

