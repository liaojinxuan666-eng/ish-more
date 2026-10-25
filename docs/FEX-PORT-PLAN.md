# iSH More — FEX JIT integration plan

Status: design / feasibility stage. This document does **not** claim that FEX is already integrated or that selecting FEX currently changes execution.

## Target behavior

- Keep the existing iSH x86 interpreter as the default and compatibility fallback.
- Add an in-app Settings selector with two entries: `Built-in x86 (stable)` and `FEX JIT (experimental)`.
- Persist the selected engine, but activate FEX only when the native FEX backend is built into the IPA and JIT readiness is confirmed.
- If the user selects FEX but the backend or JIT is unavailable, show a clear status and keep the existing engine available. Never let a setting silently make all commands fail.
- JIT activation is an external prerequisite on a sideloaded build (for example, through a compatible TrollStore workflow or StikDebug); selecting FEX in Settings must not claim JIT has been enabled.

## What the current source tells us

- `emu/cpu.h` defines a 32-bit CPU state (32-bit general registers and `eip`).
- `kernel/exec.c` builds an i686-style ELF process image and emits `i686` as the platform string.
- Current iOS builds run through `.github/workflows/ios-build.yml`; it produces an unsigned IPA with code signing disabled.
- Upstream FEX is a user-mode x86/x86-64 translator for ARM64 Linux. Its README requires an x86-64 RootFS; its top-level CMake configuration currently states that FEX supports 64-bit Linux and Windows, not iOS. A native iOS port therefore needs an intentional fork/shim layer, not just compiling the normal FEX executable and placing it in the iSH filesystem.

## Recommended engineering order

### Phase 1 — Backend boundary and safe feature gate

1. Define a small engine enum and persisted setting (`builtin` by default, `fex` opt-in).
2. Define a C/C++ bridge between the iSH execution path and a native FEXCore runtime.
3. Add a backend capability state: `not-built`, `JIT-unavailable`, `ready`, `runtime-error`.
4. Keep the setting unavailable/informational until the FEXCore target is actually linked, so the UI never advertises a nonfunctional engine as working.

### Phase 2 — FEXCore-only iOS port probe

1. Isolate FEXCore from FEX's normal Linux loader and application setup.
2. Create an iOS ARM64 CMake target and record each Linux-only dependency that must be shimmed or removed.
3. Build through GitHub Actions; do not change the current IPA build until this target can produce a native ARM64 static library.
4. Resolve executable-memory/JIT behavior under the actual signing and sideloading method, not only on the Actions runner.

### Phase 3 — iSH syscall/memory bridge

1. Connect FEX guest memory accesses to the iSH address-space/memory model.
2. Route guest syscalls, signals, exceptions and thread state into the existing iSH kernel rather than attempting to call a Linux host kernel that iOS does not provide.
3. Start with a minimal, measurable instruction/syscall subset; return unsupported errors cleanly.
4. Preserve the built-in path for unsupported instructions, JIT denial, or backend errors.

### Phase 4 — Settings and JIT UX

Expose the selector in the in-app Settings UI only once Phase 1's capability checks and fallback behavior exist. In FEX mode, show whether FEXCore is linked and whether JIT appears available. Do not treat opening StikDebug or switching apps as proof that JIT is ready.

StikDebug's integration guidance says the target app needs `get-task-allow`; it also describes pairing setup and a loopback VPN for its manual workflow. The unsigned IPA workflow must be checked after sideloading to see which entitlements the installed process actually receives.

## Acceptance tests before enabling FEX by default

- Existing built-in x86 mode still boots and runs current shell utilities.
- Selecting FEX with no FEX library gives a clear status and does not crash or break the shell.
- Selecting FEX without JIT falls back cleanly or clearly refuses the FEX launch without corrupting the session.
- With a FEX-enabled build and JIT active, a statically linked hello-world ELF can run, followed by dynamic-loader and filesystem tests.
- Test syscall failures, signals, threads, `mmap`/`mprotect`, file descriptors, and process exit behavior.
- Switch back to built-in mode and verify the original engine still works.

## Upstream references

- FEX README: https://github.com/FEX-Emu/FEX/blob/main/Readme.md
- FEX build constraints: https://github.com/FEX-Emu/FEX/blob/main/CMakeLists.txt
- FEXCore sources/build: https://github.com/FEX-Emu/FEX/tree/main/FEXCore
- StikDebug: https://github.com/StikDebug/StikDebug
- StikJIT integration requirements: https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- iSH More CPU state: https://github.com/liaojinxuan666-eng/ish-more/blob/master/emu/cpu.h
- iSH More ELF execution: https://github.com/liaojinxuan666-eng/ish-more/blob/master/kernel/exec.c
- iSH More iOS workflow: https://github.com/liaojinxuan666-eng/ish-more/blob/master/.github/workflows/ios-build.yml
