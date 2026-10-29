---
name: c-cpp-code-audit
description: "Use when auditing C/C++ for crashes, leaks, and UB."
version: 1.0.0
license: MIT
---

# C/C++ Code Audit

A checklist-driven audit for the failure modes that actually bite in production C and C++: **logic errors, segfaults, memory leaks, and wild pointers**. It produces a severity-ranked report you can hand to a reviewer — not a wall of grep hits.

Static reading complements runtime detection: for the "prove it actually happens" half, pair this with a sanitizer run (ASan/LSan).

## When to use

- "Review this C/C++ module for crash risk / leaks / undefined behaviour"
- Before shipping firmware or a library to a target you can't easily debug
- Auditing code you inherited, or a vendor SDK whose source you only partially have
- After a field crash: turn the symptom into a hunt list

## Audit procedure

### 1. Read the build first
- `Makefile` / `CMakeLists.txt`: which macros are live (`DEBUG`, feature flags), which platform is targeted
- **Pointer width matters**: cross-compiled 32-bit targets make address-truncation bugs real (see the companion skill on 32-bit address truncation)
- Which files are actually compiled (wildcards, conditional inclusion) — auditing dead sources wastes days

### 2. Map the API surface
- Public headers: signatures, struct layouts, fixed-size arrays, enum ranges
- `#define` bounds (e.g. `MAX_STREAMS`, `MAX_PLANE_NUM`) — these are the limits every index must be checked against
- Callback typedefs and the threading model: who may call what, from which thread

### 3. Trace resource lifecycle per entry point
For every public function, walk the full lifecycle:
1. **Acquire**: `malloc`/`calloc`/`new`/`open`/`mmap`/dequeue-from-ring
2. **Release**: `free`/`delete`/`close`/`munmap`/enqueue-back
3. **Error paths**: every `return`/`goto` between acquire and release
4. **Constructor/destructor symmetry**: every allocation in init has a matching free in destroy

### 4. Array and pointer safety
- Every indexed access: is the index provably bounded at this point?
- Every `memcpy(dst, src, len)`: is `len` ≤ dst capacity? Is `src` checked?
- Every pointer read out of a struct field: can it still be NULL / half-initialised?
- Every cast of a pointer to `int`/`u32`: does it truncate on a 64-bit host?

### 5. Bit-operation correctness
- `!x` (logical, yields 0/1) vs `~x` (bitwise). `flags &= !0x1` clears **everything**
- `&&` vs `&`, `||` vs `|` in flag code
- Shift amounts that can reach or exceed the type width

### 6. Thread safety
- Mutable globals/statics touched from more than one thread
- Every lock has an unlock on **all** paths, error paths included
- Thread lifecycle: start → join; what happens if the owner frees state while the thread runs

### 7. Size checks that happen too early
The classic: `if (size > LIMIT) return err;` then more data is appended afterwards without re-checking. Re-walk every write **after** the check.

## Bug pattern catalog

| Pattern | How to find it | Shape of the bug |
|---|---|---|
| Error-path leak | trace every return/goto between acquire and release | `p = malloc(n); if (err) return -1;` |
| Check-then-overflow | look for appends after a size check | header written after validation |
| `!` vs `~` in flags | grep `&= !` | clears all flag bits |
| Unchecked allocation | grep alloc sites in constructors | `p = malloc(n); p->f = x;` |
| Dequeued then dropped | error return after dequeue, no enqueue-back | each error leaks one slot → eventual deadlock |
| Unchecked `fopen` | grep `fopen(` without a NULL test | write to NULL FILE* |
| Unbounded index | `arr[var]` with no bound test | OOB read/write |
| Destructor skipped on early return | is `delete obj` still reachable? | object never destroyed |
| Stale size fields after realloc | check every field derived from the old size | capacity drift |
| Commented-out release | `//.*free\|//.*close` near alloc sites | leaks on every call |
| Idempotent global init (false positive) | does init guard on a non-NULL global? | allocates once — **not** a cumulative leak |
| Sibling init asymmetry | diff `Open` vs `Open2` of the same struct | one forgets `memset` → uninitialised fields |
| `close()` doesn't wake a blocked reader | `close(fd)` then `pthread_join` hangs in `read` | needs poll/timeout/cancel |
| Cleanup destroys uninitialised object | early `goto cleanup` on a shared path | `pthread_mutex_destroy` on a zeroed mutex = UB |
| No-op assert macro | read the custom `assertX` definition | logs but doesn't return → guard is decorative |
| Half-initialised state passes a fast path | init writes fields then allocates; reset skips when "unchanged" | partially built struct accepted by users |
| Stream-derived array index | parser output used directly as `[index]` | corrupt input → OOB read/write |
| Shift amount from input | `1 << (2 * (log - 4))` | negative shift / 32-bit overflow → absurd allocation |
| Unsigned counter underflow | `len -= consumed` where `consumed` may be 0 | wraps to ~4 GB; clamp or check first |
| Busy-wait on a hardware flag | `while (flag & BUSY);` | starves sibling threads; add a sleep or timeout |
| Unbounded `cond_wait` | no producer left, no timeout | permanent hang; use timed wait and handle the timeout |
| Double-create of a singleton/ring | two entry points both call the create function | second call leaks the first |
| Close dereferences a half-open handle | close path assumes children exist | NULL-test children on entry |

## Auditing a closed-source vendor library

When the implementation is a stripped `.so`/`.a` (crypto, driver shims), disassembly still answers "does this really allocate?":

1. Locate the symbol: `nm -D --defined-only libX.so | grep <sym>`; if stripped, search `objdump -d` for `jal <func>@plt`.
2. Dump the body by address range (`--start-address`/`--stop-address`, span taken from the neighbouring symbol).
3. Judge: a `jal malloc@plt` whose return value is stored = real allocation; `jal free@plt` = real release; a body that only returns 0 = **no-op**.
4. Classify: real leak (allocates per call, never frees) / idempotent global (guarded by a non-NULL global, allocates once) / balanced (create allocates, release frees).

This distinction matters: "init allocates but uninit is a no-op" is *not* a cumulative leak, and reporting it as one destroys the audit's credibility.

## Report format

Write a Markdown report next to the audited project **in the language the user writes to you in** — keep code, identifiers, paths and compiler output verbatim:

```markdown
# Code Audit Report

## 1. Critical (crash / deadlock / corruption)
### 1.1 <title>
**Where**: path:line
<description + snippet>
**Impact**: ...
**Fix**: ...

## 2. High (logic error, conditional crash)
## 3. Medium (missing validation, unhandled edge case)
## 4. Low (quality, dead code)
## 5. Summary table
| # | Severity | Class | Location | One-line |
## 6. Suggested fix order
```

Severity guide: 🔴 critical = crash, deadlock, corruption, security breach · 🟠 high = wrong behaviour or a crash under specific input · 🟡 medium = missing validation · 🟢 low = quality.

## Pitfalls that cost real time

- **Read the destructor/close path first.** A bug there invalidates every leak conclusion downstream.
- **Draw the CFG when the code uses `goto` error handling.** Whether cleanup runs depends entirely on label placement.
- **Never report a pattern match without following the control flow.** The variable is usually bounded somewhere you haven't read yet.
- **Overcommit changes the verdict.** Missing `malloc` NULL checks are critical on embedded/no-overcommit targets and usually harmless on a desktop Linux default; grade accordingly.
- **Vendor sources are often CRLF + GBK**, which many readers (and `read_file`) classify as binary. Read them through `sed 's/\r$//' file.c | nl -ba`, and convert GBK with `iconv -f GBK -t UTF-8`.
- **Cross-arch disassembly**: a host `objdump` refuses a foreign `.so` ("can't disassemble for architecture UNKNOWN"); use the matching `<cross>-objdump`.
- **Atomic, verified edits only.** A fuzzy `patch` can match a neighbouring block with a similar signature — check the diff after each edit, and treat `conflicting types` / `duplicate declaration` as evidence you clobbered the wrong region.
- **Batch edits need a backup first.** Before touching dozens of files, copy them (`backup/`), so a bad pass is one `rsync` away from undo.

## Related

- Runtime proof for anything you suspect: sanitizer runs (ASan/LSan/UBSan), including cross-compiled targets.
- Whole-project type widening (32-bit address fields): see the address-truncation audit skill.
