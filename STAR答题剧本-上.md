# STAR 答题剧本(上)· 签约 / 结算模块

> 基于阅文漫剧分销平台真实工作内容整理。
> 每个剧本 4 部分:一分钟版 / 三分钟版 / 预设追问 / 踩雷警告。

## 使用说明

面试官问"讲一个你做过的最复杂的",直接按这个剧本讲。

- **一分钟版**:15 秒开讲、60 秒讲完
- **三分钟版**:完整 STAR,面试官让你展开时用
- **预设追问**:8 个高频追问,每个都有标准答法
- **踩雷警告**:别主动说的话

---

# 剧本 1 · 签约框架重构(5 种合同类型 5→1 天)

**推荐开口**:"我做过一个签约框架重构,业务每隔一两个月要加一种新合同类型,我把'加一种改 3-5 处代码要 5 天'压到了'只加一个类 1 天'。"

## 一分钟版

> 阅文漫剧分销平台有 5 种合同类型:个人签约、机构合作、补充协议、版权授权、委托制作。共性多(都要做幂等、参数校验、合同创建、后置回调),个性化也多(个人查 8 项数据,机构查 15 项)。
>
> 最早是 if/else 堆一个 300 行方法,每加一种合同要改 3-5 处代码。
>
> 我用**策略模式 + 模板方法**重构:`ContractInvoker` 是策略,`CreateContractHandler` 是模板方法基类管标准流程,`CreateContractContext` 泛型上下文装主体数据。**新合同接入从 5 天压到 1 天,核心代码零改动**。

## 三分钟版

### Situation

阅文漫剧分销平台核心模块之一是"分销签约",支持 UP 主和机构 MCN 跟平台签合同。业务在一两年内陆续提了 5 种合同类型:

1. 个人签约
2. 机构合作
3. 补充协议
4. 版权授权
5. 委托制作

每种流程都有**共性步骤**:幂等校验(合同号去重)→ 参数验证 → 合同创建(调合同中心)→ 后置回调(发通知、更新状态)。也有**个性化**:个人要查实名认证、银行卡、人脸识别 8 项数据;机构要查企业资质、对公账户、法人身份证 15 项。

### Task

接手这模块时代码已经乱,**每加一种合同要改 3-5 处核心代码,开发周期 3-5 天**,review 谁都不敢点"同意"。

要重构得让:
- 新合同接入快(当时提了要加"委托制作")
- 共性代码只写一遍
- 个性化逻辑清晰隔离
- 不能影响已上线的 3 种合同

### Action

**第一步:拆共性和个性**。

我把每种合同流程画出来,发现共性是:幂等 → 参数校验 → 合同创建 → 后置回调。这 4 步所有合同类型都要做,只是中间"合同创建"这一步逻辑不同。

这是典型的**模板方法模式** — 流程固定,某几步让子类覆写。

**第二步:策略模式做类型路由**。

光有模板方法不够,还需要根据 `contract_type` 选对应的处理器。抽 `ContractInvoker` 接口,每种合同类型一个实现类:

```java
public interface ContractInvoker {
    ContractType getType();
    ContractResult invoke(CreateContractContext ctx);
}

public abstract class CreateContractHandler implements ContractInvoker {
    // 模板方法 — final 防止子类破坏流程
    public final ContractResult invoke(CreateContractContext ctx) {
        idempotentCheck(ctx);
        validateParams(ctx);
        Contract c = doCreate(ctx);    // 子类实现
        afterCreate(c, ctx);
        return ContractResult.success(c);
    }
    protected abstract Contract doCreate(CreateContractContext ctx);
}

@Component
public class PersonalSignContractHandler extends CreateContractHandler {
    public ContractType getType() { return ContractType.PERSONAL_SIGN; }

    @Override
    protected Contract doCreate(CreateContractContext ctx) {
        // 个人签约:从上下文拿 8 项数据,调合同中心
        IdentityInfo id = ctx.get(ContextKey.IDENTITY, IdentityInfo.class);
        BankCardInfo card = ctx.get(ContextKey.BANK_CARD, BankCardInfo.class);
        // ...
    }
}
```

**第三步:`CreateContractContext` 泛型上下文装数据**。

每种合同要的数据不一样,不可能塞到 `ContractHandler.doCreate(String a, String b, ...)` 里。我做了个泛型 Map 容器:

```java
public class CreateContractContext {
    private final Map<ContextKey, Object> data = new HashMap<>();

    public <T> T get(ContextKey key, Class<T> type) {
        return type.cast(data.get(key));
    }

    public static CreateContractContext forPersonal(Long guid) {
        CreateContractContext ctx = new CreateContractContext();
        ctx.put(ContextKey.IDENTITY, identityDriver.getByGuid(guid));
        ctx.put(ContextKey.BANK_CARD, bankCardDriver.getByGuid(guid));
        ctx.put(ContextKey.FACE_RECOG, faceRecogDriver.getByGuid(guid));
        // ... 8 项
        return ctx;
    }

    public static CreateContractContext forOrg(String orgId) {
        CreateContractContext ctx = new CreateContractContext();
        ctx.put(ContextKey.ORG_INFO, orgManager.getOrgInfo(orgId));
        ctx.put(ContextKey.COMPANY_CERT, companyCertDriver.getByOrgId(orgId));
        // ... 15 项
        return ctx;
    }
}
```

`ContextKey` 是 enum,编译期就能发现 key 拼写错误。

**第四步:入口 Service 按 type 路由**。

```java
@Service
public class ContractService {
    private final Map<ContractType, ContractInvoker> invokerMap;

    @Autowired
    public ContractService(List<ContractInvoker> invokers) {
        this.invokerMap = invokers.stream()
                .collect(toMap(ContractInvoker::getType, identity()));
    }

    public ContractResult createContract(ContractType type,
                                         CreateContractContext ctx) {
        ContractInvoker invoker = invokerMap.get(type);
        if (invoker == null) throw new BusinessException("unsupported " + type);
        return invoker.invoke(ctx);
    }
}
```

### Result

- **新合同接入从 5 天 → 1 天**,核心代码零改动
- **签约接口代码量减少 40%**
- 已支撑 **5 种合同类型**稳定运行
- 后面加"委托制作"时,新人 1 天就接完

## 预设追问

### Q1:策略模式和模板方法模式放一起,不会过度设计吗?

**答**:不会。两个模式解决不同的问题:

- **策略**解决"不同类型走不同逻辑"(路由)
- **模板方法**解决"同一个流程,某几步不同"(复用共性 + 隔离个性)

我这里是两者一起用 — 策略选类型,模板方法统一流程。如果只用策略,每个 Invoker 都要重复写幂等 → 校验 → 创建 → 回调 这 4 步;只用模板方法,没法按类型路由。

### Q2:`CreateContractContext` 用 Map 不用强类型对象,不会丢类型安全吗?

**答**:部分丢了,但有补偿。

- **编译期**:`ContextKey` 是 enum,拼错 key 就编译失败
- **获取时**:`ctx.get(ContextKey.IDENTITY, IdentityInfo.class)` 传 Class,内部 `type.cast()` 做强转。放错类型运行时会 ClassCastException,但在 Handler 代码里立即暴露
- **如果做成强类型**:要为每种合同类型建 `PersonalContext / OrgContext / SupplementContext...`,类爆炸,共性字段还要抽公共父类

tradeoff:Map 写法省代码,类型安全"有但不极致"。

### Q3:5 种合同类型的演进顺序是怎样的?

**答**:最早只有"个人签约"。第二期加"机构合作"时发现代码越改越难维护,这时推动了重构。重构后"补充协议""版权授权""委托制作" 3 种都是新人按框架 1 天接完的。

### Q4:合同中心是你写的吗?

**答**:不是。合同中心是集团公共中台(跨部门用的),不是业务组写的。**我做的是业务层**(分销签约模块),负责:

- 对接合同中心(TRPC)
- 管理业务侧的合同状态
- 流程编排(谁先做、谁后做)
- 后置通知

### Q5:如果下游合同中心挂了,invoke 会怎么样?

**答**:`doCreate` 抛 `BusinessException`。全局 `@ControllerAdvice` 捕获转成 HTTP 响应 + 错误码。本地事务回滚(没落库)。

但这有个一致性风险:**合同中心已创建,我们本地落库失败**。对策:

- 本地做"草稿状态"预先落库,合同中心调用成功后才更新到"已创建"
- 草稿状态的记录定时 Job 扫,用合同号反查合同中心补偿

### Q6:新加一种合同要做哪些步骤?

**答**:

1. 加一个 `@Component` 实现 `ContractInvoker`(继承 `CreateContractHandler`)
2. 在 `ContractType` enum 加一个值
3. 如果需要新的上下文数据,在 `ContextKey` enum 加 key、在 `CreateContractContext.forXxx()` 里装
4. 写单测

**就这 4 步,核心代码零改动**。

### Q7:模板方法的 `invoke` 为什么要 `final`?

**答**:防子类破坏流程。如果不 final,子类可以 override `invoke` 完全跳过幂等校验,那模板方法就白做了。`final` 是强制约束。

### Q8:如果需求变成"同一种合同类型,不同场景走不同分支"怎么办?

**答**:两种方案:

1. **在 `doCreate` 里做内部分支**:适合场景少(2-3 个),放 if/else
2. **拆成多个 Handler + 共用 ContractType**:在 Spring 注入时加个 `@Qualifier` 路由键

实际工作中只遇到过第一种,够用。

## 踩雷警告

- **别说"我整个重构了 300 行老代码"** — 带抬杠前人的感觉。说"我推动了一次重构,解决了加合同类型改动面大的问题"
- **别吹"代码量减少 90%"** — 40% 是真实数字,吹多了追问数据会掉链子
- **别说"合同中心是我写的"** — 集团中台,对接方是你
- **别主动说"模板方法可以用 Spring TemplateCallback 实现"** — 我们没用,被追问容易翻车

---

# 剧本 2 · N+1 查询优化(HashMap 本地缓存 3-5s→500ms)

**推荐开口**:"做过一个简单但量化漂亮的性能优化,结算列表从 3-5 秒压到 500ms,核心改动 5 行代码。"

## 一分钟版

> 结算列表接口每次查 50-200 条记录,每条要显示操作人名字。老代码 for 循环调用户 RPC,**最差 200 次调用,接口 3-5 秒**。
>
> 关键观察是:同一批列表里 operatorId 重复度很高(运营操作就那几个人)。我用**方法内 HashMap + `computeIfAbsent`** 做请求级缓存,同一个 operatorId 只调一次 RPC。
>
> 效果:**RPC 从 200 次降到 10-20 次,接口响应 3-5s → 500ms**,生产监控的缓存命中率常年 85% 以上。

## 三分钟版

### Situation

阅文漫剧分销平台的**结算分润模块**(我 Owner),后台有个"结算列表"接口给运营看。一次分页查 50-200 条记录,每条都要展示几个字段:

- 结算单号、金额、状态等(数据库直接 SELECT)
- **操作人姓名**(要通过 userId 调用户服务 RPC)

老代码:

```java
List<SettlementDO> list = mapper.list(param);
return list.stream().map(s -> {
    SettlementVO vo = SettlementVO.from(s);
    UserDTO u = userService.getByUserId(s.getOperatorId());   // RPC!
    vo.setOperatorName(u.getName());
    return vo;
}).collect(toList());
```

运营投诉:**列表打开要 3-5 秒**,页面 loading 卡。

### Task

优化到 1 秒以内。

要求:
- 不能改用户服务的接口(它是跨团队的 RPC 服务)
- 尽量小改动(列表接口不是核心链路,不值得上 Redis)

### Action

**第一步:找根因**。

打日志看 RPC 调用次数 — 确认是 N+1。200 条列表 = 200 次用户 RPC。用户服务单次 20ms,200 次就是 4 秒。

**第二步:观察数据特征**。

找运营 Dump 了一周的结算操作日志,发现:**50-200 条记录里,真实 operator 只有 5-15 个人**(都是特定几个运营同学在操作)。重复度 85%+。

这意味着**方法内缓存**就能解决问题,不用 Redis。

**第三步:写缓存**。

```java
public List<SettlementVO> listSettlements(QueryParam param) {
    List<SettlementDO> list = mapper.list(param);

    // 方法内本地缓存 — 生命周期 = 一次请求
    Map<Long, UserDTO> userCache = new HashMap<>();

    List<SettlementVO> result = list.stream().map(s -> {
        SettlementVO vo = SettlementVO.from(s);
        // 命中 cache 就直接返,没命中才调 RPC
        UserDTO operator = userCache.computeIfAbsent(
                s.getOperatorId(),
                uid -> userService.getByUserId(uid)
        );
        vo.setOperatorName(operator.getName());
        return vo;
    }).collect(toList());

    // 生产监控
    log.info("settlement list: size={}, unique operators={}, hit rate={}%",
            list.size(),
            userCache.size(),
            (list.size() - userCache.size()) * 100 / Math.max(list.size(), 1));

    return result;
}
```

核心在 `computeIfAbsent`:同 key 只执行一次 `uid -> userService.getByUserId(uid)`,后续都从 Map 取。

**第四步:加监控**。

我在日志里加了命中率统计。生产上线后看日志,命中率稳定在 85% 以上。

### Result

- **RPC 调用从最差 200 次 → 10-20 次**
- **接口响应 3-5s → 500ms**
- **生产缓存命中率 85%+**
- 改动只有 5 行代码

## 预设追问

### Q1:为什么不用 Redis 缓存用户信息?

**答**:三个原因:

1. **QPS 不高**:运营后台,日几百次调用。上 Redis 性价比低,还要维护连接、序列化
2. **一致性问题**:用户改了名字,Redis 要做失效。方法内 HashMap 自带"请求级一致性" — 同一次请求里看到的用户名一致,请求结束就释放
3. **运维复杂度**:加 Redis 就加了一个依赖,挂了会拖慢列表

如果哪天 QPS 涨到几千,再升级到 Caffeine 本地缓存 + Redis 两级缓存。

### Q2:批量接口 `userService.batchGetByUserIds(Set)` 一次调不是更好?

**答**:更好,如果用户服务提供这个接口的话。

实际我这里**没有**批量接口。用户服务是跨团队的老服务,不愿意改。如果能加批量接口,方案会是:

```java
// 1. 收集所有需要的 userId
Set<Long> userIds = list.stream().map(SettlementDO::getOperatorId).collect(toSet());
// 2. 一次批量查
Map<Long, UserDTO> userMap = userService.batchGetByUserIds(userIds);
// 3. 列表直接取
list.stream().map(s -> {
    UserDTO u = userMap.get(s.getOperatorId());
    ...
});
```

这是最优解。HashMap `computeIfAbsent` 是"没有批量接口"场景下的次优解。

### Q3:并发安全吗?

**答**:**安全**。HashMap 是**方法内局部变量**,不跨线程,不会被多个请求共享。每次请求都 new 一个新的 HashMap。所以**不需要 ConcurrentHashMap**。

这点 review 时要强调,避免有人误以为"HashMap 不安全要改成 ConcurrentHashMap"。

### Q4:如果用户服务在中途改了某个 userId 的名字,这批列表会混乱吗?

**答**:不会。同一次请求里,一个 userId 只查一次,后续都取缓存。所以**请求级快照一致**。

如果用户在请求期间改名,下次新请求的列表会看到新名字。这是可接受的行为。

### Q5:`computeIfAbsent` 如果 lambda 抛异常怎么办?

**答**:HashMap 不会把这个 key 存进去。下次同一 userId 还会再尝试 RPC。

如果希望"失败也缓存"(避免某个挂掉的 userId 反复重试),可以:

```java
UserDTO operator;
try {
    operator = userCache.computeIfAbsent(uid, this::fetchUser);
} catch (Exception e) {
    userCache.put(uid, UserDTO.UNKNOWN);   // 失败占位
    operator = UserDTO.UNKNOWN;
}
```

我们没做这个,因为 RPC 失败应该让整个请求失败,不该默默隐藏。

### Q6:这个优化怎么测出来的?

**答**:

1. **本地测**:起几个 mock,模拟 200 条列表,对比改前改后耗时
2. **压测**:QA 环境压 100 QPS,看 P99 变化
3. **生产灰度**:先上 10% 流量,观察接口 P99 和 RPC 调用量
4. **全量**:确认无回归后放量

生产上线前加了 metric:`settlement.list.rpc.count` 和 `settlement.list.rt`,两个都 dashboard 可见。

### Q7:如果列表扩大到 1000 条(比如导出场景),这个方案还行吗?

**答**:导出场景不走列表接口,走专门的 `ExportTaskDataService` 异步任务。那里是另一套方案:

- 分页查数据(比如每批 500 条)
- 批量收集 userId 去重
- 批量调用户服务(如果有)或并行 RPC
- 生成 CSV 传 COS

列表接口始终限定 `pageSize <= 200`,避免一次太多。

### Q8:会有其他地方的 N+1 问题吗?

**答**:我顺手排查了 10 多个后台列表接口,发现:

- 7 个有类似问题,都改成 HashMap + `computeIfAbsent`
- 3 个是 LIST 拼接了多个表,改成 JOIN 一次查完
- 剩下 2 个本来就是 N 条记录对应 N 个外部系统,没法避免

复用了这个模式后,**列表接口整体性能提升了一个数量级**。

## 踩雷警告

- **别说"命中率 99%"** — 吹高了数据掉链子。85% 是真实数字,有余量
- **别说"我凭经验想到的"** — 听起来像蒙的。说"我 dump 了操作日志发现重复度高"
- **别主动说 `ConcurrentHashMap`** — 被追问为什么用会绕,说"方法内局部变量不跨线程"就行
- **批量接口那个点要自信答** — 如果面试官直接问"为什么不用 batchGet",先承认"如果有当然更好",再说"用户服务没提供批量接口,HashMap 是次优解"

---

# 剧本 3 · organization_mapping 新旧机构 ID 双向转换

**推荐开口**:"做过一个典型的'历史系统兼容'问题 — 我们有新旧两套机构 ID 体系,老的改不动(千万级数据、几十个业务线在用),新的又不能适配老 ID,我做了一张映射表双向转换。"

## 一分钟版

> 阅文多业务线遗留新旧两套机构 ID:老的分润系统上线多年,千万级数据、几十个业务线在调,改不动;新的机构主数据系统又不能适配老 ID。
>
> 分销结算需要同时用两套 — **前端用新 ID 查询,分润系统只认老 ID,返回要翻译回新 ID 给前端**。
>
> 我设计了 `organization_mapping` 单独一张映射表,在 Service 层统一做双向转换,提供单次 + 批量两个接口。**千级机构平滑过渡,零侵入新业务,分润结算零差错**。

## 三分钟版

### Situation

阅文是个大集团,历史上多个业务线独立演进,机构(公司/MCN)的 ID 体系**不统一**:

- **老分润系统**:上线多年,存了好几年结算、分账、对账数据,几十个业务线在用,**千万级数据**,用老 ID
- **新机构主数据系统**:最近几年做的"机构身份统一入口",用新 ID(格式更规范)

我做分销结算模块时,业务流程涉及这两套系统:

- 前端(漫剧分销平台)用**新 ID**查询
- 分润系统**只认老 ID**(改不动)
- 返回结果要翻译成**新 ID**给前端

### Task

做个兼容层,让:

- 分销结算能正常调分润系统
- 前端完全不知道老 ID 的存在
- 新业务代码不被老 ID 污染
- 千级机构(实际需要映射的机构数量)都能正确转换

### Action

**第一步:评估改造方案**。

三个方案:

1. **改老分润系统**:动几十个业务线,排不过来
2. **新老系统用相同 ID**:新系统已上线,改 ID 要迁移新业务的所有引用,风险大
3. **加一层映射表**:成本最低,兼容性最好

选方案 3。

**第二步:设计映射表**。

核心字段只要 3 个必须:

```sql
CREATE TABLE organization_mapping (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    org_id VARCHAR(64) NOT NULL COMMENT '【新系统】标准机构ID',
    old_system_id VARCHAR(64) NOT NULL COMMENT '【老系统/分润系统】旧机构ID',
    status TINYINT DEFAULT 1 COMMENT '状态:1有效 0无效',
    create_time DATETIME DEFAULT NOW(),
    update_time DATETIME DEFAULT NOW(),
    UNIQUE KEY uk_org_id (org_id),
    UNIQUE KEY uk_old_system_id (old_system_id)
);
```

关键点:

- **两边都加唯一索引**,新老双向查询都 O(1)
- `status` 字段预留"软下架"能力
- 不建外键,保持独立,删表不影响新业务

**第三步:Service 层做统一翻译**。

```java
@Service
public class OrganizationMappingService {

    public String newToOld(String newId) {
        OrganizationMappingDO m = mapper.findByOrgId(newId);
        if (m == null) throw new BusinessException("机构映射缺失: " + newId);
        return m.getOldSystemId();
    }

    public String oldToNew(String oldId) {
        OrganizationMappingDO m = mapper.findByOldSystemId(oldId);
        return m == null ? null : m.getOrgId();
    }

    public Map<String, String> batchOldToNew(Set<String> oldIds) {
        if (oldIds.isEmpty()) return Collections.emptyMap();
        List<OrganizationMappingDO> list = mapper.findByOldSystemIds(oldIds);
        return list.stream().collect(toMap(
                OrganizationMappingDO::getOldSystemId,
                OrganizationMappingDO::getOrgId
        ));
    }
}
```

**第四步:业务接口流转**(以周结算为例):

```java
public PagedData<WeekSettleVO> queryWeekSettle(WeekSettleReq req) {
    // 1. 前端传新 ID → 转老 ID
    String oldOrgId = mappingService.newToOld(req.getOrgId());

    // 2. RPC 调分润系统(只认老 ID)
    List<ProfitDTO> profits = profitProvider.queryManjuWeekSettle(
            oldOrgId, req.getStartDate(), req.getEndDate(),
            req.getPageNo(), req.getPageSize());

    // 3. 分润返的是老 ID 列表 → 批量反向转新 ID
    Set<String> oldIds = profits.stream()
            .map(ProfitDTO::getOrgId).collect(toSet());
    Map<String, String> oldToNew = mappingService.batchOldToNew(oldIds);

    // 4. 查新 ID 对应的机构名字(走 OrgManager 聚合层)
    Map<String, String> orgNames = orgManager.batchGetOrgName(oldToNew.values());

    // 5. 组装 VO(带新 ID + 名字)给前端
    return profits.stream().map(p -> {
        WeekSettleVO vo = WeekSettleVO.from(p);
        String newId = oldToNew.get(p.getOrgId());
        vo.setOrgId(newId);
        vo.setOrgName(orgNames.get(newId));
        return vo;
    }).collect(...);
}
```

**核心设计点**:

- **转换逻辑只在 Service 层做**。Controller 收新 ID、Mapper/Provider 拿老 ID,层层隔离
- **单次 + 批量两个接口都提供**,批量走 `IN` 查询减少 DB 调用
- **单次出错能定位**(`throw new BusinessException("机构映射缺失")`),不会静默失败

### Result

- **千级机构新旧 ID 平滑过渡**
- **零侵入新业务代码**
- **分润结算零差错**

## 预设追问

### Q1:为什么不在 DB 加视图做映射?

**答**:分润系统是**另一个团队的另一个服务**,它的 DB 不在我们这边。视图只能在同一个 DB 里做,跨服务不行。

而且视图是 DB 层的东西,业务逻辑(比如"老 ID 不存在时走什么降级")放 DB 不合适,放 Service 更灵活。

### Q2:新机构没有老 ID 怎么办?

**答**:新机构在新系统创建时**不会往分润系统推**(分润系统已经封存,不接新数据),所以不会有老 ID。

分销结算的对象是"历史签约机构",它们必然有老 ID。如果未来新机构要接入结算,有两种方案:

1. **运维批量初始化**:手动 INSERT 一条,`old_system_id` 用分润系统预留 ID 段
2. **业务层降级**:`newToOld` 找不到时返回 null,Service 判空后走另一条"不用老 ID 的路径"(如果分润系统有的话)

### Q3:映射表会不会越来越大?

**答**:千级记录,表本身就是千行,完全不大。两个唯一索引内存占用极小。即使未来扩到 10 万级,MySQL 也一点压力没有。

### Q4:一对多或多对一的情况吗?

**答**:极少但存在。有过某个机构被合并过 — 老系统是 2 个 ID、新系统合并成 1 个。

处理:`old_system_id` 保持唯一键(每条老 ID 只对应一条映射),但 `org_id` **允许重复**(虽然实际通过业务限定做 1:1)。

查询方向:

- **老 ID → 新 ID**:走 `uk_old_system_id`,O(1),结果唯一
- **新 ID → 老 ID**:如果有多条,取 `status = 1 AND create_time DESC` 的最新一条

### Q5:这张表谁维护?

**答**:两部分:

- **存量**(上线时):我写 SQL 脚本,从分润系统的历史数据 + 机构主数据的最新数据关联映射,一次性 INSERT
- **增量**(新增机构):业务流程里,机构在新系统注册后,如果需要接入结算,运维手动加一条映射。这里做得比较粗糙 — 有个运营后台的"机构映射管理"页面,运维按需录入

理想方案是"新机构注册后自动推到分润系统拿老 ID 反填",但分润系统已经封存,不接受新数据,这条路走不通。

### Q6:为什么不用缓存?每次查映射都打 DB?

**答**:有优化空间。实际做了:

- **热点机构缓存**:用 Caffeine 本地缓存,TTL 10 分钟,Key = `newId` / `oldId`
- **批量接口**:`batchOldToNew` 走 `IN` 查询,一次把一批拿回来

没上 Redis,因为映射表本身查询很快(唯一索引 O(1)),本地缓存已经够。

### Q7:映射数据错了怎么办?

**答**:上线前做了两次全量对账:

1. 用分润系统的历史数据 join 机构主数据,对比 `org_id → old_system_id` 的映射
2. 随机抽 50 条让运营手动核对

生产上线后加了**定时对账 Job**:每天凌晨跑一次,对比分润系统的机构列表 vs 映射表,发现差异入异常表告警。

### Q8:如果分润系统某天也要切到新 ID,这张映射表怎么办?

**答**:两步退场:

1. 双写过渡:新的结算请求,同时用新 ID 和老 ID 调分润系统(它做内部兼容)
2. 全量迁完后,映射表 `status = 0` 软下架,代码里把 `mappingService.newToOld()` 改成 identity(直接返回新 ID)
3. 最后下线映射表和相关代码

整个过程**不会动到业务代码** — 因为 Service 层的 `mappingService` 调用是唯一入口,改一处就行。

## 踩雷警告

- **别说"分润系统是我们团队维护的"** — 是另一个团队的老系统,我们只是调用方
- **别吹"亿级映射"** — 实际是千级。数据量吹大反而显得假
- **一对多情况答案别答"不可能"** — 实际有,诚实承认但说明处理方案
- **别说"上线零故障"** — 说"没出过映射错误的线上事故,有定时对账 Job 做持续监控"更真实

---

# 剧本 4 · 合同号重复三层防御(治理线上脏数据)

**推荐开口**:"做过一个典型的线上脏数据治理 — 合同号重复导致分账金额统计错乱,影响 10+ 笔分账。我从代码、数据库、下游三层都加了防御。"

## 一分钟版

> 机构合作场景下出现过**合同号重复** — 用户重试、网络抖动、多点"提交"导致同一合同号被创建多条申请。下游批量创建剧本时**重复生成 artifact_script**,分账结算时**金额被重复统计**,影响 10+ 笔。
>
> 我做了三层防御:**Controller 前置幂等校验 + DB 唯一索引 + 下游剧本创建幂等**。加上存量脏数据 SQL 清洗 + 结算 SQL 按有效申请维度统计。
>
> 上线后 **3 个月零次重复创建,分账统计准确率 100%**。

## 三分钟版

### Situation

分销签约模块有个流程是"机构合作申请" — 机构和平台合作一批作品,提交合同号 + 作品列表。正常一次点击创建一条 `org_coop_apply` 记录。

线上出现问题:同一个合同号出现了**多条 apply 记录**,继而:

- 下游 `createArtifactScriptsForOrg` 批量创建剧本时,基于每条 apply 都创建一遍剧本,导致 `artifact_script` 表也重复
- 分账结算时,SQL 按 `contract_number` GROUP,金额被重复计算
- **影响 10+ 笔分账**,运营对账对不上

### Task

要做:

1. 定位脏数据范围
2. 修复已有脏数据
3. 防止新增
4. 结算逻辑修正,防止历史脏数据继续算错

### Action

**第一步:SQL 定位脏数据**。

```sql
-- 找出所有有重复合同号的记录
SELECT contract_number, COUNT(*) as cnt
FROM org_coop_apply
WHERE is_valid = 1
GROUP BY contract_number
HAVING COUNT(*) > 1;
```

这一查就看到 30+ 个重复的合同号。继续分析:

```sql
-- 看合同 - 申请 - 剧本的一对多
SELECT a.contract_number,
       COUNT(DISTINCT a.apply_id) as apply_cnt,
       COUNT(b.script_id) as script_cnt
FROM org_coop_apply a
LEFT JOIN artifact_script b ON a.apply_id = b.apply_id
WHERE a.is_valid = 1
GROUP BY a.contract_number
HAVING COUNT(DISTINCT a.apply_id) > 1;
```

确认重复合同号下,`apply_cnt` 和 `script_cnt` 都成倍了。

**第二步:分析根因**。

三个可能原因:

1. **用户双击提交**:前端没防抖
2. **网络重试**:用户提交后页面卡住,又点了一次
3. **Controller 没幂等校验**:直接 `INSERT`,数据库也没唯一索引

确认是 3 号 — 代码确实没校验。

**第三步:修复(三层防御)**。

**第一层 · Controller 前置幂等校验**:

```java
long existCount = orgCoopApplyMapper.countByContractNumberAndStatus(
        contractNumber,
        Arrays.asList(ApplyStatusEnum.PENDING.getCode(),
                      ApplyStatusEnum.PROCESSING.getCode()));
if (existCount > 0) {
    throw new BusinessException(
        "合同号[" + contractNumber + "]已存在有效申请,请勿重复提交");
}
```

**第二层 · DB 唯一索引**:

```sql
CREATE UNIQUE INDEX idx_contract_number ON org_coop_apply(contract_number);
```

两层防御的逻辑:代码校验给友好错误提示,DB 索引防并发场景(两个请求同时过代码校验时都觉得"没重复",DB 兜底拦下来)。

**第三层 · 下游剧本创建幂等**:

```java
// createArtifactScriptsForOrg 方法内
List<ArtifactScriptDO> existScripts = scriptDriver.getArtifactScriptsByApplyId(applyId);
if (!CollectionUtils.isEmpty(existScripts)) {
    Logs.access("applyId={} has already created scripts, skip", applyId);
    return existScripts;   // 已创建过,直接返老数据
}
```

**第四步:存量脏数据清洗**。

```sql
-- 保留每个重复合同号的最早一条申请,其余标记为无效
UPDATE org_coop_apply
SET is_valid = 0, update_time = NOW()
WHERE contract_number = 'xxx'
  AND apply_id NOT IN (
      SELECT min_apply_id FROM (
          SELECT MIN(apply_id) AS min_apply_id
          FROM org_coop_apply
          WHERE contract_number = 'xxx'
      ) tmp
  );

-- 删除无效申请关联的重复剧本
DELETE FROM artifact_script
WHERE apply_id IN (
    SELECT apply_id FROM org_coop_apply
    WHERE contract_number = 'xxx' AND is_valid = 0);
```

**第五步:结算逻辑修正**。

```sql
-- 修正前:按合同号直接 SUM,包含所有关联申请的剧本
SELECT SUM(settle_amount) FROM settlement_record WHERE contract_number = 'xxx';

-- 修正后:按有效申请 JOIN
SELECT SUM(s.settle_amount)
FROM settlement_record s
JOIN org_coop_apply a ON s.apply_id = a.apply_id
WHERE a.contract_number = 'xxx' AND a.is_valid = 1;
```

这样即使将来有历史脏数据没清干净,结算也只算有效 apply 的金额。

### Result

- **上线后 3 个月零次重复创建**
- **分账统计准确率 100%**
- 修复 **10+ 笔历史脏数据**
- 沉淀了"三层防御"的模式,后面其它模块遇到幂等问题也套用这个

## 预设追问

### Q1:为什么既要代码校验又要 DB 唯一索引?不冗余吗?

**答**:**不冗余,两层解决不同问题**。

- **代码校验**:给用户**友好错误提示**("合同号 xxx 已存在,请勿重复提交")。如果只靠 DB,用户看到的是"SQL 唯一约束违反"技术错误,体验差
- **DB 索引**:防**并发**。高并发下,两个请求同时过代码校验可能都觉得"没重复"(都查到 0 条),然后两个都 INSERT,DB 索引最终拦下来

少任何一层都有漏洞。

### Q2:为什么不加分布式锁?

**答**:考虑过,不必要。

- 合同号本身是**用户输入的唯一键**,天然适合做幂等
- 分布式锁适合"没有天然幂等键但要做幂等"的场景

加锁反而:

1. 多一个 Redis 依赖(Redis 挂了锁怎么办)
2. 性能有开销(每请求都要 setnx + del)
3. 锁超时/释放失败有新风险

DB 唯一索引就是最天然的分布式锁。

### Q3:if 校验会不会把"新合同重新签"也拦掉?

**答**:不会。我只查 `status IN (PENDING, PROCESSING)` 的有效申请。

- **已完成**(SIGNED / EFFECTIVE):不算,可以重新签(比如续签)
- **已终止**(TERMINATED):不算,可以重新发起
- **已驳回**(REJECTED):不算,可以重新提交

**业务上"同一个合同号重新走一次"是允许的**,只要之前那次已经走完。

### Q4:存量脏数据 SQL 执行风险大吗?

**答**:**不小**,上线前做了三步:

1. **备份**:整表 `pt-archiver` 备份到副本
2. **测试环境演练**:按同样 SQL 在 UAT 跑一遍,对比修复前后数据量
3. **生产分批执行**:不是一把 UPDATE 几百条,是按合同号循环,每个合同号单独事务

`DELETE artifact_script` 那部分尤其谨慎,先在事务里 SELECT 看要删的条数,对上再 COMMIT。

### Q5:`SELECT MIN(apply_id) ... FROM (SELECT MIN(apply_id) ...)` 嵌套看起来很奇怪,为什么?

**答**:MySQL 不允许"子查询引用要更新的表"。直接写:

```sql
UPDATE org_coop_apply SET is_valid = 0
WHERE apply_id NOT IN (SELECT MIN(apply_id) FROM org_coop_apply WHERE contract_number = 'xxx');
```

会报错。

外面套一层 SELECT,MySQL 就会把子查询结果物化成临时表,绕开这个限制。这是个经典的 MySQL quirk。

### Q6:修复完怎么验证?

**答**:

1. 重跑第一步的重复定位 SQL,确认 COUNT > 1 的记录数为 0
2. 随机抽 5 个问题合同号,手动核对分账金额
3. 数据部的报表跑一遍,对账总金额应该降下来(因为剔除了重复统计)

整个验证 1 小时内完成。

### Q7:为什么结算 SQL 要改成按 JOIN 统计,不只是清理脏数据?

**答**:**防御性编程**。

清理脏数据是 one-time 的,将来难保不会有新的脏数据混进来(业务 bug、线上故障、手动改库等)。

结算 SQL 按 `JOIN org_coop_apply WHERE is_valid = 1` 过滤,**即使将来有脏数据也不会算错**。这是"程序健壮性"层面的防御。

### Q8:重复提交为什么不靠前端防抖?

**答**:前端防抖是第一道防线,**但不能依赖前端**。

- 前端代码可能被篡改
- 脚本调用(Postman、curl)绕过前端
- 移动端和 Web 端的防抖不一致

**后端必须自己做防御**。前端防抖只是让用户体验好,不是安全保证。

## 踩雷警告

- **别说"我发现了这个 bug"** — 大概率是运营或 QA 发现报上来的。说"我接到运营反馈后排查..."更真实
- **别吹"根除了所有幂等问题"** — 可以说"沉淀了三层防御的模式,后面其它模块可以套用"
- **别主动说"我们团队都这么写代码"** — 带抬杠感。说"之前代码确实有这块漏洞,我修了"
- **脏数据 SQL 如果自己写的,一定强调上线前做了备份和 UAT 演练**

---

**STAR 剧本(上)到此。下半部分(剧本 5-7)见 STAR答题剧本-下.md。**
