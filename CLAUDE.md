# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

claude.sh is a bash reimplementation of Claude Code in ~1,500 lines of bash with zero npm dependencies. It uses only `curl` and `jq` for API communication and JSON handling, with optional `ripgrep` and `python3`.

## Commands

```bash
# Lint shell scripts
shellcheck claude.sh lib/*.sh

# Lint markdown
markdownlint -f -c .markdownlint.jsonc .

# Run tests (bats)
bats test/

# Check formatting against editorconfig
# Tabs for shell files, spaces for everything else (see .editorconfig)
```

Runtime versions are pinned in `.tool-versions`. Use `mise` to install them.

```bash
# Run tests with coverage via kcov in Ubuntu container (kcov needs Linux ptrace)
docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work ubuntu:24.04 bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq bats jq binutils cmake g++ pkg-config zlib1g-dev \
    libcurl4-openssl-dev libdw-dev libiberty-dev libssl-dev git >/dev/null 2>&1
  cd /tmp && git clone --depth 1 https://github.com/SimonKagstrom/kcov.git >/dev/null 2>&1
  cd kcov && mkdir build && cd build && cmake .. >/dev/null 2>&1
  make -j\$(nproc) >/dev/null 2>&1 && make install >/dev/null 2>&1
  kcov --bash-dont-parse-binary-dir /work/coverage bats /work/test/
"
```

## Architecture

```txt
claude.sh          # Entry point: preflight checks, REPL loop, slash commands, turn orchestration
lib/
  api.sh           # Anthropic API client with SSE streaming via FIFO named pipes
  json.sh          # Session/message state, request building, system prompt assembly, cost tracking
  tools.sh         # Tool implementations: Bash, Read, Edit, Write, Glob, Grep
  tui.sh           # Terminal UI: colors, spinner, display helpers, cleanup
```

### Turn Loop (`process_turn` in claude.sh)

1. Add user message to session
2. Loop up to 25 tool turns:
   - Build JSON request via `build_request()` (json.sh)
   - Stream response via FIFO pipe (api.sh)
   - If `stop_reason=tool_use`, execute tools and continue loop
   - If `stop_reason=end_turn`, break
3. Show per-turn cost

### Adding a New Tool

1. Add tool schema to `build_tools_json()` in tools.sh
2. Create `tool_<name>()` function in tools.sh
3. Add dispatch case in `execute_tool()` in tools.sh

### System Prompt Assembly (`build_system_prompt` in json.sh)

Composed from: base instructions + environment info + guidelines + discovered CLAUDE.md files (walked from cwd to root) + git context (branch, uncommitted changes, recent commits).

### Permission System (tools.sh)

Three modes via `CLAUDE_SH_PERMISSIONS`: `ask` (default), `allow`, `deny`. Read-only commands (ls, cat, git log, etc.) are in a safe allowlist and never prompt.

## Key Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | (required) | API authentication |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Model selection |
| `CLAUDE_MAX_TOKENS` | `8192` | Output token limit |
| `CLAUDE_SH_PERMISSIONS` | `ask` | Permission mode |

## ShellCheck

Five warnings are globally disabled in `.shellcheckrc`:

- SC1091: sourced files (libs loaded at runtime)
- SC2034: unused variables (color/state vars used by callers)
- SC2329: "function never invoked" (bats tests call functions indirectly)
- SC2030: "modification is local to subshell" (expected in bats `@test` blocks)
- SC2031: "variable was modified in subshell" (expected in bats `@test` blocks)

## Context7 libraries

Always use Context7 MCP when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.

- bats-core/bats-core
- j178/prek
- jdx/mise
- simonkagstrom/kcov
