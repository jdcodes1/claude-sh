#!/usr/bin/env bash
# json.sh — JSON/message construction helpers using jq

# Session state
SESSION_DIR=""
MESSAGES_FILE=""
SESSION_ID=""
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
TOTAL_CACHE_READ=0
TOTAL_CACHE_WRITE=0
TURN_COUNT=0

# Pricing (Sonnet 4)
PRICE_INPUT=3.00    # per 1M tokens
PRICE_OUTPUT=15.00  # per 1M tokens
PRICE_CACHE_READ=0.30
PRICE_CACHE_WRITE=3.75

# Sessions directory
SESSIONS_DIR="${HOME}/.claude-sh/sessions"

init_session() {
    SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-sh.XXXXXX")
    MESSAGES_FILE="$SESSION_DIR/messages.json"
    SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    echo '[]' > "$MESSAGES_FILE"
    mkdir -p "$SESSIONS_DIR"
}

cleanup_session() {
    if [[ -n "$SESSION_DIR" ]] && [[ -d "$SESSION_DIR" ]]; then
        rm -rf "$SESSION_DIR"
    fi
}

# Add a user message
add_user_message() {
    local text="$1"
    local escaped
    escaped=$(jq -Rs '.' <<< "$text")
    jq --argjson content "$escaped" \
        '. += [{"role": "user", "content": $content}]' \
        "$MESSAGES_FILE" > "$SESSION_DIR/tmp.json" && \
        mv "$SESSION_DIR/tmp.json" "$MESSAGES_FILE"
    TURN_COUNT=$((TURN_COUNT + 1))
}

# Add an assistant message (full content blocks)
add_assistant_message() {
    local content_json="$1"
    jq --argjson content "$content_json" \
        '. += [{"role": "assistant", "content": $content}]' \
        "$MESSAGES_FILE" > "$SESSION_DIR/tmp.json" && \
        mv "$SESSION_DIR/tmp.json" "$MESSAGES_FILE"
}

# Add tool results as a user message
add_tool_results() {
    local results_json="$1"
    jq --argjson content "$results_json" \
        '. += [{"role": "user", "content": $content}]' \
        "$MESSAGES_FILE" > "$SESSION_DIR/tmp.json" && \
        mv "$SESSION_DIR/tmp.json" "$MESSAGES_FILE"
}

# Build the API request body
build_request() {
    local model="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
    local max_tokens="${CLAUDE_MAX_TOKENS:-8192}"
    local messages tools system_prompt

    messages=$(cat "$MESSAGES_FILE")
    tools=$(build_tools_json)
    system_prompt=$(build_system_prompt)

    jq -n \
        --arg model "$model" \
        --argjson max_tokens "$max_tokens" \
        --argjson messages "$messages" \
        --argjson tools "$tools" \
        --arg system "$system_prompt" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: $messages,
            tools: $tools,
            system: $system,
            stream: true
        }'
}

build_system_prompt() {
    local cwd
    cwd=$(pwd)

    # Start with base prompt
    cat <<PROMPT
You are claude.sh, a lightweight AI coding assistant running as a bash script.
You have access to tools for reading, editing, and writing files, running bash commands, and searching codebases.

Environment:
- Working directory: $cwd
- Platform: $(uname -s) $(uname -m)
- Shell: ${SHELL:-bash}
- Date: $(date +%Y-%m-%d)

Guidelines:
- Be concise and direct
- Use tools to explore before making changes
- Prefer simple solutions
- When editing files, read them first
PROMPT

    # Load CLAUDE.md files (walk up from cwd to root)
    local claude_md_content=""
    claude_md_content=$(load_claude_md_files)
    if [[ -n "$claude_md_content" ]]; then
        printf '\n# Project Instructions\n\n%s' "$claude_md_content"
    fi

    # Git context
    local git_context=""
    git_context=$(get_git_context)
    if [[ -n "$git_context" ]]; then
        printf '\n# Git Context\n\n%s' "$git_context"
    fi
}

# Walk up directory tree collecting CLAUDE.md files
load_claude_md_files() {
    local dir
    dir=$(pwd)
    local files=()

    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/CLAUDE.md" ]]; then
            files+=("$dir/CLAUDE.md")
        fi
        if [[ -f "$dir/.claude/CLAUDE.md" ]]; then
            files+=("$dir/.claude/CLAUDE.md")
        fi
        dir=$(dirname "$dir")
    done

    # Also check home directory
    if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
        files+=("$HOME/.claude/CLAUDE.md")
    fi

    # Print in reverse order (root first, most specific last)
    local i
    for (( i=${#files[@]}-1; i>=0; i-- )); do
        local f="${files[$i]}"
        printf '## From %s\n\n' "$f"
        cat "$f"
        printf '\n\n'
    done
}

# Get git branch, status, recent commits
get_git_context() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return
    fi

    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "detached")

    local status
    status=$(git status --short 2>/dev/null | head -n 20)

    local log
    log=$(git log --oneline -5 2>/dev/null)

    printf 'Branch: %s\n' "$branch"
    if [[ -n "$status" ]]; then
        printf '\nUncommitted changes:\n%s\n' "$status"
    fi
    if [[ -n "$log" ]]; then
        printf '\nRecent commits:\n%s\n' "$log"
    fi
}

# ── Session persistence ──────────────────────────────────────

save_session() {
    local session_file="$SESSIONS_DIR/${SESSION_ID}.json"
    local cwd
    cwd=$(pwd)

    jq -n \
        --arg id "$SESSION_ID" \
        --arg cwd "$cwd" \
        --arg model "${CLAUDE_MODEL:-claude-sonnet-4-20250514}" \
        --argjson messages "$(cat "$MESSAGES_FILE")" \
        --argjson input_tokens "$TOTAL_INPUT_TOKENS" \
        --argjson output_tokens "$TOTAL_OUTPUT_TOKENS" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson turns "$TURN_COUNT" \
        '{
            id: $id,
            cwd: $cwd,
            model: $model,
            messages: $messages,
            input_tokens: $input_tokens,
            output_tokens: $output_tokens,
            timestamp: $timestamp,
            turns: $turns
        }' > "$session_file"
}

list_sessions() {
    if [[ ! -d "$SESSIONS_DIR" ]] || ! find "$SESSIONS_DIR" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null | grep -q .; then
        print_dim "  No saved sessions"
        return
    fi

    printf '\n%bSaved sessions:%b\n\n' "$BOLD" "$RESET"

    local i=0
    while IFS= read -r f; do
        local id cwd turns model
        id=$(jq -r '.id' "$f")
        cwd=$(jq -r '.cwd' "$f")
        turns=$(jq -r '.turns' "$f")
        model=$(jq -r '.model' "$f")
        i=$((i + 1))
        printf '  %b%d)%b %s %b(%s turns, %s)%b\n' \
            "$CYAN" "$i" "$RESET" "$id" "$DIM" "$turns" "$model" "$RESET"
        printf '     %b%s%b\n' "$DIM" "$cwd" "$RESET"
    done < <(find "$SESSIONS_DIR" -maxdepth 1 -name '*.json' -print0 | xargs -0 ls -t 2>/dev/null | head -n 10)
    printf '\n%bUsage:%b /resume <number> or /resume <id>\n\n' "$DIM" "$RESET"
}

resume_session() {
    local target="$1"
    local session_file=""

    # If it's a number, pick by index
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        session_file=$(find "$SESSIONS_DIR" -maxdepth 1 -name '*.json' -print0 | xargs -0 ls -t 2>/dev/null | sed -n "${target}p")
    else
        # Match by ID prefix
        session_file=$(find "$SESSIONS_DIR" -maxdepth 1 -name "${target}*.json" -print 2>/dev/null | head -1)
    fi

    if [[ -z "$session_file" ]] || [[ ! -f "$session_file" ]]; then
        print_error "Session not found: $target"
        return 1
    fi

    local id cwd model turns
    id=$(jq -r '.id' "$session_file")
    cwd=$(jq -r '.cwd' "$session_file")
    model=$(jq -r '.model' "$session_file")
    turns=$(jq -r '.turns' "$session_file")

    # Restore messages
    jq '.messages' "$session_file" > "$MESSAGES_FILE"
    TURN_COUNT=$turns
    TOTAL_INPUT_TOKENS=$(jq -r '.input_tokens' "$session_file")
    TOTAL_OUTPUT_TOKENS=$(jq -r '.output_tokens' "$session_file")
    SESSION_ID="$id"

    if [[ "$model" != "null" ]]; then
        CLAUDE_MODEL="$model"
    fi

    print_success "Resumed session: $id ($turns turns)"
    print_dim "  from: $cwd"
}

# Track token usage
update_usage() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local cache_read="${3:-0}"
    local cache_write="${4:-0}"

    TOTAL_INPUT_TOKENS=$((TOTAL_INPUT_TOKENS + input_tokens))
    TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + output_tokens))
    TOTAL_CACHE_READ=$((TOTAL_CACHE_READ + cache_read))
    TOTAL_CACHE_WRITE=$((TOTAL_CACHE_WRITE + cache_write))
}

# Calculate session cost
get_session_cost() {
    awk "BEGIN {
        cost = ($TOTAL_INPUT_TOKENS * $PRICE_INPUT / 1000000) + \
               ($TOTAL_OUTPUT_TOKENS * $PRICE_OUTPUT / 1000000) + \
               ($TOTAL_CACHE_READ * $PRICE_CACHE_READ / 1000000) + \
               ($TOTAL_CACHE_WRITE * $PRICE_CACHE_WRITE / 1000000)
        printf \"%.4f\", cost
    }"
}

# Truncate old messages if context gets too large
# Simple strategy: keep system + last N turns
maybe_compact_messages() {
    local msg_count
    msg_count=$(jq 'length' "$MESSAGES_FILE")

    # Keep last 40 messages (20 turns) max
    if (( msg_count > 40 )); then
        local keep=40
        jq --argjson keep "$keep" '.[-$keep:]' \
            "$MESSAGES_FILE" > "$SESSION_DIR/tmp.json" && \
            mv "$SESSION_DIR/tmp.json" "$MESSAGES_FILE"
        print_dim "  (compacted: kept last $keep messages)"
    fi
}
