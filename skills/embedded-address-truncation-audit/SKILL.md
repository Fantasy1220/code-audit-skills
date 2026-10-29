---
name: embedded-address-truncation-audit
description: "Use when 32-bit int truncates physical/DMA addresses."
version: 1.0.0
license: MIT
---

# Embedded Address Truncation Audit

Physical and bus addresses stored in `int` / `u32` / `S32`. On a 64-bit embedded target (RISC-V, ARM64) this is a whole-project class of bug: the address is fine on day one, then the memory map shifts and register writes go somewhere else entirely.

Worse than a wrong value: an address above `0x7FFFFFFF` stored in `int` comes back **sign-extended** on the way out — `0xFFFFFFFFxxxxxxxx` handed to a DMA register.

## When to use

- Symptoms: garbled DMA transfers, registers written with absurd values, wild-pointer crashes in code that "worked last month"
- The user asks to wipe 32-bit address storage out of a project, `u32` → `u64`
- Tracing a `u64 → int → u64` sign-extension chain
- Reviews of a diff that widened a public struct field (ABI blast radius)

## Workflow

### 1. Inventory — grep the whole tree, every subdirectory

```bash
grep -rn "int *phy\|u32 *phy\|S32 *phy\|U32 *phy\|int phyaddr\|u32 phyaddr\|int phy_addr\|u32 phy_addr"
grep -rn "FrameAddr\|busAddress\|stream_addr\|BusAddress"
grep -rn "(u32)\|(int)"                              # explicit casts
grep -rn "int frame_addr\|int addr, int size\|int buf_addr"
```

**Names without `phy` are the trap**: `luma_addr`, `chroma_addr`, `bs_addr`, `dpb_addr`, `counts_addr`, `bitstream_addr`. `scripts/residual-scan.sh` runs the whole pattern set in one pass.

### 2. Classify every hit (this is the actual skill)

| Class | Example | Action |
|---|---|---|
| **Real truncation** | `bs_addr = blk->u64PhyAddr`, `(u32)stream_addr`, `& 0xFFFFFFFF` | fix |
| **Hardware register write** | `SETREG32(...)`, `registerWrite(...)`, DMA descriptor fields | **do not touch** — the register is 32-bit, the low half is the correct value from hardware's view. Log these as "deliberately unchanged" |
| **Dead code** | inside `/* */`, `#if 0` | skip, or note it |
| **Unrelated cast** | byte counts, width/height `(u32)` | leave alone — widening these is damage |

The second row is where audits go wrong. "Every `(u32)` on an address is a bug" is false; the register interface is 32-bit by design.

### 3. Trace the data path

An address flows struct field → function parameter → extern declaration. Fixing one end and not the other is a no-op:

- **Sibling projects' `extern` declarations** must change together (`extern "C" int foo(int, int phy_addr)` mirrored across two libraries).
- **The same field on the other side of a data path**: widen one struct and leave its mirror at `S32` and you've changed nothing but the layout.
- **Structs shared with pre-built `.so` files** — see the ABI note below.

### 4. Choose the widened type

- Internal fields and parameters: `unsigned long long` — always available, no typedef-visibility questions across old projects.
- Parameters of a pre-built `.so` you can only re-declare: `intptr_t` (**only** on LP64, see pitfalls).
- Locals derived from addresses (`int n = rptr;`) — easy to miss, must change too.

### 5. Check ABI consumers before touching a public header

`grep -rl "#include <that_header.h>"` across all consuming projects:

- A consumer that only goes through a different interface header needs no rebuild — but confirm it, don't assume.
- Anything that lays out the struct or reads the field **must** be rebuilt, or it reads shifted memory.

### 6. Build, then re-scan for residue

- Build every library that consumes the header.
- Re-run step 1; the target is zero hits.
- Fix the format strings too: `printf("%x", addr)` → `%llx` (a truncated print hides a correct fix).
- Record artefact checksums before/after, and produce a change list that includes the "deliberately unchanged" set.

## Pitfalls

- **A fuzzy patch can land in the wrong block.** If `old_string` spans `u32 stream_addr` + `int phyaddr` and the file orders them differently, the tool may match a neighbour (`u32 stream_addr` + `int offset`): the old declaration survives, an unrelated variable disappears. Check the diff after every edit; treat `conflicting types` / `duplicate declaration` as a clobber, and restore from backup immediately.
- **LP64 ABI**: on RISC-V/ARM64, `int` and `intptr_t` parameters are passed identically (same register, positive values sign-extend to the same bits), so re-declaring `int → intptr_t` against a pre-built `.so` is safe. On 32-bit targets, or where the value can be negative, it is not.
- **"It fits today" is not safety.** A logical address that happens to sit below `2^31` leaves zero headroom; the memory map grows, and the field silently wraps. Widen for correctness, not for the current value.
- **Back up before batch editing.** Copy the tree (`backup_32bit/`) before touching dozens of files; a bad pass should cost one `rsync`, not a day.
- **Hard-coded simulation addresses are a different bug.** Where a fixed test address coexists with a dynamically allocated one, that's a value-domain problem, not a type problem — record it as residual risk instead of "fixing" it inside the type change.

## Verification

- Zero compile errors; the residual grep returns nothing; format strings updated.
- Deliverable: a change list with the widening principle, per-file edits, the deliberately-unchanged hardware register writes, and residual risks — written in the language the user writes to you in.

## Support files

- `scripts/residual-scan.sh` — re-runs the full grep set to prove nothing was missed.
