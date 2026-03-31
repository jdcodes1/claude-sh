#!/usr/bin/env bash
# tui.sh — ANSI colors, spinner, display helpers

# Colors
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'
UNDERLINE='\033[4m'

# Claude orange
CLAUDE='\033[38;2;204;136;68m'
CLAUDE_BG='\033[48;2;204;136;68m'

# Semantic colors
RED='\033[38;2;255;85;85m'
GREEN='\033[38;2;85;255;85m'
YELLOW='\033[38;2;255;255;85m'
BLUE='\033[38;2;85;85;255m'
CYAN='\033[38;2;85;255;255m'
MAGENTA='\033[38;2;255;85;255m'
GRAY='\033[38;2;128;128;128m'
WHITE='\033[38;2;220;220;220m'

# Spinner verbs (from the original source)
SPINNER_VERBS=(
    "Accomplishing" "Architecting" "Baking" "Beboppin'" "Bloviating"
    "Boondoggling" "Bootstrapping" "Brewing" "Canoodling" "Caramelizing"
    "Cerebrating" "Clauding" "Cogitating" "Combobulating" "Computing"
    "Contemplating" "Cooking" "Crafting" "Crystallizing" "Deliberating"
    "Discombobulating" "Fermenting" "Finagling" "Flibbertigibbeting"
    "Gallivanting" "Generating" "Harmonizing" "Hatching" "Hullaballooing"
    "Ideating" "Imagining" "Inferring" "Lollygagging" "Manifesting"
    "Meandering" "Moonwalking" "Mulling" "Noodling" "Orchestrating"
    "Percolating" "Pondering" "Processing" "Quantumizing" "Razzmatazzing"
    "Recombobulating" "Ruminating" "Simmering" "Synthesizing" "Thinking"
    "Tinkering" "Tomfoolering" "Vibing" "Whatchamacalliting" "Working"
    "Zigzagging"
)

random_verb() {
    echo "${SPINNER_VERBS[$((RANDOM % ${#SPINNER_VERBS[@]}))]}"
}

# Spinner management
SPINNER_PID=""
SPINNER_ACTIVE=false

start_spinner() {
    local verb
    verb=$(random_verb)
    SPINNER_ACTIVE=true

    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        local elapsed=0
        local start_time=$SECONDS
        while true; do
            elapsed=$(( SECONDS - start_time ))
            printf '\r\033[K%b%s %s... %b(%ds)%b' \
                "$CLAUDE" "${frames[$i]}" "$verb" "$DIM" "$elapsed" "$RESET"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        SPINNER_ACTIVE=false
        printf '\r\033[K'
    fi
}

# Display helpers
print_claude() {
    printf '%b%s%b\n' "$CLAUDE" "$1" "$RESET"
}

print_error() {
    printf '%b%s error:%b %s\n' "$RED$BOLD" "claude.sh" "$RESET" "$1" >&2
}

print_warning() {
    printf '%b%s warning:%b %s\n' "$YELLOW" "claude.sh" "$RESET" "$1" >&2
}

print_success() {
    printf '%b%s%b\n' "$GREEN" "$1" "$RESET"
}

print_dim() {
    printf '%b%s%b\n' "$DIM" "$1" "$RESET"
}

print_tool_header() {
    local tool_name="$1"
    local detail="$2"
    printf '%b %b%s%b' "$DIM" "$CYAN$BOLD" "$tool_name" "$RESET"
    if [[ -n "$detail" ]]; then
        printf ' %b%s%b' "$DIM" "$detail" "$RESET"
    fi
    printf '\n'
}

print_tool_output() {
    local output="$1"
    local max_lines="${2:-50}"
    local line_count
    line_count=$(echo "$output" | wc -l)

    if (( line_count > max_lines )); then
        echo "$output" | head -n "$max_lines"
        printf '%b... (%d more lines)%b\n' "$DIM" "$(( line_count - max_lines ))" "$RESET"
    else
        echo "$output"
    fi
}

print_cost() {
    local cost="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    printf '\n%b  Session cost: $%s | %s input tokens | %s output tokens%b\n' \
        "$DIM" "$cost" "$input_tokens" "$output_tokens" "$RESET"
}

print_separator() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    printf '%b%*s%b\n' "$DIM" "$cols" '' "$RESET" | tr ' ' '─'
}

# Banner
print_banner() {
    printf '\n'
    printf '%b╭─────────────────────────────╮%b\n' "$CLAUDE" "$RESET"
    printf '%b│%b  claude.sh %b— bash edition  %b│%b\n' "$CLAUDE" "$BOLD$WHITE" "$DIM" "$CLAUDE" "$RESET"
    printf '%b╰─────────────────────────────╯%b\n' "$CLAUDE" "$RESET"
    printf '%b  model: %s%b\n' "$DIM" "${CLAUDE_MODEL:-claude-sonnet-4-20250514}" "$RESET"
    printf '%b  type /help for commands, ctrl-c to cancel%b\n\n' "$DIM" "$RESET"
}

# Prompt
print_prompt() {
    printf '%b❯%b ' "$CLAUDE" "$RESET"
}

# Cleanup handler
cleanup_tui() {
    stop_spinner
    printf '%b' "$RESET"
    tput cnorm 2>/dev/null  # Show cursor
}
