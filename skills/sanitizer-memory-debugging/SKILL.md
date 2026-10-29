---
name: sanitizer-memory-debugging
description: "Use when ASan/LSan reports nothing on a real target."
version: 1.0.0
license: MIT
---

# Sanitizer Memory Debugging (ASan / LSan / UBSan)

Static review finds suspects; sanitizers catch them **at the moment they happen**. This skill is the runtime half: build with ASan, get a stack, done.

The interesting part isn't the happy path — it's the three places where a correct build still shows **nothing**, and you conclude "the sanitizer is broken" when in fact the evidence was optimised away or never symbolised.

## When to use

- "ASan reports nothing but I know there's a leak" ← start at §1, this is the usual answer
- Prove a suspected leak / overflow / use-after-free on hardware, not just on the host
- Cross-compile the sanitizer runtime for an embedded target (RISC-V, ARM)
- A library is `dlopen`ed and its leaks aren't attributed to it

## 1. The bug was optimised away (the #1 false negative)

At `-O1`+ the compiler deletes a `malloc` whose result is **never read and never freed**. Not "the allocator is fine" — the call no longer exists.

- Even a `volatile` read of **one byte** doesn't save it: the compiler can replace the whole `malloc` with a stack slot (observed with clang 22 on riscv64).
- The pointer must **escape** to survive: store it in a `volatile` global, or hand it to an opaque function in another translation unit (no LTO).
- The guaranteed fix is `-O0` for the code under test.

> **Verify the bug survived before blaming the tool**: `objdump -d` the function and count the `malloc`/`memset` call sites. Zero means the demo was optimised out; two after rebuilding at `-O0` means it's live.

## 2. Shared libraries: one runtime, `-shared-libasan`

When `main` dlopens or links a `.so` that contains the bug:

- Build **both** with `-fsanitize=address -shared-libasan` so they share a single `libclang_rt.asan.so`.
- Two statically-linked ASan runtimes produce *"ASan runtime does not come first"* and undefined behaviour.
- The `.so`'s `malloc` is still intercepted, because the runtime sits earlier than libc in `DT_NEEDED`. In the report, frame #0 is the interceptor and frame #1 is the leak site inside the `.so`.

## 3. LeakSanitizer semantics

- `ASAN_OPTIONS=detect_leaks=1` (default on Linux); leaks are reported at exit with a non-zero status.
- LSan only calls **unreachable** allocations a leak. A pointer still held by a global or a live stack frame is "still reachable" and silent by default — that is often the real story.
- Don't `dlclose` the leaking `.so` before exit, or the allocation stack can no longer be symbolised back to it.

## 4. Symbolisation without the target's symbols

Embedded targets rarely ship `llvm-symbolizer` (and the cross toolchain's copy is host-arch, useless on-device). Reports then read `libleak.so+0xd10`.

Resolve offline with the cross `addr2line`:

```bash
<cross>-addr2line -e binary -f -C 0xd10     # function + file:line
```

Frame layout of a leak report: `#0` interceptor · `#1` your allocation site · callers · `__libc_start_main`.

## 5. Cross-compiling ASan for an embedded target

```bash
clang --target=riscv64-unknown-linux-gnu --sysroot=<sysroot> \
  -O0 -g -fsanitize=address -shared-libasan -fno-omit-frame-pointer \
  [-fPIC -shared] -o out in.c
```

Two things bite here: the target needs a **compatible glibc** (ship one alongside and start the binary through its `ld-linux-*.so.1`), and GCC builds often lack `libsanitizer` entirely — if `-fsanitize=address` fails to link, that's the reason, and Clang is the way round it. Full recipe: `references/cross-compile-asan.md`.

## Reading a report

| Line | Meaning |
|---|---|
| `ERROR: AddressSanitizer: heap-buffer-overflow` | "N bytes after M-byte region" + shadow bytes (`fa` = redzone, `00` = addressable) |
| `ERROR: LeakSanitizer: detected memory leaks` | `Direct leak of N byte(s) in M object(s) allocated from:` + stack + `SUMMARY:` |
| `SEGV on unknown address` | often a wild pointer from a truncated address or a freed object |

## Verification checklist

1. `objdump -d` confirms the buggy code survived the build.
2. `readelf -d` shows the exact `DT_NEEDED` closure — assemble the portable runtime from exactly that, nothing more.
3. Run with `ASAN_OPTIONS=detect_leaks=1`; expect a non-zero exit and a report.
4. Still silent? Go to §1 before anything else.

## Output language

Report findings in the language the user writes to you in. Keep code, paths, flag names and sanitizer output verbatim — they are evidence, not prose.
