# Validation / 验证记录

On 12 November 2026, Oracle AI Database 26ai Free Lite `23.26.3.0.0` executed the standalone launcher against a newly created `OPEN_SHELF_BOOKS_TEST` schema. A temporary engine adapter connected the launcher to an existing ARM64 Oracle container through Lima and nerdctl. This run covered the SQL entry points. Docker and Podman container startup remain unverified in this run.

2026 年 11 月 12 日，在 Oracle AI Database 26ai Free Lite `23.26.3.0.0` 的新建 `OPEN_SHELF_BOOKS_TEST` schema 中运行独立启动脚本。临时容器引擎适配器通过 Lima 和 nerdctl 连接已有的 ARM64 Oracle 容器。此次验证覆盖 SQL 命令入口。Docker 与 Podman 启动流程未纳入本次实测。

| Command or check / 命令或检查 | Observed result / 实测结果 |
|---|---|
| `python3 tests/validate_offline.py` | 44 fixture and schema checks passed / 44 项样本与结构检查通过 |
| `scripts/oracle.sh status` | `FREEPDB1` was `READ WRITE` / `FREEPDB1` 处于可读写状态 |
| `scripts/oracle.sh setup` | 11 tables built in an empty schema / 在空 schema 建成 11 张表 |
| `scripts/oracle.sh verify` | All 30 assertions passed. DML, fault rollback and DDL probe passed. There were 12 enabled foreign keys and zero invalid objects or compile errors. / 30 项断言及 DML、故障回滚、DDL 验证均通过。12 个外键已启用，无无效对象或编译错误。 |
| `scripts/oracle.sh demo` | All four statements ran. Loan 1 was returned and then restored to outstanding by rollback. / 四条语句全部执行。借阅 1 归还后通过回滚恢复未归还状态。 |
| `scripts/oracle.sh concurrency` | The second session waited 2.51 s in each race. It received `-20004` for the same copy and `-20005` for the member quota. Cleanup restored eight loans. / 第二会话在两次竞态中各等待 2.51 秒。副本冲突返回 `-20004`，名额冲突返回 `-20005`。清理后恢复 8 条借阅。 |
| Rebuild guard / 重复建库保护 | Setup rejected a populated schema with `ORA-20860`. / 已有对象时拒绝建库，返回 `ORA-20860`。 |
| Reset and rebuild / 重置与重建 | Reset required `--confirm`. The confirmed reset and subsequent setup passed. / 重置要求 `--confirm`。确认后重置及再次建库均通过。 |

The test account and its dedicated tablespace were removed after verification. The demo uses `2026-10-29` as the fixed date for overdue calculations.

验证后已移除测试账号及其专用表空间。演示以 `2026-10-29` 作为固定逾期计算日期。
