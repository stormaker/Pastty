# Maccy 2.7.1 REA 静态逆向分析

日期：2026-10-24。目标：为极简 Pastty 提取必要系统交互和存储设计。只下载、解包和检查官方发布物；未安装、启动或注入 Maccy，未读取用户剪贴板历史。

## 目标身份与证据

- 官方目标：[p0deje/Maccy 2.7.1](https://github.com/p0deje/Maccy/releases/tag/2.7.1)，发布包 `Maccy.app.zip`。
- ZIP SHA-256：`f388aee34de09a0c7531631303785d9938bef9a92130e21ce1049c8f56aad077`。
- 主程序 SHA-256：`e73120dbc9f12ec8241548cd156e5530a00c2d845ba624943212a07a1d05bedc`。
- 版本2.7.1，构建62，bundle ID `org.p0deje.Maccy`，最低系统14.0，`LSUIElement=true`。
- 主程序含 x86_64/arm64。选取arm64的UUID为 `D5091AA9-5F50-381C-AAAA-9893261BCBFE`，与本机10月23日Jetsam记录中Maccy的UUID一致。该身份匹配不证明死机原因。
- 签名元数据：Developer ID Application Alexey Rodionov，Team MN3X4648SC，hardened runtime，app sandbox。此处是静态签名字段检查，不是完整信任/公证验证。

REA证据保存为 `../research/rea-evidence.json`：

| 问题 | 结果 | Evidence |
|---|---|---|
| 发布包内容身份 | ZIP静态清单，623个occurrences，458文件、159目录、6符号链接 | `ev_49a3c7f61e74e5d26bbb13c7499bc021db8bd60af99a6e94dc78d9c1f3b80d31` |
| 主程序架构与UUID | Mach-O universal，当前检查arm64 | `ev_b28ca67a661ee9e4558b290f08f88fb4a53739011225763b6ddf7dc0089558bc` |
| 原生框架依赖 | 44项依赖，包括AppKit、SwiftUI、SwiftData、Vision、Carbon、Sparkle | `ev_9e9e5eb551a1e874a347e209686052dceaa95b8bf656e429c39bed3aa6070789` |
| 签名声明 | 签名、沙盒与权限声明 | `ev_a788cea6f97b2ae83cfc44e97edbcdd3901a2ecc695b67f1bedb1c7085055e66` |
| 包元数据 | 版本、后台应用、最低系统 | `ev_55d1807e1591444f663aecb0dc4fa5c7c1149cb3b97fabc6219341f1d8da8e38` |

## 与同版本源码交叉检查

1. **监听**：[Clipboard.swift](https://github.com/p0deje/Maccy/blob/2.7.1/Maccy/Clipboard.swift) 通过定时器比较NSPasteboard.changeCount，变化后读取内容；并非保存每一次复制的系统事件队列。Pastty采用有界轮询，明确快速连续覆盖可能漏掉中间项。
2. **回贴**：同文件先写回所选类型，再用CGEvent发送粘贴按键，检查辅助功能授权。Pastty保留这条必要机制，同时处理原窗口焦点、物理Option键释放、重复点击与授权失败。
3. **存储**：[Storage.swift](https://github.com/p0deje/Maccy/blob/2.7.1/Maccy/Storage.swift) 使用SwiftData ModelContainer与Storage.sqlite；[HistoryItemContent.swift](https://github.com/p0deje/Maccy/blob/2.7.1/Maccy/Models/HistoryItemContent.swift) 保存类型和Data。Pastty采用SQLite索引、文字按需读取，图片数据落磁盘，避免全历史大对象常驻。
4. **图片**：[HistoryItem.swift](https://github.com/p0deje/Maccy/blob/2.7.1/Maccy/Models/HistoryItem.swift) 含cachedDecodedImage缓存和clearDecodedImageCache清理方法，generateTitle遇图片会执行Vision OCR。Pastty没有OCR需求，省去该路径；缩略图单独降采样并设字节上限。静态源码不能建立缓存泄漏、清理无效或原应用死机的因果链。
5. **面板**：[FloatingPanel.swift](https://github.com/p0deje/Maccy/blob/2.7.1/Maccy/FloatingPanel.swift) 为NSPanel子类，使用nonactivatingPanel与SwiftUI NSHostingView。Pastty可直接使用AppKit NSPanel和NSTableView，无需网页层。

本次成功保存的部分源码副本位于 `../research/source-2.7.1/`；未声称已经克隆完整仓库。二进制依赖与源码设计相符，但二者不能代替动态调用证据。

## 给 Pastty 的决定

采用 **Rust + objc2原生AppKit + rusqlite/SQLite + ImageIO缩略图** 可行。Rust并不自动带来低内存；决定占用的是常驻数据量、图片解码、FFI对象生命周期和查询策略。Swift/AppKit同样可实现低占用；Tauri多出WebView与IPC，不作为此极简工具首选。

只实现文字/图片历史、保留系统Cmd+V、可配置热键打开列表、鼠标/方向键选择回贴、Esc取消，以及三个管理设置：显示菜单栏图标、历史快捷键、登录后自动启动。隐藏图标后的重新打开入口不可缺失。

## 覆盖与未解决项

已完成：发布包清单、包身份、架构、UUID、依赖、签名字段和公开同版本源码交叉分析。

未完成：函数反编译、动态调用追踪、堆分析、原问题复现、Pastty实现及性能验收。当前REA的Hopper/Ghidra未配置；本次使用可用的native-macos静态能力，未安装额外逆向引擎。导入/导出符号清单非穷尽；没有把符号未返回解释为功能不存在。REA原生会话已关闭。

现有证据支持精简设计，不支持声称找到了Maccy高内存或整机死机的确定根因。

## 项目迁移

研究资料于2026-10-24从`/Users/stormaker/Projects/Pastty`迁入正式目录`/Volumes/Docs/IO/Pastty`。原始Evidence保留采集时的路径，不改写历史证据。迁移后重新计算ZIP和主程序SHA-256，均与上文一致；本机记录为`research/relocation.json`。`research/`不发布到GitHub。
