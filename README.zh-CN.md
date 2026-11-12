# Open Shelf Books 开架图书流通数据库

[English](README.md)

Open Shelf Books 是面向实体图书借阅的独立 Oracle 数据库。系统分开管理书目与实体副本，按会员类别执行借阅规则，保持续借历史，并按先到先得顺序处理预约。项目包含 Oracle 建库脚本、PL/SQL 流通接口、示例数据、报表查询和测试。

样本记录、标识和交易日期均为合成数据。数据库通过 SQL 和 PL/SQL 提供接口。接入应用需自行提供用户认证和操作界面。

## 快速启动

启动 Docker 或 Podman 后，在仓库根目录运行以下命令。脚本启动固定版本的 Oracle Free Lite 容器，并使用专用的 `OPEN_SHELF_BOOKS` schema。访问该 schema 的命令会提示输入密码。密码须为 12–64 个 ASCII 字母、数字或下划线。

```sh
./scripts/oracle.sh start
./scripts/oracle.sh setup
./scripts/oracle.sh verify
./scripts/oracle.sh demo
```

演示会列出未归还借阅、热门书目和未满足预约，并通过接口归还一个副本。演示结束后回滚归还操作，恢复样本状态。安装 Python 3 后，可运行 `./scripts/oracle.sh concurrency`，通过两个 Oracle 会话验证并发借出。

用 `./scripts/oracle.sh status` 查看容器和 PDB 状态。可将 SQL 通过管道送入 `./scripts/oracle.sh sql`，该命令从标准输入读取语句。`./scripts/oracle.sh stop` 停止容器并保留数据卷。`./scripts/oracle.sh reset --confirm` 删除专用 schema 中的项目对象及数据。

### 使用已有 Oracle 实例

SQL 面向 Oracle Database 19c 及以上版本。使用 SQL*Plus 或 SQLcl 连接至**专用的空 schema**。建库需要 `CREATE SESSION`、`CREATE TABLE`、`CREATE VIEW`、`CREATE PROCEDURE`、`CREATE SEQUENCE` 和表空间配额。故障注入测试还需要 `CREATE TRIGGER`。密码应通过交互输入或本地配置提供。

从仓库根目录启动 SQL 会话后执行：

```sql
@db/00_build.sql
@tests/01_assertions.sql
@db/05_demo.sql
```

Oracle DDL 会隐式提交。仅在确实要清空可丢弃的项目 schema 时，运行 `@db/99_drop_project_objects.sql`。没有 Oracle 时可用 `python3 tests/validate_offline.py` 做离线检查。PL/SQL 和 Oracle 行锁须通过实机测试验证。

## 流通流程

| 操作 | 数据库行为 |
| --- | --- |
| 借出 | 核对会员资格、副本状态、借阅名额与预约顺序。建立借阅记录，若借阅者为首位预约者，同时完成其预约。 |
| 归还 | 关闭借阅记录，并重新计算副本可借状态。 |
| 续借 | 核对借阅、会员资格、续借次数和其他会员预约。将续借前后的到期日写入续借事件。 |
| 预约与取消 | 无可借副本时，同一会员可为同一书目保留一个有效预约。取消时关闭有效预约。 |
| 报表 | 查看副本可借状态、逾期借阅、书目借阅量及未满足预约。 |

流通接口在检查共享状态前锁定书目和会员行。调用方负责提交成功操作或回滚事务。数据库还约束每个副本只能有一条未归还借阅，且同一会员对同一书目只能有一条有效预约。

## 验证结果

在 Oracle AI Database 26ai Free `23.26.3.0.0` 的独立测试 schema 中，建库、30 项断言、DML、原子回滚和运行检查均通过。两项并发测试也通过，分别验证两位会员争借同一副本，以及两次借出争用同一会员最后一个借阅名额。实测得到 11 张表、12 个外键，失效对象和编译错误均为零。实机验证使用已有 Oracle 容器。[演示实测输出](demo/oracle-demo.txt)

## 项目文件

| 路径 | 内容 |
| --- | --- |
| [`db/`](db/) | 表结构、合成样本、PL/SQL 包、报表及可重复执行的演示 |
| [`scripts/`](scripts/) | 本地 Oracle 运行命令 |
| [`tests/`](tests/) | Oracle 断言、事务和并发测试，以及离线检查 |
| [表结构与 ERD](docs/schema.md) | 数据关系、字段字典及约束 |
| [设计与规则](docs/design.md#设计与规则) | 工作流程、权限、行锁和样本规则来源 |
| [演示](demo/README.md#演示) | 运行命令及样本实测结果 |
