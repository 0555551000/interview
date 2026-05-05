# STAR 答题剧本(下)· IP 中台 + 状态管理 + 通用串讲

> 基于阅文漫剧分销平台真实工作内容。
> 延续上半部分(签约框架、N+1 优化、新旧 ID 映射、合同号重复治理),本半继续 3 个核心剧本 + 通用串讲策略。

---

# 剧本 5 · ArtifactHandlerFactory 成品处理器工厂

**推荐开口**:"做过一个内容类型扩展的需求,用工厂模式把'加一种内容类型要改 4-6 处代码' 压到了'只加一个类,核心流程零改动'。"

## 一分钟版

> IP 中台要登记 3 种内容类型:剧本、剧集、成品。每种类型的创建字段、下游服务、CAMS 绑定参数都不一样。老实现 if/else 满天飞,**加一种类型要改 4-6 处代码**。
>
> 我用**工厂模式 + 统一 `ArtifactHandler` 接口**重构:`ArtifactHandlerFactory` 启动时扫所有 `@Component` 实现,按 `ContentType` 注册到 Map。加新类型只要新建一个 `@Component` 的 Handler,Spring 自动装进工厂。
>
> **新增内容形态从 3 天降到 0.5 天**,已支撑 4 种内容类型,核心流程零改动。

## 三分钟版

### Situation

IP 中台内容模块(我是核心开发者)要登记 3 种内容类型:

- **剧本**(Script)
- **剧集**(Episode)
- **成品**(Artifact)

每种类型差异很大:

- 创建字段不一样:剧本有"书籍 ID",剧集有"集数、片长"
- 下游服务不一样:剧本调内容中心,剧集调短剧服务
- CAMS 绑定参数不一样(给集团财务系统做分账登记)
- 状态同步不一样:剧集要同步天网 IP 中台,成品不用

老代码是一个大 Service:

```java
public void createArtifact(ContentType type, CreateContext ctx) {
    if (type == SCRIPT) {
        // 剧本创建逻辑 50 行
    } else if (type == EPISODE) {
        // 剧集创建逻辑 60 行
    } else if (type == ARTIFACT) {
        // 成品创建逻辑 40 行
    }
}

public void bindCams(ContentType type, BindContext ctx) {
    if (type == SCRIPT) { ... }
    else if (type == EPISODE) { ... }
    else if (type == ARTIFACT) { ... }
}

// 同样的 if/else 还有 syncStatus / queryDetail / updateStatus 等...
```

### Task

业务要加第 4 种内容类型"非标剧集"。如果照旧逻辑,要改 4-6 处代码。而且每次加新类型,测试回归面越来越大。

借这个机会**重构成开放扩展的设计**。

### Action

**第一步:抽象统一接口**。

观察每种类型都要做的事:create、bindCams、syncStatus、queryDetail、updateStatus。抽一个 `ArtifactHandler`:

```java
public interface ArtifactHandler {
    ContentType getType();
    void create(CreateContext ctx);
    void bindCams(BindContext ctx);
    void syncStatus(SyncContext ctx);
    ArtifactDetail queryDetail(Long id);
    void updateStatus(Long id, ArtifactStatus status);
}
```

**第二步:每种类型一个实现类**。

```java
@Component
public class ScriptArtifactHandler implements ArtifactHandler {
    public ContentType getType() { return ContentType.SCRIPT; }

    public void create(CreateContext ctx) {
        // 剧本特有的:查书籍 ID,调内容中心 addScript
    }

    public void bindCams(BindContext ctx) {
        // 剧本绑定 CAMS 的参数组装
    }

    public void syncStatus(SyncContext ctx) {
        // 剧本状态同步
    }
    // ...
}

@Component
public class EpisodeArtifactHandler implements ArtifactHandler {
    public ContentType getType() { return ContentType.EPISODE; }
    // 剧集的不同实现
}
```

**第三步:工厂自动注册**。

```java
@Component
public class ArtifactHandlerFactory {
    private final Map<ContentType, ArtifactHandler> handlerMap = new HashMap<>();

    @Autowired
    public ArtifactHandlerFactory(List<ArtifactHandler> all) {
        for (ArtifactHandler h : all) {
            handlerMap.put(h.getType(), h);
        }
    }

    @PostConstruct
    public void validate() {
        // 启动时校验:同一 ContentType 只能有一个 Handler
        Set<ContentType> seen = new HashSet<>();
        for (ArtifactHandler h : handlerMap.values()) {
            if (!seen.add(h.getType())) {
                throw new IllegalStateException("重复的 ContentType: " + h.getType());
            }
        }
    }

    public ArtifactHandler get(ContentType type) {
        ArtifactHandler h = handlerMap.get(type);
        if (h == null) throw new BusinessException("unsupported " + type);
        return h;
    }
}
```

核心技巧:

- Spring 支持 `@Autowired List<ArtifactHandler>` 把所有实现类都注入进来
- 启动时遍历 List 装进 Map,查找 O(1)
- `@PostConstruct` 校验避免两个 Handler 返相同 ContentType

**第四步:业务代码完全不用判断类型**。

```java
public void createArtifact(ContentType type, CreateContext ctx) {
    handlerFactory.get(type).create(ctx);
}

public void bindCams(ContentType type, BindContext ctx) {
    handlerFactory.get(type).bindCams(ctx);
}
```

Service 层从几百行 if/else 变成几十行。

**第五步:加"非标剧集"类型**。

1. 在 `ContentType` enum 加一个值
2. 新建 `NonStandardEpisodeArtifactHandler implements ArtifactHandler` + `@Component`
3. 写单测

**就这些。业务代码零改动**。

### Result

- **新增内容形态开发周期从 3 天 → 0.5 天**
- **核心流程零改动**
- 已支撑 4 种内容类型稳定运行
- Service 层代码量减少 50%+,if/else 基本消失

## 预设追问

### Q1:为什么用 List 注入不用 Spring 的 `@Autowired Map`?

**答**:Spring 支持 `@Autowired Map<String, ArtifactHandler>`,但 key 是 **Bean 名字**,不是我要的 `ContentType` enum。

我要的 Map 是 `Map<ContentType, ArtifactHandler>`,所以必须手动把 List 转成 Map(以 `handler.getType()` 为 key)。

### Q2:两个 Handler 返相同 ContentType 会怎样?

**答**:启动时就会报错。我加了 `@PostConstruct` 校验,如果 `seen.add()` 返 false(说明重复),直接 `throw IllegalStateException`,Spring 启动失败。

这比等到运行时才发现"某个类型被哪个 Handler 处理"的 bug 要好得多。

### Q3:本地缓存优化实例复用是啥意思?

**答**:最早的版本 `applicationContext.getBean(ScriptArtifactHandler.class)` 每次从 Spring 容器取。Spring 容器内部有个查找(虽然是 O(1),但有反射等开销)。

改成启动时就把 handler 装 Map,直接 `handlerMap.get(type)`,纯 HashMap 操作,更快。

其实 Bean 是单例,复用是一开始就做到的;这里优化的是**查找 Bean 的开销**。

### Q4:如果某种类型的 `syncStatus` 不需要做,接口方法还得实现吗?

**答**:可以提供**抽象基类**给空实现:

```java
public abstract class AbstractArtifactHandler implements ArtifactHandler {
    public void syncStatus(SyncContext ctx) { /* 默认空实现 */ }
}

@Component
public class ArtifactArtifactHandler extends AbstractArtifactHandler {
    public ContentType getType() { return ContentType.ARTIFACT; }
    public void create(CreateContext ctx) { ... }
    // 不需要 override syncStatus,用默认空实现
}
```

Java 8 之后 interface 也能有 `default` 方法,同样可以:

```java
public interface ArtifactHandler {
    ContentType getType();
    default void syncStatus(SyncContext ctx) { /* 默认不做 */ }
    // ...
}
```

### Q5:如果某种类型的 `create` 和另一种几乎一样,能复用吗?

**答**:两种方式:

1. **继承**:让相似的 Handler 继承共同父类,在父类里写共性逻辑
2. **组合**:把共性抽成 Helper 类,两个 Handler 都注入并调用

我倾向**组合**,继承层级深了也难维护。

### Q6:工厂本身需要加锁吗?

**答**:不需要。`handlerMap` 是 `@PostConstruct` 之后就不变的(只读),多线程读 HashMap 是安全的。

如果未来有**动态注册**的需求(运行时加 Handler),那需要 ConcurrentHashMap + 读写锁。我们当前场景不需要。

### Q7:策略模式和工厂模式你觉得有什么区别?

**答**:

- **策略**:定义一组可互换的算法/逻辑(`ArtifactHandler` 接口 + 各种实现)
- **工厂**:根据参数**决定用哪个策略**(`ArtifactHandlerFactory.get(type)`)

两者是配合关系。策略提供"有哪些选择",工厂提供"怎么选"。

如果只有策略没有工厂,调用方要自己写 if/else 选对应的策略实例,又回到老代码。工厂统一了"选择策略"的入口。

### Q8:这个模式被其它模块复用了吗?

**答**:是。我做了 `ArtifactHandlerFactory` 之后,团队其他人做**合同类型处理**也套用了类似模式(见剧本 1 的 `ContractInvoker` 策略),以及**数据源提供者**(`DataProviderFactory`)、**登录方式**(`LoginProviderFactory`)等多处。

一个好的模式被复用,证明它确实解决了共性问题。

## 踩雷警告

- **别吹"代码量减少 90%"** — 50% 是真实的
- **别说"我是第一个用这个模式的"** — 说"套用了成熟的工厂 + 策略模式"更谦逊
- **`@PostConstruct` 校验一定要提** — 很多人会忘,提了说明你想得细

---

# 剧本 6 · 合同"已过期"状态动态计算

**推荐开口**:"做过一个状态管理的优化,消除了一个定时任务,状态延迟从 1 小时变成 0。"

## 一分钟版

> 合同有 3 种状态:已生效、已终止、已过期。老实现 DB 存 3 种 status,定时任务每小时扫表把"已生效但到期时间过了"的改成"已过期"。
>
> 问题:**最长延迟 1 小时**,用户看到明明过期的合同还显示"已生效";**万级合同扫表压力大**;**Job 挂了状态永远错**。
>
> 我改成**"已过期"不存库,实时动态计算** — SQL 里 `CASE WHEN status = 1 AND cooperation_end_time < NOW() THEN 2` 实时判断。DB 只存两种基础状态。**状态延迟从 1 小时 → 0**,消除了 Job 依赖。

## 三分钟版

### Situation

分销签约模块里合同有 3 种展示状态:

- **已生效**(Effective)
- **已终止**(Terminated):人工触发(单方违约、协商解约)
- **已过期**(Expired):到了 `cooperation_end_time` 自动变

前端列表要按状态筛选,详情页要显示当前状态。业务对准确性要求高 — 用户看到"已生效但其实已过期"的合同会影响后续操作。

### Task

老实现:

- DB 存 status = 1(已生效)/ 2(已过期)/ 9(已终止)
- 定时任务每小时扫表,把"status = 1 AND cooperation_end_time < NOW()"的改成 status = 2

问题很多:

1. **状态延迟最长 1 小时**
2. 万级合同扫表 `UPDATE` 有**锁冲突风险**
3. **Job 挂了状态永远错**(我真遇到过 Job 因为内存 OOM 挂掉,凌晨没人管,白天运营投诉)
4. **业务加新状态(比如"临期")要再加一个 Job**

要优化到零延迟 + 零 Job 依赖。

### Action

**第一步:重新思考"什么状态该存,什么该算"**。

观察 3 个状态的本质:

- **已生效 / 已终止**:**事实**(某个时间点发生了"签约完成"或"终止"动作),必须存库
- **已过期**:**推导值**(时间到自动变),不是事实,是**规则**

结论:**事实存库,推导值动态算**。

**第二步:SQL 里 CASE WHEN 动态推导**。

```sql
SELECT
  id,
  contract_number,
  cooperation_end_time,
  status,
  CASE
      WHEN status = 1 AND cooperation_end_time < NOW() THEN 2   -- 已过期
      WHEN status = 1 THEN 1                                    -- 已生效
      WHEN status = 9 THEN 9                                    -- 已终止
  END AS status_view
FROM contract
WHERE ...
```

`status_view` 是前端看到的状态,是 DB 算出来的。

**第三步:筛选条件自动转换**。

前端按"已过期"筛选时,把 `status_view = 2` 自动转成 SQL 条件:

```java
public List<ContractVO> list(QueryParam param) {
    ContractQuery q = new ContractQuery();

    // 状态筛选
    if (param.getStatusView() != null) {
        switch (param.getStatusView()) {
            case 1 -> {
                q.setStatus(1);
                q.setCooperationEndAfter(LocalDateTime.now());
            }
            case 2 -> {
                q.setStatus(1);
                q.setCooperationEndBefore(LocalDateTime.now());
            }
            case 9 -> q.setStatus(9);
        }
    }

    return mapper.list(q);
}
```

**第四步:组合索引配合**。

```sql
CREATE INDEX idx_status_end_time ON contract(status, cooperation_end_time);
```

WHERE `status = 1 AND cooperation_end_time < NOW()` 正好走最左前缀,查询很快。

**第五步:去掉 Job**。

原来的 `ContractExpireJob` 下线。

### Result

- **状态延迟从最长 1 小时 → 0**(实时)
- **消除定时任务依赖**
- **万级合同状态查询实时准确**

## 预设追问

### Q1:为什么不把"已过期"也存库?不是查询更快吗?

**答**:查询速度差距可忽略,但**一致性风险大**:

- 定时任务有延迟,用户看到的状态可能是几十分钟前的
- Job 挂了数据就错
- 时间到的边界情况(刚过 `cooperation_end_time` 1 秒)永远要等下一次 Job

动态计算虽然多了一个字段的时间比较,但因为能走索引,性能完全可接受。一致性和可靠性的收益远大于一点点性能开销。

### Q2:`CASE WHEN` 会影响查询性能吗?

**答**:分两部分看:

- **SELECT 列的 CASE WHEN**:只是结果集上的计算,每行几个纳秒,可忽略
- **WHERE 条件里的时间比较**:`cooperation_end_time < NOW()`,配合 `idx_status_end_time(status, cooperation_end_time)` 组合索引,完全走索引

实际看查询计划,走 range scan,和之前按 status 查等值 scan 差不多。

### Q3:以后加"临期"状态(7 天内到期)怎么办?

**答**:同样套路,只改 `CASE WHEN`:

```sql
CASE
    WHEN status = 1 AND cooperation_end_time < NOW() THEN 2
    WHEN status = 1 AND cooperation_end_time BETWEEN NOW() AND DATE_ADD(NOW(), INTERVAL 7 DAY) THEN 3   -- 临期
    WHEN status = 1 THEN 1
    WHEN status = 9 THEN 9
END
```

**不用改表,不用加 Job**。这是动态计算的核心优势。

### Q4:为什么"已终止"要存库不动态算?

**答**:它是**人工触发**的状态。流程是:

1. 运营后台点"终止合同" → 写 `terminated_time` + `status = 9`
2. 前端展示"已终止"

"已终止"不是时间到了自动变的,是有个**发生时间点**(谁在什么时候点了终止)。这种必须存库 — 你没法从其它字段推导出"我什么时候被终止了"。

**事实存库,推导值动态算**。这是设计原则。

### Q5:分页场景下,SQL 能用 `status_view` 做排序/筛选吗?

**答**:能,但有坑。

- **筛选**:前端传 statusView,Java 转成 SQL 条件。**走原始字段的索引,能用**
- **排序**:`ORDER BY status_view` 可以,但 CASE WHEN 列不走索引,排序要回表。建议**按 `status` + `cooperation_end_time` 两列排**,用 `status DESC, cooperation_end_time ASC` 这种组合,效果等同且走索引

### Q6:如果时区问题导致 `cooperation_end_time < NOW()` 判断错误怎么办?

**答**:

- MySQL `NOW()` 用服务器时区
- DB 存 `cooperation_end_time` 也是服务器时区
- 一致的 timezone 就不会错

实际风险点是**跨时区业务**(比如海外合同)。对策:

- 合同所有时间字段**统一存 UTC**
- 展示时按用户时区转换
- WHERE 比较永远用 UTC

我们项目都是国内业务,没碰到这个问题。

### Q7:列表接口返回给前端时,status_view 怎么传?

**答**:DO 里加个瞬时字段:

```java
@Data
public class ContractDO {
    private Integer status;                    // DB 原始 1/9
    private LocalDateTime cooperationEndTime;
    private transient Integer statusView;      // Service 层计算,不落库

    public Integer getStatusView() {
        if (status == 1 && cooperationEndTime != null
                && cooperationEndTime.isBefore(LocalDateTime.now())) {
            return 2;
        }
        return status;
    }
}
```

或者直接在 Mapper 查询时 SELECT 出来:

```xml
<select id="list" resultMap="contractMap">
    SELECT *,
        CASE WHEN status = 1 AND cooperation_end_time < NOW() THEN 2
             ELSE status END AS status_view
    FROM contract
</select>
```

两种都可以,看团队风格。

### Q8:老 Job 下线了,历史数据里 status = 2 的脏数据怎么处理?

**答**:一次性 SQL 清洗:

```sql
-- 历史 status = 2 的都应该是"已生效但已过期"
-- 改成 status = 1,动态计算会自动推导为 status_view = 2
UPDATE contract SET status = 1 WHERE status = 2;
```

验证:跑完后,`SELECT COUNT(*) WHERE status = 1 AND cooperation_end_time < NOW()` 应该等于之前清洗前 `status = 2` 的数量。

## 踩雷警告

- **别说"Job 挂了好几次"** — 实际发生过,但别说多。一次就够了
- **别主动说"加索引会占用空间"** — 万级数据的索引几十 MB,不用谈空间
- **"临期"状态的追问很常见** — 准备好"同样套路改 CASE WHEN"的答法
- **别说"我觉得 Job 方案很愚蠢"** — 抬杠前人。说"之前的方案在业务量小时是合理的,业务涨起来后才暴露问题"

---

# 剧本 7 · batchCreateContentScriptForOrg 批量创建剧本

**推荐开口**:"做过一个批量处理的核心方法,机构一次要批量上线 50-500 个剧本,涉及去重、分批 RPC、跨服务 ID 映射、幂等落库等 5 步。"

## 一分钟版

> 机构合作签完约后一次要批量上线 50-500 个剧本。流程 5 步:**解析 JSON 扩展字段 → 三维度去重(name + 书籍ID + 作品类型) → 分批调内容中心(单次上限 50 条) → 反向组装 ID 映射(临时 ID → 正式 ID) → 本地落库 + 幂等**。
>
> 难点在**跨服务 ID 映射**:我方传"临时 ID",内容中心返"正式 ID",反转成 `{正式ID: 剧本数据}` 给落库用。
>
> 效果:**单次最高 500 条,去重准确率 100%,跨服务 ID 映射零错乱**。

## 三分钟版

### Situation

IP 中台内容模块(我核心开发者),业务场景是:机构和平台签完合作协议后,机构要一次**批量上线自己的全部剧本**给分销平台。

特点:

- 单次可能 50-500 条(看机构规模)
- 每条剧本信息复杂,有几十个扩展字段(用 JSON 存)
- 要在**我们本地 DB** 和**内容中心**两个系统都落地

### Task

实现 `batchCreateContentScriptForOrg` 方法,要求:

1. JSON 扩展字段解析成结构化对象
2. 业务级去重(不只按 name,要看 name + 书籍 + 作品类型)
3. 分批调内容中心(单次 API 上限 50 条)
4. 跨服务 ID 映射不能错(我方临时 ID ↔ 内容中心正式 ID)
5. 幂等(防止前端重试导致重复创建)

### Action

**五步流程**:

**步骤 1:解析 JSON**

```java
public List<ArtifactScriptDO> batchCreateContentScriptForOrg(BatchCreateParam param) {
    List<CreateScriptWorkItem> workList = param.getWorks().stream()
            .map(this::parseExtraJson)
            .collect(toList());
    // ...
}

private CreateScriptWorkItem parseExtraJson(RawWorkItem raw) {
    CreateScriptWorkItem w = new CreateScriptWorkItem();
    w.setScriptName(raw.getScriptName());
    w.setCbid(raw.getCbid());
    w.setWorkType(raw.getWorkType());
    // 扩展字段 JSON 解析
    if (raw.getExtraJson() != null) {
        WorkExtra extra = JSON.parseObject(raw.getExtraJson(), WorkExtra.class);
        w.setExtra(extra);
    }
    return w;
}
```

**步骤 2:三维度去重**

```java
Map<String, CreateScriptWorkItem> uniqueMap = new LinkedHashMap<>();
for (CreateScriptWorkItem w : workList) {
    String key = w.getScriptName() + "|" + w.getCbid() + "|" + w.getWorkType();
    uniqueMap.putIfAbsent(key, w);   // 先到先得
}
List<CreateScriptWorkItem> uniqList = new ArrayList<>(uniqueMap.values());
```

为什么 **LinkedHashMap**:保持输入顺序。`putIfAbsent` 自然实现"先到先得"。

为什么**三维度**:同名字但不同书(`cbid`)是合法的;同名同书但不同作品类型(比如既有原著也有改编)也合法。

**步骤 3:分批调内容中心**

```java
Map<Long, CreateScriptWorkItem> idMap = new HashMap<>();
Lists.partition(uniqList, 50).forEach(batch -> {
    Map<Long, CreateScriptWorkItem> sub = batchDoCreateContentScript(
            batch, userDO, orgInfoDO, type);
    idMap.putAll(sub);
});
```

**步骤 4:`batchDoCreateContentScript` 方法**

```java
private Map<Long, CreateScriptWorkItem> batchDoCreateContentScript(
        List<CreateScriptWorkItem> workList, UserDO userDO,
        OrgInfoDO orgInfoDO, ContentTypeEnum type) {

    // 4.1 组装第三方请求参数
    List<AddComicScriptArg> argList = workList.stream().map(w -> {
        AddComicScriptArg arg = new AddComicScriptArg();
        arg.setScriptName(w.getScriptName());
        arg.setCbid(w.getCbid());
        arg.setOrgId(orgInfoDO.getOrgId());
        arg.setTempId(w.getTempId());   // 我方生成的临时 ID
        return arg;
    }).collect(toList());

    // 4.2 调内容中心/短剧服务
    Result<Map<Long, Long>> result = shortPlayProvider.batchAddScript(argList);
    if (!result.isSuccess()) {
        log.error("第三方创建失败: {}", result.getMessage());
        throw new BusinessException("剧本创建失败");
    }

    // 4.3 反转映射:{临时ID → 正式ID} 反转成 {正式ID → 剧本数据}
    Map<Long, Long> tempToFormal = result.getData();
    return reverseMap(tempToFormal, workList);
}

private Map<Long, CreateScriptWorkItem> reverseMap(
        Map<Long, Long> tempToFormal, List<CreateScriptWorkItem> workList) {
    // 先构建 {临时ID → 剧本数据}
    Map<Long, CreateScriptWorkItem> tempToWork = workList.stream()
            .collect(toMap(CreateScriptWorkItem::getTempId, w -> w));

    // 反转
    Map<Long, CreateScriptWorkItem> result = new HashMap<>();
    for (Map.Entry<Long, Long> e : tempToFormal.entrySet()) {
        Long tempId = e.getKey();
        Long formalId = e.getValue();
        CreateScriptWorkItem w = tempToWork.get(tempId);
        if (w != null) {
            result.put(formalId, w);
        }
    }
    return result;
}
```

**步骤 5:本地落库 + 幂等**

```java
private List<ArtifactScriptDO> createArtifactScripts(
        Map<Long, CreateScriptWorkItem> idMap,
        OrgInfoDO orgInfoDO, ContractInfo contractInfo) {

    List<ArtifactScriptDO> result = new ArrayList<>();
    for (Map.Entry<Long, CreateScriptWorkItem> e : idMap.entrySet()) {
        Long formalId = e.getKey();
        CreateScriptWorkItem w = e.getValue();

        // 幂等检查:已经存在的正式 ID 不重复创建
        ArtifactScriptDO exist = scriptDriver.getByFormalId(formalId);
        if (exist != null) {
            log.info("script already exists, formalId={}, skip", formalId);
            result.add(exist);
            continue;
        }

        ArtifactScriptDO script = new ArtifactScriptDO();
        script.setFormalId(formalId);
        script.setScriptName(w.getScriptName());
        script.setCbid(w.getCbid());
        script.setWorkType(w.getWorkType());
        script.setOrgId(orgInfoDO.getOrgId());
        script.setContractNumber(contractInfo.getContractNumber());
        script.setCreatorId(userDO.getUserId());
        // ... 更多字段

        scriptDriver.insert(script);
        result.add(script);
    }
    return result;
}
```

### Result

- 支撑机构合作场景批量剧本上线
- **单次最高 500 条**
- **去重准确率 100%**
- **跨服务 ID 映射零错乱**

## 预设追问

### Q1:为什么用 LinkedHashMap 不用 HashSet?

**答**:需要**保持输入顺序**(前端传的顺序 = 业务期望的顺序,比如按合同附件顺序)。

- HashMap / HashSet 不保证顺序
- LinkedHashMap 保序,且 `putIfAbsent` 自然完成"先到先得"去重

如果用 HashSet,要另外维护一个 List 保持顺序,代码更复杂。

### Q2:为什么三维度是 name + cbid + workType,不是 name + orgId?

**答**:业务规则:

- **同名不同书**:合法(不同书叫同一个名字)
- **同名同书不同作品类型**:合法(既有原著剧本也有改编剧本)
- **同 orgId 同名**:也可能合法(一个机构不同合同里提同样的剧本,由合同号区分)

真正的业务唯一键是 `name + cbid + workType + contractNumber`。但**同一次批量提交里合同号是固定的**,所以批量内部去重只需要前三个字段。

### Q3:分批 50 条为什么不并行?

**答**:

1. **内容中心有 QPS 限制**,并行会被限流
2. **ID 映射错误排查要串行日志**(哪个批次失败)
3. **500 条 10 批,每批 200ms = 2 秒**,业务可接受

如果未来业务量涨到 5000 条以上,压测发现串行成瓶颈,可以用 `CompletableFuture` 控并发度 3,但要做好限流。

### Q4:中途某一批失败怎么办?

**答**:**部分成功策略**。失败的记录到 `failedList`,接口返 `{success: [...], failed: [...]}`,前端告诉运营哪些失败,让他们点"重试失败的"再发一次。

**为什么不整体回滚**:

- 内容中心 delete 接口不一定幂等(可能需要人工介入)
- 大批量回滚风险高
- 部分成功 + 失败重试 是运营可接受的体验

### Q5:反向组装 ID 映射为什么要两步(先 `tempToWork`,再反转)?

**答**:内容中心返 `{临时ID: 正式ID}`。要拿到`{正式ID: 剧本数据}` 用来落库。两种实现:

**两步法**(我用的):

```java
// 步骤 1: {临时ID → 剧本数据}
Map<Long, CreateScriptWorkItem> tempToWork = workList.stream()
        .collect(toMap(CreateScriptWorkItem::getTempId, w -> w));

// 步骤 2: 反转
for (Entry<Long, Long> e : tempToFormal.entrySet()) {
    result.put(e.getValue(), tempToWork.get(e.getKey()));
}
```

**一步法**(O(n²)):

```java
for (Entry<Long, Long> e : tempToFormal.entrySet()) {
    Long tempId = e.getKey();
    for (CreateScriptWorkItem w : workList) {
        if (w.getTempId().equals(tempId)) {
            result.put(e.getValue(), w);
            break;
        }
    }
}
```

两步法时间复杂度 O(n),一步法 O(n²)。批量 500 条一步法 25 万次比较,两步法 1000 次。**两步法更快**。

### Q6:幂等用"正式 ID 已存在"做判断,会不会漏?

**答**:**会漏**。有边界情况:

- 第一次提交:内容中心创建成功,正式 ID 返回,但本地落库前 JVM 挂了
- 第二次提交:本地没有,又去调内容中心 — 内容中心可能报"合同号 + 剧本名已存在"或返回原来的正式 ID

对策:**幂等键加一层**。用 `contract_number + script_name + cbid` 作为 DB 唯一键:

```sql
UNIQUE KEY uk_contract_script (contract_number, script_name, cbid, work_type)
```

这样 INSERT 时 DB 拦一次,代码里 catch `DuplicateKeyException` 转成"已存在,返回老数据"。

### Q7:CreateScriptWorkItem 的 tempId 怎么生成?

**答**:简单的自增:

```java
// 在解析 JSON 时分配
AtomicLong counter = new AtomicLong(0);
for (RawWorkItem raw : param.getWorks()) {
    CreateScriptWorkItem w = parseExtraJson(raw);
    w.setTempId(counter.incrementAndGet());
    // ...
}
```

tempId 只在**本次批量内**有意义,用完就丢。不需要全局唯一,不需要持久化。所以自增够用。

### Q8:500 条批量,失败重试会重复创建吗?

**答**:有 DB 唯一键 `uk_contract_script` 兜底,重复插会被 DB 拦。

更友好的做法:**重试时先批量查已有的**:

```java
// 重试前先查哪些已存在
Set<String> existKeys = scriptDriver.batchQueryExistKeys(
        contractNumber,
        uniqList.stream().map(w -> w.getScriptName() + "|" + w.getCbid()).collect(toSet())
);

// 过滤掉已存在的
List<CreateScriptWorkItem> toCreate = uniqList.stream()
        .filter(w -> !existKeys.contains(w.getScriptName() + "|" + w.getCbid()))
        .collect(toList());
```

这样重试时**只处理新增部分**,不依赖 DB 异常做控制流,代码更清晰。

## 踩雷警告

- **别说"500 条也是我们业务量的上限"** — 上限是业务限制,不是技术限制。可以说"当前业务场景稳定支撑 500 条,技术上没瓶颈"
- **别夸"去重准确率 100%"** — 100% 是真实但容易被追问,准备好答"因为去重 key 覆盖所有可能的重复场景"
- **并行那个问题不要主动抛** — 容易让面试官问"那你并行做过吗",答"没有"会尴尬

---

# 通用串讲策略(面试全局)

## 开场 1 分钟自我介绍

> 我最近 2 年主要做的是**阅文漫剧分销与签约平台**,面向万级 UP 主和千级机构 MCN,月均签约 300 多单,年结算千万级。
>
> 基于阅文集团的 Peacock 脚手架开发,深度对接了 6+ 集团中台(合同中心、分润系统、机构主数据、敏感数据中心、内容中心等)。
>
> 我负责 3 个核心模块,都是 Owner 或核心开发者:
>
> 1. **分销签约模块**:策略+模板方法做了签约框架,5 种合同类型接入从 5 天降到 1 天
> 2. **结算分润模块**:做了 N+1 优化(3-5s → 500ms)、新旧机构 ID 双向转换
> 3. **IP 中台内容模块**:工厂模式做了成品处理器,支撑 4 种内容类型
>
> 另外线上也治理过合同号重复、回调状态不同步、双合同展示错误等几个典型问题。

## 问题类型 → 剧本选择

| 面试官问 | 推荐剧本 |
|---|---|
| "讲一个最复杂的" | 剧本 1(签约框架)or 剧本 7(batchCreate) |
| "讲一个最有成就感的" | 剧本 2(N+1 优化,数字漂亮) |
| "讲一个踩坑最深的" | 剧本 4(合同号重复三层防御) |
| "讲一个设计模式实践" | 剧本 5(工厂模式)or 剧本 1(策略+模板方法) |
| "讲一个跨系统问题" | 剧本 3(新旧 ID 映射) |
| "讲一个状态管理问题" | 剧本 6(动态计算过期) |
| "讲一个批量处理" | 剧本 7(batchCreate) |
| "讲一个性能优化" | 剧本 2(N+1 优化) |

## 时间控制

| 阶段 | 理想时长 |
|---|---|
| 自我介绍 | 60 秒 |
| 单个需求(详细版) | 3-5 分钟 |
| 回答追问 | 每个 30-60 秒 |
| 反问面试官 | 不限(越多越显得感兴趣) |

**讲需求的节奏**:

1. 背景 30 秒(SITUATION)
2. 要解决什么 20 秒(TASK)
3. 我怎么做 2 分钟(ACTION)— **重点**
4. 结果 30 秒(RESULT)
5. 抛钩子:"这里面还有个细节,后来 PM 发现..." 引导追问

## 常见陷阱

### "你们团队规模多大?"

实话实说。别吹显得没话语权,别缩显得项目小。

### "QPS 多少?日活多少?"

有数据说数据。没数据说"这是 B 端后台,QPS 不高,**核心关注稳定性和数据准确性**"。

**可以说的数据**:

- 月均签约 300+ 单
- 年结算金额千万级
- 管理万部漫剧
- 结算列表接口 P99 500ms

### "你做过的最失败的项目?"

**不要说"都很成功"**。准备一个真实的失败经历:

**候选**:剧本 4 的"合同号重复三层防御" — 可以说"我接手这模块前已经有重复问题了,接手后才发现,花了一周治理。教训是接手模块时要先做一次脏数据排查,不能等业务炸了再治"。

这个失败很"安全" — 不是架构级失败,是治理级发现,展示你能从错误中学习。

### "你们怎么做 Code Review?"

> 我们用 MR(Merge Request)流程,至少一个 reviewer 批准才能合。我个人 review 重点看两个:① 错误处理是否完整,② 边界 case 是否覆盖。最近印象深的一次是剧本 6 的"差 1 天问题",review 时被指出 `plusDays(3)` 应该是 `plusDays(4)`,这种细节必须照抄需求文档。

## 反问清单(按优先级)

1. **这个岗位目前最大的技术挑战是什么?** (显得对岗位有思考)
2. **团队技术栈有没有升级计划?比如 JDK / 中间件?** (评估技术氛围)
3. **Code review 和设计评审的流程是怎样的?** (关心工程质量)
4. **新人 onboarding 到能独立交付平均多久?** (评估培养体系)
5. **如果我入职了,前 3 个月大概会接触什么?** (表现主动)
6. **团队规模是怎么样的?** (评估稳定性)

---

## 最后

### 别背书

这份文档的目的是**让你对自己做过的事有结构化的记忆**,不是让你逐字背。真到面试时,你讲出来会比文档更自然 — 你会带着停顿、语气、思考感,那才是真人的讲法。

### 心态

你面试的项目本来就是真实做过的,代码在、需求文档在、你自己熟悉细节。**你对业务的了解比面试官深得多**,不要心虚。

面试官问你,你就当作跟同事讨论技术方案 — 他想听的是你怎么想的、为什么这么选,而不是你能不能背出来。

### 兜底话术

如果真卡住了:

- "这个细节我一下想不起来,但思路是..."
- "具体的错误码记不清了,逻辑大致是..."
- "我回去可以翻代码确认,当时的方案是..."

承认不记得比瞎编好 10 倍。
