# C 端结算优化(周结 + 发票核验 + 层级调整)

> 2026 Q1 的一个"大活"。从原来月结一次,改成按周结算 + 发票核验流程 + B 端下载能力 + 多层级结算单重构。
> 我是这个需求的**主力开发**,对接产品、财务、计费、大数据四个方向,从方案设计到上线 3 周。
> 这份文档是面试真正能讲出来的那种——背景、卡点、方案、坑、亮点,一条龙。

---

## 一、一句话讲清楚是什么

原来分销商(抖音自然流 + MCN)是**月结**,一个月拉一次账、发一次票、打一次款。
财务和业务都不满意:月结对账周期太长、资金占用大、错账回溯难。

这个需求要做的事:
1. **分销商改周结**——一个月 4~5 张结算单,每周一张
2. **C 端加发票核验全流程**——上传 → 核验 → 已收票 → 已打款,状态机搞起来
3. **结算层级重构**——原来一个列表,现在按"收入类型 + 渠道 + 周期"分成三层
4. **B 端下载页面加分销商视角**——运营能按周下载结算单 + 发票
5. **数据爬取**——抖音后台的结算数据自动爬,省掉人工每周手动导出

---

## 二、需求背景(面试开场讲这块)

### 业务诉求
- 分销商规模变大(上百家),月结对账慢,发现错账已经是一个月后,追溯困难
- 抖音端原生本来就是**周级出账**(账单日 7/14/21/28),我们反而月结,**资金占用 2-4 周**
- 财务提了硬要求:发票必须能在系统里核验,避免"纸票收到了金额却对不上"

### 技术诉求
- 原来运营每周从抖音后台手动下载 Excel → 本地合并 → 系统上传,**3 人天/月的重复劳动**
- 结算单只有"已上传/未上传"两个状态,发票收没收、打没打款全靠口头跟进
- 一个结算单类型支撑所有场景,多主体(红袖/宏文)、多渠道(抖音/快手/视频号/小程序)全挤一起,代码一坨

### 我的定位
我是分销平台这边的后端主力。上下游:
- 👆 对接 **财务系统**(发票核验接口)、**计费中心**(结算金额、收票状态)
- 👇 对接 **大数据**(爬虫数据入库)、**前端**(C 端/B 端页面重构)
- ↔️ 协作 **产品**(流程设计)、**运营**(数据字段口径)

---

## 三、核心模块拆解

### 模块 1:结算周期从月改周

#### 业务规则
- **账期定义**:自然周,每周一到周日;用 `R1-R4` 表示一月内的第几周
- **结算周 = 产生周 + 2 周顺延**(对齐抖音),比如 `2026-02-R1` 是 2 月第 1 周产生的收入,2 月第 3 周出账单
- **一个月可能有 5 份结算单**:
  - R1-R4:每周一份"每账期结算单"
  - 第 5 份:**每月返点**(根据月总流水返点比例)
- **自然流量 vs 非自然流量**分开:
  - 自然流量(红果小剧场):**月结**,每月 5-15 号爬一次
  - 非自然流量(广告流/挂载流/免费+付费):**周结**

#### 数据模型改动
原 `settle_bill` 表只有 `settle_month` 一个周期字段。改造:
```sql
ALTER TABLE settle_bill ADD COLUMN settle_period VARCHAR(16) COMMENT '结算周期 2026-02-R1';
ALTER TABLE settle_bill ADD COLUMN period_type TINYINT COMMENT '1周结 2月结 3返点';
ALTER TABLE settle_bill ADD COLUMN revenue_week VARCHAR(16) COMMENT '收入产生周';
ALTER TABLE settle_bill ADD COLUMN entity VARCHAR(32) COMMENT '结算主体 红袖/宏文';

-- 索引:按机构+周期查最频繁
CREATE INDEX idx_org_period ON settle_bill(org_id, settle_period);
```

#### 周期计算工具类
不用第三方库,基于 `java.time` 自己封一层:
```java
public class SettlePeriodUtil {
    /** 产生周 2026-W05 → 结算周 2026-02-R1 */
    public static String calcSettlePeriod(LocalDate revenueDate) {
        // 顺延 2 周
        LocalDate settleDate = revenueDate.plusWeeks(2);
        int month = settleDate.getMonthValue();
        // 该月第几个完整周(ISO 规则)
        int weekInMonth = getWeekOfMonth(settleDate);
        return String.format("%d-%02d-R%d", settleDate.getYear(), month, weekInMonth);
    }
    // 第 5 份返点单用 "2026-02-RM" 表示 Rebate of Month
}
```

> **卡点**:跨月的周怎么算?比如 1 月 31 日那周跨到 2 月,**算 1 月 R5 还是 2 月 R1**?
> 财务口径定的是"**按周日所在月**",写代码时踩了两次坑,后来在 util 加了单元测试全覆盖。

---

### 模块 2:发票核验状态机(最值得讲的一块)

#### 状态定义
```
0 待确认   → 用户还没点"确认结算"
1 未结算   → 用户已确认,等待上传结算单+发票
2 核验中   → 已上传,计费接口校验发票
3 已收票   → 核验通过,财务能打款
4 已打款   → 钱到账
5 发票错误 → 核验失败,回到 1 重新上传
```

#### 状态流转(状态机驱动)
用**枚举 + 策略**的模式,不用 if-else 堆:
```java
public enum SettleStatus {
    TO_CONFIRM(0), UNSETTLED(1), VERIFYING(2), INVOICE_RECEIVED(3),
    PAID(4), INVOICE_ERROR(5);

    // 定义合法流转
    private static final Map<SettleStatus, Set<SettleStatus>> ALLOW = Map.of(
        TO_CONFIRM,       Set.of(UNSETTLED),
        UNSETTLED,        Set.of(VERIFYING),
        VERIFYING,        Set.of(INVOICE_RECEIVED, INVOICE_ERROR),
        INVOICE_ERROR,    Set.of(UNSETTLED),        // 允许重新上传
        INVOICE_RECEIVED, Set.of(PAID),
        PAID,             Set.of()                  // 终态
    );

    public boolean canTransitTo(SettleStatus next) {
        return ALLOW.getOrDefault(this, Set.of()).contains(next);
    }
}
```

每次变更前强校验,不合法的直接拒:
```java
public void transit(Long billId, SettleStatus next, String operator) {
    SettleBill bill = mapper.selectForUpdate(billId);  // 行锁
    if (!bill.getStatus().canTransitTo(next)) {
        throw new BizException("非法状态流转: " + bill.getStatus() + " → " + next);
    }
    mapper.updateStatus(billId, next.code(), operator);
    // 发异步事件,推送通知/日志
    eventBus.publish(new SettleStatusChanged(billId, bill.getStatus(), next));
}
```

#### 发票核验异步流程
用户上传发票 → 我们**不直接同步调财务**(它慢,偶尔超时),而是:

```
[用户] 上传发票
   ↓
[我方] 存 COS + 落库,状态改"核验中"
   ↓ 发 TDMQ 消息
[消费者] 调财务核验接口
   ↓
  成功 → 状态 "已收票"
  失败 → 状态 "发票错误",记录失败原因
   ↓
[用户] 在页面看到失败原因,重新上传 → 回到"核验中"
```

> **卡点 1**:财务接口没有"异步回调",只能轮询。我用 **TDMQ 延迟消息**每 30 秒重试一次,最多 10 次,超过就报警让运营介入。
>
> **卡点 2**:"重新上传"场景,状态要能从 `INVOICE_ERROR` 回到 `UNSETTLED`,我在状态机里专门加了这条逆向边,并且加了审计日志记录"被打回多少次"——后来 PM 根据这个数据做了机构画像。

#### 自动确认(超时兜底)
产品要求:如果分销商 **10 天没点"确认结算"**,系统默认确认,避免卡死流程。

用**XXL-Job 每天跑**:
```java
@XxlJob("autoConfirmSettleJob")
public void autoConfirm() {
    LocalDate threshold = LocalDate.now().minusDays(10);
    List<SettleBill> bills = mapper.findToConfirmBefore(threshold);
    for (SettleBill b : bills) {
        try {
            transit(b.getId(), SettleStatus.UNSETTLED, "SYSTEM_AUTO");
            log.info("auto confirm billId={}", b.getId());
        } catch (Exception e) {
            log.error("auto confirm failed billId={}", b.getId(), e);
        }
    }
}
```

---

### 模块 3:结算单三级层级重构(前后端都动)

#### 原结构(一个扁平列表)
```
[所有结算单]
- 2026-01 抖音周结单 R1
- 2026-01 抖音周结单 R2
- 2026-01 快手月结单
- 2026-01 内容收入单
- ...
```
问题:一个机构同时是分销商+内容创作者时,**混着看**,用户经常找错。

#### 新结构(三层 Tab)
```
结算单
├─ 推广收入(按周)
│  ├─ 抖音渠道
│  │  ├─ 正常周(R1/R2/R3/R4)
│  │  └─ 每月返点(RM)
│  └─ 快手渠道
│     └─ 正常月
└─ 内容收入(月)
```

#### 实现做了抽象
每个 Tab 的数据源、结算规则、字段都不一样。我用了**策略模式**,不让 Controller 臃肿:

```java
public interface SettleTabProvider {
    TabType type();
    PageResult<BillVO> listBills(Long orgId, QueryDTO q);
    BillDetailVO detail(Long billId);
}

// 三个实现类
@Component class PromotionDouyinProvider implements SettleTabProvider { ... }
@Component class PromotionKuaishouProvider implements SettleTabProvider { ... }
@Component class ContentMonthlyProvider implements SettleTabProvider { ... }

// Controller 只做路由
@GetMapping("/bills")
public Result<?> list(@RequestParam TabType tab, @RequestParam Long orgId, QueryDTO q) {
    SettleTabProvider p = providerFactory.get(tab);
    return Result.ok(p.listBills(orgId, q));
}
```

好处:新加一个渠道(比如视频号),写一个新 Provider 注册进去就行,不用动老代码。

---

### 模块 4:B 端下载页面加"分销商"视角

#### 需求
原来 B 端「下载机构附件」只支持**内容创作者**月粒度下载。现在运营也要能按周下载分销商的结算单和发票,用于手动给财务核验打款(过渡方案,以后自动化)。

#### 关键改动
- 页面顶部加**机构类型筛选器**(内容创作者 / 分销商),切换时整个查询条件和列表全变
- 分销商模式下,**「收入结算月」细化到周**(`2026-02-R1`)
- 把**「下载确认书」**按钮替换成**「下载结算单」**
- 后端接口参数加 `orgType` 区分

#### 前端 + 后端配合
和前端小俊对了一下午:
- 一套页面两套模式用 `v-if` 切是不是太挫了?最后用的是**两个独立组件 + 顶部筛选器**,切换时重新挂载
- 接口设计上,虽然复用了同一个 `/download/list` 路径,但内部根据 `orgType` 走不同 Service,避免 `if orgType == x then...` 的分支

---

### 模块 5:抖音数据爬取(未落地,只做了预研)

**背景**:运营每周手动从抖音后台导出 Excel → 整理 → 系统上传,**3 人天/月**,而且容易出错。

**方案**:大数据团队的同学(钟先乐)已经有抖音管家账号的 cookie 池,他们按我们的字段规范爬数据,**每天增量推 TDMQ**,我们消费入库。

我这边定了**消息协议**(字段名、类型、主键、幂等键),写了**消费端逻辑**(去重、冲突处理、异常告警),但**生产侧还没上**,这一期先保留人工上传通道作为主路径,爬取作为 shadow 模式跑对比。

> **这个点面试怎么讲**:诚实讲"预研阶段已完成,生产侧等大数据排期",突出你做的**协议设计 + 消费端健壮性**——比"我做完了所有东西"更可信。

---

## 四、我遇到的三个最坑的点

### 坑 1:周结"跨月周"算在哪个月
财务、产品、我们三方扯了两次会。
- 产品说:**按周一所在月**
- 财务说:**按周日所在月**
- 我最早按 ISO 标准(周四所在月)写的代码

最后以财务为准,但这个事让我意识到:**业务规则必须文档化+测试覆盖**,不能靠"我们说了算"。
我在 util 里写了 20+ 个边界 case 的单测,跨年、闰年、月末周全覆盖。

### 坑 2:状态机被越权改写
开发中有一次,别人写新功能直接 `UPDATE settle_bill SET status = 3`,跳过了状态机校验。
线上立刻出问题:有些单子从"待确认"直接跳到了"已收票",财务对账出错。

我做了两件事:
- **MyBatis 拦截器**:所有对 `settle_bill.status` 的直接 UPDATE 抛异常,强制走 `SettleStatusService`
- **CR 规范**:Service 层任何状态变更必须走状态机,评审时必检项

### 坑 3:发票核验接口慢 + 不稳定
财务的核验接口 P99 接近 8 秒,偶尔 timeout。如果同步调用,用户上传发票后页面一直转圈,体验炸裂。

解决方案前面提过(异步 + 延迟消息轮询),但真正难的是**和财务同学对接口协议**:
- 对方一开始想让我们把发票 base64 塞请求体,我拒绝——改为**我们把 COS URL 传给他们**,他们自己下载核验
- 对方一开始没考虑"重新上传"场景,我让他们**接口必须幂等**(用 `billId + invoiceHash` 做幂等键)

---

## 五、亮点提炼(面试能用的 3 个数字)

1. **人效提升**:运营结算相关操作从 **3 人天/月降到 0.5 人天/月**(确认结算 + 手动介入打款异常)
2. **资金占用缩短**:从月结到周结,分销商平均**回款周期从 35 天缩到 14 天**,带头部机构给了好评
3. **结算错账率**:状态机 + 核验流程上线后,**错账从每月 3-5 起降到 0**(上线 3 个月内)

---

## 六、技术栈 + 代码量

- **后端**:Spring Boot + MyBatis + XXL-Job + TDMQ + Redis
- **存储**:COS(发票文件) + MySQL(结算单主表)
- **代码量**:约 **5000 行**(含新增 + 重构),其中状态机 + Provider 框架约 800 行
- **参与角色**:我(主力)+ 前端 1 人 + 产品 1 人 + 计费对接 1 人 + 大数据对接 1 人

---

## 七、面试问到可能的追问 + 准备好的答案

### Q1:为什么选状态机而不是 if-else?
状态多(6 个)、流转规则复杂(有逆向、有终态),if-else 写起来容易漏分支。枚举 + 静态流转表,新加状态只需要改一行 Map,并且**一眼看懂全图**,CR 也快。

### Q2:发票上传怎么保证幂等?
幂等键:`billId + invoiceFileMd5`。同一张发票重复上传只会插一条日志,不会重复调财务接口。另外 DB 层 `(bill_id, invoice_hash)` 唯一索引兜底。

### Q3:三层 Tab 切换的性能?
- 初次加载只请求当前 Tab 的数据,其他懒加载
- 列表分页 20 条/页,机构侧常用近 3 个月,默认筛选条件控制数据量
- Provider 里缓存了机构 → 可用 Tab 的映射(Redis TTL 30 min),避免每次都查权限表

### Q4:XXL-Job 定时自动确认,万一重复跑怎么办?
- XXL-Job 本身支持路由策略为"分片广播"或"故障转移",我们选了**故障转移**,同时刻只有一个实例执行
- Job 内部还加了 **Redis 分布式锁**(`SETNX settle:auto_confirm EX 600`),双保险
- 业务层:即使真重复跑了,状态机只允许 `TO_CONFIRM → UNSETTLED` 一次,重复调用会抛"非法流转"异常,幂等天然保证

### Q5:跨渠道数据对账怎么做?
每月 20 号后跑**对账 Job**,拉计费侧总金额 vs 我们 settle_bill 求和,差异 > 100 元报警到运营群。目前上线后差异全部 = 0(因为金额来源就是计费)。

---

## 八、如果让我重做,我会怎么优化

1. **状态机代码迁到独立库**,整个分销平台的订单/合同/结算状态机共用一套框架
2. **发票核验做本地轻量校验**(金额、主体名从 OCR 拉出来先比对),再调财务接口,减少无效请求
3. **数据爬取上线后**,把 shadow 模式改成 primary,人工上传降级为容灾通道
4. **加实时大屏**:机构未确认结算单数量 / 平均核验时长 / 错账数 三个指标,运营团队能直接看

---

## 九、一句话总结(开场用)

> "这个需求是我 2026 年初做的最重的项目之一,C 端周结 + 发票核验状态机 + 结算单三层重构,我是主力,对接财务、计费、大数据四个方向 3 周上线。难点在状态机设计和异步核验的健壮性,上线后分销商回款周期从 35 天缩到 14 天,错账降到 0。"
