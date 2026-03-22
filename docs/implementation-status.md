# Implementation Status

Last updated: 2026-03-23

## Core Features

| Feature | Status | Notes |
|---------|--------|-------|
| Authentication (env / prompt / keychain) | Done | macOS Keychain, auto-save on first auth |
| Channel list (public/private) | Done | Sidebar with section headers |
| DM list (im) | Done | Separate API call, graceful scope fallback |
| Message history | Done | conversations.history, cache + display |
| Real-time messages (Socket Mode) | Done | WebSocket, auto-reconnect |
| Send messages | Done | chat.postMessage |
| Thread view | Done | conversations.replies, right pane |
| Thread reply | Done | thread_ts parameter |
| Thread reply + channel broadcast | Done | Shift+Enter, reply_broadcast=true |
| File upload | Done | 3-step API: getUploadURLExternal + PUT + completeUploadExternal |
| Channel search | Done | Ctrl+K, fuzzy filter modal |
| @mention send | Done | @name auto-resolved to <@USER_ID> |
| @mention receive | Done | Terminal bell + sidebar @ badge |
| Unread indicator | Done | Sidebar * badge for new messages |
| Mouse scroll | Done | Wheel up/down on sidebar and messages |
| Mouse click | Done | Focus + select, double-click opens thread |
| Japanese input | Done | UTF-8 codepoint-aware cursor, CJK width calculation |
| Timestamp display | Done | localtime_r, YYYY-MM-DD HH:MM:SS |

## Not Yet Implemented

| Feature | Priority | Notes |
|---------|----------|-------|
| Reactions (add/remove/display) | High | API: reactions.add/remove/get |
| Emoji rendering | High | Currently shows raw Unicode (some terminals don't render) |
| MPIM (multi-party IM) | Medium | Needs mpim:read scope |
| Message editing | Medium | chat.update API |
| Message deletion | Medium | chat.delete API |
| Code block / syntax highlight | Medium | mrkdwn.zig is a stub |
| Link preview / unfurl | Low | Display URL metadata |
| User presence (online/away) | Low | users.getPresence |
| Starred channels section | Low | stars.list API |
| External connections section | Low | Slack Connect API |
| Apps section | Low | Bot user filtering |
| Pagination (>200 channels/users) | Medium | pagination.zig exists but unused |
| Offline message queue | Low | db.zig has enqueueMessage, not wired to retry |
| Multiple workspaces | Low | UI framework exists (Ctrl+W modal) |
| Notification sound customization | Low | Currently terminal bell only |
| Linux support | Medium | Keychain -> libsecret, no Security.framework |
| Image preview in terminal | Low | Requires sixel/kitty protocol |
| Message search | Medium | search.messages API |

## API Coverage

| Slack API Method | Used | Location |
|-----------------|------|----------|
| auth.test | Yes | api.zig:authTest |
| conversations.list | Yes | api.zig:conversationsList, conversationsListIm |
| conversations.history | Yes | api.zig:conversationsHistory |
| conversations.replies | Yes | api.zig:conversationsReplies |
| conversations.mark | Yes | api.zig:conversationsMark (defined, not wired) |
| chat.postMessage | Yes | api.zig:chatPostMessage, chatPostMessageBroadcast |
| users.list | Yes | api.zig:usersList |
| users.info | Yes | api.zig:usersInfo (defined, not wired) |
| apps.connections.open | Yes | api.zig:appsConnectionsOpen |
| files.getUploadURLExternal | Yes | api.zig:filesUpload step 1 |
| files.completeUploadExternal | Yes | api.zig:filesUpload step 3 |

## Test Coverage

| Module | Tests | Categories |
|--------|-------|------------|
| types.zig | 13 | JSON parsing, error responses, IM fields |
| auth.zig | 17 | Token validation, boundary values, keychain names |
| cache.zig | 12 | CRUD, reverse lookup, replace, multi-channel |
| input.zig | 15 | UTF-8 width, codepoint navigation, boundary values |
| messages.zig | 7 | Timestamp format, invalid input, XSS, path traversal |
| **Total** | **64** | |

## Binary Stats

| Metric | Value |
|--------|-------|
| Source lines | ~6,700 |
| Binary size (debug) | 5.5 MB |
| Dependencies | sqlite3, vaxis, websocket (Zig packages) |
| Platform | macOS (Security.framework) |
