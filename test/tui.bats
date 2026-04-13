#!/usr/bin/env bats
# tui.bats — tests for lib/tui.sh

bats_require_minimum_version 1.5.0

load test_helper

setup() {
	source "$PROJECT_ROOT/lib/tui.sh"
}

# ── Color variables ──────────────────────────────────────────

@test "color variables are defined" {
	[ -n "$RESET" ]
	[ -n "$BOLD" ]
	[ -n "$DIM" ]
	[ -n "$RED" ]
	[ -n "$GREEN" ]
	[ -n "$YELLOW" ]
	[ -n "$CYAN" ]
	[ -n "$CLAUDE" ]
}

# ── print_banner ─────────────────────────────────────────────

@test "print_banner: box lines are equal display width" {
	local output
	output=$(print_banner)

	# Strip ANSI escape sequences to get display characters
	local strip_ansi
	strip_ansi=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')

	# Extract the three box lines
	local top mid bot
	top=$(echo "$strip_ansi" | grep '╭.*╮')
	mid=$(echo "$strip_ansi" | grep '│.*│')
	bot=$(echo "$strip_ansi" | grep '╰.*╯')

	# All three lines must have the same display width
	local top_len mid_len bot_len
	top_len=$(printf '%s' "$top" | wc -m)
	mid_len=$(printf '%s' "$mid" | wc -m)
	bot_len=$(printf '%s' "$bot" | wc -m)

	[ "$top_len" -eq "$bot_len" ]
	[ "$top_len" -eq "$mid_len" ]
}

# ── random_verb ──────────────────────────────────────────────

@test "random_verb: returns a non-empty string" {
	local verb
	verb=$(random_verb)
	[ -n "$verb" ]
}

@test "random_verb: returns value from SPINNER_VERBS array" {
	local verb
	verb=$(random_verb)
	local found=false
	for v in "${SPINNER_VERBS[@]}"; do
		if [ "$v" = "$verb" ]; then
			found=true
			break
		fi
	done
	[ "$found" = true ]
}

# ── print_error ──────────────────────────────────────────────

@test "print_error: outputs to stderr" {
	local output
	output=$(print_error "test error" 2>&1 1>/dev/null)
	[[ "$output" == *"test error"* ]]
}

@test "print_error: includes claude.sh prefix" {
	local output
	output=$(print_error "oops" 2>&1)
	[[ "$output" == *"claude.sh"* ]]
}

# ── print_warning ────────────────────────────────────────────

@test "print_warning: outputs to stderr" {
	local output
	output=$(print_warning "test warning" 2>&1 1>/dev/null)
	[[ "$output" == *"test warning"* ]]
}

# ── print_success ────────────────────────────────────────────

@test "print_success: outputs the message" {
	run print_success "all good"
	[ "$status" -eq 0 ]
	[[ "$output" == *"all good"* ]]
}

# ── print_dim ────────────────────────────────────────────────

@test "print_dim: outputs the message" {
	run print_dim "faded text"
	[ "$status" -eq 0 ]
	[[ "$output" == *"faded text"* ]]
}

# ── print_tool_header ────────────────────────────────────────

@test "print_tool_header: shows tool name" {
	run print_tool_header "Read" "/path/to/file"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Read"* ]]
	[[ "$output" == *"/path/to/file"* ]]
}

@test "print_tool_header: works without detail" {
	run print_tool_header "Bash" ""
	[ "$status" -eq 0 ]
	[[ "$output" == *"Bash"* ]]
}

# ── print_tool_output ────────────────────────────────────────

@test "print_tool_output: shows full output under limit" {
	run print_tool_output "short output" 50
	[ "$status" -eq 0 ]
	[[ "$output" == *"short output"* ]]
}

@test "print_tool_output: truncates output over limit" {
	local long_output
	long_output=$(printf '%s\n' $(seq 1 100))
	run print_tool_output "$long_output" 5
	[ "$status" -eq 0 ]
	[[ "$output" == *"more lines"* ]]
}

# ── print_separator ──────────────────────────────────────────

@test "print_separator: produces output" {
	run print_separator
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

# ── SPINNER_VERBS ────────────────────────────────────────────

@test "SPINNER_VERBS: array is non-empty" {
	[ "${#SPINNER_VERBS[@]}" -gt 0 ]
}

@test "SPINNER_VERBS: contains Thinking" {
	local found=false
	for v in "${SPINNER_VERBS[@]}"; do
		if [ "$v" = "Thinking" ]; then
			found=true
			break
		fi
	done
	[ "$found" = true ]
}

# ── print_claude ────────────────────────────────────────────

@test "print_claude: outputs the message" {
	run print_claude "hello from claude"
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello from claude"* ]]
}

# ── print_cost ──────────────────────────────────────────────

@test "print_cost: shows cost and token counts" {
	run print_cost "1.2345" "1000" "500"
	[ "$status" -eq 0 ]
	[[ "$output" == *"1.2345"* ]]
	[[ "$output" == *"1000"* ]]
	[[ "$output" == *"500"* ]]
}

# ── print_prompt ────────────────────────────────────────────

@test "print_prompt: outputs the prompt character" {
	run print_prompt
	[ "$status" -eq 0 ]
	# Should contain the arrow character
	[[ "$output" == *"❯"* ]]
}

# ── start_spinner / stop_spinner ────────────────────────────

@test "start_spinner: launches a background process" {
	start_spinner
	[ -n "$SPINNER_PID" ]
	# Verify the process is running
	kill -0 "$SPINNER_PID" 2>/dev/null
	local running=$?
	[ "$running" -eq 0 ]
	# Clean up
	stop_spinner
}

@test "stop_spinner: kills the spinner process" {
	start_spinner
	local pid="$SPINNER_PID"
	[ -n "$pid" ]
	stop_spinner
	[ -z "$SPINNER_PID" ]
	# Process should no longer be running (give it a moment)
	sleep 0.1
	run ! kill -0 "$pid" 2>/dev/null
}

@test "stop_spinner: no-op when no spinner is running" {
	SPINNER_PID=""
	run stop_spinner
	[ "$status" -eq 0 ]
}

# ── cleanup_tui ─────────────────────────────────────────────

@test "cleanup_tui: stops spinner and resets terminal" {
	start_spinner
	[ -n "$SPINNER_PID" ]
	# Call directly (not via run) so SPINNER_PID is accessible
	cleanup_tui
	[ -z "$SPINNER_PID" ]
}
