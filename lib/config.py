# 配置解析模块：解析 REPO-GROUPS.md 配置文件
#
# 主要功能：
#   - parse_repo_groups()：解析配置文件，提取所有分组和仓库信息
#   - get_group_folder()：根据分组名和高地编号生成文件夹路径
#
# 配置文件格式：
#   ## 分组名 <!-- 高地编号 -->
#   - 仓库名1
#   - 仓库名2

import re
from pathlib import Path
from typing import Dict, List, Optional

from lib.logger import log_error
from lib.paths import SCRIPT_DIR, REPOS_DIR

# 默认配置文件
CONFIG_FILE = "REPO-GROUPS.md"

# 仓库所有者（从配置文件提取）
REPO_OWNER: Optional[str] = None


def get_group_folder(group_name: str, highland: Optional[str] = None) -> Path:
    """根据分组名和高地编号生成文件夹路径
    
    格式：组名 (高地编号)
    
    Args:
        group_name: 分组名
        highland: 高地编号（可选）
    
    Returns:
        完整的文件夹路径
    """
    if highland:
        return REPOS_DIR / f"{group_name} ({highland})"
    else:
        return REPOS_DIR / group_name


def parse_repo_groups(config_file: Optional[str] = None) -> List[Dict[str, str]]:
    """解析配置文件，提取分组和仓库信息
    
    Args:
        config_file: 配置文件路径（可选，默认使用 CONFIG_FILE）
    
    Returns:
        任务列表，每个任务包含: repo_full, repo_name, group_folder, group_name, highland
    
    Raises:
        SystemExit: 如果配置文件不存在或未找到仓库所有者
    """
    global REPO_OWNER
    
    if config_file is None:
        config_file = CONFIG_FILE
    
    config_path = Path(config_file)
    
    # 如果配置文件是相对路径，使用项目目录
    if not config_path.is_absolute():
        # 检查是否是 Windows 绝对路径（C:\ 格式）
        if not re.match(r'^[A-Za-z]:', str(config_path)):
            config_path = SCRIPT_DIR / config_path
    
    if not config_path.exists():
        log_error(f"配置文件不存在: {config_path}")
        raise SystemExit(1)
    
    if not config_path.is_file():
        log_error(f"不是有效的文件: {config_path}")
        raise SystemExit(1)
    
    # 读取文件内容
    try:
        content = config_path.read_text(encoding='utf-8')
    except Exception as e:
        log_error(f"读取配置文件失败: {config_path} - {e}")
        raise SystemExit(1)
    
    # 提取仓库所有者（第一行：仓库所有者: xxx）
    owner_match = re.search(r'^仓库所有者:\s*(.+)$', content, re.MULTILINE)
    if not owner_match:
        log_error("未找到仓库所有者信息")
        raise SystemExit(1)
    
    REPO_OWNER = owner_match.group(1).strip()
    
    if not REPO_OWNER:
        log_error("仓库所有者信息为空")
        raise SystemExit(1)
    
    # 正则表达式模式
    # 匹配分组标题：## 分组名 <!-- 高地编号 -->
    group_pattern = re.compile(r'^##\s+(.+?)\s*<!--\s*(.+?)\s*-->')
    # 匹配仓库列表项：- 仓库名
    repo_pattern = re.compile(r'^-\s+(\S+)')
    
    tasks = []
    current_group: Optional[str] = None
    current_highland: Optional[str] = None
    
    # 按行解析
    for line in content.splitlines():
        # 匹配分组标题
        group_match = group_pattern.match(line)
        if group_match:
            current_group = group_match.group(1).strip()
            current_highland = group_match.group(2).strip()
            continue
        
        # 匹配仓库列表项
        repo_match = repo_pattern.match(line)
        if repo_match and current_group:
            repo_name = repo_match.group(1).strip()
            repo_full = f"{REPO_OWNER}/{repo_name}"
            group_folder = get_group_folder(current_group, current_highland)
            
            tasks.append({
                'repo_full': repo_full,
                'repo_name': repo_name,
                'group_folder': str(group_folder),
                'group_name': current_group,
                'highland': current_highland if current_highland else ''
            })
    
    return tasks

