# 数据与版本连接

2026-11-01 已在本机实测 GitHub、Zotero 和 arXiv 读取。凭据沿用本机配置，本文不保存密钥。

| 接口 | 实测结果 | 数据去向 |
| --- | --- | --- |
| GitHub CLI | 现有登录有效；包括 fork 的代码搜索返回 44 处匹配，抽查 2 条 | 用户主动选定的代码范围进入 code dataset |
| Zotero Desktop API | API v3 返回 HTTP 200；按加入时间读取，排除附件、批注与笔记 | 最近 20 篇论文的元数据进入 paper dataset |
| arXiv API | 读取 1 条机器人论文的 Atom 元数据及原始论文 URL | 研究任务按需搜索或入库 |

数据集保存在 `~/Library/Application Support/F/applications/datasets/global/records/`。
每条记录单独原子写入，并通过跨进程锁串行修改；重复同步保持首次入库日期与已有评价证据。
目前已保存 20 条论文记录和 1 条代码记录，没有下载论文附件、运行外部代码或向 GitHub 发布仓库。

代码样例为用户既有仓库中的 [IsaacLab 回放入口](https://github.com/jiandiffy/InterMimic/blob/82bf10dd9d840503caa5e2eb7134469e71b4d7de/isaaclab/examples/data_replay.py#L1-L40)，保留确切提交、文件、行号与 SHA256。后续复用仍需核对来源仓库许可与运行环境。

Agent 先从总线激活 `datasets` 能力，再用 `dataset` 工具发现来源、搜索、同步选定论文或捕获代码范围。
GitHub 查询默认限定已登录账户并包含 fork；可用明确的 `owner/repository` 缩小范围。
Zotero 默认走本机只读 API。只有调用者显式指定 `cloud=true` 时，才读取已有私有凭据文件访问云端 API。
未来数据源通过 `ctx.datasets.register({name, description, search})` 插入，释放注册即可移除。

论文优先级由最近加入时间（0.4）、单位证据（0.2）、性能证据（0.2）、讨论证据（0.2）组成。
后三项必须附来源 URL、摘要和明确的 0–1 评分；缺失项返回 `null`，不编造声誉或性能。
评分是可追溯的研究判断，不是自动判定论文质量。排序结果包含各项分数和计算规则。

项目版本插件在文件夹自身开启 Git，拒绝把上级目录仓库当作该项目。子任务分配独立工作树和文件范围，形成父子版本树。
提交只包含指定路径；合并验证子分支和合并后的结果。失败保留现场，由主 Agent 决定修复或重新规划。
GitHub 发布来自用户界面的明确上传操作；首次创建私有仓库，随后推送已提交分支，不强推。
当前原生版本插件处理本机文件夹；SSH 项目继续使用已认证的远程 Git 工具，不操作本机描述目录。

验证命令：

```sh
./pi/runtime/node/bin/node --test harness/tests/datasets.test.mjs harness/tests/versions.test.mjs
```

测试覆盖数据并发更新、证据保留、排序、提供方释放、Zotero 元数据映射、arXiv XML 解析、真实 Git 分支合并、父仓库隔离、范围/符号链接/凭据拒绝、并发版本树和测试失败现场保留。真实服务检查记录位于维护时生成的 `/tmp/f-datasets-live-report.json`。

接口依据：[GitHub Code Search](https://docs.github.com/en/rest/search/search?apiVersion=2022-11-28#search-code)、[Zotero API v3](https://www.zotero.org/support/dev/web_api/v3/basics)、[arXiv API](https://info.arxiv.org/help/api/user-manual.html)。
