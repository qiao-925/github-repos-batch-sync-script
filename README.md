# GitHub 仓库批量分类克隆脚本

**批量克隆 GitHub 仓库**，采用**双重并行加速**技术（应用层多仓库并发 + Git 层多连接传输），大幅提升克隆速度。结合独特的**军事高地编号体系**，实现仓库的智能分类与高效管理。

## 一、🚀 快速开始

1. **安装 GitHub CLI**（如果未安装）：
   ```bash
   # Windows (使用 Chocolatey)
   choco install gh
   
   # macOS (使用 Homebrew)
   brew install gh
   
   # Linux
   # 参考: https://cli.github.com/
   ```

2. **登录认证**：
   ```bash
   gh auth login
   ```

3. **创建分类文档**（使用 AI 辅助）：
   - 打开 `GitHub 仓库分类 Prompt.md`
   - 在 Cursor 中执行：`@GitHub 仓库分类 Prompt.md 执行当前prompt`
   - 确认后保存为 `REPO-GROUPS.md`

4. **开始克隆**：
   ```bash
   # 使用默认参数，从 REPO-GROUPS.md 解析所有仓库
   bash main.sh
   
   # 如果有失败的仓库，会自动生成 failed-repos.txt
   # 可以重新执行失败的仓库
   bash main.sh -f failed-repos.txt
   ```

## 二、🎯 核心特点

### 🚀 一键批量克隆
**核心功能**：自动扫描所有分组，批量克隆所有仓库，无需手动逐个操作。

### ⚡ 双重并行加速
**性能优势**：应用层并行（同时克隆多个仓库，默认 5 并发）+ Git 层并行传输（每个仓库多连接，默认 8 连接），双重叠加充分利用网络带宽，大幅提升克隆速度。

### 🚀 智能协议选择与 Git 优化
**性能优化**：自动选择最优协议（SSH 优先，回退到 HTTPS）+ Git 配置优化（HTTP/2、大缓冲区、多线程压缩），在高带宽环境下可提升 25-55% 的克隆速度。

### 📁 高效组织管理
**清晰结构**：每个分组自动创建独立文件夹（格式：`组名 (高地编号)`），所有仓库按分组清晰组织。

### ⚔️ 军事高地编号体系
**独特特色**：使用历史上著名高地编号（如 `597.9高地`、`382高地`）作为分组代号，以"攻占高地"的心态专注管理项目，增强记忆和识别度。

### 🎯 极简设计
**设计理念**：保持极简，只保留核心功能，去除所有非必要的复杂逻辑，易于理解和维护。

### 📝 任务列表文件支持
**灵活控制**：支持从文件读取任务列表，可以执行全量仓库、失败列表或自定义列表。脚本不关心输入来源，只负责执行任务列表，保持纯粹性。

## 三、⚙️ 自定义参数

### 并发参数配置

脚本支持以下参数：

- **`-t, --tasks NUM`**：并行任务数（同时克隆的仓库数量，默认: 5）
- **`-c, --connections NUM`**：并行传输数（每个仓库的 Git 连接数，默认: 8）
- **`-f, --file FILE`**：指定任务列表文件（如果不指定，默认从 REPO-GROUPS.md 解析）

#### 推荐配置

根据你的网络带宽选择合适的配置：

- **低带宽（< 10Mbps）**：`-t 3-5 -c 4-8`
- **中带宽（10-50Mbps）**：`-t 5-10 -c 8-12`
- **高带宽（50-200Mbps）**：`-t 10-15 -c 16-24`
- **超高带宽（> 200Mbps，如 300Mbps）**：`-t 15-20 -c 24-32`

#### 使用示例

```bash
# 使用默认参数，从 REPO-GROUPS.md 解析所有仓库
bash main.sh

# 自定义并行参数
bash main.sh -t 10 -c 16

# 从失败列表重新执行失败的仓库
bash main.sh -f failed-repos.txt

# 从自定义列表文件执行
bash main.sh -f custom-list.txt -t 10 -c 16

# 查看帮助信息
bash main.sh --help
```

### 任务列表文件功能

#### 功能说明

脚本支持从文件读取任务列表，实现灵活的任务控制：

1. **默认模式**：不指定 `-f` 参数时，从 `REPO-GROUPS.md` 解析所有仓库
2. **文件模式**：指定 `-f` 参数时，从指定文件读取任务列表（REPO-GROUPS.md 格式）
3. **失败列表**：执行完成后，失败的仓库自动保存到 `failed-repos.txt`（REPO-GROUPS.md 格式，可直接用 `-f` 参数重新执行）

#### 任务列表文件格式

**统一使用 REPO-GROUPS.md 格式**，所有输入文件（包括失败列表）都使用相同格式，脚本统一用 `parse_repo_groups()` 解析。

格式示例：
```markdown
# GitHub 仓库分组

仓库所有者: qiao-925

## Go-Practice <!-- 397.8号高地 -->
- go-admin
- JavaGuide

## Java-Practice <!-- 597.9号高地 -->
- incubator-seata
- distribute-transaction
```

#### 使用场景

1. **重新执行失败的仓库**：
   ```bash
   # 第一次执行
   bash main.sh -t 10 -c 16
   
   # 如果有失败的，会自动生成 failed-repos.txt
   # 重新执行失败的仓库
   bash main.sh -f failed-repos.txt -t 10 -c 16
   ```

2. **执行自定义仓库列表**：
   ```bash
   # 创建自定义列表文件 custom-list.md（REPO-GROUPS.md 格式）
   # 编辑文件，添加要克隆的仓库分组
   # 执行自定义列表
   bash main.sh -f custom-list.md
   ```

3. **分批执行**：
   ```bash
   # 可以将大量仓库分成多个列表文件
   # 分别执行，避免一次性执行太多
   bash main.sh -f list-1.txt
   bash main.sh -f list-2.txt
   ```

## 四、📐 架构设计

### 核心设计原则

1. **极简优先**：只保留核心功能，去除所有非必要的复杂逻辑
2. **双重并行**：应用层并行（-t 参数） + Git 层并行传输（-c 参数）
3. **智能优化**：自动选择最优协议（SSH/HTTPS）+ Git 配置优化
4. **直接覆盖**：不检查仓库是否存在，直接克隆（覆盖）
5. **完整克隆**：全部使用完整克隆，不使用浅克隆

### 主要工作流程

```
开始 (main.sh)
  │
  ├─→ [1] 解析命令行参数
  │     └─ parse_args()
  │         ├─ 解析 -t 参数（并行任务数，默认 5）
  │         └─ 解析 -c 参数（并行传输数，默认 8）
  │
  ├─→ [2] 获取任务列表
  │     ├─ 如果指定 -f 参数：从文件读取任务列表
  │     └─ 否则：解析 REPO-GROUPS.md，提取所有分组和仓库
  │         └─ parse_repo_groups() [lib/config.sh]
  │
  ├─→ [3] 构建克隆任务列表
  │     └─ 任务格式：repo_full|repo_name|group_folder|group_name
  │
  ├─→ [4] 并行执行克隆
  │     └─ execute_parallel_clone() [main.sh]
  │         ├─ 使用后台进程 + wait 实现并行控制
  │         └─ 并行调用 clone_repo() [lib/clone.sh]
  │             ├─ 自动选择协议（SSH 优先，回退到 HTTPS）
  │             ├─ 应用 Git 配置优化（HTTP/2、大缓冲区、多线程）
  │             └─ 使用 git clone --jobs $CONNECTIONS
  │             ├─ 自动选择协议（SSH 优先，回退到 HTTPS）
  │             ├─ 应用 Git 配置优化（HTTP/2、大缓冲区、多线程）
  │             └─ 使用 git clone --jobs $CONNECTIONS
  │
  ├─→ [5] 记录失败列表
  │     └─ 将失败的仓库保存到 failed-repos.txt
  │
  └─→ [6] 输出最终统计
        └─ print_summary()
            ├─ 显示成功/失败统计
            └─ 显示耗时统计
```

### 模块化架构

```
main.sh (主入口)
  │
  ├── lib/logger.sh (日志输出)
  ├── lib/config.sh (配置解析)
  └── lib/clone.sh (仓库克隆)
```

**模块依赖关系**: logger → config/clone → main

**文件结构**: `main.sh` + `lib/*.sh` (3 个模块)

**核心函数**:
- `parse_repo_groups()`: 解析配置文件，提取分组和仓库信息
- `clone_repo()`: 克隆单个仓库，使用 Git 并行传输参数
- `execute_parallel_clone()`: 并行执行克隆任务
- `print_summary()`: 输出最终统计报告

### 代码统计

#### 主要代码文件列表

| 文件 | 行数 | 功能说明 |
|------|------|----------|
| `main.sh` | ~200 | **主入口**：解析命令行参数、协调各模块执行、并行任务管理 |
| `lib/config.sh` | ~70 | **配置解析模块**：解析 REPO-GROUPS.md，提取分组和仓库信息 |
| `lib/clone.sh` | ~50 | **仓库克隆模块**：实现单个仓库克隆，使用 --jobs 参数 |
| `lib/logger.sh` | ~50 | **日志输出模块**：提供统一的日志输出功能 |
| **总计** | **~370** | **4 个文件** |

