# Pastty

极简 macOS 文字/图片剪贴板历史工具。MIT 开源，计划通过 GitHub Releases 提供可拖拽安装的 DMG。

官方仓库：[stormaker/Pastty](https://github.com/stormaker/Pastty)。

正式工作目录：`/Volumes/Docs/IO/Pastty`。当前阶段：已完成Maccy源码与REA发布包静态分析、功能范围和技术选型；尚无可运行应用，性能目标未实测。

## 已确认范围

- 记录文字和图片，保留系统Cmd+V行为。
- 默认Option+V打开历史面板；鼠标点击或上下方向键+Enter选择并回贴，Esc关闭。
- 极简管理菜单：打开历史、设置、退出。
- 设置仅三项：显示菜单栏图标、历史快捷键、登录后自动启动。
- 隐藏菜单栏图标后，再次打开Pastty.app显示设置；复用同一运行实例。
- 不做搜索、置顶、OCR、同步、富文本或文件历史。

## 建议方案

Rust + objc2/AppKit原生UI + SQLite。图片原数据存磁盘，缩略图有界缓存；按条数和字节限制历史，避免全量载入。自动粘贴使用macOS辅助功能授权，自启动使用SMAppService。Rust工具链尚未安装。

## 文档

- [技术选型与性能验收目标](docs/技术选型研究.md)
- [REA逆向分析与证据边界](docs/REA逆向分析.md)
- [开源、签名、公证与 DMG 发布约定](docs/发布与开源.md)
- [许可证](LICENSE) · [第三方说明](THIRD_PARTY_NOTICES.md)

本机研究发布包与REA原始证据保存在Git忽略的`research/`目录，仅供静态分析，没有重新安装或运行Maccy。迁移后哈希已重新核对；原证据保留采集时路径。GitHub远程仓库已配置。应用构建、签名、公证与DMG发布均未执行。
