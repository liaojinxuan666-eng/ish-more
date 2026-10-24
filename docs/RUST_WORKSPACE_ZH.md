# Rust 工作区与 iOS「文件」App（RC1）

## 推荐目录

在 iSH More 终端内执行：

```sh
mkdir -p /workspace
cd /workspace
cargo new hello_cargo
cd hello_cargo
```

这样，项目位于 Linux 根目录的 `/workspace/hello_cargo`。`mkdir` 创建的是 iSH 虚拟 Linux 文件系统中的目录，不是 iOS 沙盒里的独立目录。iSH More 现有的 File Provider 会把该 root 展示给系统「文件」App。

## 在「文件」App 中查看

1. 打开「文件」App，点击「浏览」。
2. 在「位置」中打开 `iSH More`（如果没有显示，检查 iSH More 是否已安装并首次启动）。
3. 打开对应的文件系统 root，默认名称通常是 `default`。
4. 打开 `workspace`，然后进入 `hello_cargo`。

如果你继续在 `~`（通常是 `/root`）目录中运行 `mkdir rust-test`，则应在 File Provider 的 `default/root/rust-test` 下查找。

## 注意

- App 的 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` 设置暴露的是 App Documents；Linux 根文件系统则由独立的 File Provider domain 暴露，两者不是同一目录。
- 目前 iSH 的 File Provider 没有完整的文件变更枚举；新目录未即时出现时，返回上一级并重新打开。RC1 文档不会把这点描述为已解决。
- 不要把 `cargo new` 成功当作编译成功。你当前遇到的 `cargo run` → `Bad system call` 仍需单独诊断。
