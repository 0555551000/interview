# Git 日常使用(唠嗑版)

> 这份是当跟新来的同事讲"我们平常 Git 都怎么用"时写的。
> 面试问 Git 基本不会考 `git init`,会考场景:冲突怎么办、rebase vs merge、怎么回退等。
> 照着这份讲你的真实工作流,比背命令厉害得多。

---

## 一、日常 80% 都在用这 6 个命令

说实话,我每天 Git 就来回用这几个:

```bash
git status              # 看当前状态,最最常用
git add .               # 加到暂存区
git commit -m "xxx"     # 提交
git push                # 推远程
git pull                # 拉同事的最新代码
git log --oneline       # 看提交历史
```

其他的命令,**遇到问题了才用**。正因为日常只有 6 个,**偶尔遇到问题就容易慌**,面试里常问的就是这些非日常命令。

---

## 二、我们组的分支策略

**GitLab Flow** 改版,本质是 Git Flow 的简化:

```
master          <- 主分支,生产环境代码,受保护不能直推
  │
  ├─ develop    <- 开发主干,集成分支
  │    │
  │    ├─ feature/c端结算         <- 新功能分支
  │    ├─ feature/视频号加热       
  │    └─ fix/签约幂等bug          <- bug 修复分支
  │
  ├─ release/v1.8.0              <- 发布分支,冻结后只改 bug
  │
  └─ hotfix/支付异常              <- 线上紧急修复,直接从 master 拉
```

**一个 feature 从 develop 拉,完了合回 develop**
**发版时从 develop 拉 release 分支,测试通过合回 master + 打 tag**
**线上 bug 从 master 拉 hotfix,修完合回 master 和 develop**

---

## 三、日常开发 workflow(一天的 Git 动作)

### 早上到工位第一件事

```bash
# 切到主干,拉最新
git checkout develop
git pull --rebase

# 切回自己的 feature 分支
git checkout feature/c端结算

# 把 develop 最新代码 rebase 到自己分支上(下面细说)
git rebase develop
```

### 写代码中途

每写完一个小功能或修完一个小问题,**就提交一次**:

```bash
git add .
git status           # 确认改了啥
git diff --cached    # 看最终会提交啥(加了 --cached 是看暂存区)
git commit -m "feat(settle): 支持周结分账统计"
```

Commit message 我们组规范是 **Conventional Commits**:
- `feat:` 新功能
- `fix:` Bug 修复
- `refactor:` 重构(不改行为)
- `perf:` 性能优化
- `docs:` 文档
- `test:` 测试
- `chore:` 构建/工具

括号里是模块,比如 `feat(settle):` 表示这是结算模块的新功能。

### 下班前 push

```bash
git push origin feature/c端结算
```

第一次推新分支会要求 `--set-upstream`,我 alias 了:

```bash
alias gp='git push -u origin HEAD'
```

`HEAD` 表示当前分支,所以不管在什么分支都能直接 `gp`。

---

## 四、提交信息写得好 vs 写得烂

### ❌ 烂例子

```
fix bug
update code
阶段提交
asdfasdf
.
```

这种被 reviewer 看到会骂娘的。你自己一个月后也看不懂改了啥。

### ✅ 好例子

```
fix(signing): 修复个人签约提交后签名校验失败

原因:InternalSignUtil 拼接签名时没有对 URL 编码的空格做兼容,
前端 encodeURIComponent 生成 %20,后端拼接用了原始空格,导致签
名不一致。

修复方法:后端拼接时也对空格做 %20 转换,和前端统一。

影响范围:所有走 /api/sign/ 前缀的接口,测试已覆盖 P0 用例。
```

**主题一行(<= 72 字符) + 空行 + 详细描述**。
写清楚 **Why**(为啥改) + **How**(怎么改) + **影响**(影响哪些功能)。

---

## 五、Merge vs Rebase(经典面试题)

这是我解释给新人的类比:

### Merge - "把两条时间线拼起来"

```bash
git checkout feature/c端结算
git merge develop
```

效果:

```
develop:  A---B---C---D
                       \
feature:                 M  <- 合并提交
                       /
          X---Y---Z---/
```

- **优点**:保留完整的分支历史,能看出来哪些提交是"合并过来的"
- **缺点**:历史是"分叉"的,git log 看起来乱

### Rebase - "把我的提交搬到别人最新之后"

```bash
git checkout feature/c端结算
git rebase develop
```

效果:

```
develop:  A---B---C---D
                       \
feature:                X'---Y'---Z'   <- 重新基于 D
```

- **优点**:历史是**直线**,看起来清爽
- **缺点**:
  - **改写了提交历史**(X 变成 X',hash 变了)
  - 如果这个分支已经 push 过、别人拉过,再 rebase 会让大家乱套

### 我们组的约定

**私人 feature 分支用 rebase,合并回 develop 用 merge(或 squash merge)**

```bash
# 自己的 feature 分支同步主干,用 rebase 保持历史干净
git checkout feature/c端结算
git fetch origin
git rebase origin/develop

# 开 MR 合并回 develop,用 GitLab 界面的 "Squash commits" 选项
# 把 feature 分支的 N 个提交合并成 1 个干净的 commit 合入
```

### 铁律:**别对已经 push 过的分支 rebase**

除非是你一个人的个人分支。
已经有其他人拉过的分支,你 rebase 后他们再 pull 会卡住,要重新 `git pull --rebase` 才行。

---

## 六、冲突怎么解(被问到最多的)

场景:你 rebase develop 的时候提示:

```
CONFLICT (content): Merge conflict in src/settle/SettleService.java
```

### 步骤 1: 看哪些文件冲突了

```bash
git status
# Unmerged paths:
#   both modified:   src/settle/SettleService.java
```

### 步骤 2: 打开文件找 <<<<<<< 标记

```java
public class SettleService {
<<<<<<< HEAD (我的修改)
    public void settleWeekly() {
        // 我写的周结
    }
=======
    public void settleMonthly() {
        // 同事写的月结
    }
>>>>>>> develop
}
```

上半部(`HEAD` 那段)是当前 branch(你的修改),下半部(`>>>>>>> develop`)是要合并进来的代码。

### 步骤 3: 决定保留哪段

三种情况:

- **只保留我的**: 删掉中间到下半部
- **只保留别人的**: 删掉上半部到中间
- **两个都要**: 手动把两段代码合起来(最常见)

比如上面那个:

```java
public class SettleService {
    public void settleWeekly() {
        // 我写的周结
    }
    
    public void settleMonthly() {
        // 同事写的月结
    }
}
```

记得把 `<<<<<<<` / `=======` / `>>>>>>>` 这三行标记**全部删掉**。

### 步骤 4: 标记冲突已解决

```bash
git add src/settle/SettleService.java   # 标记这个文件已解决
git status                               # 确认没有 unmerged 了
```

### 步骤 5: 继续

- 如果是 **rebase** 冲突:`git rebase --continue`
- 如果是 **merge** 冲突:`git commit`(会自动生成合并提交)

### 如果冲突太多不想解了

```bash
git rebase --abort    # 放弃 rebase,回到 rebase 前的状态
git merge --abort     # 放弃 merge
```

### IDE 工具帮你看冲突更直观

IntelliJ 里 `VCS → Resolve Conflicts`,能看到**左中右三栏**(我的版本 / 合并后 / 对方版本),点点箭头就能选择保留哪段。**强烈建议用 IDE 解冲突**,比肉眼读 `<<<<<<<` 标记靠谱多了。

---

## 七、操作失误了怎么救

### 我提交到错的分支了

场景:我在 develop 分支写了代码,以为在 feature 分支,提交完才发现。

```bash
# 1. 把提交搬到新的 feature 分支
git branch feature/我写错了     # 基于当前 HEAD 创建新分支
git reset --hard HEAD~1         # develop 回退一个提交
git checkout feature/我写错了   # 切到新分支
# 提交还在
```

### 我 commit message 写错了

```bash
# 改最近一次的 commit message
git commit --amend -m "新的消息"

# 如果已经 push 了?需要强推(小心)
git push --force-with-lease
```

`--force-with-lease` 比 `--force` 安全,它会检查远程分支是否被别人推过,如果被动过就拒绝强推,避免覆盖同事的提交。

### 我忘了加文件到上一次提交

```bash
# 改完文件
git add 忘记的文件.java
git commit --amend --no-edit    # 加到上个 commit,不改 message
```

### 我要撤回最后一次提交但保留改动

```bash
git reset --soft HEAD~1         # 提交撤回,代码还在工作区
git reset HEAD~1                # 提交撤回,代码还在工作区,但 unstage
git reset --hard HEAD~1         # 提交撤回,代码也丢了(危险!)
```

### 我 `git reset --hard` 把代码删了能救回来吗

```bash
git reflog                      # 看所有 HEAD 变化记录
# 找到之前的 commit hash,比如 a1b2c3
git reset --hard a1b2c3         # 回到那个状态
```

`reflog` 是我的救命稻草,reset/rebase 误操作 90% 情况都能救回来(30 天内)。

### 我想把 3 个提交合成 1 个

交互式 rebase:

```bash
git rebase -i HEAD~3

# 弹出编辑器:
pick abc1234 feat: 第一版
pick def5678 fix: 调整参数  
pick ghi9012 fix: 再调一次

# 把后两个改成 squash 或 s:
pick   abc1234 feat: 第一版
squash def5678 fix: 调整参数
squash ghi9012 fix: 再调一次

# 保存,再弹出编辑器让你合并 message
```

### cherry-pick 挑一个提交过来

场景:生产 hotfix 也要同步到 develop 分支。

```bash
git checkout develop
git cherry-pick <hotfix 分支的 commit hash>
```

相当于"把这一个提交单独搬过来",不合并整个分支。

---

## 八、我踩过的 Git 坑

### 坑 1:`git push --force` 覆盖了同事代码

早期有次我 rebase 完直接 `git push --force` 到共享的 feature 分支,**把同事下午写的代码覆盖了**。他早上推的 commit,我 fetch 之后没 rebase 就强推了。

后来组里规矩:**共享分支不能 force push**,GitLab 配了保护。个人分支如果必须 force,用 `--force-with-lease`。

### 坑 2:merge conflict 解错了,把同事代码删了

冲突解决不细心,手快把同事写的一块业务逻辑删了,自测没发现。上线后客服反馈"原来能用的功能没了",复查才发现。

现在养成习惯:
1. **冲突解完跑一遍编译** `mvn compile`
2. **解完再过一遍 `git diff HEAD`** 看有没有误删
3. **大冲突让两个人一起看**,不独自拍板

### 坑 3:`.gitignore` 提交晚了

新建项目没写 `.gitignore`,把 `target/`、`.idea/`、`*.iml` 一股脑推上去了。
后来加 `.gitignore` 发现**这些文件已经被 tracked**,不 ignore 生效。

解决:

```bash
git rm -r --cached target/ .idea/ *.iml
git commit -m "chore: 清理不该追踪的文件"
```

`--cached` 是只从 index 移除不删本地文件。

### 坑 4:不小心把密钥 push 到公开仓

把 `.env` 里的 AK/SK 推到 GitLab。立刻:

```bash
# 1. 先吊销密钥(去云厂商后台)
# 2. 清理历史
git filter-repo --path .env --invert-paths    # 比 filter-branch 快
git push --force                               # 强推覆盖
# 3. 通知所有克隆过的同事重新 clone
```

**密钥泄漏了,靠删历史是救不回来的,一定要先吊销。**

### 坑 5:rebase 把别人的 merge commit 搞丢了

一个已经 merge 了 N 次的 feature 分支,我去 rebase develop,把所有 merge commit 全变成普通 commit,历史完全变了样。

后来学乖了:**rebase 只在"分支还没 merge 过"时做**。已经 merge 过的分支,用 `git merge develop` 同步最新就行。

---

## 九、Git 效率提升技巧

### alias 配置(我的 `~/.gitconfig`)

```ini
[alias]
    st = status
    co = checkout
    br = branch
    ci = commit
    lg = log --oneline --graph --decorate --all -20
    last = log -1 HEAD
    amend = commit --amend --no-edit
    undo = reset --soft HEAD~1
    unstage = reset HEAD --
    please = push --force-with-lease
    sync = !git fetch origin && git rebase origin/develop
```

用起来:

```bash
git st       # 代替 git status
git lg       # 图形化看最近 20 个提交
git sync     # 同步 develop 最新
```

### .gitconfig 通用配置

```ini
[user]
    name = pengchong
    email = xxx@example.com

[pull]
    rebase = true          # git pull 默认用 rebase

[push]
    default = current       # git push 默认推当前分支
    autoSetupRemote = true  # 自动关联远程

[rebase]
    autoStash = true        # rebase 自动 stash 工作区改动

[core]
    editor = vim
    autocrlf = input        # Mac 上避免 CRLF 问题
```

### 常用查看技巧

```bash
# 看某文件最近谁改的
git blame src/foo.java

# 看某个提交改了啥
git show <commit-hash>

# 两个分支的差异
git log develop..feature/xxx

# 搜提交记录里的关键字
git log --all --grep="签约幂等"

# 搜代码里某个字符串被谁在啥时候加的
git log -S "InternalSignUtil" --all

# 看某个文件的完整历史
git log --follow src/SignUtil.java
```

---

## 十、面试常见 Q&A

### Q: merge 和 rebase 的区别?实际工作用哪个?

> "区别是 **merge 保留完整分支历史**,会产生一个合并提交;**rebase 把当前分支的提交"搬到"目标分支的最新,历史变成直线**。
>
> 我们组的约定是:
> - **私人分支同步主干用 rebase**,保持个人提交历史干净
> - **合并回主干用 squash merge**,把多个小提交合成一个有意义的提交
>
> 铁律:**已经 push 过给别人的分支不 rebase**,不然别人拉不动。"

### Q: 遇到冲突怎么解?

> "分四步:
>
> 1. `git status` 看哪些文件冲突
> 2. 打开文件找 `<<<<<<<` 标记,决定保留哪段
> 3. `git add <文件>` 标记已解决
> 4. `git rebase --continue` 或 `git commit` 完成
>
> 冲突大的时候我用 **IntelliJ 的可视化合并工具**,左中右三栏看得清晰。
>
> 解完**跑一遍编译+核心测试**,别直接 push,我之前有过手误删同事代码的教训。"

### Q: 本地改错了怎么撤回?

> "看撤回什么程度:
>
> - **改了还没 add**:`git checkout -- <文件>` 或 `git restore <文件>`
> - **add 了还没 commit**:`git reset HEAD <文件>` 撤回暂存
> - **commit 了想改信息**:`git commit --amend`
> - **commit 了想丢弃改动**:`git reset --hard HEAD~1`(危险)
> - **已经 push 了**:`--force-with-lease` 强推(共享分支别干)
>
> 实在搞不回来就 `git reflog`,30 天内所有 HEAD 变化都有记录,能救。"

### Q: 分支策略怎么用?

> "我们用 **GitLab Flow**:
>
> - `master` - 生产代码,保护分支
> - `develop` - 开发主干
> - `feature/xxx` - 从 develop 拉,合回 develop
> - `release/vx.x` - 发版冻结用
> - `hotfix/xxx` - 紧急修复,从 master 拉,合回 master 和 develop
>
> 每个分支有明确的生命周期,不会乱。"

### Q: 提交信息怎么写?

> "Conventional Commits 规范:**type(scope): 主题**
>
> - type: feat/fix/refactor/perf/docs/test/chore
> - scope: 模块名,比如 settle/sign/contract
> - 主题: 一句话说清改了啥,< 72 字
>
> 详细描述写 **Why + How + 影响范围**,方便半年后自己看懂。"

---

## 十一、口语化速记卡

- "日常就 6 个命令:**status / add / commit / push / pull / log**,其他遇到才用"
- "分支规矩:**不直推 master,feature 命名规范,MR 至少 2 个 approve**"
- "**私人分支 rebase,合并用 squash**。已推过的共享分支不 rebase"
- "冲突四步:**status → 改文件 → add → continue**,大冲突用 IDE 合并工具"
- "回退利器:**reset --soft 保代码,reset --hard 丢代码,reflog 救命**"
- "force push 用 `--force-with-lease` 不用 `--force`"
- "commit message 写 **Why + How + 影响**,不要 `fix bug` 糊弄"
