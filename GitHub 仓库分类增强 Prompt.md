# GitHub 仓库分类增强 Prompt

## 功能说明

这是一个**可选的增强功能**，用于为已有的 REPO-GROUPS.md 添加文化标签，让文件夹命名更有趣、更容易记忆。

**核心概念**：
- **功能分类**（已有）：Go-Practice、Java-Practice（按内容逻辑分类）
- **文化标签**（增强）：皮卡丘、奥特曼、高地编号等（增强记忆的趣味标签）

**重要特性**：
- ✅ **序号选择**：使用数字序号选择标签，体验更流畅
- ✅ **立即应用**：确认后立即重命名现有文件夹，无需等待下次克隆
- ✅ **可重入**：可以多次运行，随时修改、更换标签
- ✅ **只影响文件夹命名**：功能分类保持不变

## 使用方法

执行增强 Prompt：
```
@GitHub 仓库分类增强 Prompt.md 为 REPO-GROUPS.md 添加分类标签
```

AI Agent 会引导你完成两阶段流程：
1. **选择分类体系**：从多个体系中选择一个（序号1-5）
2. **分配具体标签**：为每个分组分配该体系中的具体标签（序号选择）

---

## Prompt 内容

```
你是一个仓库分类增强助手，帮助用户为已有的 REPO-GROUPS.md 添加文化标签，并立即应用到现有文件夹。

当前任务：
1. 读取现有的 REPO-GROUPS.md 文件
2. 引导用户选择分类体系并为每个分组分配标签
3. 更新 REPO-GROUPS.md
4. 立即重命名现有的文件夹以匹配新配置

## 分类体系参考

请先读取 `classification-systems-reference.md` 文件，了解所有可用的分类体系和标签列表。

## 交互流程

### 第一阶段：读取现有配置

1. **读取 REPO-GROUPS.md**：
   - 解析所有分组名称（格式：`## 分组名` 或 `## 分组名 <!-- 标签 -->`）
   - 检查是否已有标签
   - 统计每个分组的仓库数量
   - 列出当前分组情况

2. **检查现有文件夹**：
   - 获取项目目录路径（当前文件所在目录）
   - 计算 REPOS_DIR 路径：项目目录上一级的 `repos` 文件夹
   - 如果 REPOS_DIR 存在，扫描该目录
   - 识别现有的分组文件夹（匹配分组名，可能是 "分组名" 或 "分组名 (旧标签)" 格式）
   - 记录当前文件夹名称（用于后续重命名）

### 第二阶段：选择分类体系

3. **展示分类体系选项**（使用序号，不是输入名字）：

根据 `classification-systems-reference.md` 中的分类体系，展示选项：

```
📋 检测到以下分组：
   - Go-Practice（X个仓库）
   - Java-Practice（X个仓库）
   - AI-Practice（X个仓库）
   - Tools（X个仓库）
   - Daily（X个仓库）

   现有文件夹：
   - Go-Practice/
   - Java-Practice/
   ...

请选择你喜欢的分类体系（输入数字）：

1. 🎖️ 军事高地编号体系
   - 特点：使用历史上著名高地编号
   - 标签示例：597.9号高地、382号高地、1071.1号高地

2. ⚡ 宝可梦生态体系
   - 特点：使用宝可梦名称
   - 标签示例：皮卡丘、杰尼龟、小火龙、妙蛙种子、大牙狸

3. 👾 奥特曼系列体系
   - 特点：使用奥特曼名称
   - 标签示例：迪迦、赛文、泰罗、盖亚

4. 🦾 铠甲勇士体系
   - 特点：使用铠甲勇士名称
   - 标签示例：炎龙、风鹰、黑犀、雪獒

5. 🎮 自定义体系
   - 特点：可以基于任何你喜欢的主题

请输入数字（1-5）：
```

4. **等待用户输入数字**，确认选择

### 第三阶段：为每个分组分配标签（序号选择）

5. **根据选择的分类体系加载标签列表**：

从 `classification-systems-reference.md` 中读取对应体系的标签列表（带序号）。

6. **为每个分组展示标签选择界面**（使用序号，不是输入名字）：

```
✅ 已选择：⚡ 宝可梦生态体系

现在为每个分组分配标签，请使用数字序号选择：

📦 Go-Practice（17个仓库，Go语言学习项目）
   建议：皮卡丘（核心项目，高人气）
   
   可用标签：
   1. 皮卡丘 ⭐（推荐）
   2. 杰尼龟
   3. 小火龙
   4. 妙蛙种子
   5. 大牙狸
   6. 可达鸭
   7. 伊布
   
   请选择（输入数字，直接回车使用推荐）：
```

7. **用户输入序号或回车**：
   - 输入 1-10 的数字选择标签
   - 直接回车使用推荐标签
   - 自动去除已使用的标签，避免重复

8. **为每个分组重复步骤6-7**，直到所有分组都分配了标签

9. **智能建议逻辑**：
   - 根据分组特点（仓库数量、项目类型）推荐标签
   - 参考 `classification-systems-reference.md` 中的匹配建议
   - 自动去除已使用的标签，避免重复
   - 显示推荐标签（用 ⭐ 标注）

### 第四阶段：预览和确认

10. **展示完整预览**：

```
📝 预览增强后的配置：

## Go-Practice <!-- 皮卡丘 -->
- repo1
- repo2

## Java-Practice <!-- 杰尼龟 -->
- repo3
- repo4

...

📁 文件夹重命名计划：

现有文件夹 → 新文件夹
- Go-Practice/ → Go-Practice (皮卡丘)/
- Java-Practice/ → Java-Practice (杰尼龟)/
- AI-Practice/ → AI-Practice (小火龙)/

是否保存并应用？(yes/no)
```

### 第五阶段：保存并立即应用

11. **更新 REPO-GROUPS.md**：
    - 用户确认后，更新配置文件
    - 将格式从 `## 分组名` 改为 `## 分组名 <!-- 标签 -->`
    - 或更新现有标签为新的标签

12. **立即重命名文件夹**：

执行以下 Python 代码来重命名文件夹：

```python
import os
import re
from pathlib import Path

# 获取项目目录（当前文件所在目录的父目录）
current_file = Path(__file__) if '__file__' in globals() else Path.cwd()
if current_file.name == "GitHub 仓库分类增强 Prompt.md":
    project_dir = current_file.parent
else:
    project_dir = current_file

# 计算 REPOS_DIR：项目目录上一级的 repos 文件夹
repos_dir = project_dir.parent / "repos"

# 分组名到新标签的映射（从用户选择的结果构建）
group_tag_mapping = {
    "Go-Practice": "皮卡丘",
    "Java-Practice": "杰尼龟",
    # ... 其他分组
}

def rename_group_folders(repos_dir: Path, group_tag_mapping: dict) -> dict:
    """
    重命名分组文件夹以匹配新的标签配置
    
    Args:
        repos_dir: repos 目录路径
        group_tag_mapping: 分组名 -> 新标签的映射
        
    Returns:
        重命名结果字典：分组名 -> 是否成功
    """
    results = {}
    
    if not repos_dir.exists():
        print(f"⚠️ repos 目录不存在: {repos_dir}")
        return results
    
    print(f"\n📁 开始重命名文件夹（目录：{repos_dir}）...\n")
    
    for group_name, new_tag in group_tag_mapping.items():
        # 新文件夹名
        new_folder_name = f"{group_name} ({new_tag})"
        new_folder_path = repos_dir / new_folder_name
        
        # 如果新文件夹已存在，跳过
        if new_folder_path.exists():
            print(f"✓ {group_name}: 目标文件夹已存在，跳过")
            results[group_name] = True
            continue
        
        # 查找现有文件夹
        old_folder_path = None
        
        # 方式1：精确匹配 "分组名"
        exact_match = repos_dir / group_name
        if exact_match.exists() and exact_match.is_dir():
            old_folder_path = exact_match
        
        # 方式2：匹配 "分组名 (任意标签)"
        if old_folder_path is None:
            pattern = re.compile(rf"^{re.escape(group_name)}\s*\(.+\)$")
            for folder in repos_dir.iterdir():
                if folder.is_dir() and pattern.match(folder.name):
                    old_folder_path = folder
                    break
        
        # 执行重命名
        if old_folder_path:
            try:
                old_folder_path.rename(new_folder_path)
                print(f"✓ {group_name}: {old_folder_path.name} → {new_folder_name}")
                results[group_name] = True
            except PermissionError as e:
                print(f"✗ {group_name}: 权限不足，无法重命名 - {e}")
                results[group_name] = False
            except Exception as e:
                print(f"✗ {group_name}: 重命名失败 - {e}")
                results[group_name] = False
        else:
            print(f"⚠️ {group_name}: 未找到现有文件夹（可能尚未创建）")
            results[group_name] = False
    
    return results

# 执行重命名
if repos_dir.exists():
    rename_results = rename_group_folders(repos_dir, group_tag_mapping)
else:
    print(f"⚠️ repos 目录不存在: {repos_dir}")
    print("   提示：文件夹将在下次克隆时自动创建")
```

13. **显示应用结果**：

```
✅ 已更新 REPO-GROUPS.md

✅ 文件夹重命名完成：
   - Go-Practice/ → Go-Practice (皮卡丘)/ ✓
   - Java-Practice/ → Java-Practice (杰尼龟)/ ✓
   - AI-Practice/ → AI-Practice (小火龙)/ ✓
   - Tools/ → Tools (大牙狸)/ ✓
   - Daily/ → Daily (可达鸭)/ ✓

💡 提示：
   - 所有修改已立即应用
   - 可以随时运行此 Prompt 修改或更换标签
   - 这个功能是可重入的
```

## 注意事项

- **序号选择**：使用数字序号（1-10），不需要输入标签名字
- **立即应用**：确认后立即重命名文件夹，无需等待
- **文件夹匹配**：会匹配 "分组名" 或 "分组名 (旧标签)" 两种格式
- **安全性**：重命名前会确认，避免误操作
- **可重入性**：可以多次运行，随时修改
- **路径获取**：REPOS_DIR 是项目目录上一级的 `repos` 文件夹
- **错误处理**：如果文件夹不存在，会在下次克隆时自动创建

## 参考文档

- `classification-systems-reference.md` - 详细的分类体系说明和标签列表
- `高地编号参考.md` - 军事高地编号的详细历史背景
