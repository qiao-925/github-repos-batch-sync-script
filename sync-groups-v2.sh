#!/bin/bash
# GitHub 仓库按分组同步脚本
# 
# 注意：此脚本已重构为模块化版本
# 实际实现在 lib/ 目录下的各个模块文件中
# 主入口在 main.sh

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 调用新的模块化主入口
exec "$SCRIPT_DIR/main.sh" "$@"
