# SQL 优化实战(唠嗑版)

> 这份是当跟组里同事聊 "你们 SQL 出问题了都怎么搞的" 写的。
> 不讲 B+ 树是怎么画的(八股清单有),专门讲 **真实线上场景里怎么把一条慢 SQL 调好**。
> 照着这份讲,比背"最左前缀原则"走心得多。

---

## 一、面试官最爱问的第一问:"你做过 SQL 优化吗?讲一个例子"

标准回答模板:**我的一条 600ms 查询是怎么变成 30ms 的**,每一步干了啥、为啥这么干。

### 背景

我们分销后台有个接口是"按条件查签约单",产品希望支持:
- 按 up 主昵称模糊搜
- 按签约时间范围
- 按签约状态过滤
- 按商品名模糊搜
- 分页,每页 20

```sql
-- 最初的 SQL(简化版)
SELECT c.* 
FROM contract c
  LEFT JOIN user u ON c.user_id = u.id
  LEFT JOIN goods g ON c.goods_id = g.id
WHERE u.nickname LIKE '%某某%'
  AND c.create_time BETWEEN '2024-01-01' AND '2024-12-31'
  AND c.status IN (1, 2)
  AND g.title LIKE '%某剧%'
ORDER BY c.create_time DESC
LIMIT 0, 20;
```

**线上 P99 是 600ms**,慢查询日志天天刷。

### 第 1 步:EXPLAIN 看现场

先用 EXPLAIN 看执行计划:

```
+----+------+-------+------+------+---------+----------+
| id | type | rows  | key  | ref  | Extra   |
+----+------+-------+------+------+---------+----------+
|  1 | ALL  | 580k  | NULL | NULL | Using filesort, Using temporary |
|  2 | ALL  | 120k  | NULL | NULL |         |
|  3 | ALL  | 30k   | NULL | NULL |         |
+----+------+-------+------+------+---------+----------+
```

关键词:
- **type: ALL** = 全表扫(最差)
- **rows: 580k** = 扫了 58 万行
- **Using filesort** = 没用索引排序,MySQL 自己在内存/磁盘排
- **Using temporary** = 用了临时表

三个最糟糕的信号同时出现,难怪慢。

### 第 2 步:定位真正的瓶颈

慢的原因有三个:
1. **contract 表没有合适的索引**,WHERE 里 create_time 和 status 都没利用起来
2. **nickname LIKE '%某某%'** 这种**左模糊**用不上 user 表的 nickname 索引
3. **ORDER BY create_time DESC** 用不上索引排序

### 第 3 步:优化 1 —— 加组合索引

```sql
-- contract 表加组合索引
ALTER TABLE contract 
ADD INDEX idx_status_ctime (status, create_time DESC);
```

为啥 `(status, create_time)` 这个顺序?

- **status 在前**:因为 status 是离散值(1, 2),经过 IN 过滤后集合小
- **create_time 在后**:用来做范围过滤和 ORDER BY 下推

如果换成 `(create_time, status)`:
- 范围列放在前,后面的 status 就用不上索引了(MySQL 范围后索引失效规则)

### 第 4 步:优化 2 —— 搞定模糊匹配

`nickname LIKE '%x%'` 和 `goods.title LIKE '%x%'` 都是**左模糊**,索引无效。

几种解法对比:

**方案 A:去掉左模糊**(业务能否接受?)
- 把 `LIKE '%某某%'` 改成 `LIKE '某某%'`(只右模糊),就能用索引
- **真去和产品聊**:"搜索 UP 主要不要支持中间匹配?比如搜 `张` 要不要匹配 `小张三`?"
- 产品说"开头匹配就够了",成功!直接改成右模糊,查询时间立刻降一大截

**方案 B:走 Elasticsearch**
- 如果产品坚持要中间匹配,大表量级的模糊搜 **MySQL 干不动**,该上 ES
- 我们后来的做法:contract 表和 user 表的关键字段同步到 ES,搜索走 ES
- MySQL 只做主键查和精确条件查

**方案 C:全文索引(FULLTEXT)**
- MySQL 自带全文索引,配合 `MATCH AGAINST` 语法
- 对中文分词支持弱(要配 ngram),我们没用

我选的是**方案 A**。

### 第 5 步:优化 3 —— 不要 SELECT *

原 SQL `SELECT c.*` 拉了 30 多个字段,包括几个大 JSON 字段(签约快照、审批意见)。

每次都传这么多字段浪费,改成:

```sql
SELECT c.id, c.user_id, c.goods_id, c.status, c.create_time, c.amount
FROM contract c
...
```

**只拿列表页展示需要的几个字段**。用户点详情页再单独查,走主键超级快。

### 第 6 步:优化 4 —— 分页深度问题

`LIMIT 0, 20` 还好,但产品要做 `LIMIT 10000, 20`(翻到第 500 页)就非常慢:

```sql
-- 慢:MySQL 要扫 10020 行再丢掉前 10000
SELECT * FROM contract ORDER BY create_time LIMIT 10000, 20;

-- 快:"延迟关联" + 主键过滤
SELECT c.* 
FROM contract c
INNER JOIN (
    SELECT id FROM contract 
    WHERE ...
    ORDER BY create_time DESC 
    LIMIT 10000, 20
) t ON c.id = t.id;
```

原理:**子查询只走索引拿 id**(覆盖索引),主查询再用 id 回表拿 `*`。扫的数据量从"10020 行的完整数据"变成"10020 行的 id + 20 行完整数据"。

### 最终效果

```
优化前: P99 = 600ms
├─ 加组合索引: 600ms → 320ms
├─ 去左模糊(改右模糊): 320ms → 110ms
├─ 不要 SELECT *: 110ms → 80ms
└─ 延迟关联分页: 80ms → 30ms

最终: P99 = 30ms (20 倍提升)
```

**面试讲的时候**:重点讲"**为什么**这样优化"和"**怎么发现瓶颈**",不要只罗列结论。

---

## 二、我的 SQL 优化 checklist(慢查询排查流程)

每次线上告警 "慢 SQL 出现",我按这个顺序查:

### 1. 找到具体的 SQL

```bash
# 生产 MySQL 慢查询日志
tail -f /var/log/mysql/slow.log

# 或者 performance_schema
SELECT * FROM performance_schema.events_statements_summary_by_digest
WHERE AVG_TIMER_WAIT > 1e9  -- 平均 1 秒以上
ORDER BY AVG_TIMER_WAIT DESC LIMIT 10;
```

阅文这边走 DBA 平台,慢 SQL 会自动推送到企业微信群。

### 2. EXPLAIN 看执行计划

```sql
EXPLAIN [慢 SQL]

-- 看关键列:
-- type: ALL / index / range / ref / eq_ref / const(从差到好)
-- key: 实际用了哪个索引(NULL = 没用索引)
-- rows: 预计扫描多少行
-- Extra: Using filesort / Using temporary / Using index / Using where
```

**红灯**:
- `type: ALL` = 全表扫
- `rows: 几十万以上` = 扫太多
- `Using filesort` = 没用索引排序
- `Using temporary` = 临时表(group by / distinct / union 触发)

**绿灯**:
- `type: ref / eq_ref / const`
- `Using index` = 覆盖索引(完全在索引上完成,不回表)

### 3. 看表结构和现有索引

```sql
SHOW CREATE TABLE contract;
SHOW INDEX FROM contract;
```

看现有索引够不够用,有没有无用索引(一个字段建了好几个索引浪费空间)。

### 4. 看数据量级

```sql
-- 看表行数(近似,快)
SELECT TABLE_ROWS 
FROM information_schema.tables 
WHERE TABLE_NAME = 'contract';

-- 看字段的唯一性(索引选择性)
SELECT COUNT(DISTINCT status) / COUNT(*) FROM contract;
-- 结果越接近 1 越适合建索引;接近 0 说明区分度差,建了也没用
```

### 5. 重写 SQL / 加索引 / 改业务逻辑

三条路:
- **加索引** — 覆盖不到的 where/order by
- **改 SQL** — 去子查询、拆复杂查询、去左模糊
- **改业务** — 比如列表页加默认时间范围、不给产品"任意条件组合查"

---

## 三、索引设计的几个铁律

### 铁律 1: 区分度低的字段,别建单独索引

```sql
-- 反面教材
ALTER TABLE contract ADD INDEX idx_status (status);
```

status 只有 1/2/3 三个值,**整个表 58 万行,status=1 有 30 万行**。
MySQL 优化器一看"用这个索引还是扫 30 万行,不如直接全表扫",**索引根本不用**。

**正确做法**:和高区分度字段组合。
```sql
ALTER TABLE contract ADD INDEX idx_status_ctime (status, create_time DESC);
```

### 铁律 2: 组合索引的字段顺序,等值列在前、范围列在后

```sql
-- WHERE user_id = ? AND create_time > ?
ADD INDEX idx_uid_ctime (user_id, create_time);  -- 正确

-- 错误顺序
ADD INDEX idx_ctime_uid (create_time, user_id);  -- 错,范围在前,后面 user_id 用不上索引
```

### 铁律 3: 避免回表,走覆盖索引

```sql
-- 场景:列表页只要 id, status, create_time 三个字段
SELECT id, status, create_time FROM contract WHERE user_id = ? ORDER BY create_time DESC;

-- 索引设计成"覆盖"所有查询字段:
ADD INDEX idx_uid_ctime_cover (user_id, create_time, status);
-- 结果:Extra 里出现 "Using index",完全不回表,快得飞起
```

### 铁律 4: 前缀索引(大字段)

```sql
-- email 字段 VARCHAR(255),建完整索引占空间
ADD INDEX idx_email_full (email);           -- 浪费

-- 建前缀 10 字符就够了,区分度已经足够
ADD INDEX idx_email_prefix (email(10));     -- 省空间
```

前缀长度选取:
```sql
-- 看多长的前缀能达到 95% 区分度
SELECT COUNT(DISTINCT LEFT(email, 5)) / COUNT(*) FROM user;
SELECT COUNT(DISTINCT LEFT(email, 10)) / COUNT(*) FROM user;
SELECT COUNT(DISTINCT LEFT(email, 15)) / COUNT(*) FROM user;
-- 选"足够大但不超"的前缀长度
```

### 铁律 5: 不要在索引字段上做运算 / 函数

```sql
-- 错:索引失效
WHERE DATE(create_time) = '2024-01-01';
WHERE create_time + INTERVAL 1 DAY > NOW();
WHERE user_id + 1 = 100;

-- 对:
WHERE create_time BETWEEN '2024-01-01 00:00:00' AND '2024-01-01 23:59:59';
WHERE create_time > DATE_SUB(NOW(), INTERVAL 1 DAY);
WHERE user_id = 99;
```

### 铁律 6: 隐式类型转换会让索引失效

```sql
-- user_id 是 bigint,但查询传了字符串
WHERE user_id = '100';
-- MySQL 做类型转换 → 索引失效

-- 对:
WHERE user_id = 100;
```

这个坑我踩过,Java 里 `String.format("... user_id = %s", userId)` 拼 SQL 没加引号,结果传到 MyBatis 变成字符串。

---

## 四、常见慢 SQL 套路对应优化

### 套路 1:COUNT 大表

```sql
-- 慢:全表扫
SELECT COUNT(*) FROM contract WHERE status = 1;

-- 优化 A:如果总数不变,缓存到 Redis,定时刷新
-- 优化 B:如果 status=1 比例稳定,建组合索引 (status)
-- 优化 C:看业务能否接受近似值,用 information_schema.tables 的 TABLE_ROWS
```

### 套路 2:OR 条件

```sql
-- 慢:OR 容易让 MySQL 放弃索引
SELECT * FROM user WHERE phone = '1' OR email = '2';

-- 优化:改 UNION
SELECT * FROM user WHERE phone = '1'
UNION
SELECT * FROM user WHERE email = '2';
-- 两个独立查询都能用各自的索引,合并结果
```

### 套路 3:IN 大列表

```sql
-- 有时候慢,有时候快,取决于列表大小
SELECT * FROM contract WHERE user_id IN (1, 2, 3, ..., 10000);
```

优化:
- **小列表**(< 500):IN 就行
- **大列表**(> 1000):
  - 临时表 `CREATE TEMPORARY TABLE t ...`,再 JOIN
  - 或者拆成多次查询再业务层合并

### 套路 4:JOIN 过多

```sql
-- 慢:5 张表 JOIN
SELECT a.*, b.x, c.y, d.z, e.w
FROM contract a
LEFT JOIN user b ON ...
LEFT JOIN goods c ON ...
LEFT JOIN payment d ON ...
LEFT JOIN invoice e ON ...
WHERE ...;

-- 优化 A:业务层拆查询,先查 contract,再用 id 列表批量查其他表
-- 优化 B:宽表冗余,把经常一起查的字段冗余到 contract 表
-- 优化 C:数据量小的表做**驱动表**(放 FROM 后第一位)
```

阅文漫剧这边,高频列表查询都做了**宽表**,把 user.nickname、goods.title 这些冗余到 contract_list_view。更新成本稍高,但查询快 10 倍。

### 套路 5:ORDER BY + LIMIT 深分页

前面讲过,用**延迟关联**:

```sql
-- 慢
SELECT * FROM contract ORDER BY create_time DESC LIMIT 50000, 20;

-- 快
SELECT c.* FROM contract c
INNER JOIN (
    SELECT id FROM contract ORDER BY create_time DESC LIMIT 50000, 20
) t ON c.id = t.id;

-- 更快(如果业务允许):游标分页
SELECT * FROM contract 
WHERE create_time < '上页最后一条的 create_time'
ORDER BY create_time DESC LIMIT 20;
```

### 套路 6:UPDATE / DELETE 大批量

```sql
-- 慢且锁表:一次更新 100 万行
UPDATE contract SET status = 2 WHERE create_time < '2023-01-01';

-- 改成分批处理:
-- Java 里循环,每次 1000 行
while (true) {
    int affected = mapper.update(
        "UPDATE contract SET status = 2 WHERE create_time < '2023-01-01' AND status != 2 LIMIT 1000"
    );
    if (affected == 0) break;
    Thread.sleep(100);  // 休息一下别把 MySQL 打挂
}
```

**生产环境批量 UPDATE/DELETE 必须分批**,不然锁表影响其他业务。

### 套路 7:子查询能 JOIN 就 JOIN

```sql
-- MySQL 5.7 以前子查询常被展开成 JOIN 不好优化
SELECT * FROM contract WHERE user_id IN (SELECT id FROM user WHERE level > 3);

-- 直接写 JOIN:
SELECT c.* FROM contract c JOIN user u ON c.user_id = u.id WHERE u.level > 3;
```

MySQL 8.0 对子查询优化好了很多,但 JOIN 写法仍然更清晰、更可控。

---

## 五、实战经验:几个"非索引"优化

### 1. 归档冷数据

contract 表跑了两年,70% 数据是两年前的,用户根本不查。
解法:
- 每月一次归档任务,把 `create_time < 1 年前` 的数据搬到 `contract_archive` 表
- 主表保留热数据,SQL 快得多
- 历史查询走 `UNION archive` 或单独的接口

### 2. 读写分离

签约业务是"写少读多":
- MySQL 主库:处理写(INSERT/UPDATE)
- MySQL 从库:处理读,水平扩展
- ShardingJDBC 或集团的中间件自动路由

**坑**:主从延迟 100ms~1s,写完立即读可能读到老数据。
解决:
- **强一致读**走主库(用 hint 或 annotation)
- **最终一致读**走从库

### 3. Redis 缓存热点 SQL

高频查询(比如首页推荐列表)的结果缓存在 Redis:
```
key: "hot_list:page:1:size:20"
value: JSON 序列化的结果
TTL: 5 分钟
```

注意:
- 缓存击穿:用互斥锁或 "空值缓存"
- 缓存雪崩:TTL 随机化(4-6 分钟而不是统一 5 分钟)
- 缓存穿透:Bloom Filter 过滤不存在的 key

### 4. 分库分表

表到 **千万级** 才考虑,不要提早优化。
阅文漫剧 contract 表才 58 万,**远远没到分表门槛**。
过早分表会带来:
- 跨分片查询复杂
- 分布式事务
- 全局 ID 方案
- 扩容迁移痛苦

**能单表搞定就别分**。

### 5. 连接池调优

经常被忽略的一块。HikariCP 配置:

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20         # 默认 10,高并发调大
      minimum-idle: 5
      connection-timeout: 3000      # 获取连接超时
      idle-timeout: 600000          # 空闲超时
      max-lifetime: 1800000         # 连接最大生命周期
      leak-detection-threshold: 60000  # 连接泄漏检测
```

经验:maximum-pool-size **不是越大越好**。MySQL 单机极限大概几百连接,连接数多了反而拖慢 MySQL。
一般公式:`CPU 核数 × 2 + 磁盘数`,我们生产 20 够用。

---

## 六、踩过的真实坑

### 坑 1:索引建了没生效

排查发现:MySQL 优化器的**统计信息过期**。
解法:
```sql
ANALYZE TABLE contract;   -- 重新计算索引统计
```

如果还不走,可以用 hint 强制:
```sql
SELECT * FROM contract FORCE INDEX (idx_status_ctime) WHERE ...;
```

### 坑 2:一个 IN 查询把 MySQL 打挂

业务同学写了 `WHERE user_id IN (?, ?, ... ?)` 传进去 50 万个 id,MySQL 直接 OOM。
事后改造:
- 应用层限制 IN 列表最多 1000 个
- 超过就分批查
- 代码里加静态检查,SQL 里 IN 的大小做拦截

### 坑 3:update 时 where 写错,全表更新

经典事故。新人把 UPDATE 语句的 WHERE 写错了,加了 `=` 写成了没条件,结果全表 60 万行 status 都变成 2。

现在的红线:
1. **生产 DB 禁用直接 update,要走 DBA 工单平台**
2. DBA 平台强制要 WHERE 条件,要 `LIMIT` 上限
3. 大批量操作要做 dry-run(先查出要影响多少行)

### 坑 4:XA 事务 + MySQL 的坑

分布式事务用 XA,MySQL 有个 bug(某些版本)导致 XA 事务未提交时阻塞 binlog,从库复制卡住。
我们后来用 **本地消息表 + MQ 重试** 替代 XA,不依赖数据库的分布式事务。

### 坑 5:字段类型选错

user 表的 `age` 字段建了 `INT`,4 字节。实际年龄 0-150 用 `TINYINT UNSIGNED`(1 字节)就够了。
千万行的表,一个字段省 3 字节 = 省 3MB 索引空间和内存。

字段类型小贴士:
- **INT 字段如果不存负数**,加 UNSIGNED
- **字符串尽量定长**,VARCHAR 留意长度,别乱给 VARCHAR(1000)
- **时间用 DATETIME 或 TIMESTAMP**,不要 VARCHAR 存 "2024-01-01"
- **布尔用 TINYINT(1)**,不要 VARCHAR 存 "Y/N"
- **大 JSON 字段考虑单独拆表**,避免影响主表 IO

---

## 七、面试高频 Q&A

### Q: 一条 SQL 慢,怎么排查?

> "四步:
>
> 1. **EXPLAIN 看执行计划**,重点看 type / key / rows / Extra
> 2. **看表的数据量、索引结构、字段区分度**
> 3. **分析哪里没用上索引**——WHERE、ORDER BY、JOIN 的 ON 条件
> 4. **优化**:加合适的索引、改写 SQL 消除临时表/filesort、调整业务逻辑
>
> 如果加索引没效果,用 `FORCE INDEX` 强制走或者 `ANALYZE TABLE` 刷新统计。"

### Q: 索引失效的几种情况?

> "我按'出现频率'排:
>
> 1. **左模糊** `LIKE '%xxx%'` —— 最常见
> 2. **WHERE 里对字段做运算/函数** `DATE(c_time) = ...`
> 3. **隐式类型转换** `user_id = '100'`(字段是 INT)
> 4. **OR 两边不全是索引字段**
> 5. **组合索引不满足最左前缀**
> 6. **范围查询之后的字段**(组合索引 `(a, b, c)`,`WHERE a=1 AND b>2 AND c=3`,c 用不上)
> 7. **区分度太低**,优化器觉得全表扫更快
> 8. **NOT IN / !=** 有时不走索引"

### Q: 覆盖索引是什么?

> "**查询需要的字段全部在索引里**,不需要回表去拿其他字段。
>
> 例子:SELECT id, name FROM user WHERE phone = 'x'
> 如果索引是 (phone, name),Extra 里会出现 `Using index`。
>
> 好处:
> - 不回表,减少一次磁盘 IO
> - 通常快 2-5 倍
>
> 代价:索引占空间变大"

### Q: 什么时候需要分库分表?

> "表数据量到**千万级**开始考虑,**亿级**必须做。
>
> 判断标准:
> - **单表 > 1000万行** 或 **单表文件 > 50GB**
> - 加索引也解决不了慢查询(单表本身太大)
> - 写入 QPS 打到单机 MySQL 极限(几千 TPS)
>
> 中间件:ShardingJDBC(Java 端)、MyCat(代理)、集团自研分片中间件。
>
> **我不会主动建议分库分表**——带来的复杂度(跨库 JOIN、分布式事务、全局 ID)往往比性能问题更棘手。"

### Q: 深分页怎么优化?

> "三种方式:
>
> 1. **延迟关联**:子查询只走索引拿 id,主查询 id 回表
>    ```sql
>    SELECT * FROM t JOIN (SELECT id FROM t WHERE ... LIMIT 10000,20) s ON t.id = s.id;
>    ```
> 2. **游标分页**:基于上一页最后一条的排序字段
>    ```sql
>    SELECT * FROM t WHERE create_time < '上页最小值' ORDER BY create_time DESC LIMIT 20;
>    ```
>    但这种不支持跳页。
> 3. **业务限制**:产品上限制最多翻到第 50 页,实际用户也很少翻那么深。"

### Q: 你怎么设计一个高并发查询接口?

> "四层 checklist:
>
> 1. **SQL 层**:确保走索引、覆盖索引、避免临时表
> 2. **DB 层**:读写分离、主从复制
> 3. **缓存层**:Redis 缓存热点查询,5-10 分钟 TTL
> 4. **业务层**:限制查询复杂度(强制时间范围、禁止任意组合查询)
>
> 如果单机扛不住,再考虑分库分表/ES/ClickHouse(分析型场景)。"

### Q: INNODB 和 MyISAM 区别?

> "一句话:**现在都用 InnoDB**,MyISAM 基本退役。
>
> 主要区别:
> - **事务支持**:InnoDB 有,MyISAM 没
> - **锁粒度**:InnoDB 行锁,MyISAM 表锁
> - **外键**:InnoDB 支持,MyISAM 不支持
> - **崩溃恢复**:InnoDB 有 redo log,MyISAM 崩了就完
> - **聚簇索引**:InnoDB 主键就是聚簇索引,MyISAM 没有
>
> 只有一些特殊只读场景(日志表归档)还在用 MyISAM。"

### Q: 事务隔离级别?

> "4 个:
>
> - **READ UNCOMMITTED** - 脏读(几乎不用)
> - **READ COMMITTED** - 解决脏读,Oracle 默认
> - **REPEATABLE READ** - 解决不可重复读,**MySQL 默认**,通过 MVCC 实现
> - **SERIALIZABLE** - 串行化,性能差很少用
>
> MySQL 默认 RR + MVCC,解决了脏读和不可重复读,幻读在 RR 下也基本解决了(间隙锁)。
>
> 实操:一般用默认的 RR 就好,不要手动改成 RC。"

### Q: 乐观锁和悲观锁在 SQL 里怎么实现?

> "**悲观锁**:
> ```sql
> SELECT * FROM t WHERE id = 1 FOR UPDATE;   -- 加行锁
> ```
> 适合冲突概率高的场景,比如抢优惠券。
>
> **乐观锁**:
> ```sql
> UPDATE t SET ..., version = version + 1 
>   WHERE id = 1 AND version = 5;
> ```
> 根据 affectedRows 判断是否成功,适合冲突概率低的场景,比如修改订单状态。
>
> 我们项目大部分用乐观锁,性能更好,只有少数地方(比如分布式扣库存)用悲观锁 + 行锁。"

---

## 八、速记卡

- **慢 SQL 排查**:EXPLAIN → 看 type/key/rows/Extra → 加索引/改 SQL → 验证
- **索引设计顺序**:**等值列在前,范围列在后,排序列尾部**
- **索引失效 Top3**:**左模糊、函数运算、隐式类型转换**
- **深分页利器**:**延迟关联(子查询拿 id + 主查询回表)**
- **覆盖索引**:Using index = 不回表,首选优化方向
- **写操作铁律**:**生产禁止无 WHERE 的 UPDATE/DELETE**,大批量分批
- **连接池**:HikariCP max-pool-size = `CPU×2+磁盘`,不是越大越好
- **读写分离**:默认读从库,"刚写完要读"走主库
- **千万级才考虑分表**,百万级单表加索引就能搞定
- **性能排查永远先 EXPLAIN**,别凭感觉加索引

---

## 九、我真实经历的"最满意一次优化"

讲故事版:

> "我们 C 端结算每月月初有个高峰——UP 主查上月结算详情。
>
> 最初我写了个接口,月初那天 P99 能飙到 3-4 秒,很多 UP 主刷不出来。
>
> 查下来是 3 个问题:
>
> 1. **list 接口查 settlement 表**,没有 `(user_id, settle_month)` 组合索引,全表扫 200 万行
> 2. **详情接口走了 6 张表 JOIN**,包括一个大 JSON 字段的 snapshot
> 3. **每次进页面都查**,没有缓存
>
> 优化分 3 步:
>
> 1. 加 `(user_id, settle_month DESC)` 组合索引 → 600ms
> 2. 拆 SQL:主查 settlement,批量查其他 5 张表,应用层拼装 → 150ms
> 3. 结算数据不变,用 Redis 缓存 30 分钟 → 首次 150ms,命中后 5ms
>
> 最终:P99 从 3s 降到 **30ms**(命中缓存),月初高峰再没被用户投诉。
>
> 这个故事面试时 3 分钟能讲完,涵盖索引设计、SQL 重构、缓存、数据规模判断,面试官会顺着问下去的几个点我也都有料接。"
