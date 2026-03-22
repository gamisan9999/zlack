# zlack

A lightweight Slack client for the terminal, built with Zig.

**~6,700 lines of Zig / 5.5MB binary / zero runtime dependencies**

English | [日本語](README.ja.md) | [简体中文](README.zh.md) | [Português (BR)](README.pt-BR.md)

## Features

- Channel browsing with section headers (Channels / DMs)
- Real-time messaging via Socket Mode (WebSocket)
- Thread view and thread replies
- File upload (Ctrl+U)
- Channel search (Ctrl+K)
- @mention with auto-resolve (name to user ID)
- Mention notification (terminal bell + sidebar badge)
- Mouse support (scroll, click, double-click)
- Japanese / Chinese input support (UTF-8 codepoint-aware cursor)
- Keychain token storage (macOS)

## Prerequisites

- macOS (uses Security.framework for Keychain) or Linux (env/prompt auth)
- [devenv](https://devenv.sh/) (provides Zig and SQLite)
- Slack App with Socket Mode enabled

### Required Slack App Scopes (User Token)

| Scope | Purpose |
|-------|---------|
| `channels:read` | Channel list |
| `channels:history` | Message history |
| `channels:write` | Post messages |
| `groups:read` | Private channel list |
| `groups:history` | Private channel history |
| `groups:write` | Post to private channels |
| `im:read` | DM list |
| `im:history` | DM history |
| `im:write` | Send DMs |
| `users:read` | User list (for display names) |
| `chat:write` | Post messages |
| `files:write` | File upload |

### Required Slack App Settings

- **Socket Mode**: Enabled
- **Event Subscriptions**: `message.channels`, `message.groups`, `message.im`
- **App-Level Token**: With `connections:write` scope

## Build

```bash
git clone https://github.com/gamisan9999/zlack.git
cd zlack
devenv shell
zig build
```

Binary is output to `zig-out/bin/zlack`.

### Setup git hooks (for contributors)

```bash
git config core.hooksPath .githooks
```

## Run

### First launch (set tokens)

```bash
# Option 1: Environment variables
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# Option 2: Interactive prompt
./zig-out/bin/zlack
# Enter User Token (xoxp-...): <paste token>
# Enter App Token (xapp-...): <paste token>
```

Tokens are saved to macOS Keychain on first successful auth.

### Subsequent launches

```bash
./zig-out/bin/zlack
```

### Reconfigure tokens

```bash
./zig-out/bin/zlack --reconfigure
```

## Keybindings

### Navigation

| Key | Action |
|-----|--------|
| `Tab` | Cycle focus: Channels -> Messages -> Input |
| `Shift+Tab` | Cycle focus backward |
| `j` / `Down` | Move down in list |
| `k` / `Up` | Move up in list |
| `Ctrl+F` | Page down (10 items) |
| `Ctrl+B` | Page up (10 items) |
| `Enter` | Select channel / Open thread / Send message |

### Commands

| Key | Action |
|-----|--------|
| `Ctrl+K` | Channel search (fuzzy filter) |
| `Ctrl+U` | File upload mode (enter file path) |
| `Ctrl+T` | Toggle thread pane |
| `Escape` | Close thread / Cancel file upload |
| `Ctrl+C` / `Ctrl+Q` | Quit |

### Messaging

| Key | Action |
|-----|--------|
| `Enter` | Send message (or thread reply when in thread mode) |
| `Shift+Enter` | Thread reply + also post to channel |
| `@name` | Auto-resolved to Slack mention on send |

### Mouse

| Action | Effect |
|--------|--------|
| Click sidebar | Select channel + focus input |
| Click message area | Select message + focus messages |
| Click input area | Focus input |
| Double-click message | Open thread |
| Scroll wheel | Scroll sidebar or messages |

## Architecture

```
src/
  main.zig            # Entry point
  app.zig             # Application state + event loop
  slack/
    api.zig           # Slack REST API client
    auth.zig          # Token validation + Keychain storage
    socket.zig        # Socket Mode WebSocket client
    types.zig         # Slack API response types
    pagination.zig    # Cursor-based pagination helper
  tui/
    root.zig          # Root layout (header + sidebar + messages + thread + input)
    sidebar.zig       # Channel list with sections
    messages.zig      # Message display pane
    thread.zig        # Thread display pane
    input.zig         # Text input with UTF-8 support
    modal.zig         # Search/switch modal popup
    mrkdwn.zig        # Slack mrkdwn parser (stub)
  store/
    cache.zig         # In-memory cache (channels, users, messages)
    db.zig            # SQLite database (offline queue)
  platform/
    keychain.zig      # macOS Keychain / Linux stub
```

## Tests

```bash
devenv shell
zig build test --summary all
```

64 tests covering types, auth, cache, UTF-8 handling, and timestamp formatting.

## License

MIT
