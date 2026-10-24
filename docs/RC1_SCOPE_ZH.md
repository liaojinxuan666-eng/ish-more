# iSH More — 1.0.0-rc1 范围

本仓库基于 [iSH](https://github.com/ish-app/ish)，目标是在 iPhone/iPad 上提供轻量的 Linux shell 和可通过 iOS「文件」访问的开发工作区。

## RC1 目标

- 使用独立的应用显示名称、Bundle ID 和 App Group，便于与原版 iSH 并存安装。
- 将 iOS 营销版本设为 `1.0.0`；RC 阶段通过 `1.0.0-rc1` 标识。
- 保留 iSH 现有的 File Provider，不重复实现一套文件提供器。
- 通过 `/workspace` 作为建议工作目录，让项目在 File Provider 中更容易找到。
- Rust 编译器、Cargo 和标准库继续按需在 Alpine 环境中安装，不随 IPA 打包。
- 为后续 FEX 移植评估提供明确的技术边界和测试路径。

## 当前实现边界

RC1 的元数据与文档改动不代表 FEX 已经移植，也不代表 `cargo run` 的 `Bad system call` 已修复。iSH 的 x86 用户态模拟器和系统调用转换层，与 FEX 所依赖的 ARM64 Linux 运行环境不是可直接互换的组件。需要先采集实际失败日志，再按指令兼容性、系统调用和内存映射逐项定位。

## 手动验收

1. 构建 iOS App，并确认桌面显示为 `iSH More`。
2. 打开「文件」App →「浏览」→「位置」下的 `iSH More` → 对应 root（通常为 `default`）。
3. 在终端运行 `mkdir -p /workspace`，再运行 `cd /workspace && cargo new hello_cargo`。
4. 重新打开该 root 的文件列表，确认 `workspace/hello_cargo/Cargo.toml` 和 `src/main.rs` 可见。
5. 执行 `sh scripts/rust-diagnostics.sh`（将脚本复制到 iSH 内后运行），记录 Cargo/Rust 版本和命令退出状态。
6. 在未取得 `rustc`/`cargo` 的运行日志并完成设备测试前，不宣称 Rust 编译运行已修复。

## 已知限制

- File Provider 的 `enumerateChangesForObserver` 目前没有完整的变化跟踪实现；创建目录后若未立即显示，请返回上级并重新打开目录。实时刷新仍需单独实现和设备验证。
- FEX 不是 RC1 的运行时组件。
- 本补丁没有在 macOS/Xcode 上执行完整 iOS 构建；必须以 GitHub Actions 的结果作为首轮编译检查。
