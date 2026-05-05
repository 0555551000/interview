# Java 21 虚拟线程(唠嗑版)

> 这份是当跟朋友吃饭聊"Java 21 这个虚拟线程听说很猛,到底多猛"写的。
> 面试问到 Java 21 新特性,这是最常考也最能体现深度的点。
> 照着这份讲,能把大部分面试官绕进去。

---

## 一、到底要解决啥问题(先讲动机,比硬讲概念强)

**问题**:Java 的传统线程(Platform Thread)**太贵**。

### 传统线程的成本

一个 Platform Thread:
- **1 个 OS 线程**(内核态对象,1:1 绑定)
- **默认 1MB 栈内存**(可配,但最低几十 KB)
- **上下文切换要陷入内核态**,慢
- **总数受限**,单机撑个几千上万就到头了

这意味着什么?

```java
// 假设你的 Controller 是这样:
@GetMapping("/contracts")
public List<Contract> list() {
    return contractService.list();  // 调数据库,耗时 50ms
}
```

Tomcat 的线程池默认 200 个。

**QPS 理论上限** = 200 / 0.05s = **4000 QPS**。

- 如果数据库慢了,单请求变 500ms → 只能 400 QPS
- 想撑 10000 QPS?得 500 个线程
- 500 个线程 × 1MB 栈 = **500MB 纯栈内存**,还没算业务对象

**这就是 "C10K 问题" 的 Java 版本**——线程成本太高,阻塞型 IO 模型撑不起大并发。

### 大家是怎么绕过去的?

**方案 1**:加机器 —— 简单粗暴,贵。

**方案 2**:响应式编程(Reactor/WebFlux) —— 代码难写,异步回调到处飞,debug 想死。

```java
// 响应式版本,代码变得很难读
public Mono<List<Contract>> list() {
    return contractService.findAsync()
        .flatMap(cs -> userService.enrichAsync(cs))
        .flatMap(enriched -> filterAsync(enriched))
        .timeout(Duration.ofSeconds(3))
        .onErrorResume(e -> Mono.just(List.of()));
}
```

**方案 3**:虚拟线程 —— Java 21 的解法。

---

## 二、虚拟线程的核心思路

### 一句话解释

**虚拟线程是 JVM 用户态调度的"轻量级线程",运行在少量平台线程之上,遇到阻塞时自动切换,用户代码看起来像同步但实际非阻塞。**

### 类比理解

- **传统线程**:每个员工配一辆公司车(OS 线程),公司车就那么多,员工多了车不够分
- **虚拟线程**:员工去车库领"共享电动车"(虚拟线程),车库里有几千辆(JVM 管理),停车充电时车自动给别人用(让出载体线程)

### 跑一个例子

```java
// 传统写法:Executors.newFixedThreadPool(200)
// 虚拟线程写法:
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    IntStream.range(0, 10_000).forEach(i -> {
        executor.submit(() -> {
            Thread.sleep(1000);  // 模拟 IO 等待
            return i;
        });
    });
}  // 等所有任务完成
```

这段代码:
- **创建 10000 个虚拟线程**
- **总耗时 ~1 秒**(几乎所有都在 sleep 时并行等待)
- **实际占用 OS 线程 < 机器 CPU 核数**(默认 = CPU 数)
- **内存占用** < 100MB(传统线程得 10GB)

这就是"廉价"的意义。

---

## 三、关键概念(面试常问)

### Carrier Thread(载体线程)

虚拟线程跑在少量"载体线程"(实际是 `ForkJoinPool` 里的 Platform Thread)上。默认载体数 = CPU 核数。

```
10000 个虚拟线程(VT)
       ↓
  ForkJoinPool 里的 N 个载体线程(CT,N = CPU 核数)
       ↓
  N 个 OS 线程
       ↓
  内核调度
```

### Mount / Unmount(挂载 / 卸载)

- **VT 在 CT 上执行代码**,叫 **mount**
- **VT 遇到阻塞**(比如 `Thread.sleep`、网络 IO),JVM 把 VT 从 CT 上**拿下来**,这叫 **unmount**
- **CT 空出来去跑别的 VT**
- **阻塞结束**(IO 返回、sleep 到期),VT 再被**挂**回某个 CT(不一定是之前那个),继续执行

这整个过程**用户代码无感知**,还是普通的同步代码风格。

### Pinned(钉住)

**一个 VT 不能 unmount 的状态,就叫 pinned**。
导致 pinned 的常见原因:

1. **synchronized 块里执行阻塞操作**:
```java
synchronized (lock) {
    Thread.sleep(1000);  // 这时 VT 被钉在 CT 上,CT 不能给别人用
}
```

2. **native 代码(JNI)里阻塞**

3. **调用 `Object.wait()`**(比 synchronized 更严重,Java 24 已优化)

**pinned 是性能杀手**。如果你的代码里 `synchronized` + 阻塞操作遍地都是,换成虚拟线程反而会**把所有 CT 都钉死,整个应用卡住**。

**修复方法**:
- 把 `synchronized` 换成 `ReentrantLock`(不会 pinned)
- 或者把阻塞操作移到 synchronized 外面

---

## 四、怎么用(API 速览)

### 创建单个虚拟线程

```java
// 方式 1: 直接启动
Thread vt = Thread.startVirtualThread(() -> {
    System.out.println("在虚拟线程跑");
});

// 方式 2: 用 Builder
Thread vt2 = Thread.ofVirtual()
    .name("vt-settle-", 0)   // 名字 + 起始编号
    .start(() -> doWork());
```

### 创建虚拟线程池

```java
// 推荐:每个任务一个 VT,无池化
ExecutorService ex = Executors.newVirtualThreadPerTaskExecutor();
ex.submit(() -> ...);

// 不要这样!不要 "固定虚拟线程池":
// VT 本来就是"廉价用完即抛",池化反而限制了并发度
```

### 在 Spring Boot 3.2+ 里用

```yaml
# application.yml
spring:
  threads:
    virtual:
      enabled: true   # 一行配置让 Tomcat 用虚拟线程处理请求
```

这行开了之后,Tomcat 接到的每个请求都跑在一个 VT 上,自动享受高并发红利。
**前提**:Spring Boot 3.2 + JDK 21。

---

## 五、什么场景真的用上,什么场景鸡肋

### 适合用 VT 的场景 ✅

**1. IO 密集型 Web 应用**

最典型的就是我们这种:
- Controller 接请求
- 调 MySQL(阻塞 IO)
- 调下游 HTTP 服务(阻塞 IO)
- 调 Redis(阻塞 IO)
- 返回

每一步都在"等"。用 VT,单机从 4000 QPS 变 40000 QPS,基本不需要改代码。

**2. 短时扇出并行调用**

```java
// 传统:要建线程池,怕爆
// VT:随便开,不心疼
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    Future<User> user = scope.fork(() -> userSvc.get(uid));
    Future<Order> order = scope.fork(() -> orderSvc.get(oid));
    Future<Stock> stock = scope.fork(() -> stockSvc.get(sid));
    scope.join();              // 等所有完成
    scope.throwIfFailed();     // 任一失败就抛
    return assemble(user.resultNow(), order.resultNow(), stock.resultNow());
}
```

`StructuredTaskScope` 是 Java 21 的结构化并发 API,配 VT 用很爽。

**3. 长连接 / SSE / WebSocket**

每个客户端一个长连接占一个线程。传统得用 Netty 反应堆,VT 可以回归同步写法,每连接一个 VT 都不心疼。

### 不适合 VT 的场景 ❌

**1. CPU 密集型计算**

```java
// 图像处理 / 加密运算 / 大量序列化
// 用 VT 没意义——反正你的瓶颈是 CPU,VT 解决的是 IO 阻塞
```

CPU 满的时候,给你 1 万个 VT 也撑不起吞吐,反而多了调度开销。
这种场景继续用 `ForkJoinPool` 或者 `newFixedThreadPool(CPU 核数)`。

**2. synchronized 密集 + 阻塞操作**

前面说过 pinning 问题。你的老代码如果 synchronized 遍地飞,直接换 VT 会死得很惨。

**3. 大量 ThreadLocal**

VT 是大量生成的(一个请求一个),如果每个 VT 都要初始化一堆 ThreadLocal,内存开销反而增加。

Java 21 给了替代品 **ScopedValue**(预览特性):

```java
// 传统 ThreadLocal
private static ThreadLocal<User> CURRENT_USER = new ThreadLocal<>();
CURRENT_USER.set(user);
... use ...
CURRENT_USER.remove();   // 忘了 remove 就内存泄漏

// ScopedValue(不可变 + 自动清理)
private static final ScopedValue<User> CURRENT_USER = ScopedValue.newInstance();
ScopedValue.where(CURRENT_USER, user).run(() -> {
    ... use CURRENT_USER.get() ...
});  // 结束自动清理
```

---

## 六、我们项目会怎么用 VT(结合实际)

### 现在还是 Java 8

我们项目是**阅文集团 Peacock 脚手架**,底层 Spring Boot 2.x + JDK 8。目前用传统 Tomcat 线程池(200 个 Platform Thread)。

**没办法用 VT,除非升级 JDK 21**。但集团层面不是随便换的,要:
- 先跑兼容性测试(几千个依赖包)
- 观察其他组试水情况
- 等集团基础架构组发"升级指南"

### 假如未来升 JDK 21 能用 VT,我会怎么改

**第一步**:开启 Spring Boot 的 VT 支持

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

**第二步**:把老代码里的 `synchronized + 阻塞调用` 换成 `ReentrantLock`

比如 MerchantUserIdCryptoUtil 里的 DCL 单例:
```java
// 老
public static synchronized Cipher getCipher() {
    if (cipher == null) { cipher = init(); }
    return cipher;
}

// 新:只保护对象创建,不包阻塞逻辑
private static volatile Cipher cipher;
private static final ReentrantLock lock = new ReentrantLock();
public static Cipher getCipher() {
    if (cipher == null) {
        lock.lock();
        try {
            if (cipher == null) cipher = init();
        } finally {
            lock.unlock();
        }
    }
    return cipher;
}
```

**第三步**:扇出调用用 `StructuredTaskScope`

C端结算里,算单笔分账要查:商品、用户、合同、分润规则,四个独立查询。
传统是串行查(4 × 50ms = 200ms)。
用 VT + 结构化并发:并行(max(50ms) = 50ms),**单请求延迟直接减 75%**。

**第四步**:给下游调用一并改成同步写法

老代码里为了性能写了 CompletableFuture,链式调用看着头大。VT 世界里直接同步写,性能相当、可读性飙升。

### 预期收益

- **同机器 QPS 提升 3-5 倍**(IO 密集场景)
- **接口 P99 延迟下降 30-50%**(扇出查询并行化)
- **代码复杂度下降**(异步代码回归同步写法)

**代价**:
- 要 JDK 21 + 一堆依赖升级
- 要重构 synchronized 为 ReentrantLock(容易踩 pinned 坑)
- 监控体系要改(线程相关的旧监控失效,需要新的 VT 指标)

---

## 七、常见误解(面试被追问容易翻车的点)

### ❌ 误解 1:VT 比传统线程"更快"

**不是**。VT 的 CPU 指令执行效率和 Platform Thread 完全一样,甚至因为调度层多一层,**单线程任务执行反而略慢**。

VT 的优势是 **"廉价 + 高并发"**,不是"单任务更快"。
给 CPU 密集型任务用 VT,**只会慢不会快**。

### ❌ 误解 2:VT 取代线程池

**不是**。VT 和 Platform Thread **共存**,Netty 那种反应式框架、CPU 密集池、定时任务还是用传统线程。

VT 只是**特别适合阻塞 IO 场景的一种新工具**。

### ❌ 误解 3:加个 `@Async` 就是虚拟线程

```java
@Async
public CompletableFuture<User> fetch() { ... }
```

默认 `@Async` 走 Spring 的 `SimpleAsyncTaskExecutor`(**每次新建 Platform 线程**)或配置的线程池。要用 VT 得:

```java
@Bean
public AsyncTaskExecutor applicationTaskExecutor() {
    return new TaskExecutorAdapter(Executors.newVirtualThreadPerTaskExecutor());
}
```

Spring Boot 3.2 + `spring.threads.virtual.enabled=true` 会自动配成这样。

### ❌ 误解 4:VT 没锁竞争

**错**。VT 之间访问共享变量一样要加锁,一样要用线程安全容器。VT 只是"线程廉价"了,并没有"免锁"。

### ❌ 误解 5:能无限开

**理论上**单机几百万 VT 没问题(内存是瓶颈,不是调度)。
**实际上**每个 VT 里的业务代码会分配对象、占连接池、占数据库 session。
**连接池不够才是瓶颈**——10000 个 VT 在等数据库,数据库连接池只有 50 个,后面的 VT 全卡在获取连接上。

---

## 八、监控和 debug

### 怎么知道用了 VT

```java
Thread t = Thread.currentThread();
System.out.println(t.isVirtual());        // true / false
System.out.println(t);                     // VirtualThread[...]/runnable@...
```

### 堆栈里怎么看

线程 dump(`jstack`)里 VT 显示为:
```
"" #23 virtual
   java.base/jdk.internal.vm.Continuation.enter0(...)
   ...
```

带 `virtual` 标记。

### 怎么知道有没有 pinning

JVM 参数:
```
-Djdk.tracePinnedThreads=short   # 简短堆栈
-Djdk.tracePinnedThreads=full    # 完整堆栈
```

启动加这个参数,VT 被 pinned 时会打日志:
```
Thread[#23,ForkJoinPool-1-worker-1] is pinned
    java.base/java.lang.Object.wait(Object.java:366)  <== monitors:1
```

看到这种日志,说明有 synchronized 锁在阻塞,要优化。

### 生产监控指标

- **VT 总数**:`Thread.getAllStackTraces().size()` 或 JMX
- **载体线程池**:`ForkJoinPool.commonPool()` 的任务队列深度
- **Pinned 次数**:JFR(JDK Flight Recorder)事件

JFR 配置:
```
-XX:StartFlightRecording=duration=60s,filename=rec.jfr
```

录制完用 JMC(JDK Mission Control)打开看 "Java Application > Virtual Threads"。

---

## 九、面试常被问的 Q&A

### Q: 虚拟线程是啥?解决什么问题?

> "JDK 21 正式 GA 的轻量级线程,叫 **Project Loom**。
>
> 解决的是 Java 传统 **1:1 线程模型**(一个 Java 线程对应一个 OS 线程)的**高并发瓶颈**。传统线程一个 1MB 栈,单机撑几千就是极限。
>
> VT 是 JVM 用户态调度,N:M 模型,一万个 VT 只用少量 OS 线程(默认 = CPU 核数)跑。
>
> 适合 IO 密集场景,把阻塞等待时间变成并发吞吐。"

### Q: VT 和传统线程的核心区别?

> "三个核心区别:
>
> 1. **调度主体不同**:传统由 OS 调度,VT 由 JVM 调度
> 2. **资源成本**:传统每个线程 ~1MB 栈,VT 几 KB
> 3. **阻塞行为**:传统线程阻塞会占着 OS 线程,VT 阻塞会 **unmount**,让 CT 去跑别的 VT
>
> 性能上 VT 不是单任务快,是**并发承载量大**。"

### Q: 什么是 pinning?怎么避免?

> "**pinning 是 VT 被钉死在载体线程上,不能 unmount**。
>
> 典型场景是 `synchronized` 块里执行阻塞操作:
> ```java
> synchronized (lock) {
>     network.call();   // pinned
> }
> ```
>
> 影响是:被钉死期间,载体线程不能给其他 VT 用,高并发下直接把载体池打满。
>
> 避免方法:
> 1. 把 `synchronized` 换成 `ReentrantLock`
> 2. 阻塞操作移出 synchronized
> 3. JDK 参数 `-Djdk.tracePinnedThreads=short` 观察哪里被钉,针对性改"

### Q: 什么场景适合用?什么不适合?

> "**适合**:
> - IO 密集 Web 应用(接请求 + 调 DB/下游 HTTP)
> - 扇出并行调用(配合 StructuredTaskScope)
> - 长连接(WebSocket/SSE)
>
> **不适合**:
> - CPU 密集计算(VT 解决的是 IO 阻塞,不是算得快)
> - synchronized 重的老代码(pinning 风险)
> - 已经用响应式(WebFlux)的项目(收益不大)"

### Q: ThreadLocal 在 VT 下有问题吗?

> "有两个问题:
>
> 1. **内存膨胀**:VT 数量巨大,每个 VT 的 ThreadLocalMap 都要占内存
> 2. **泄漏风险**:线程池复用时 ThreadLocal 要 remove,VT 每次 new,`remove` 习惯不好就容易漏
>
> JDK 21 提供 **ScopedValue**(预览)作为替代:
> - 不可变
> - 作用域结束自动清理
> - 在大量 VT 场景内存占用小得多"

### Q: 怎么在 Spring Boot 里启用?

> "Spring Boot 3.2+ 一行配置:
>
> ```yaml
> spring.threads.virtual.enabled: true
> ```
>
> 它会自动把:
> - Tomcat 的请求线程池 → VT
> - `@Async` 默认 executor → VT
> - `@Scheduled` 任务执行器 → VT
>
> 自动配置了 `TaskExecutorAdapter(newVirtualThreadPerTaskExecutor())`。"

### Q: 用 VT 能把 QPS 提升多少?

> "和场景强相关。IO 密集接口能提 3-10 倍,因为瓶颈从'线程数'变成'下游依赖'。
>
> 我们结算这种 4 个下游并行调用的接口,用 VT + StructuredTaskScope 后:
> - 延迟从 ~200ms(串行)→ ~50ms(并行)
> - 单机 QPS 从 4000 → 20000+(Tomcat 200 VT 换成无限 VT)
>
> **但瓶颈会转移**:数据库连接池、Redis 连接池、下游服务容量,这些反而成了新天花板。"

---

## 十、速记口诀

- **VT 是 JVM 用户态调度的轻量级线程**,N:M 模型
- **解决问题**:1:1 线程模型单机撑不起大并发
- **核心机制**:遇阻塞 **unmount**,载体线程去跑别的 VT
- **性能模型**:不是单任务更快,是**并发承载量大**
- **最大坑**:**pinning**(synchronized + 阻塞 = 钉死载体线程)
- **适合**:IO 密集、扇出调用、长连接
- **不适合**:CPU 密集、synchronized 老代码、WebFlux 项目
- **Spring Boot 3.2+** 一行 yaml 启用
- **监控**:`-Djdk.tracePinnedThreads=short` + JFR

---

## 十一、和面试官聊深一点的几个话题

### 为什么 Java 到 21 才做,Go 早就有 goroutine?

Go 从第一天就是 N:M + goroutine,JVM 历史包袱大:
- Java 有 20 年的同步代码和库假设"一个 Java 线程 = 一个 OS 线程"
- 现有 `synchronized`、`ThreadLocal`、JNI 都是基于这个假设
- Loom 项目做了 6 年,要改 JVM 底层 + 兼容老代码

Go 的 goroutine 没历史包袱,但也付出了代价:go routine 的栈是**可增长的**(初始 2KB,满了就扩),Java VT 用 Continuation + ForkJoinPool,机制不同但目标类似。

### 虚拟线程是协程吗?

**勉强算"有栈协程"**(stackful coroutine),但 Java 团队不说这个词,因为 Java 的语义上 VT 就是 Thread 的子类型,开发者用 `Thread` API 就行。

Go 的 goroutine 也是有栈协程。
Kotlin coroutines / JS async-await 是"无栈协程"(stackless),机制不同。

### 为啥叫"载体线程"不叫"工作线程"?

"载体(carrier)"强调 **VT 在它上面跑,它随时可能换车**。传统"工作线程"是跟任务绑定的,VT 的 carrier 是 **任务跑完就空出来接下一个 VT**,语义更贴切。

### JVM 怎么实现的?

底层是 **Continuation**(延续)这个概念:
- VT 执行到阻塞点,JVM 把栈帧**复制到堆**上(相当于"把执行状态存下来")
- 载体线程空出来去跑别的 VT
- 阻塞结束,JVM 把栈帧**复制回载体线程的栈**,继续执行

所以 VT 的栈是"可移动"的,这也是为啥 VT 不能有固定的 native 栈(JNI 里阻塞会 pinned)。
