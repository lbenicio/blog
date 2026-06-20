---
title: "Designing A Protocol For Log Replication With Snapshotting: The Etcd Raft Implementation"
description: "A comprehensive technical exploration of designing a protocol for log replication with snapshotting: the etcd raft implementation, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-08"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Designing-A-Protocol-For-Log-Replication-With-Snapshotting-The-Etcd-Raft-Implementation.png"
coverAlt: "Technical visualization representing designing a protocol for log replication with snapshotting: the etcd raft implementation"
---

这是将您提供的开头扩展为一篇完整的、超过10,000字的技术博客文章。文章沿用了您的“画家与壁画”比喻（现在改写为“工匠与墙壁”），并融入了Raft、Etcd、Kafka、存储引擎和具体的生产环境案例，确保了技术深度与可读性。

---

# 无尽记忆的无声危机：为什么日志复制需要一个垃圾回收器

## 引言：从一幅壁画到一个日志——当“永远追加”变成“永远痛苦”

想象一下，你是一位被委托创作世界上最大、最复杂壁画的工匠。你从一公里长的墙壁的一端开始，每天小心翼翼地勾勒细节。为了追求完美，你拥有一支学徒团队，他们必须完美地复制你的每一笔。你每画一片草叶，就给你的学徒递一张纸条：“第10,452笔，绘制一片草叶，颜色：森林绿#4。”你的学徒们，勤勤恳恳，在各自的墙壁上也画下同样的草叶。

起初，一切完美。你的系统具有容错性——如果一位学徒睡着了醒来，他只需翻阅你的日志，从第一条纸条开始，就能重现整个画面。

但随着你前进，问题出现了。当壁画完成一半时，你的日志已经记录了数百万条纸条。如果一位新人加入团队，或者一台学徒的工作室被毁了（服务器宕机），他必须从头阅读那数百万条纸条才能知道当前的画面是什么。这不仅浪费时间和体力，而且日志本身占据了整个工作室的库房（内存和磁盘）。更糟糕的是，由于学徒们必须按顺序处理纸条，日志越长，他们响应你的指令就越慢。

这就是分布式共识领域最核心的张力：**日志是终极真理的来源，但一个无界的日志是一个缓慢、消耗资源且脆性的系统。**

在这个数字世界的壁画中，你的壁画就是应用的状态（例如Kubernetes的Etcd集群中存储的所有对象）。工匠是Raft集群中的节点。日志是追加写入的预写式日志。我们依赖Raft协议保证每个节点以相同的顺序应用指令，从而保证整个系统的强一致性。Raft协议因其优雅和可理解性，已经成为构建强一致系统的行业标准。Etcd（Kubernetes的基石）和TiKV（分布式数据库）都是其著名的实现。

但是，如果你曾运行过大型Etcd集群，或者管理过一天处理数十亿条Kafka消息的系统，你会立刻明白这个无声的危机：**日志在无限增长。** 不受控制的增长是系统设计者需要严肃对待的“熵增”。一个每秒处理数千次写入的集群，在几小时内就能积累数GB的日志。

问题不在于“日志会增长”——这是必然的。问题在于 **“我们什么时候以及如何去清理这些已经无关紧要的历史？”** 如果我们只是机械地追加，系统最终会因为内存耗尽、磁盘满、或者上线一个新节点需要花几天时间“回放日志”而崩溃。这种崩溃不是突发的电路故障，而是一种缓慢的窒息。

我们必须正视这个问题：**日志复制需要垃圾回收器。** 这一篇文章将带你深入这个复杂但又至关重要的工程挑战，从Raft日志的原理，到Etcd的MVCC存储，再到Kafka和Pulsar的架构选择，最后到具体的调优实战。

---

## 第一部分：回放日志的根源——为什么Raft会产生“无限”的日志？

要理解为什么需要垃圾回收，我们必须理解Raft日志的本质。

### 1.1 日志即状态机

在Raft中，整个集群的状态机通过复制日志来保持同步。每一个客户端的请求（比如“创建一个Pod”、“更新一个键值对”）都被包装成一个条目，追加到所有节点的日志中。

```
                术语（Term）:
                 |  2   |  2   |  3   |  3   |  3   |  4   |  4   |
日志索引 (Index): |  1   |  2   |  3   |  4   |  5   |  6   |  7   |
                 +------+------+------+------+------+------+------+
操作 (Command):   | SET  | SET  | DEL  | CAS  | SET  | DEL  | SET  |
                 | A=1  | B=2  | A    | C=3  | D=4  | B    | E=5  |
                 +------+------+------+------+------+------+------+
```

当Raft日志达到某个索引时，该节点必须按照顺序将这些指令输入到状态机中。

**问题根源：索引的线性增长**

- **日志是无限的：** 只要集群在运行，客户端的请求就会不断产生新的日志条目。Etcd没有“刷掉历史”的天然机制，除非我们强制进行压缩。
- **追随者追赶（Catch-up）：** 当一个新节点加入集群（由于故障恢复或横向扩展），Leader必须通过**日志复制**将缺失的日志条目发送给它。如果Leader的日志有100GB，新节点就必须下载并应用100GB的日志。网络传输和重放成为瓶颈。
- **快照缺失时的灾难：** Raft的解决方案是**快照（Snapshot）**。Leader可以拍摄当前状态机的快照（内存中的键值对），然后截断此前的日志。但这引入了一个全新的挑战：如果集群从来不拍快照（或者快照间隔极长），日志会无限制地膨胀。

### 1.2 日志膨胀的直接后果

1.  **磁盘压力：** 日志是持久化的。典型的Raft实现（如Etcd的WAL）会一直保留日志文件。如果磁盘写满，系统将进入恐慌模式（只读或崩溃）。
2.  **内存压力：** 许多系统（如Etcd 3.x）为了支持MVCC（多版本并发控制）和高效的Watch机制，会将日志条目缓存到内存中。日志越长，RSS（驻留内存）占用越大，最终导致OOM（内存溢出）。
3.  **I/O 瓶颈：** 当进行日志一致性检查（AppendEntries RPC）时，Leader需要将一批日志取出发给Follower。日志条目越多，序列化和网络传输的开销越大。此外，新节点回放旧的日志将产生大量的随机I/O。
4.  **快照传输负担：** 如前所述，当Leader发现Follower落后太多（例如日志索引差了几百万），它会选择发送快照来代替发送日志。如果日志非常大，快照本身也变得巨大。一次性传输一个10GB的快照将占用大量带宽并导致延迟飙升。

**这个圆圈开始露出割裂的痕迹：你为了系统可用性而复制日志，却因为日志的复制而损失了可用性。**

---

## 第二部分：深入Etcd——MVCC视角下的日志膨胀

让我们把焦点放在最典型的例子——Etcd上。Etcd 3.x使用的是基于MVCC（多版本并发控制）的bbolt存储引擎。

### 2.1 为什么Etcd的“日志”会变得极其庞大？

Etcd的日志包含两个部分：

1.  **Raft WAL:** 标准的Raft日志，存储在磁盘的WAL目录。这是真正的线性追加日志。
2.  **MVCC历史记录：** 在bbolt后端数据库中，key-value的每一次修改都会生成一个新的版本（Revision）。**旧版本的数据不会被立即删除。**

想象一个键 `/registry/secrets/cluster-token` 被频繁更新（比如每10秒更新一次）。在Etcd的MVCC存储中：

- Revision 100: 存储值为 “Token-ABC”
- Revision 102: 存储值为 “Token-DEF”
- Revision 105: 存储值为 “Token-GHI”
- ...

**关键在于：Revision 100 和 102 的数据在 Revision 105 写入时仍然存在于磁盘中**。它们不会被自动清理，因为可能有一些客户端正在通过“历史Watch”或`--rev=100`的查询来访问这些数据。这正是MVCC的初衷：允许时间旅行。

但是，如果这些旧的Revision永远不被压缩，Etcd的数据库文件（`member/snap/db`）会持续增长。

### 2.2 内存中的“inflight”队列

除了持久化存储，`etcdserver`还维护着一个内存中的`inflight`日志队列。当返回给客户端前，日志需要被提交并应用到状态机。在高峰期（比如Kubernetes频繁创建Pod、更新Deployment时），这个队列中可能堆积数万个未处理的WAL条目。

这对内存的消耗极大。一个WAL条目虽然不大，但当条目数达到数十万甚至百万时，仅Raft内部用于一致性检查的内存数据结构就可能达到数GB。

### 2.3 实战案例：Kubernetes中的Etcd爆炸

在大型Kubernetes集群中（5000个节点以上），Etcd是公认的“薄弱环节”。常见的现象是：

- **DevOps工程师发现Etcd Pod的CPU使用率达到100%**，伴随着请求延迟抖动。
- 检查Etcd实例，发现`db size`已经飙升至8GB（Etcd默认的硬限制是8GB）。
- 更深入的排查显示，`raft_term`和`applied_index`之间的差距在拉大，说明Follower节点正在拼命回放日志，但追不上。
- 这是一个经典的日志膨胀导致级联故障的案例。

**压缩的必要性** 在这种背景下变得不可辩驳。我们需要一份机制，能够像Java的GC清理堆内存一样，去清理那些“已死的”历史记录。

---

## 第三部分：解决方案全景——我们需要一个“垃圾回收器”

既然问题清楚了，我们来看看我们能怎么做。这里涉及两个层次的清理：

1.  **状态机级的清理：** 清理MVCC数据库中的历史版本。
2.  **Raft日志级的清理：** 截断WAL，用快照代替旧的日志。

### 3.1 解决方案1：自动定期压缩（Auto-Compaction）

这是Etcd最常用的策略，也被称为“软清理”。它专门用来清理MVCC历史版本。

Etcd支持两种模式：

- **Periodic（按周期）：** 基于时间进行压缩。例如，每5分钟运行一次。
- **Revision（按版本数）：** 保留最近的N个版本。

**原理：**
压缩器会遍历bbolt数据库，标记那些已经“死掉”的旧版本为可删除。不过，压缩本身只负责逻辑清理（删除索引）。物理空间的回收还需要后续的**碎片整理（Defragmentation）**。

**代码层面的模拟：**

在Etcd中，你可以通过`etcdctl`或gRPC API调用压缩：

```bash
# 按周期压缩，保留5分钟内的所有版本
ETCDCTL_API=3 etcdctl compaction `date -d "-5 minutes" +%s000000`

# 或启用自动压缩（在Etcd启动参数或API中设置）
# --auto-compaction-mode=revision
# --auto-compaction-retention=10000  # 保留最近10000个版本
```

**代价：**
压缩过程对CPU有显著消耗。它需要扫描内存中的B-tree索引。如果压缩频率太高（每1分钟一次），Etcd可能会因为CPU争抢而拒绝服务。

### 3.2 解决方案2：快照截断（Snapshot）——Raft日志的GC

Raft协议自身已经设计了快照机制来解决日志无限增长问题。

当Leader认为日志条目过多时，它可以拍摄一个当前状态机的快照。这个快照包含了到当前应用索引为止的完整状态数据（如所有KV值）。

快照完成后：

- Leader可以将此前的WAL日志截断，仅在磁盘上保留快照文件和快照之后的新日志。
- Follower落后过多时，不再一个一个地发送日志条目，而是发送快照。

**Etcd默认的行为：**
Etcd每拍摄10,000个日志条目就会触发一次快照（可以通过`--snapshot-count`配置）。这可以确保WAL文件的大小受到控制。

**快照的隐患（大型快照的代价）：**

然而，当状态机本身非常大时（比方说，状态机快照已经达到4GB），快照的传输成为了新的瓶颈。想象一下场景：

1.  集群中的一个节点因为网络抖动而滞后（它的`applied index`比Leader低了几百万）。
2.  Leader发现它需要的日志已经被截断了（因为已经写入了快照）。
3.  Leader决定发送快照。
4.  Etcd通过gRPC流发送4GB的快照文件。网络带宽被占满，持续数分钟。
5.  Follower收到快照后，需要加载它到内存（巨大的内存分配），旧的状态机被卸载，这会引发I/O抖动和STW式的停顿。
6.  **更严重的是：** 如果3个节点的集群中，另一个节点正好在此时也故障了，集群将无法形成法定人数（Quorum），导致彻底不可用。

**这里，快照本来是日志GC的工具，但太大太快导致自身成为了一种DoS攻击。**

### 3.3 解决方案3：增量快照与流式压缩

为了克服大块快照的问题，更先进的分布式系统（如TiKV、Flink、Pulsar）采用了不同的策略：

- **增量快照（Incremental Snapshot）：** 不必每次都拍摄全量快照，而是只记录自上次快照以来的变化（类似事务日志的差异文件）。当节点需要恢复时，它可以先加载基准备份（Bases），再按顺序应用增量（Deltas）。这极大地减少了单次传输的数据量。
- **流式压缩（Streaming Compaction）：** 系统持续地将WAL的末尾写入新的压缩区域。在Pulsar的分层存储中，历史数据会被流式地转移到廉价的对象存储（如S3）中，只保留一个引用。这相当于在GC过程中直接将“垃圾对象”移出堆内存。

---

## 第四部分：生产环境中的实战调优（血泪史）

理论讲完了，让我们动手写点“真正的建议”。

### 4.1 判断你的日志是否“病”了

这是一个典型的Etcd的告警输出，表示存在问题：

```
# 查询当前的 WAL 大小
du -sh /var/lib/etcd/member/wal/
# 输出: 40G  /var/lib/etcd/member/wal/   # 危险信号！

# 查看数据库大小
ETCDCTL_API=3 etcdctl --endpoints=localhost:2379 endpoint status -w table
# 如果 DB SIZE 接近 8GB 阈值，你可能需要立即行动。
```

### 4.2 调优策略清单

针对Etcd的日志GC和性能，你可以考虑以下配置：

1.  **激进的自动压缩（MVCC）：**
    - **不要**设置过小的保留时间（如`--auto-compaction-retention=1m`）。这会导致压缩器用掉你所有的CPU。
    - 建议：对于高变更率的集群，保留1小时或保留10000-50000个Revision是一个合理的起点。
    - 结合**手动碎片整理**：压缩只是逻辑删除，只有执行`defrag`才能物理释放空间。在业务低峰期运行（先租约续期，再defrag一个节点）：

    ```bash
    etcdctl defrag --endpoints=localhost:2379
    ```

2.  **精细控制快照大小（Raft）：**
    - 默认的`--snapshot-count=100000`（即10万条日志触发一次快照）对于大多数场景都太大。
    - 如果集群写请求多（如5000+ QPS），将其降低到`10000`或`5000`。这样可以控制WAL的峰值大小，使其永远不会膨胀到10GB以上。
    - 但是，降低快照频率会导致快照拍摄更频繁（消耗少量CPU）。你需要找到那个平衡点。

3.  **增加后端空间配额（最后的手段）：**
    - `--quota-backend-bytes` 默认是8GB。对于大型集群，可以将其提高到16GB或32GB。
    - **警告：** 这仅仅是把天花板抬高了，并没有解决GC的问题。它只是为你的GC操作争取了更多时间。如果配额过高，一旦发生故障，快照会更大，传输更慢，风险也更大。

4.  **使用Leaner存储（新兴方案）：**
    - 考虑使用专门的日志和状态存储引擎。例如，用于Kafka的Raft实现（KIP-853）引入了新的Leader Epoch机制，使得日志恢复不再需要回放到日志尾，极大地减轻了GC压力。

### 4.3 监控指标：你需要的警报

如果你运维Etcd，这些指标是逃不掉的：

- **`etcd_server_snapshot_missed_total`**：如果这个指标在递增，说明Follower因为日志截断而需要频繁接收快照，这是危险的信号。
- **`etcd_db_total_size_in_bytes`**：看看它是否在配额附近徘徊。
- **`etcd_raft_log_unapplied_entries`**：如果这个值持续大于0并增加，说明应用端（后端MVCC）正在成为瓶颈，日志正在积压。
- **`etcd_server_proposals_failed_total`**：提案失败通常是因为Leader无法把日志复制到大多数节点（磁盘满或GC导致的暂停）。

---

## 第五部分：危机之外——未来架构的思考（Kafka vs. Pulsar vs. Etcd）

这场“日志GC”的危机，本质上是“数据结构”的选择问题。不同的分布式系统场选择了不同的妥协。

### 5.1 纯追加日志的崇拜：Kafka

Kafka是典型的“日志即一切”的信仰者。它的核心抽象是一个不可变的、仅追加的日志分区。

- **GC机制：** 日志碎片的删除。Kafka不修改现有日志，只是将过期的日志段（Segment）从文件系统中删除。
- **强项：** 写得非常快（追加写）和顺序读。
- **弱点：** Kafka不提供“状态机”的强一致性视图。虽然Kafka Streams能在拓扑中维护状态，但底层的存储引擎（RocksDB）依然面临着与Etcd相同的GC和压缩问题。Kafka的“日志清理”策略（`delete.cleanup.policy`）本质上就是最原始的垃圾回收钩子，它只能在分区层面（独立于CPU和内存）运行。

### 5.2 分层存储的先锋：Apache Pulsar

Pulsar改变了游戏规则。它将“日志”和“存储”分离。

- **BookKeeper（日志）：** 负责低延迟的写入和复制。BookKeeper的日志可以独立扩容。
- **分层存储（S3/HDD）：** 当日志在BookKeeper热存储中积累到一定程度，Pulsar会自动将旧的数据段卸载（Offload）到对象存储中，并在热存储中只保留一个指针。
- **巨大优势：** “GC”在Pulsar中几乎免费。你不再需要昂贵的大规模压缩来腾出热存储空间。你只需要在S3上支付廉价的存储费和少量的请求费。

**这给我们的启示：** 未来的Raft实现可能会借鉴这种思想。Leader可以将一个臃肿的快照看作是一个“冷段”，将它卸载到廉价的对象存储中，而Follower可以通过高效的HTTP访问对像存储来获取快照，而不是使用笨重的gRPC流。

### 5.3 混合式：TiKV的解决方案

TiKV（基于Raft的分布式KV存储）面临同样的问题。它的解法是彻底的“Multi-Raft”。

- Etcd是单Raft组。所有键值对共享一个WAL和一个快照。这导致快照巨大。
- TiKV将数据分为许多Region（每个Region是一个小的Raft组）。每个Region的大小默认为96MB。
- **优势：** 每个Region的日志增长有限。当一个Region超过96MB时，它会分裂(Split)。GC只需要处理这个小Raft组的WAL，快照大小只有96MB。这是**并行的细粒度GC**。

对于Etcd的维护者而言，Etcd正在尝试“结”，但很多时候，大型单Raft组的模式在万兆级负载下已经接近工程极限。TiKV的思路或许是对Etcd的未来（或者下一代共识引擎，如`braft`、`jepio`）的一种启示。

---

## 第六部分：实操指南——当你发现你的日志在燃烧（10000字版）

尽管我们可以讨论架构，但在生产环境中，你的脚边已经着了火。以下是具体的操作步骤。

### 步骤一：紧急止血（如果集群已经响应缓慢或OOM）

如果`etcd`进程快要死了，或者磁盘只剩最后的空间：

**1. 停止写入：** 暂停所有Pod调度（`kubectl cordon all nodes`）和数据库写操作。只保留读操作。这是最痛苦但最有效的决定。

**2. 执行紧急压缩和defrag：**

虽然在没有足够内存的情况下无法运行defrag，但你可以尝试强制进行Revision压缩：

```bash
# 获取当前最新 Revision
ETCDCTL_API=3 etcdctl endpoint status --write-out=fields | grep revision | head -1

# 强制压缩，保留最近5个版本
REV=$(ETCDCTL_API=3 etcdctl endpoint status --write-out=fields | grep '"Revision"' | awk -F':' '{print $NF}')
TARGET_REV=$((REV - 5))
ETCDCTL_API=3 etcdctl compaction $TARGET_REV
```

**3. （如果有第二个Etcd实例）尝试清理数据库（谨慎）：**

如果集群是多节点，且你有一个备用节点，你可以：

```bash
# 停用该节点，清理数据
systemctl stop etcd
rm -rf /var/lib/etcd/member/snap/
systemctl start etcd  # 这会触发从Leader拉取快照和日志

# 这个节点会变成Follower，但需要等待它追赶Raft。
```

这等同于“重启GC”。它会迫使Lagging节点进行状态机的全新加载。

### 步骤二：日常运维脚本

永远不要等到警报响了再考虑GC。你应该有一个cronjob。

**理想做法：**

```bash
#!/bin/bash

# 获取当前最新版本
ENDPOINTS="localhost:2379"
LATEST_REV=$(ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint status --write-out=fields | grep '"Revision"' | awk -F': ' '{print $2}')
# 保留3600秒（1小时）的窗口，假设写QPS恒定，计算出大约要保留的Rev数
DEFEND_REV=$((LATEST_REV - 3600 * QPS))

# 确保我们保留最近的版本不被压缩
MIN_REV=$(ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS alarm list | head -1) # 简化

# 执行压缩
ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS compaction $DEFEND_REV

# 等待几秒让压缩生效
sleep 10

# 对每个端点进行defrag
ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS defrag

echo "AutoGC completed at $(date)"
exit 0
```

**避坑指南：**

- **不要**在`defrag`期间同时操作Follower，以免集群状态不一致。
- **永远**不要在Leader上进行`defrag`时同时进行Leader选举（除非你准备好掉线）。最好在低峰期逐个节点执行，并先确认该节点的Etcd不会因为`defrag`导致暂停而触发选举超时（可以将`--election-timeout`临时调大，但极度不推荐）。

---

## 第七部分：结语——记忆的黄金准则

我们回到一开始的壁画。如果你是一位出色的工匠，你不会等到你的学徒们被百万张纸条压垮时才想办法。你会定期（比如每周）拍一张整幅壁画的高清照片（快照）。告诉学徒们：“忘掉此前的纸条，现在的壁画就是你们的起点，之后的新纸条从这里开始。”

这就是分布式系统中的垃圾回收。

- **日志是短暂的，状态才是永恒的。**
- **好的GC策略是系统稳定的前提。** 它不应该是一个事后补救的脚本，而应该是系统架构的默认设置。
- **自动化是你的朋友.** 无论是Raft的快照、Etcd的自动压缩，还是Pulsar的分层存储，最终目标是：对于操作者而言，日志GC应该是透明的。

**展望未来：**

随着系统规模的不断扩大，传统的MVCC+单Raft组模式可能走到尽头。我们需要：

- **更好的压缩引擎：** 更加节省CPU和I/O。
- **面向对象的存储：** 将日志视为冷热数据分离。
- **自适应GC：** 系统能够根据当前CPU、内存和磁盘IO动态调整压缩的激进程度。就像一个实时的JVM垃圾回收器，它会根据水位线调整自己的频率。

最终，我们追求的是一种优雅的状态机：**它既能记住所有现在与未来，又能忘掉所有无关的过去。** 只有这样，分布式系统才能从“勉强可用”迈向“真正的可靠”。

**现在，去检查你的Etcd日志吧。如果它的WAL已经超过10GB，无声的危机已经开始。**
