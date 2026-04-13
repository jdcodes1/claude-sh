#!/usr/bin/env bash
# test_helper.bash — shared setup for all bats tests

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Stub out tui.sh color variables and display functions to avoid terminal deps
setup_stubs() {
	# Color stubs
	RESET='' BOLD='' DIM='' ITALIC='' UNDERLINE=''
	CLAUDE='' CLAUDE_BG=''
	RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' GRAY='' WHITE=''

	# Display stubs (no-ops)
	print_claude()      { :; }
	print_error()       { echo "ERROR: $1" >&2; }
	print_warning()     { echo "WARNING: $1" >&2; }
	print_success()     { :; }
	print_dim()         { :; }
	print_tool_header() { :; }
	print_tool_output() { :; }
	print_cost()        { :; }
	print_separator()   { :; }
	print_banner()      { :; }
	print_prompt()      { :; }
	start_spinner()     { :; }
	stop_spinner()      { :; }
	cleanup_tui()       { :; }

	export RESET BOLD DIM ITALIC UNDERLINE
	export CLAUDE CLAUDE_BG
	export RED GREEN YELLOW BLUE CYAN MAGENTA GRAY WHITE
	export -f print_claude print_error print_warning print_success print_dim
	export -f print_tool_header print_tool_output print_cost print_separator
	export -f print_banner print_prompt start_spinner stop_spinner cleanup_tui
}

# Create a temporary working directory for test isolation
setup_tempdir() {
	BATS_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bats-claude-sh.XXXXXX")"
}

teardown_tempdir() {
	[[ -d "${BATS_TEST_TMPDIR:-}" ]] && rm -rf "$BATS_TEST_TMPDIR"
}
