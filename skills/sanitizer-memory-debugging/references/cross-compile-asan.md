# Cross-compiling ASan for a 64-bit embedded target

Recipe for the case where you must run the sanitizer **on the board**, not on the host: x86_64 build machine → riscv64 (or aarch64) target running an older glibc.

## Toolchain choice: use Clang

Most prebuilt GCC cross packages ship **without `libsanitizer`**, so `gcc -fsanitize=address` dies at link time with `cannot find -lasan`. Clang's `compiler-rt` runtime ships with the toolchain, under:

```
<toolchain>/lib/clang/<version>/lib/<target>/libclang_rt.asan.a      # static
<toolchain>/lib/clang/<version>/lib/<target>/libclang_rt.asan.so     # for -shared-libasan
```

So: **GCC for the product build, Clang for the ASan build.** Keep them pointed at the same sysroot.

## Compile

```sh
CLANG=/opt/cross/bin/clang
SYS=/opt/cross/sysroot
T=riscv64-unknown-linux-gnu

# the library under test — the buggy code MUST be -O0 (see SKILL.md §1)
"$CLANG" --target=$T --sysroot="$SYS" -O0 -g \
  -fsanitize=address -shared-libasan -fno-omit-frame-pointer \
  -fPIC -shared -o libsuspect.so suspect.c

# the driver — same -shared-libasan so both share ONE runtime
"$CLANG" --target=$T --sysroot="$SYS" -O1 -g \
  -fsanitize=address -shared-libasan -fno-omit-frame-pointer \
  -o driver driver.c -ldl -Wl,-rpath,'$ORIGIN'
```

## glibc mismatch: ship a portable runtime

A board built with an older glibc (Buildroot-based images are commonly 2.29–2.31) refuses a binary linked against the toolchain's newer sysroot: `GLIBC_2.34 not found`.

Don't touch the system libraries. Copy the loader + the closure into a directory and start the binary through the loader:

```sh
./libs/ld-linux-riscv64-lp64d.so.1 --library-path ./libs ./driver
```

### The minimal closure, from `readelf -d`

`libclang_rt.asan.so` itself needs `libstdc++.so.6 libgcc_s.so.1 libc.so.6 libm.so.6`; add the driver's `libc.so.6` and (for the static runtime) `libresolv.so.2` — seven files in practice:

```
ld-linux-riscv64-lp64d.so.1
libc.so.6  libm.so.6  libgcc_s.so.1  libresolv.so.2
libstdc++.so.6        # copy libstdc++.so.6.0.xx and rename: ASan runtime is C++
libclang_rt.asan.so
```

Name `libstdc++` by its **SONAME** (`libstdc++.so.6`), not the versioned filename.

## Upload and run

`scp` is often blocked on internal networks; pipe a tar through ssh instead (and never mix it with a background `&` in the same ssh command):

```sh
tar czf - -C deploy . | ssh "$BOARD" 'mkdir -p /tmp/asan && cd /tmp/asan && tar xzf -'
```

```sh
ASAN_OPTIONS=detect_leaks=1 ./libs/ld-linux-riscv64-lp64d.so.1 --library-path ./libs ./driver
```

## Symbolising without the device

The toolchain's `llvm-symbolizer` is a **host-arch** binary and won't run on the board. Reports contain `module+offset`; resolve offline:

```sh
riscv64-unknown-linux-gnu-addr2line -e libsuspect.so -f -C 0xd10
# → do_something
#   /build/suspect.c:19      ← the malloc line
```

## What a good report looks like

```
==19026==ERROR: LeakSanitizer: detected memory leaks
Direct leak of 524288 byte(s) in 8 object(s) allocated from:
    #0 ... (libs/libclang_rt.asan.so+0xe580c)   # interceptor
    #1 ... (libsuspect.so+0xd10)                # leak site inside the .so
    #2 ... (loader+0x113a)                      # driver
    #3 ... (libc.so.6+0x2bd48)                  # __libc_start_main
SUMMARY: AddressSanitizer: 524288 byte(s) leaked in 8 allocation(s).
```

Frame #1 inside the `.so` is the proof that ASan crosses the library boundary — that is what the shared-runtime build buys you.
