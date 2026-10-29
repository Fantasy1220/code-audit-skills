# 给 C/C++ 代码做体检的三把刀

![format](https://img.shields.io/badge/format-SKILL.md-8A2BE2) ![license](https://img.shields.io/badge/license-MIT-3DA639) ![deps](https://img.shields.io/badge/dependencies-zero-lightgrey)

> **"这段 C 代码偶尔崩，可我说不清为什么。"**
>
> grep 出两百条命中，一半是误报；
> ASan 从头跑到尾，一行都没报；
> 地址明明是 64 位，写进寄存器就是错的。

三份 `SKILL.md`，专治这三种"说不清"。装进你的 agent（Claude Code / Hermes / Codex / OpenClaw / Cursor 都行），它就从"随手 grep 一下"变成"按流程审一遍，交一份能指到 `file:line` 的分级报告"。

---

## 你可能正卡在哪 → 该用哪把刀

| 你现在的症状 | 用这个 | 它真正给的东西 |
|---|---|---|
| 野指针、泄漏、越界、逻辑错，**读代码看不出来** | [`c-cpp-code-audit`](skills/c-cpp-code-audit/) | 23 类 bug 模式对照表 + 资源生命周期追踪法；连**没有源码的 `.so`** 都能靠反汇编判定是不是真泄漏 |
| ASan/LSan 跑完**一个错都不报**，开始怀疑工具 | [`sanitizer-memory-debugging`](skills/sanitizer-memory-debugging/) | 一条铁律：`-O1` 以上，你的 bug 已经被编译器**删掉了**。外加交叉编译 ASan 上真机的完整配方 |
| 物理地址是 64 位，**写进 DMA 寄存器就错乱** | [`embedded-address-truncation-audit`](skills/embedded-address-truncation-audit/) | 把"真截断"和"32 位寄存器本来就该 32 位"分开；揪出 `u64 → int → u64` 符号扩展，避免把 `0xFFFFFFFFxxxxxxxx` 送进硬件 |

三句话的分工：**一份负责"读出来"（静态），一份负责"跑出来"（运行时），一份负责"改对且不误伤"（整工程类型改造）。**

---

## 一、`c-cpp-code-audit`：把"感觉有 bug"变成"第 212 行有 bug"

它不丢给你一堆 grep 结果，而是走一遍真流程：**读构建配置 → 摸清 API 边界 → 逐个入口追资源生命周期 → 查数组/指针/位运算/线程 → 再回头查"检查完又追加数据"的老套路**。

自带的模式表有 23 条，摘几条最要命的：

| 模式 | 怎么发现 | bug 长什么样 |
|---|---|---|
| 错误路径泄漏 | 追 acquire 与 release 之间的每个 `return`/`goto` | `p = malloc(n); if (err) return -1;` |
| 检查完再溢出 | 盯着检查点之后的每一次写入 | 校验过了才写 header |
| `!` 当 `~` 用 | grep `&= !` | `flags &= !0x1` 把**全部**标志位清掉 |
| 出队后丢弃 | 出队后错误返回、没有归还 | 每次错误丢一个槽位，最终死锁 |
| 无操作的 assert 宏 | 读自定义 `assertX` 的定义 | 只打日志不返回，防护形同虚设 |
| 半初始化状态被快路径放行 | Init 写字段后逐个分配、Reset 有"没变就跳过" | 残缺结构被放行 → 使用点 SIGSEGV |

**独门的一段**：厂商只给你 `.so` 的时候——`nm -D` 找符号、`objdump --start/--stop-address` 挖函数体，看有没有 `jal malloc@plt` 且返回值被存下。这一招分出三类：真泄漏 / 幂等全局（init 判空跳过，只分配一次，**不是**累计泄漏）/ create-free 配平。**把"不是 bug 的东西"报成 bug，是审计最贵的错。**

## 二、`sanitizer-memory-debugging`：为什么你的 ASan 什么都没说

这是三份里最反直觉的一份。**ASan 不报错，九成不是 ASan 坏了**：

- `-O1` 以上，编译器会把"结果从没被读、也从没被 free"的 `malloc` 直接删掉 —— 你的 bug 在二进制里**已经不存在了**；
- 连 `volatile` 读回一个字节都救不了它，编译器会把整个 `malloc` 换成栈变量；
- 救法只有两个：被测代码 `-O0`，或者让指针"逃逸"（存进 `volatile` 全局 / 传给另一个编译单元里不可见的函数）。

所以它给的第一个动作不是加编译参数，是**先证明 bug 还在**：

```bash
objdump -d your_func | grep -c 'call.*malloc'   # 0 = bug 被优化没了，别怪 ASan
```

其余同样是踩出来的：`-shared-libasan` 为什么能让 `dlopen` 的库泄漏被正确归因；LSan 的 "still reachable" 为什么会被静默；交叉编译到 RISC-V/ARM 时那七个文件的便携 glibc 闭包（用 `readelf -d` 追 `DT_NEEDED` 得出，不猜）；设备上没有 `llvm-symbolizer` 时怎么用交叉 `addr2line` 离线还原行号。

## 三、`embedded-address-truncation-audit`：32 位存地址，今天是能用，明天是灾难

最难的不是改，是**判断哪些不该改**。硬件寄存器就是 32 位，你把它加宽反而错。所以这份技能的核心是一张分类表：

| 命中 | 判定 | 处理 |
|---|---|---|
| `bs_addr = blk->u64PhyAddr`、`(u32)stream_addr` | 真截断 | 改 |
| `SETREG32(...)`、DMA 描述符字段 | 硬件接口本来就是 32 位 | **不动**，写进"有意不改"清单 |
| `(u32)` 用在字节数、宽高上 | 跟地址无关 | 别误伤 |

以及最容易漏的一步：**地址会跨工程流动**。一个 `extern` 声明、数据通路另一侧的同名字段、预编译 `.so` 共享的结构体 —— 改了这头不改那头，等于什么都没改（还会被更隐蔽的结构布局错位咬一口）。配套 `scripts/residual-scan.sh` 一条命令复扫全部模式，改完拿它验收"零残留"。

---

## 它交出来的报告长这样

```markdown
## 1. 严重
### 1.1 解码错误路径上空闲槽位未归还
**位置**: src/codec/queue.c:212
**影响**: 累计 N 次错误后槽位耗尽，工作线程永久阻塞
**修复**: 错误返回前归还槽位，或统一走 cleanup 标签
```

分级只有四档 —— 🔴 崩溃/死锁/数据损坏 · 🟠 逻辑错或特定输入下崩溃 · 🟡 缺校验 · 🟢 质量。每条都必须能被 `file:line` 指到：**指不到的就是没查清，不该写成"可能的隐患"。**

报告语言跟随你：你用中文问，就用中文交；代码、路径、编译器原话保持原样，因为那是证据。SKILL.md 正文用英文只是为了让更多人能直接用。

## 装

纯 Markdown，无运行时、无依赖、不要 API key。

```bash
# Hermes
./install.sh --hermes      # → ~/.hermes/skills/<name>/

# Claude Code
./install.sh --claude      # → ~/.claude/skills/<name>/

# 任意 agent（显式指定目录）
./install.sh --to ~/.codex/skills

# 自动探测本机所有已知目录
./install.sh --all
```

没有 skills 机制的 agent（Codex / Cursor / Copilot 多数走 `AGENTS.md`），在 `AGENTS.md` 里加一行指过去即可：

```markdown
## 代码审计
审计本仓库 C/C++ 前，先读 `skills/c-cpp-code-audit/SKILL.md` 并按流程执行。
需要运行时证据时，读 `skills/sanitizer-memory-debugging/SKILL.md`。
```

## 这三份是怎么来的

不是从别人的模板改的。它们提炼自多轮真实审计：几十万行的 C 代码、64 位嵌入式 SoC、视频编解码栈、DMA 内存池、交叉编译的库。**模式表里的每一行，都对应某次真实的调试事故。**

所以它不教你"如何 grep 得更狠"，而是教你：**哪个命中是真的、哪个是假的、哪个是所有人都会漏掉的那一个。**

## 目录

```
skills/
├── c-cpp-code-audit/SKILL.md
├── sanitizer-memory-debugging/
│   ├── SKILL.md
│   └── references/cross-compile-asan.md
└── embedded-address-truncation-audit/
    ├── SKILL.md
    └── scripts/residual-scan.sh
install.sh
```

## License

MIT —— 拿去用，拿去改，塞进你团队的 agent 配置里。
