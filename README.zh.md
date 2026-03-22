# zlack

终端轻量级 Slack 客户端，使用 Zig 构建。

**约 6,700 行 Zig 代码 / 5.5MB 二进制文件 / 零运行时依赖**

[English](README.md) | [日本語](README.ja.md) | 简体中文

## 功能

- 频道浏览（Channels / DMs 分区显示）
- 通过 Socket Mode 实时消息传递（WebSocket）
- 线程查看和回复
- 文件上传（Ctrl+U）
- 频道搜索（Ctrl+K）
- @提及（自动将用户名解析为用户 ID）
- 提及通知（终端响铃 + 侧边栏标记）
- 鼠标支持（滚动、点击、双击）
- 中日文输入支持（UTF-8 码点级光标移动）
- macOS Keychain 令牌存储

## 前提条件

- macOS（使用 Keychain）或 Linux（环境变量/提示认证）
- [devenv](https://devenv.sh/)（提供 Zig 和 SQLite）
- 启用了 Socket Mode 的 Slack App

### Slack App 所需权限（User Token Scopes）

| 权限范围 | 用途 |
|---------|------|
| `channels:read` | 频道列表 |
| `channels:history` | 消息历史 |
| `channels:write` | 发送消息 |
| `groups:read` | 私有频道列表 |
| `groups:history` | 私有频道历史 |
| `groups:write` | 发送到私有频道 |
| `im:read` | 私信列表 |
| `im:history` | 私信历史 |
| `im:write` | 发送私信 |
| `users:read` | 用户列表（获取显示名） |
| `chat:write` | 发送消息 |
| `files:write` | 文件上传 |

### Slack App 设置

- **Socket Mode**: 启用
- **Event Subscriptions**: `message.channels`, `message.groups`, `message.im`
- **App-Level Token**: 需要 `connections:write` 权限

## 构建

```bash
git clone https://github.com/gamisan9999/zlack.git
cd zlack
devenv shell
zig build
```

二进制文件输出到 `zig-out/bin/zlack`。

### 设置 Git hooks（贡献者）

```bash
git config core.hooksPath .githooks
```

## 运行

### 首次运行（设置令牌）

```bash
# 方式1：通过环境变量
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# 方式2：交互式提示
./zig-out/bin/zlack
# Enter User Token (xoxp-...): <粘贴令牌>
# Enter App Token (xapp-...): <粘贴令牌>
```

首次认证成功后，令牌会保存到 macOS Keychain。

### 后续运行

```bash
./zig-out/bin/zlack
```

### 重新配置令牌

```bash
./zig-out/bin/zlack --reconfigure
```

## 快捷键

### 导航

| 按键 | 操作 |
|------|------|
| `Tab` | 切换焦点：频道 → 消息 → 输入框 |
| `Shift+Tab` | 反向切换焦点 |
| `j` / `↓` | 向下移动 |
| `k` / `↑` | 向上移动 |
| `Ctrl+F` | 向下翻页（10 项） |
| `Ctrl+B` | 向上翻页（10 项） |
| `Enter` | 选择频道 / 打开线程 / 发送消息 |

### 命令

| 按键 | 操作 |
|------|------|
| `Ctrl+K` | 频道搜索 |
| `Ctrl+U` | 文件上传 |
| `Ctrl+T` | 切换线程面板 |
| `Escape` | 关闭线程 / 取消上传 |
| `Ctrl+C` / `Ctrl+Q` | 退出 |

### 消息

| 按键 | 操作 |
|------|------|
| `Enter` | 发送消息（线程模式时为线程回复） |
| `Shift+Enter` | 线程回复 + 同时发送到频道 |
| `@名称` | 发送时自动解析为 Slack 提及 |

### 鼠标操作

| 操作 | 效果 |
|------|------|
| 点击侧边栏 | 选择频道 + 焦点移到输入框 |
| 点击消息区域 | 选择消息 |
| 双击消息 | 打开线程 |
| 滚轮 | 滚动侧边栏/消息 |

## 测试

```bash
devenv shell
zig build test --summary all
```

64 个测试，覆盖类型定义、认证、缓存、UTF-8 处理和时间戳格式化。

## 许可证

MIT
