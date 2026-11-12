# Design and policies

[中文](#设计与规则) · [Schema and ERD](schema.md)

## Operations and transactions

Applications call the `circulation_api` package for circulation writes. The package is defined with `AUTHID DEFINER`. A successful operation keeps its locks until the caller commits or rolls back. A failed operation rolls back to the package’s internal savepoint. Reserve the savepoint name `circulation_call` for the package.

| Procedure | Validation and changes |
| --- | --- |
| `checkout` | Locks the title and member before checking the copy, active loan count, and oldest active hold. Creates a loan with the member category’s loan period. Fulfills the oldest hold when its member checks out. |
| `return_loan` | Rejects a closed loan and a return earlier than checkout or the last renewal. Sets `returned_on` and leaves earlier events intact. |
| `renew_loan` | Requires an eligible member and an open loan within its due date and renewal limit. A different member’s active hold blocks renewal. Advances the due date by the current loan period and inserts the old and new due dates in `RENEWAL`. |
| `reserve_title` | Requires an active, unexpired member and no lendable copy of the requested title. Inserts one active hold per member/title. |
| `cancel_reservation` | Closes an active reservation belonging to the specified member, recording the closure time. |

The package takes locks in the order title, member, copy, loan where those rows are involved. The title lock serializes copy checkout and reservation decisions for a title. The member lock protects the quota across titles. Use one circulation call per transaction unless the caller controls a consistent lock order across its entire batch. If a transaction deadlocks, roll it back before retrying.

## Database rules

- A function-based unique index permits at most one open loan per copy. Another permits at most one active reservation per member/title. Closed rows remain in the history.
- `v_copy_availability` calculates lendability from a copy’s condition and the absence of an open loan. The checkout API also applies membership eligibility and reservation priority.
- `v_active_loans` uses the Oracle server date for overdue days. The demo fixes its comparison date for reproducibility and still selects currently open loans.
- An integrating service needs package execution and any view access it uses. It authenticates the requester and authorizes the submitted member and staff identifiers. Keep direct circulation table writes with the schema owner. Direct writes by a privileged account can bypass package rules such as quota and queue priority.
- The catalog stores publishers and authors separately from titles. `TITLE_AUTHOR` records many-to-many authorship, and each `BOOK_COPY` belongs to one title. `RENEWAL` stores the history of due dates. [Field dictionary and ERD](schema.md)

## Seed policies and project scope

| Member category | Loan limit | Loan period | Maximum renewals |
| --- | ---: | ---: | ---: |
| Undergraduate | 20 | 30 days | 3 |
| Final-year undergraduate | 25 | 30 days | 3 |
| Postgraduate | 30 | 30 days | 3 |

The seed limits and periods are informed by Universiti Malaya Central Library’s publicly documented open-shelf student borrowing rules. The policy also describes a three-renewal cap and a restriction when another borrower has reserved the item. The records and implementation in this repository are synthetic and independently modeled. [Library borrowing and returning policy](https://umlib.um.edu.my/borrowing-amp-returning)

FIFO ordering by reservation timestamp and ID, holding a title only when no copy can be lent, excluding overdue renewals, and adding renewal days to the current due date are project design choices. This implementation covers one open-shelf collection. Fines, notifications, transfer between branches, electronic resources, and integration with identity systems are outside its scope.

## 设计与规则

[English](#design-and-policies) · [表结构与 ERD](schema.md)

### 操作与事务

应用通过定义者权限（`AUTHID DEFINER`）的 `circulation_api` 包执行流通写操作。调用成功后，行锁会保留到调用方提交或回滚事务。调用失败时，接口回滚到内部保存点。`circulation_call` 是该包保留的保存点名称。

| 过程 | 检查与变更 |
| --- | --- |
| `checkout` | 锁定书目和会员，检查副本状态、未归还数量及最早的有效预约。按会员类别规则计算到期日并建立借阅。借阅者为首位预约者时，同时完成该预约。 |
| `return_loan` | 拒绝已关闭的借阅，以及早于借出或最近续借时间的归还。写入 `returned_on` 并保留先前事件。 |
| `renew_loan` | 检查会员资格、有效借阅、到期日和续借次数。其他会员有有效预约时拒绝续借。按当前规则增加借期，将续借前后的到期日记录到 `RENEWAL`。 |
| `reserve_title` | 会员资格有效，且目标书目无可借副本时，可建立有效预约。同一会员对同一书目最多有一条有效预约。 |
| `cancel_reservation` | 取消指定会员的有效预约，记录关闭时间。 |

涉及多个对象时，接口按书目、会员、副本和借阅顺序获取行锁。书目锁使同一书目的借出与预约判断按顺序执行，会员锁保护跨书目的借阅名额。每个事务通常调用一次流通接口。批处理需要在整个事务中遵循统一的加锁顺序。发生死锁时，先回滚该事务再重试。

### 数据库约束

- 基于函数的唯一索引分别保证每个副本至多有一条未归还借阅，同一会员与书目的组合至多有一条有效预约。已关闭记录继续保留在历史中。
- `v_copy_availability` 依据副本实体状态及有无未归还借阅计算可借性。借出接口还会检查会员资格及预约优先顺序。
- `v_active_loans` 使用 Oracle 服务器日期计算逾期天数。演示固定计算日期以便复现，查询的记录仍是当前未归还借阅。
- 接入服务只需流通包执行权及所需视图读取权，并负责验证调用者身份与会员、职员编号的操作权限。直接写入流通表的权限由 schema 所有者保留。具有高权限的账号直接写表时可以绕过借阅名额、预约顺序等包内规则。
- 出版社、作者和书目独立存储，`TITLE_AUTHOR` 表示多对多作者关系。每个 `BOOK_COPY` 属于一个书目。`RENEWAL` 保存到期日变更历史。[字段字典与 ERD](schema.md)

### 样本规则及范围

| 会员类别 | 借阅上限 | 借期 | 最多续借 |
| --- | ---: | ---: | ---: |
| 普通本科生 | 20 本 | 30 天 | 3 次 |
| 毕业年级本科生 | 25 本 | 30 天 | 3 次 |
| 研究生 | 30 本 | 30 天 | 3 次 |

样本借期和限额参考马来亚大学中央图书馆公开的学生开架借阅规则。该公开规则还说明最多续借三次，并限制被其他用户预约后的续借。仓库中的数据均为合成记录，数据库为独立设计。[图书馆借还规则](https://umlib.um.edu.my/borrowing-amp-returning)

预约按时间和编号排序、仅在无可借副本时开放预约、拒绝逾期续借，以及在当前到期日上增加借期，均为本项目的设计选择。当前实现覆盖一个开架馆藏，范围不包括罚款、通知、跨馆调拨、电子资源及统一身份系统集成。
