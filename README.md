# FolderLock 2.4.2

Windows 本地文件夹加密工具。粘贴目录地址、设置密码后，逐个转换文件：生成密文 → 解密回读 → 比对字节数和 SHA-256 → 刷新密文到磁盘 → 删除对应明文。内容、文件名和子目录名由 **rclone crypt** 加密，使用 **WinFsp** 挂载后按需读取大文件。2.2 默认直接在原目录路径访问，下载器无需修改保存位置。

解锁后支持正常读写，包括编辑、保存、新增、删除、文件和目录重命名、编辑器的替换保存，以及 ffmpeg 视频拼接和 MP4 文件头回写。读取仍按需解密，**写入文件使用临时明文缓存**；安全锁定会等待文件关闭和写回、回读验证、刷新密文到磁盘，再清理缓存。

## 运行

2.4.1 更新品牌图标：文件夹与锁的组合标志，透明背景，16–256 像素共十档尺寸，右键菜单、程序 EXE、窗口及解锁入口使用同一套图形。请保留包内 `FolderLock-brand-v1.ico`；运行新版会更新右键图标并修复已登记目录的快捷方式。矢量源文件与配色说明见 `assets/README.md`。

2.4 新增文件夹右键入口：完整解压到固定位置后先运行一次 `FolderLock.exe`，自动为当前用户登记“使用 FolderLock 加密此文件夹”。以后右键普通文件夹，选择该项即可设置并确认密码，无需先寻找 EXE；App 已运行时交给现有窗口。Windows 11 请展开“显示更多选项”。可在 App 点击“安装 / 更新右键菜单”重新登记；移动程序后需重新运行新位置的 EXE。登记位置仅为 `HKCU\Software\Classes\Directory\shell\FolderLock.Encrypt`，无需管理员权限。移除此项可删除该注册表键，密文不受影响。

密文存储目录使用 `Hidden + System` 属性，勾选“隐藏的项目”不足以显示；可直接在地址栏输入完整的 `D:\Documents\Private.folderlock`，或在文件夹选项中取消“隐藏受保护的操作系统文件”。这两个属性仅减少误操作，内容保护由 rclone crypt 提供。微软 PowerToys 的 [File Locksmith](https://learn.microsoft.com/en-us/windows/powertoys/file-locksmith) 用于查找文件占用，与 FolderLock 无关。

完整解压 [FolderLock-2.4.2-Windows.zip](packages/FolderLock-2.4.2-Windows.zip)，保持 `FolderLock.exe` 和 `rclone.exe` 在同一目录。首次运行 `FolderLock.exe`，点击“准备挂载组件”安装 WinFsp；已安装时无需重装。面向 Windows x64，使用系统自带的 Windows PowerShell 5.1 / .NET Framework 4.x。

1. 粘贴普通文件夹的完整地址，也可点击“浏览”。
2. 点击“加密 / 继续加密”，首次设置并确认至少 8 个字符的密码。不同目录可设置不同密码。
3. 等待加密和验证完成。可点击“暂停转换”；会在安全检查点停止，当前明文保留，下次输入原密码继续。
4. 位置默认选择“原路径”，点击“解锁并打开（可读写）”，输入此目录密码。比如仍在 `D:\Documents\Private` 中查看、编辑、下载和执行 ffmpeg；新文件自动加密写回。也可改选空闲盘符。
5. 点击“安全锁定全部”，或关闭程序。程序会等待编辑软件/ffmpeg 释放写入文件并完成写回，再卸载、校验和清理。锁屏也会请求此流程。**只有显示“已锁定”才算完成**；文件仍被占用或写回失败时，不会强制丢弃缓存，也不会假报成功。退出请求会等安全锁定完成后才关闭窗口。

正常锁定后，双击原来的 `Private` 文件夹，里面显示带锁图标的“解锁文件夹”快捷方式。双击后直接弹出密码框，成功后打开原路径下的内容；App 已运行时请求交给现有窗口。以后正常使用无需手动寻找 EXE，但应保持完整的程序解压目录，不要移动或删除它。程序支持 `FolderLock.exe --open "D:\Documents\Private"`。

**存储位置：**例如访问路径是 `D:\Documents\Private`，真实密文位于同盘相邻的隐藏存储目录 `D:\Documents\Private.folderlock`。原路径是工具管理的固定目录入口，解锁时指向加密文件系统，锁定时指向只读的解锁入口。**备份必须包含整个 `Private.folderlock`，不能只备份 Private 的入口；不要删除存储目录或手工修改内部文件。** 密码验证标记、随机盐、状态及恢复缓存也在此存储目录内。最近目录记录不是恢复密文所必需的。

普通程序在锁定期间写入原路径会被拒绝。更新后的 OnlineVideoDownloader 只在原有流程准备写入目标目录时检查 FolderLock：目录已锁定则弹出密码框，成功解锁后继续原来的保存操作。下载位置、缓存和拼接流程保持原样；取消密码框、密码错误或保存失败时保留下载数据并显示恢复位置。密码只在 FolderLock 内使用；保存后目录保持解锁，使用完仍需安全锁定。

## 登录后恢复入口与单一锁图标

2.3 在首次打开已有保险箱、成功加密或导入后，登记当前用户的 Windows 登录启动项 `FolderLockEntryRestore`，命令为 `FolderLock.exe --restore-entries`。登录后静默重建最近目录中的锁入口，修复已确认失效的挂载点；无需先手动打开主界面。只处理入口，不加载密码、不挂载明文，不清理或假报写缓存已提交。崩溃后的待恢复缓存保持原样，点击锁图标输入原密码后恢复。操作互斥改用可在崩溃后恢复的内核锁，避免遗留磁盘锁文件挡住入口恢复。

这是 Windows **登录后**恢复，系统可能延迟启动；程序应保留在固定目录，不要在 Windows 中禁用其启动项。启动恢复日志在 `%LOCALAPPDATA%\FolderLock\entry-restore.log`。若磁盘尚未连接、入口被替换或存在未知文件，会保留数据并记录错误。运行正常主界面也会补做入口恢复。卸载时可在 Windows 启动应用中禁用此项，或删除当前用户 `Software\Microsoft\Windows\CurrentVersion\Run` 下的 `FolderLockEntryRestore` 值。

已修复 Windows PowerShell 5.1 下历史记录包含多个目录时自动恢复失败的问题。更新或移动程序后，运行新位置的 EXE 会逐个更新已登记目录的解锁入口；快捷方式提示目标已移动时，也可直接运行新位置的程序修复。

`Private` 是唯一日常入口；`Private.folderlock` 是真实存储，两者不表示两份视频。2.3 将存储目录设为隐藏/系统目录，旧版内部 `Open` 快捷方式在确认属于工具后移除，改用隐藏的数据模板 `.entry-template.dat`。正常显示只需使用 Private 中的“解锁文件夹”。手动显示受保护系统文件时仍能看到真实存储，请勿删除。登录机制参考 [Microsoft Run 注册表说明](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys)。

## 复制到另一台电脑或迁移位置

密码与密文没有绑定电脑或 Windows 账户。先在原电脑**安全锁定并确认完成**，再完整复制 `Private.folderlock`（包括配置、密钥校验标记及所有隐藏文件），不必复制 Private 联接点或旧快捷方式。

新 Windows 电脑安装此版本和 WinFsp，点击“导入已有密文…”，选择复制来的 `Private.folderlock`，输入原密码。也可先把密文目录地址粘贴到路径框再点导入。工具验证密码成功后才更新本机入口位置，在其旁边建立新的 Private，保留密码和加密文件内容；不依赖原电脑盘符、用户名或 App 历史记录。只有完整存储副本与密码即可导入，原副本不被修改。若改名，保留 `名称.folderlock` 的后缀格式。

目标 Private 已有其他文件时会拒绝覆盖；错误密码不改变旧配置。含未提交写缓存的副本会被拒绝导入，请回原电脑完成恢复和安全锁定后再复制。只拷贝部分密文或丢失配置/密码无法保证恢复。

## 空间、性能与恢复

- 首次必须完整读写所有已有内容，另有一次完整解密回读验证。每次只处理一个文件，不长期保留整份明文副本。
- 临时空间需要容纳最大的一个文件的密文，加上每 64 KiB 约 16 字节开销、文件头和至少 1 MiB 余量。暂停或失败时若已有同一文件的密文，重试替换可能需要更多空间；空间检查采取保守策略，不足时保留源文件并停止。
- 普通解锁只处理密钥并挂载。纯读取不缓存整份文件；通过 rclone VFS `writes` 模式支持随机写入。编辑/拼接时，需要为正在修改和输出的文件预留缓存空间，可能达到这些文件的完整大小。原路径模式的缓存位于相邻存储目录 `Private.folderlock/write-cache`，正常锁定成功后清理；不是长期保留整份文件夹副本。
- 保存关闭后使用 5 秒写回缓冲，供编辑器完成临时文件和重命名操作。锁定只等待和验证变动文件，不重新加密整个目录。超大输出的最后写回和回读验证仍需相应 I/O 时间，不能承诺锁定瞬间完成。
- 正常锁定会清除本工具的临时写缓存。**断电、崩溃或强制结束可能留下明文写缓存和未提交修改**，此时显示“写缓存待恢复 / 未锁定”，不保证处于已加密锁定状态。再次输入原密码，会先恢复可完整提交的缓存并验证，再挂载；残缺元数据会被拒绝并保留原数据，不能擅自删除缓存。尚在应用/系统内存中的内容不保证可恢复。
- 中断会保留已完成的密文和未转换的明文，状态为未完成。使用原密码“继续加密”；原文件尚在时允许重做它的密文，只有验证成功后才删除原文件。
- 密文校验失败、源文件被写入占用、权限不足或空间不足时停止，不显示完成。不要在加密过程中通过其他软件修改该目录。
- 删除通过仍持有的原文件句柄完成。不支持用户自建的符号链接、联接点、硬链接、EFS、未知备用数据流、网络路径、嵌套保险箱和系统/配置目录。仅允许工具自己建立且目标校验一致的原路径入口。
- 保留普通文件内容、修改时间及空目录；不承诺保留原始 NTFS ACL、创建时间等全部元数据。只读或无删除权限文件会被拒绝。
- 暂无永久解密/移除加密按钮。可从挂载盘复制导出明文，导出位置需要相应空间，导出文件不再受本工具保护。

## 安全边界

2.4.2 支持常见音视频文件的 `Zone.Identifier` 下载来源标记（至多 1 MiB）。先将标记的原始字节、原文件相对路径、长度和 SHA-256 另行加密归档到内部 `keycheck` 树，完整回读校验并刷新密文后才删除源文件；不直接删除来源标记。未知流、超大标记及非音视频文件上的标记仍会拒绝处理并保留原文件。支持的扩展名：webm、mp4、mkv、mov、avi、m4v、mpeg、mpg、ts、m2ts、mp3、m4a、aac、wav、flac、ogg、opus。

挂载视图不模拟 NTFS 备用流，归档的标记不会自动变成挂载文件的下载警告；归档按首次转换时的路径和内容哈希保留，不随以后重命名/编辑更新。需要恢复记录时，先安全锁定，在程序目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\Export-DownloadOrigins.ps1 -Folder "D:\Documents\Private" -Destination "D:\OriginExport"`，输入密码，导出到尚不存在的外部目录。JSON 的 `Data` 为原始流字节的 Base64；恢复到具体文件前应核对记录的 SHA-256。导出记录为明文，可能包含下载网址，完整备份保险箱则仍应复制整个 `.folderlock` 存储目录。

2.0 真实加密内容；未解锁且没有密码/密钥时，单纯修改 NTFS 权限无法读取原文。rclone 使用 scrypt 派生密钥、分块认证加密，并加密文件名。密码通过子进程标准输入/仅该进程的环境传递，不写入配置或命令行；obscured password 也只存在于运行进程内，并非安全存储形式。

忘记密码无法恢复数据，请保管密码并另做备份。文件数量、密文大小、时间戳、顶层目录名仍可能可见。加密不阻止有写权限的人删除或破坏密文，也不能防止已控制此电脑的程序在解锁期间读取数据。

**旧缩略图、索引、最近访问记录、应用缓存，以及删除原文件后磁盘上的历史明文残留不会自动清除。** 替换操作不是安全擦除，尤其是 SSD，不能承诺清除既有明文残留。加密过程中部分文件仍是明文；只在整个目录完成后显示完成。系统分页、休眠及外部软件缓存也不在本工具控制范围内。

## 旧版 ACL 用户升级

2.1 不覆盖 `%LOCALAPPDATA%\FolderLock\folders.json`，不自动处理旧版受管理目录。点击“旧版 ACL 恢复”打开原版程序，用旧密码解锁并“移除管理”，再回到 2.1 执行真正加密。仍在旧版管理中的目录及其上/下级目录会被拒绝。旧快捷方式仍属于旧版 ACL，不会自动升级为加密入口。

最近目录记录在 `%LOCALAPPDATA%\FolderLock\vaults.json`，程序资源在 `%LOCALAPPDATA%\FolderLock\app-v2`。卸载程序不会解密 `.folderlock`；卸载前应先确认密码、备份和需要导出的文件。

## 从 2.0 加密版本升级 / 长文件名报错

从 2.0/2.1 升级到 2.2：先关闭旧版并完成旧写缓存的安全锁定；新版粘贴原路径，保留“原路径”选项，用原密码解锁。工具只把原 `.folderlock` 重命名到相邻的 `Private.folderlock`，不复制或重新加密文件内容，然后建立固定入口和锁图标。切换后使用 2.2，旧版不能识别新的存储布局。相邻目标已存在或入口含未知文件时会停止并保留数据。

2.0 默认 base32 会放大密文文件名，普通长视频名称也可能超出 NTFS 单个名称 255 字符上限。2.1 改用更紧凑的 base32768，并在开始替换源文件前检查全部名称。极长的多字节名称若仍超过上限，会指出原文件并保留它，需要缩短该名称。

关闭旧程序后，用 2.1 粘贴原路径，输入**原密码**点击“加密 / 继续加密”；已经完成的保险箱直接“解锁并打开”。兼容升级只重命名既有密文，不重新加密文件内容，保留可恢复的升级日志。成功后保险箱格式版本为 2，旧版 2.0 会拒绝打开，避免错误解码。不要删除 `.folderlock`、重新设置密码或手动移动其中的密文。

最近目录列表的 PowerShell `File.Replace` 空备份参数错误也已修复；更新已有列表不会再报“使用 3 个参数调用 Replace：路径格式不合法”。

2.1.1 修复了文件名含中文全角问号 `？`、冒号等字符时的 `error reading source root directory: directory not found`。这些名称在 Windows 中合法，但把原生源路径交给 rclone 本地后端时会被当作转义名称重新解释。转换和缓存恢复现在都从已打开的文件流输入加密引擎，再完整回读验证，避免重新解析源文件名；不会修改原名称或已有保险箱格式。遇到此问题时保留 `.folderlock`，使用原密码继续加密即可。

同时修正写缓存的 Windows 文件名转义与逻辑名称之间的映射，锁定验证和异常恢复按正确名称访问密文。回归覆盖全角标点、类似引号的字符、结尾全角句点/空格符号的编辑保存，以及全角标点文件的崩溃恢复；转换后的文件仍保留原修改时间。

## 源码与构建

先下载固定版本 rclone（核对官方 SHA256SUMS）并安装 WinFsp：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Dependencies.ps1 -InstallWinFsp
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\FolderLock.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-App.ps1
```

输出 `dist\FolderLock.exe`、`dist\rclone.exe`、引擎说明和 `packages\FolderLock-2.4.2-Windows.zip`。EXE 需分发完整 ZIP。WinFsp MSI 会核验官方 NAVIMATICS LLC 签名，缺少挂载组件时界面会阻止开始加密。

测试只操作仓库内随机临时目录：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\smoke-test.ps1
# WinFsp 安装完成后，验证实际挂载/写入/卸载：
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\smoke-test.ps1 -MountTest
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\writable-test.ps1
# 加 -Ffmpeg C:\path\ffmpeg.exe 可增加真实视频生成/拼接/解锁后解码测试：
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\writable-test.ps1 -Ffmpeg C:\path\ffmpeg.exe
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\regression-test.ps1 -Case History
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\regression-test.ps1 -Case LongNames
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\migration-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\filename-test.ps1 -MountTest
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\original-path-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\entry-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\open-flow-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\startup-portability-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\history-restore-test.ps1
# 关闭 OVD 后，用实际下载器测试 HTTP 下载、锁定失败保留分片和安全锁定往返：
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\download-import-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\launch-test.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\dialog-test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\legacy-smoke-test.ps1
```

覆盖跨块边界二进制/空文件往返、中文和特殊字符密码、空目录、错误密码、暂停恢复、文件占用、备用流拒绝、密文损坏，以及注入验证失败后保留原文件。脚本保持 UTF-8 BOM 以支持 Windows PowerShell 5.1 中文。

读写回归还覆盖随机 seek、原子替换保存、文件/目录重命名、已有密文文件重命名、长中文缓存路径、占用写句柄时拒绝误锁、锁定后缓存清理及重新解锁读取；兼容回归覆盖中断的文件名升级。

依赖及格式参考：[rclone crypt](https://rclone.org/crypt/)、[rclone mount](https://rclone.org/commands/rclone_mount/)、[WinFsp](https://winfsp.dev/)。rclone 为 MIT 许可，随包附带上游 README；WinFsp 使用官方安装包。
