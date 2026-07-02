# OpenPathTrace

OpenPathTrace 是一个自用、可审计的 macOS 文件弹窗助手。它在标准“打开/保存”文件弹窗旁显示常用目录，点击后用系统的 `Cmd+Shift+G` 跳转到目标路径。

目标不是复刻完整商业软件，而是保留最有用的最小闭环：少代码、无网络、无第三方依赖、本地配置可读。

## 功能

- 菜单栏常驻应用。
- 监听标准 `NSOpenPanel` / `NSSavePanel`。
- 在文件弹窗旁显示收藏、最近、Finder 当前窗口目录。
- 点击目录后跳转到对应文件夹。
- 搜索当前列表里的路径。
- 右键收藏或取消收藏。
- 配置保存在 `~/Library/Application Support/OpenPathTrace/config.json`。
- 支持菜单开关登录启动。

## 安全边界

- 不联网。
- 不读取文件内容。
- 不做自动更新。
- 不使用第三方依赖。
- 不启用 App Sandbox，因为 Accessibility 和 Finder 自动化需要跨应用访问。
- 需要辅助功能权限，用于识别和操作标准文件弹窗。
- Finder 分组会请求 Finder 自动化权限；拒绝后收藏和最近路径仍可用。

## 构建

需要 macOS 14+ 和 Xcode Command Line Tools。

```bash
git clone https://github.com/immadolf/OpenPathTrace.git
cd OpenPathTrace
make app
open .build/OpenPathTrace.app
```

开发时也可以直接运行：

```bash
swift run OpenPathTrace
```

## 安装到 Applications

辅助功能权限绑定 app 的 Bundle ID、安装路径和签名要求。开发时反复复制未签名或 ad-hoc 签名的 app，会导致 TCC 记录失效，表现为标准文件弹窗出现时不显示面板。

首次安装前先检查本机是否有可用签名身份：

```bash
security find-identity -p codesigning -v
```

如果没有 `Apple Development`、`Developer ID Application`、`Mac Developer` 或 `OpenPathTrace Local Code Signing`，先创建本机自签名 code signing 证书：

```bash
make create-signing-identity
```

然后安装稳定签名版本：

```bash
make install
```

`make install` 会执行 release 构建、组装 `.app`、使用固定签名身份签名、停止旧进程、复制到 `/Applications/OpenPathTrace.app` 并启动。

如果这是从 ad-hoc 签名切换过来的首次修复，需要手动重置一次辅助功能授权：

1. 打开“系统设置 > 隐私与安全性 > 辅助功能”。
2. 删除旧的 OpenPathTrace 记录。
3. 添加 `/Applications/OpenPathTrace.app`。
4. 开启授权。

之后只要继续使用同一个签名身份和 `/Applications/OpenPathTrace.app`，TCC 授权不应因为每次构建反复失效。

## 验证

```bash
swift build
swift run OpenPathTraceCoreChecks
make app
plutil -lint Resources/Info.plist
make verify-installed
```

也可以拆开执行这些系统核验命令：

```bash
codesign -dv --verbose=4 /Applications/OpenPathTrace.app
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value, auth_reason, auth_version, last_modified FROM access WHERE service = 'kTCCServiceAccessibility' AND (client = 'dev.repairman.OpenPathTrace' OR client LIKE '%OpenPathTrace%');"
/usr/bin/log show --last 10m --predicate 'process == "OpenPathTrace" OR process == "tccd"'
```

`OpenPathTraceCoreChecks` 覆盖当前可纯函数验证的行为：最近路径去重/上限，以及贴边面板的位置策略。AX 监听和 `Cmd+Shift+G` 跳转属于 macOS 系统集成，需要手动打开标准文件弹窗验证。

## 文档

第一版 PRD 在 [docs/open-pathtrace-prd.html](docs/open-pathtrace-prd.html)。

## 当前限制

- 只承诺支持标准 macOS 文件弹窗。
- 不支持浏览器或 Electron 自绘上传控件的专门适配。
- 不做拖拽暂存架、统计面板、复杂分组管理。
- 不保证系统把 AX 事件送到本进程之前的耗时；只优化本进程处理路径。
