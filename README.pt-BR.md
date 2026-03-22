# zlack

Cliente Slack leve para o terminal, construído com Zig.

**~6.700 linhas de Zig / 5,5MB de binário / zero dependências em tempo de execução**

[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh.md) | Português (BR)

## Funcionalidades

- Navegação de canais com cabeçalhos de seção (Channels / DMs)
- Mensagens em tempo real via Socket Mode (WebSocket)
- Visualização e respostas em threads
- Upload de arquivos (Ctrl+U)
- Busca de canais (Ctrl+K)
- @menção com resolução automática (nome para ID de usuário)
- Notificação de menção (alerta do terminal + badge na barra lateral)
- Suporte a mouse (scroll, clique, duplo clique)
- Suporte a entrada CJK (cursor com reconhecimento de codepoint UTF-8)
- Armazenamento de tokens no macOS Keychain

## Pré-requisitos

- macOS (usa Security.framework para Keychain) ou Linux (autenticação por variáveis de ambiente/prompt)
- [devenv](https://devenv.sh/) (fornece Zig e SQLite)
- Slack App com Socket Mode habilitado

### Escopos necessários do Slack App (User Token)

| Escopo | Finalidade |
|--------|-----------|
| `channels:read` | Lista de canais |
| `channels:history` | Histórico de mensagens |
| `channels:write` | Enviar mensagens |
| `groups:read` | Lista de canais privados |
| `groups:history` | Histórico de canais privados |
| `groups:write` | Enviar para canais privados |
| `im:read` | Lista de DMs |
| `im:history` | Histórico de DMs |
| `im:write` | Enviar DMs |
| `users:read` | Lista de usuários (nomes de exibição) |
| `chat:write` | Enviar mensagens |
| `files:write` | Upload de arquivos |

### Configurações do Slack App

- **Socket Mode**: Habilitado
- **Event Subscriptions**: `message.channels`, `message.groups`, `message.im`
- **App-Level Token**: Com escopo `connections:write`

## Build

```bash
git clone https://github.com/gamisan9999/zlack.git
cd zlack
devenv shell
zig build
```

O binário é gerado em `zig-out/bin/zlack`.

### Configurar Git hooks (para contribuidores)

```bash
git config core.hooksPath .githooks
```

## Execução

### Primeira execução (configurar tokens)

```bash
# Opção 1: Variáveis de ambiente
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# Opção 2: Prompt interativo
./zig-out/bin/zlack
# Enter User Token (xoxp-...): <colar token>
# Enter App Token (xapp-...): <colar token>
```

Os tokens são salvos no macOS Keychain após a primeira autenticação bem-sucedida.

### Execuções seguintes

```bash
./zig-out/bin/zlack
```

### Reconfigurar tokens

```bash
./zig-out/bin/zlack --reconfigure
```

## Atalhos de teclado

### Navegação

| Tecla | Ação |
|-------|------|
| `Tab` | Alternar foco: Canais → Mensagens → Entrada |
| `Shift+Tab` | Alternar foco (reverso) |
| `j` / `↓` | Mover para baixo |
| `k` / `↑` | Mover para cima |
| `Ctrl+F` | Página para baixo (10 itens) |
| `Ctrl+B` | Página para cima (10 itens) |
| `Enter` | Selecionar canal / Abrir thread / Enviar mensagem |

### Comandos

| Tecla | Ação |
|-------|------|
| `Ctrl+K` | Busca de canais |
| `Ctrl+U` | Upload de arquivo |
| `Ctrl+T` | Alternar painel de thread |
| `Escape` | Fechar thread / Cancelar upload |
| `Ctrl+C` / `Ctrl+Q` | Sair |

### Mensagens

| Tecla | Ação |
|-------|------|
| `Enter` | Enviar mensagem (ou resposta em thread quando no modo thread) |
| `Shift+Enter` | Resposta em thread + enviar também para o canal |
| `@nome` | Resolvido automaticamente para menção Slack ao enviar |

### Mouse

| Ação | Efeito |
|------|--------|
| Clique na barra lateral | Selecionar canal + foco na entrada |
| Clique na área de mensagens | Selecionar mensagem |
| Duplo clique na mensagem | Abrir thread |
| Roda de scroll | Rolar barra lateral/mensagens |

## Testes

```bash
devenv shell
zig build test --summary all
```

64 testes cobrindo tipos, autenticação, cache, tratamento UTF-8 e formatação de timestamps.

## Licença

MIT
