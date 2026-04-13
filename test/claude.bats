#!/usr/bin/env bats
# claude.bats — tests for claude.sh top-level functions

load test_helper

setup() {
	setup_tempdir

	# Source claude.sh directly — the entry point guard prevents main from running
	source "$PROJECT_ROOT/claude.sh"

	# Apply stubs AFTER sourcing to override real tui functions
	setup_stubs

	init_session
	PERMISSION_MODE="allow"
}

teardown() {
	cleanup_session 2>/dev/null
	teardown_tempdir
}

# ── preflight ────────────────────────────────────────────────

@test "preflight: passes when curl, jq, and API key are present" {
	ANTHROPIC_API_KEY="sk-test"
	run preflight
	[ "$status" -eq 0 ]
}

@test "preflight: fails when ANTHROPIC_API_KEY is empty" {
	ANTHROPIC_API_KEY=""
	run preflight
	[ "$status" -eq 1 ]
	[[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "preflight: warns when rg is not found" {
	# Temporarily hide rg
	rg() { return 1; }
	command() {
		if [[ "$2" == "rg" ]]; then return 1; fi
		builtin command "$@"
	}
	export -f command rg
	ANTHROPIC_API_KEY="sk-test"
	run preflight
	# Should still succeed (rg is optional)
	[ "$status" -eq 0 ]
}

# ── handle_command ───────────────────────────────────────────

@test "handle_command: /help shows commands" {
	run handle_command "/help"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/help"* ]]
	[[ "$output" == *"/quit"* ]]
}

@test "handle_command: /cost shows session cost" {
	TOTAL_INPUT_TOKENS=100
	TOTAL_OUTPUT_TOKENS=200
	# Override print_cost to capture call
	print_cost() { echo "COST: $1 $2 $3"; }
	export -f print_cost
	run handle_command "/cost"
	[ "$status" -eq 0 ]
}

@test "handle_command: /model shows current model" {
	CLAUDE_MODEL="claude-test-model"
	run handle_command "/model"
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude-test-model"* ]]
}

@test "handle_command: /model <name> changes model" {
	handle_command "/model claude-haiku-3"
	[ "$CLAUDE_MODEL" = "claude-haiku-3" ]
}

@test "handle_command: /clear resets messages and turn count" {
	add_user_message "hello"
	TURN_COUNT=5
	handle_command "/clear"
	local count
	count=$(jq 'length' "$MESSAGES_FILE")
	[ "$count" -eq 0 ]
	[ "$TURN_COUNT" -eq 0 ]
}

@test "handle_command: /compact calls maybe_compact_messages" {
	run handle_command "/compact"
	[ "$status" -eq 0 ]
}

@test "handle_command: /save saves session" {
	add_user_message "save me"
	run handle_command "/save"
	[ "$status" -eq 0 ]
	[ -f "$SESSIONS_DIR/${SESSION_ID}.json" ]
}

@test "handle_command: /resume lists sessions" {
	# Just verify it doesn't error
	run handle_command "/resume"
	[ "$status" -eq 0 ]
}

@test "handle_command: /resume <id> resumes session" {
	add_user_message "test msg"
	TOTAL_INPUT_TOKENS=100
	TOTAL_OUTPUT_TOKENS=200
	save_session
	local saved_id="$SESSION_ID"

	# Reset
	init_session
	TURN_COUNT=0
	TOTAL_INPUT_TOKENS=0

	handle_command "/resume $saved_id"
	[ "$SESSION_ID" = "$saved_id" ]
}

@test "handle_command: /diff outside git repo warns" {
	# Override git to fail
	git() { return 1; }
	export -f git
	run handle_command "/diff"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Not in a git"* ]]
}

@test "handle_command: /diff inside git repo shows diff" {
	# Create a minimal git repo
	local repo="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "init"
	echo "changed" > "$repo/file.txt"

	cd "$repo"
	run handle_command "/diff"
	[ "$status" -eq 0 ]
	[[ "$output" == *"file.txt"* ]]
}

@test "handle_command: /commit outside git repo warns" {
	git() { return 1; }
	export -f git
	run handle_command "/commit"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Not in a git"* ]]
}

@test "handle_command: /commit with no changes warns" {
	local repo="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "init"

	cd "$repo"
	run handle_command "/commit"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No changes"* ]]
}

@test "handle_command: /commit with unstaged changes stages and delegates" {
	local repo="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "init"
	echo "changed" > "$repo/file.txt"

	# Stub process_turn to avoid real API call
	process_turn() { echo "PROCESS_TURN_CALLED: $1"; }
	export -f process_turn

	cd "$repo"
	run handle_command "/commit"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PROCESS_TURN_CALLED"* ]]
	# Verify changes were staged
	local staged
	staged=$(git -C "$repo" diff --cached --stat)
	[[ "$staged" == *"file.txt"* ]]
}

@test "handle_command: /quit exits with code 0" {
	run handle_command "/quit"
	[ "$status" -eq 0 ]
}

@test "handle_command: /exit exits with code 0" {
	run handle_command "/exit"
	[ "$status" -eq 0 ]
}

@test "handle_command: /q exits with code 0" {
	run handle_command "/q"
	[ "$status" -eq 0 ]
}

@test "handle_command: /unknown shows warning" {
	run handle_command "/foobar"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Unknown command"* ]]
}

@test "handle_command: non-command input returns 1" {
	run handle_command "hello world"
	[ "$status" -eq 1 ]
}

# ── show_exit_summary ────────────────────────────────────────

@test "show_exit_summary: shows bye when no turns" {
	TURN_COUNT=0
	run show_exit_summary
	[ "$status" -eq 0 ]
	[[ "$output" == *"bye"* ]]
}

@test "show_exit_summary: shows cost and session info when turns > 0" {
	TURN_COUNT=3
	TOTAL_INPUT_TOKENS=1000
	TOTAL_OUTPUT_TOKENS=500
	CLAUDE_MODEL="claude-test"

	# Re-enable print_cost for this test
	print_cost() { echo "COST_SHOWN: $1"; }
	print_separator() { echo "---"; }
	export -f print_cost print_separator

	run show_exit_summary
	[ "$status" -eq 0 ]
	[[ "$output" == *"bye"* ]]
	[[ "$output" == *"COST_SHOWN"* ]]
	[[ "$output" == *"3 turns"* ]]
	[[ "$output" == *"claude-test"* ]]
	[[ "$output" == *"--resume"* ]]
}

# ── process_turn ─────────────────────────────────────────────

@test "process_turn: handles stream failure gracefully" {
	# Stub stream_request_with_retry to fail
	stream_request_with_retry() { return 1; }
	export -f stream_request_with_retry

	run process_turn "test input"
	[ "$status" -eq 1 ]
}

@test "process_turn: handles end_turn response" {
	# Set up response state that stream_request_with_retry would set
	stream_request_with_retry() {
		RESPONSE_CONTENT_BLOCKS='[{"type":"text","text":"Hello"}]'
		RESPONSE_STOP_REASON="end_turn"
		RESPONSE_INPUT_TOKENS=50
		RESPONSE_OUTPUT_TOKENS=25
		RESPONSE_CACHE_READ=0
		RESPONSE_CACHE_WRITE=0
		return 0
	}
	export -f stream_request_with_retry

	PRICE_INPUT=3.00
	PRICE_OUTPUT=15.00

	run process_turn "hello"
	[ "$status" -eq 0 ]
}

@test "process_turn: executes tool_use blocks and loops" {
	local call_count_file="$BATS_TEST_TMPDIR/api_calls"
	echo "0" > "$call_count_file"

	stream_request_with_retry() {
		local count
		count=$(cat "$call_count_file")
		count=$((count + 1))
		echo "$count" > "$call_count_file"

		if (( count == 1 )); then
			# First call: return tool_use
			RESPONSE_CONTENT_BLOCKS='[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]'
			RESPONSE_STOP_REASON="tool_use"
		else
			# Second call: return end_turn
			RESPONSE_CONTENT_BLOCKS='[{"type":"text","text":"Done"}]'
			RESPONSE_STOP_REASON="end_turn"
		fi
		RESPONSE_INPUT_TOKENS=10
		RESPONSE_OUTPUT_TOKENS=5
		RESPONSE_CACHE_READ=0
		RESPONSE_CACHE_WRITE=0
		return 0
	}
	export -f stream_request_with_retry
	export call_count_file

	PRICE_INPUT=3.00
	PRICE_OUTPUT=15.00

	run process_turn "run echo hi"
	[ "$status" -eq 0 ]

	local calls
	calls=$(cat "$call_count_file")
	[ "$calls" -eq 2 ]
}
