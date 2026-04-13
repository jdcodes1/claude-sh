#!/usr/bin/env bash

: <<'HELP'
claude.sh — Claude Code, rewritten as a bash script

Dependencies: curl, jq
Optional: rg (ripgrep) for better grep

Usage:
	export ANTHROPIC_API_KEY="sk-ant-..."
	./claude.sh

Environment:
	ANTHROPIC_API_KEY   — Required. Your Anthropic API key.
	CLAUDE_MODEL        — Model to use (default: claude-sonnet-4-6)
	CLAUDE_MAX_TOKENS   — Max output tokens (default: 8192)
	ANTHROPIC_API_URL   — API base URL (default: https://api.anthropic.com)
HELP

# ── Resolve script directory and source libs ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/tui.sh"
source "$SCRIPT_DIR/lib/json.sh"
source "$SCRIPT_DIR/lib/tools.sh"
source "$SCRIPT_DIR/lib/api.sh"

# ── Preflight checks ─────────────────────────────────────────
preflight() {
    local missing=()
    command -v curl &>/dev/null || missing+=("curl")
    command -v jq &>/dev/null   || missing+=("jq")

    if (( ${#missing[@]} > 0 )); then
        print_error "Missing required dependencies: ${missing[*]}"
        echo "  Install with: brew install ${missing[*]}"
        exit 1
    fi

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        print_error "ANTHROPIC_API_KEY environment variable not set"
        echo "  export ANTHROPIC_API_KEY=\"sk-ant-...\""
        exit 1
    fi

    if ! command -v rg &>/dev/null; then
        print_warning "ripgrep (rg) not found, falling back to grep for search"
    fi
}

# ── Slash commands ────────────────────────────────────────────
handle_command() {
    local input="$1"

    case "$input" in
        /help)
            printf '\n%bCommands:%b\n' "$BOLD" "$RESET"
            printf '  %b/help%b      — Show this help\n' "$CYAN" "$RESET"
            printf '  %b/cost%b      — Show session cost\n' "$CYAN" "$RESET"
            printf '  %b/model%b     — Show/change model\n' "$CYAN" "$RESET"
            printf '  %b/clear%b     — Clear conversation\n' "$CYAN" "$RESET"
            printf '  %b/compact%b   — Compact message history\n' "$CYAN" "$RESET"
            printf '  %b/save%b      — Save current session\n' "$CYAN" "$RESET"
            printf '  %b/resume%b    — Resume a saved session\n' "$CYAN" "$RESET"
            printf '  %b/commit%b    — Auto-generate a commit\n' "$CYAN" "$RESET"
            printf '  %b/diff%b      — Show git diff\n' "$CYAN" "$RESET"
            printf '  %b/quit%b      — Exit\n' "$CYAN" "$RESET"
            printf '\n'
            return 0
            ;;
        /cost)
            local cost
            cost=$(get_session_cost)
            print_cost "$cost" "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS"
            return 0
            ;;
        /model)
            printf '%bCurrent model:%b %s\n' "$DIM" "$RESET" "${CLAUDE_MODEL:-claude-sonnet-4-6}"
            printf '%bChange with:%b export CLAUDE_MODEL=<model>\n' "$DIM" "$RESET"
            return 0
            ;;
        /model\ *)
            CLAUDE_MODEL="${input#/model }"
            print_success "Model set to: $CLAUDE_MODEL"
            return 0
            ;;
        /clear)
            echo '[]' > "$MESSAGES_FILE"
            TURN_COUNT=0
            print_success "Conversation cleared"
            return 0
            ;;
        /compact)
            maybe_compact_messages
            return 0
            ;;
        /save)
            save_session
            print_success "Session saved: $SESSION_ID"
            return 0
            ;;
        /resume)
            list_sessions
            return 0
            ;;
        /resume\ *)
            resume_session "${input#/resume }"
            return 0
            ;;
        /diff)
            if git rev-parse --is-inside-work-tree &>/dev/null; then
                git diff --stat
                printf '\n'
                git diff
            else
                print_warning "Not in a git repository"
            fi
            return 0
            ;;
        /commit)
            if ! git rev-parse --is-inside-work-tree &>/dev/null; then
                print_warning "Not in a git repository"
                return 0
            fi
            local diff_summary
            diff_summary=$(git diff --cached --stat 2>/dev/null)
            if [[ -z "$diff_summary" ]]; then
                diff_summary=$(git diff --stat 2>/dev/null)
                if [[ -z "$diff_summary" ]]; then
                    print_warning "No changes to commit"
                    return 0
                fi
                print_dim "  No staged changes. Staging all changes first..."
                git add -A
            fi
            # Ask Claude to generate a commit message
            process_turn "Look at the current git diff (use \`git diff --cached\`) and recent git log. Generate a concise commit message and run \`git commit -m '<message>'\`. Do NOT amend."
            return 0
            ;;
        /quit|/exit|/q)
            exit 0
            ;;
        /*)
            print_warning "Unknown command: $input (try /help)"
            return 0
            ;;
    esac

    return 1  # Not a command
}

# ── Process one turn (may loop for tool_use) ──────────────────
process_turn() {
    local user_input="$1"

    # Add user message
    add_user_message "$user_input"

    # Tool use loop
    local max_tool_turns=25
    local tool_turn=0

    while true; do
        # Maybe compact if history is getting long
        maybe_compact_messages

        # Build and send request
        start_spinner
        local request
        request=$(build_request)
        stream_request_with_retry "$request"
        local stream_status=$?

        if (( stream_status != 0 )); then
            return 1
        fi

        # Track usage
        update_usage "$RESPONSE_INPUT_TOKENS" "$RESPONSE_OUTPUT_TOKENS" \
            "$RESPONSE_CACHE_READ" "$RESPONSE_CACHE_WRITE"

        # Add assistant message to history
        add_assistant_message "$RESPONSE_CONTENT_BLOCKS"

        # Check if we need to execute tools
        if [[ "$RESPONSE_STOP_REASON" != "tool_use" ]]; then
            break
        fi

        tool_turn=$((tool_turn + 1))
        if (( tool_turn >= max_tool_turns )); then
            print_warning "Max tool turns ($max_tool_turns) reached"
            break
        fi

        # Extract and execute tool_use blocks
        local tool_count
        tool_count=$(echo "$RESPONSE_CONTENT_BLOCKS" | jq '[.[] | select(.type == "tool_use")] | length')

        if (( tool_count == 0 )); then
            break
        fi

        printf '\n'

        # Build tool results array
        local tool_results="[]"
        local i

        for (( i = 0; i < tool_count; i++ )); do
            local tool_block
            tool_block=$(echo "$RESPONSE_CONTENT_BLOCKS" | jq -c "[.[] | select(.type == \"tool_use\")][$i]")

            local tool_name tool_id tool_input
            tool_name=$(echo "$tool_block" | jq -r '.name')
            tool_id=$(echo "$tool_block" | jq -r '.id')
            tool_input=$(echo "$tool_block" | jq -c '.input')

            # Execute the tool
            local result
            result=$(execute_tool "$tool_name" "$tool_id" "$tool_input")

            # Append to results array
            tool_results=$(echo "$tool_results" | jq --argjson result "$result" '. += [$result]')
        done

        # Add tool results to conversation
        add_tool_results "$tool_results"

        printf '\n'
    done

    # Show per-turn cost
    local turn_cost
    turn_cost=$(awk "BEGIN { printf \"%.4f\", ($RESPONSE_INPUT_TOKENS * $PRICE_INPUT + $RESPONSE_OUTPUT_TOKENS * $PRICE_OUTPUT) / 1000000 }")
    printf '%b  $%s · %s in / %s out%b\n' \
        "$DIM" "$turn_cost" "$RESPONSE_INPUT_TOKENS" "$RESPONSE_OUTPUT_TOKENS" "$RESET"
}

# ── Main REPL ─────────────────────────────────────────────────
main() {
    preflight
    init_session

    # Handle --resume flag
    if [[ "${1:-}" == "--resume" ]] && [[ -n "${2:-}" ]]; then
        resume_session "$2"
    fi

    # Cleanup on exit
    trap 'cleanup_tui; show_exit_summary; cleanup_session' EXIT
    trap 'stop_spinner; printf "\n"' INT

    print_banner

    # Check for piped input (non-interactive mode)
    if [[ ! -t 0 ]]; then
        local piped_input
        piped_input=$(cat)
        if [[ -n "$piped_input" ]]; then
            process_turn "$piped_input"
        fi
        return
    fi

    # Interactive REPL
    while true; do
        local user_input=""

        # Read input (supports multiline with \)
        print_prompt
        if ! IFS= read -re user_input; then
            # EOF (ctrl-d)
            printf '\n'
            break
        fi

        # Skip empty input
        [[ -z "${user_input// /}" ]] && continue

        # Add to readline history
        history -s "$user_input"

        # Handle slash commands
        if [[ "$user_input" == /* ]]; then
            if handle_command "$user_input"; then
                continue
            fi
        fi

        # Process the turn
        process_turn "$user_input"
        printf '\n'
    done
}

show_exit_summary() {
    if (( TURN_COUNT > 0 )); then
        # Auto-save session
        save_session 2>/dev/null
        local cost
        cost=$(get_session_cost)
        printf '\n'
        print_separator
        print_cost "$cost" "$TOTAL_INPUT_TOKENS" "$TOTAL_OUTPUT_TOKENS"
        printf '%b  %d turns | model: %s | session: %s%b\n' \
            "$DIM" "$TURN_COUNT" "${CLAUDE_MODEL:-claude-sonnet-4-6}" "$SESSION_ID" "$RESET"
        printf '%b  resume with: ./claude.sh --resume %s%b\n' "$DIM" "$SESSION_ID" "$RESET"
    fi
    printf '\n%bbye!%b\n' "$DIM" "$RESET"
}

# ── Entry point ───────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main "$@"
fi
