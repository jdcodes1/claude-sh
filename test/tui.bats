#!/usr/bin/env bats
# tui.bats — tests for lib/tui.sh

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
