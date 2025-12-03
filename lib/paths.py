# 路径处理模块：提供路径和目录处理功能
#
# 主要功能：
#   - 获取脚本目录（SCRIPT_DIR）
#   - 获取仓库目录（REPOS_DIR）
#   - 获取临时目录（跨平台兼容）

import os
import tempfile
from pathlib import Path
from typing import Optional


def get_script_dir() -> Path:
    """获取脚本所在目录"""
    # 获取当前文件的绝对路径，然后获取其父目录
    return Path(__file__).parent.parent.resolve()


def get_repos_dir() -> Path:
    """获取仓库目录（REPOS_DIR）
    
    仓库目录放在项目目录的上一级（同级目录）
    SCRIPT_DIR 已经是项目目录，所以上一级是 SCRIPT_DIR/..
    """
    script_dir = get_script_dir()
    # 上一级目录的 repos 子目录
    return script_dir.parent / "repos"


def get_temp_dir() -> Path:
    """获取临时目录（跨平台兼容）
    
    优先使用系统临时目录（TMP 或 TEMP 环境变量），
    如果不存在则使用项目目录下的 .tmp 目录
    """
    # 尝试获取系统临时目录
    temp_dir = os.environ.get('TMP') or os.environ.get('TEMP')
    if temp_dir and Path(temp_dir).exists():
        return Path(temp_dir)
    
    # 回退到系统默认临时目录
    try:
        return Path(tempfile.gettempdir())
    except (OSError, AttributeError):
        pass
    
    # 最后回退到项目目录下的 .tmp
    script_dir = get_script_dir()
    tmp_dir = script_dir / ".tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    return tmp_dir


# 全局路径常量
SCRIPT_DIR = get_script_dir()
REPOS_DIR = get_repos_dir()

