# Pastty

<img src="assets/Pastty-1024.png" width="96" alt="Pastty clipboard app icon">

极简、原生的 macOS 文字和图片剪贴板历史。MIT 开源。

> 当前版本为 **0.1.0 开发预览**：已有可运行的 Apple Silicon 应用与本地打包流程，尚未完成 Developer ID 签名、公证、跨机器安装和长时间稳定性验收。公开 Release 尚未发布。

## 使用

- 复制文字或图片后自动记录；`⌘V` 保持系统正常粘贴行为。
- 按 `⌥V` 或点击菜单栏图标打开紧凑历史菜单。
- 用鼠标或 `↑` / `↓` 选择，`Enter` 粘贴，`Esc` 取消。
- 菜单底部进入设置；仅包含菜单栏图标、历史快捷键、登录后自动启动。
- 隐藏图标后，重新打开 Pastty.app 返回设置。

自动粘贴需要在系统设置中给予 Pastty 辅助功能权限。未授权时，选中历史仍会复制到剪贴板，回到目标应用按`⌘V`即可。系统可能要求允许剪贴板访问。快捷键在安全输入/部分密码框中可能受系统限制；可以更换快捷键。

安装与权限说明见[安装与使用](docs/安装与使用.md)。

## 本地构建

需要 macOS、Command Line Tools、Rust 1.94.0（项目工具链文件固定版本）和 Python 3；普通安装用户不需要这些开发工具。

```sh
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --all -- --check
scripts/build-app.sh
scripts/make-dmg.sh
```

生成 `dist/Pastty.app` 和 `dist/Pastty-0.1.0-arm64-dev.dmg`。当前默认构建为 ad-hoc 签名的开发预览，不能视为已公证的正式发行。正式安装包后续通过 [GitHub Releases](https://github.com/stormaker/Pastty/releases) 提供。

## 低内存设计

Rust 管理历史与配置，轻量 Objective-C 桥接 AppKit 原生菜单/列表；单进程，无 WebView。SQLite 仅查询历史元数据，图片原数据按需从磁盘读取，缩略图按字节限制缓存，菜单关闭后释放图片引用。

历史默认限制为500项、30天、256 MiB有效内容；文字单项1 MiB、图片单项16 MiB。超限内容仍可正常系统粘贴，但不存入历史。轮询间隔400ms，快速连续覆盖可能漏过中间复制。不做搜索、置顶、OCR、同步、富文本或文件历史。

资源预算与长期测试要求见技术方案；本轮补齐启动隔离验证、10,000次文字、960次图片存储和1,000次菜单循环。具体口径与尚待项目见[第二轮验收](docs/第二轮验收.md)，首轮记录保留在[首版验收](docs/首版验收.md)。

## 文档

- [技术选型研究](docs/技术选型研究.md) · [REA逆向分析](docs/REA逆向分析.md)
- [Sprint 01](docs/Sprint-01.md) · [本地构建与验收](docs/本地构建与验收.md)
- [发布与开源](docs/发布与开源.md)
- [MIT许可证](LICENSE) · [第三方说明](THIRD_PARTY_NOTICES.md)

本机研究资料位于Git忽略的`research/`目录，未上传Maccy二进制或个人剪贴板数据。
