# FEX 接入评估路线（RC1 规划）

## 为什么不能直接把 FEX 当作 iSH 的 CPU 后端

[FEX 官方项目](https://github.com/FEX-Emu/FEX) 的目标是让 x86/x86-64 Linux 程序运行在 ARM64 Linux 上。它不仅包含指令转译，还依赖 Linux 主机提供的系统调用、内存映射、线程和运行时环境。iOS 本身不是 Linux 主机；而 iSH 已经有自己的 x86 指令模拟与 Linux 系统调用转换层。把 FEX 放进工程目录或作为子模块，并不会自动让它接管 iSH 的 ELF 执行流程。

## 建议分阶段推进

### 阶段 A：定位 Cargo 故障

- 启用 iSH 的 `strace` 日志通道进行一次受控复现。
- 分别运行 `cargo --version`、`rustc --version`、`cargo check -v`，确定故障发生在 Cargo 启动、Rust 编译器启动，还是系统调用/指令执行过程中。
- 把 `Bad system call` 当作当前观察到的输出，不提前断言它一定来自某一种 CPU 指令。

### 阶段 B：构建与接口可行性

- 在 ARM64 Linux 环境先构建并测试所选 FEX 版本，明确依赖和最小 CPU 运行接口。
- 单独验证 FEX 相关组件在 iOS SDK/Clang 下能否编译；记录 Linux-only 依赖、系统调用入口、线程/信号机制和内存管理假设。
- 评估 iOS 对动态生成代码、可执行内存和目标分发方式的限制。没有通过这一步前，不把 JIT 方案视为可用。

### 阶段 C：桥接原型

- 设计明确的 `x86 ELF → FEX CPU backend → iSH syscall bridge → iSH filesystem` 路径。
- 与现有 iSH 执行路径并存，使用开关启用原型，不直接替换稳定路径。
- 先测试静态小程序、文件读写、线程/同步，再测试 `rustc --version`、`cargo check` 和 `cargo run`。

### 阶段 D：发布门槛

只有在真机可构建、可执行、有可复现测试，并且文件系统/进程兼容性经过验证后，才考虑把该路径纳入后续 RC。RC1 不包含 FEX 代码或二进制。
