# FolderLock

Windows 文件夹访问锁。通过 NTFS ACL 暂时拒绝当前 Windows 用户读取目录，用统一密码的哈希控制恢复原权限。**文件内容没有加密**；管理员、离线读取磁盘或有能力修改 ACL 的人可以绕过它。

## 下载与运行

下载 [Windows ZIP 包](packages/FolderLock-1.0.0-Windows.zip)，解压后双击 `FolderLock.exe`。这是免安装的单文件启动器，首次运行会将内嵌的 PowerShell 应用和图标放到 `%LOCALAPPDATA%\FolderLock\app`。需要 Windows PowerShell 5.1、.NET Framework 4.x、NTFS 文件夹，并以拥有目标文件夹权限的 Windows 用户运行。EXE 尚未进行代码签名，Windows 可能显示来源提示。

首次启动时设置并确认一次统一密码：在第一栏按 Enter 会进入确认栏，确认成功后即可将文件夹拖入列表，或点击“添加文件夹”。以后添加目录无需再设密码。添加后，程序会在同级目录生成“`文件夹名 - 解锁并打开.lnk`”。双击这个快捷方式会提示统一密码、恢复权限并打开 Explorer。原文件夹本身的双击仍由 Explorer 处理，Windows 不允许普通程序接管任意现有目录的双击动作。

首次设置的密码至少 8 个字符。程序只保存一份统一密码的随机盐和 PBKDF2-SHA256 哈希（310,000 次迭代），不保存明文密码。原 ACL 的 DACL 备份和全局设置保存在 `%LOCALAPPDATA%\FolderLock\folders.json`，所以**请勿删除或修改此文件**。已有旧版条目首次升级时会逐个要求旧密码，验证后改用统一密码。忘记密码时，程序无法代你恢复权限；管理员仍可通过 Windows 权限工具接管并修复。

## 自动锁定

默认开启 Explorer 窗口关闭、Windows 锁屏、睡眠前锁定，最长解锁时间默认为“无限制”。这些选项全局生效，可修改并点击“保存全局设置”。若设定了分钟数，任一启用的条件先触发就会锁定；“无限制”只关闭计时条件，其他条件仍有效。程序运行时每 5 秒处理一次系统事件；睡眠事件可能来不及在系统挂起前完成处理。关闭主程序时也会尝试锁定。由快捷方式启动的进程会在该文件夹再次锁定前保持运行。若进程崩溃、被强制结束或电脑突然断电，解锁状态可能暂时保留；下次启动主程序时会尝试重新锁定。

Explorer 关闭检测依赖 Explorer 的窗口路径：若 Explorer 不暴露当前标签页路径，仍由最长解锁时间兜底。锁定也不会撤销其他程序已打开的文件句柄或清除缩略图、最近文件等缓存。

## 从源码运行与构建

开发时可直接双击 `Start-FolderLock.cmd`。生成 EXE 和 ZIP 包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-App.ps1
```

构建脚本使用 Windows 自带的 .NET Framework C# 编译器，不需要安装 .NET SDK。输出为 `dist\FolderLock.exe` 和 `packages\FolderLock-1.0.0-Windows.zip`。仓库保留这个版本化 ZIP；`dist` 和 `build` 为忽略的本地中间产物。

可运行 `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\launch-test.ps1` 检查界面启动，运行 `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\dialog-test.ps1` 检查未确认密码无法提交，再运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\smoke-test.ps1` 验证拒绝读取、统一密码、旧数据迁移、计时选项和 ACL 恢复。`FolderLock.ps1` 必须保持 UTF-8 BOM 编码，以便 Windows PowerShell 5.1 正确读取中文文本。

## 使用与卸载提醒

先在一个无关紧要的测试文件夹中试用。锁定后请通过生成的快捷方式打开；如需停止管理，先解锁，再点击“移除管理”。不要把这个工具用于系统目录、用户配置目录、程序目录、网络目录或需要真正加密保护的资料。

卸载前先逐个解锁并“移除管理”，再删除 EXE 和 `%LOCALAPPDATA%\FolderLock`。仍有受管理文件夹时，不能删除其中的 `folders.json`，它保存了恢复原 ACL 所需的数据。
