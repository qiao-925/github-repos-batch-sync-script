# sync-groups-v2.sh 工作流与架构文档

---

## 核心设计原则

1. **全局性处理**: 先全局扫描所有差异，再统一执行同步，确保整体一致性
2. **优先级处理**: 缺失的仓库优先克隆，已存在的仓库后更新
3. **并行处理**: 支持多仓库并行同步（默认 5 并发，可通过 `PARALLEL_JOBS` 配置）
4. **错误隔离**: 单个仓库失败不影响整体流程，统一收集后重试
5. **缓存优化**: 所有数据一次性加载到内存，避免重复 I/O 和 API 调用

---

## 主要工作流程

### 完整执行流程

```
开始 (main.sh)
  │
  ├─→ [1] 初始化阶段
  │     ├─ initialize_sync() [sync.sh]
  │     │   ├─ 检查配置文件存在性
  │     │   ├─ 初始化 GitHub 连接 [github.sh]
  │     │   └─ 初始化统计变量 [stats.sh]
  │     │
  │     ├─ init_config_cache() [cache.sh]
  │     │   └─ 解析 REPO-GROUPS.md，建立分组缓存
  │     │
  │     ├─ init_repo_cache() [cache.sh]
  │     │   └─ 批量获取所有远程仓库，建立名称映射
  │     │
  │     └─ list_groups() [config.sh]
  │         └─ 显示所有可用分组（带高地编号）
  │
  ├─→ [2] 全局差异扫描阶段
  │     └─ scan_global_diff() [sync.sh]
  │         ├─ 遍历所有分组和仓库
  │         ├─ 检查每个仓库的本地状态
  │         ├─ 分类：缺失 / 已存在 / 跳过 / 不存在
  │         └─ 存储到全局数组：
  │             ├─ global_repos_to_clone (缺失的)
  │             └─ global_repos_to_update (已存在的)
  │
  ├─→ [3] 本地仓库缓存初始化
  │     └─ init_local_repo_cache() [cache.sh]
  │         └─ 扫描所有分组文件夹，建立本地仓库映射
  │
  ├─→ [4] 同步执行阶段（优先级处理 + 并行处理）
  │     └─ execute_sync() [sync.sh]
  │         │
  │         ├─→ [4.1] 优先处理缺失仓库（克隆）
  │         │     ├─ 遍历 global_repos_to_clone
  │         │     ├─ 并行调用 clone_repo() [repo.sh] (默认 5 并发)
  │         │     └─ 记录失败的仓库到 all_failed_repos
  │         │
  │         ├─→ [4.2] 处理已存在仓库（更新）
  │         │     ├─ 遍历 global_repos_to_update
  │         │     ├─ 并行调用 update_repo() [repo.sh] (默认 5 并发)
  │         │     └─ 记录失败的仓库到 all_failed_repos
  │         │
  │         └─→ [4.3] 统一重试失败的仓库
  │               ├─ 遍历 all_failed_repos
  │               ├─ 调用 retry_repo_sync() [sync.sh]
  │               └─ 更新统计信息 [stats.sh]
  │
  ├─→ [5] 清理阶段
  │     └─ cleanup_deleted_repos() [repo.sh]
  │         ├─ 扫描所有本地仓库
  │         ├─ 检查是否在同步列表中
  │         ├─ 检查远程是否还存在
  │         └─ 删除远程已不存在的本地仓库
  │
  └─→ [6] 报告生成阶段
        ├─ print_final_summary() [stats.sh]
        ├─ print_failed_repos_details() [stats.sh]
        └─ compare_remote_local_diff() [stats.sh]
```

---

## 模块化架构

```
main.sh (主入口)
  │
  ├── lib/logger.sh (日志输出)
  ├── lib/utils.sh (工具函数)
  ├── lib/config.sh (配置解析)
  ├── lib/cache.sh (缓存初始化)
  ├── lib/github.sh (GitHub API)
  ├── lib/repo.sh (仓库操作)
  ├── lib/stats.sh (统计报告)
  └── lib/sync.sh (同步逻辑)
```

**模块依赖关系**: logger/utils → config/cache/github → repo/stats → sync → main

**文件结构**: `main.sh` + `lib/*.sh` (8 个模块，总计 ~2000 行)

---

## 使用说明

```bash
# 运行方式
./sync-groups-v2.sh    # 向后兼容
./main.sh              # 直接使用主入口

# 环境变量
PARALLEL_JOBS=10 ./main.sh  # 设置并发数（默认: 5）
```

---

## 维护说明

代码修改后必须：
1. **全局性检查**: 使用 AI Agent 对整个脚本进行全面的全局性分析检查
2. **更新工作流文档**: 任何对脚本的修改都必须同步更新 `WORKFLOW.md`
3. **测试验证**: 确保拆分后的脚本功能正常
