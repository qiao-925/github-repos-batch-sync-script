#!/bin/bash
# 日志输出模块

# 获取时间戳
_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 带时间戳的日志函数（输出到 stderr，避免被命令替换捕获）
print_info() {
    echo "[$(_get_timestamp)] ℹ️  $1" >&2
}

print_warning() {
    echo "[$(_get_timestamp)] ⚠️  $1" >&2
}

print_error() {
    echo "[$(_get_timestamp)] ❌ $1" >&2
}

print_success() {
    echo "[$(_get_timestamp)] ✅ $1" >&2
}

print_debug() {
    : # Debug 模式已关闭
}

print_step() {
    echo "[$(_get_timestamp)] ➜  $1" >&2
}

# 高亮日志函数（用于强调关键操作，如开始克隆/更新）
# 支持 -n 参数（不换行）
# 使用图标突出显示
print_highlight() {
    if [ "$1" = "-n" ]; then
        shift
        echo -n "🔹 $*" >&2
    else
        echo "🔹 $*" >&2
    fi
}

# 计算时间差（兼容 Windows，不依赖 bc）
_calculate_duration() {
    local start=$1
    local end=$2
    
    # 提取整数部分和小数部分
    local start_int=${start%.*}
    local start_frac=${start#*.}
    local end_int=${end%.*}
    local end_frac=${end#*.}
    
    # 如果没有小数部分，使用整数秒
    if [ -z "$start_frac" ] || [ "$start_frac" = "$start" ]; then
        local duration=$((end_int - start_int))
        echo "$duration"
        return 0
    fi
    
    # 有小数部分，尝试精确计算
    if command -v bc >/dev/null 2>&1; then
        local duration=$(echo "scale=2; $end - $start" | bc 2>/dev/null)
        if [ -n "$duration" ]; then
            echo "$duration"
            return 0
        fi
    fi
    
    # 回退到整数秒计算
    local duration=$((end_int - start_int))
    echo "$duration"
}

# API 调用日志函数（带计时）
# 参数: operation_description command [args...]
# 用法: log_api_call "获取仓库列表" gh repo list --limit 1000
log_api_call() {
    local description="$1"
    shift
    
    print_info "🌐 [API调用] 开始: $description"
    
    # 获取开始时间（尝试高精度，回退到秒）
    local start_time
    if date +%s.%N &>/dev/null; then
        start_time=$(date +%s.%N)
    else
        start_time=$(date +%s)
    fi
    
    # 执行命令并捕获输出和退出码
    local output
    local exit_code
    output=$("$@" 2>&1)
    exit_code=$?
    
    # 获取结束时间
    local end_time
    if date +%s.%N &>/dev/null; then
        end_time=$(date +%s.%N)
    else
        end_time=$(date +%s)
    fi
    
    local duration=$(_calculate_duration "$start_time" "$end_time")
    
    if [ "$exit_code" -eq 0 ]; then
        print_success "✅ [API调用] 完成: $description (耗时: ${duration}秒)"
    else
        print_error "❌ [API调用] 失败: $description (耗时: ${duration}秒, 退出码: $exit_code)"
        if [ -n "$output" ]; then
            # 限制错误信息长度，避免输出过长
            local error_msg="${output:0:200}"
            if [ ${#output} -gt 200 ]; then
                error_msg="${error_msg}..."
            fi
            print_error "   错误信息: $error_msg"
        fi
    fi
    
    # 返回命令的输出（用于进一步处理）
    echo "$output"
    return $exit_code
}

# 简化版 API 调用日志（不捕获输出，只记录开始和结束）
# 用于长时间运行的命令（如 git clone/pull）
log_api_call_simple() {
    local description="$1"
    shift
    
    print_info "🌐 [外部调用] 开始: $description"
    
    # 获取开始时间
    local start_time
    if date +%s.%N &>/dev/null; then
        start_time=$(date +%s.%N)
    else
        start_time=$(date +%s)
    fi
    
    # 执行命令
    "$@"
    local exit_code=$?
    
    # 获取结束时间
    local end_time
    if date +%s.%N &>/dev/null; then
        end_time=$(date +%s.%N)
    else
        end_time=$(date +%s)
    fi
    
    local duration=$(_calculate_duration "$start_time" "$end_time")
    
    if [ "$exit_code" -eq 0 ]; then
        print_success "✅ [外部调用] 完成: $description (耗时: ${duration}秒)"
    else
        print_error "❌ [外部调用] 失败: $description (耗时: ${duration}秒, 退出码: $exit_code)"
    fi
    
    return $exit_code
}

