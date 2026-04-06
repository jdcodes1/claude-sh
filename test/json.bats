#!/usr/bin/env bats
# json.bats — tests for lib/json.sh

load test_helper

setup() {
	setup_stubs
	setup_tempdir
	source "$PROJECT_ROOT/lib/json.sh"
}

teardown() {
	teardown_tempdir
}

# ── init_session ─────────────────────────────────────────────

@test "init_session: creates session directory and messages file" {
	init_session
	[ -d "$SESSION_DIR" ]
	[ -f "$MESSAGES_FILE" ]
	local content
	content=$(cat "$MESSAGES_FILE")
	[ "$content" = "[]" ]
}

@test "init_session: sets SESSION_ID with expected format" {
	init_session
	# Format: YYYYMMDD-HHMMSS-PID
	[[ "$SESSION_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]
}

@test "init_session: token counters start at zero from source" {
	# Counters are initialized when json.sh is sourced, not by init_session
	[ "$TOTAL_INPUT_TOKENS" -eq 0 ]
	[ "$TOTAL_OUTPUT_TOKENS" -eq 0 ]
	[ "$TURN_COUNT" -eq 0 ]
}

# ── cleanup_session ──────────────────────────────────────────

@test "cleanup_session: removes session directory" {
	init_session
	local dir="$SESSION_DIR"
	[ -d "$dir" ]
	cleanup_session
	[ ! -d "$dir" ]
}

@test "cleanup_session: succeeds when SESSION_DIR does not exist" {
	SESSION_DIR="/nonexistent/path/$$"
	run cleanup_session
	[ "$status" -eq 0 ]
}

@test "cleanup_session: succeeds when SESSION_DIR is empty string" {
	SESSION_DIR=""
	run cleanup_session
	[ "$status" -eq 0 ]
}

# ── add_user_message ─────────────────────────────────────────

@test "add_user_message: appends user message to history" {
	init_session
	add_user_message "hello world"
	local role
	role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
	[ "$role" = "user" ]
	local content
	content=$(jq -r '.[-1].content' "$MESSAGES_FILE")
	[ "$content" = "hello world" ]
}

@test "add_user_message: increments TURN_COUNT" {
	init_session
	[ "$TURN_COUNT" -eq 0 ]
	add_user_message "first"
	[ "$TURN_COUNT" -eq 1 ]
	add_user_message "second"
	[ "$TURN_COUNT" -eq 2 ]
}

@test "add_user_message: escapes special characters" {
	init_session
	add_user_message 'quotes "and" newlines
and tabs	here'
	local content
	content=$(jq -r '.[-1].content' "$MESSAGES_FILE")
	[[ "$content" == *'quotes "and" newlines'* ]]
}

# ── add_assistant_message ────────────────────────────────────

@test "add_assistant_message: appends assistant message" {
	init_session
	local blocks='[{"type": "text", "text": "hello"}]'
	add_assistant_message "$blocks"
	local role
	role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
	[ "$role" = "assistant" ]
	local text
	text=$(jq -r '.[-1].content[0].text' "$MESSAGES_FILE")
	[ "$text" = "hello" ]
}

# ── add_tool_results ─────────────────────────────────────────

@test "add_tool_results: appends tool results as user message" {
	init_session
	local results='[{"type": "tool_result", "tool_use_id": "id1", "content": "result"}]'
	add_tool_results "$results"
	local role
	role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
	[ "$role" = "user" ]
	local tool_type
	tool_type=$(jq -r '.[-1].content[0].type' "$MESSAGES_FILE")
	[ "$tool_type" = "tool_result" ]
}

# ── update_usage ─────────────────────────────────────────────

@test "update_usage: accumulates token counts" {
	init_session
	update_usage 100 200 50 25
	[ "$TOTAL_INPUT_TOKENS" -eq 100 ]
	[ "$TOTAL_OUTPUT_TOKENS" -eq 200 ]
	[ "$TOTAL_CACHE_READ" -eq 50 ]
	[ "$TOTAL_CACHE_WRITE" -eq 25 ]

	update_usage 50 100 10 5
	[ "$TOTAL_INPUT_TOKENS" -eq 150 ]
	[ "$TOTAL_OUTPUT_TOKENS" -eq 300 ]
	[ "$TOTAL_CACHE_READ" -eq 60 ]
	[ "$TOTAL_CACHE_WRITE" -eq 30 ]
}

# ── get_session_cost ─────────────────────────────────────────

@test "get_session_cost: returns zero for no usage" {
	init_session
	local cost
	cost=$(get_session_cost)
	[ "$cost" = "0.0000" ]
}

@test "get_session_cost: calculates cost correctly" {
	init_session
	# 1M input tokens at $3.00 = $3.00
	# 1M output tokens at $15.00 = $15.00
	TOTAL_INPUT_TOKENS=1000000
	TOTAL_OUTPUT_TOKENS=1000000
	TOTAL_CACHE_READ=0
	TOTAL_CACHE_WRITE=0
	local cost
	cost=$(get_session_cost)
	[ "$cost" = "18.0000" ]
}

# ── maybe_compact_messages ───────────────────────────────────

@test "maybe_compact_messages: no-op when messages are short" {
	init_session
	add_user_message "hello"
	local before
	before=$(jq 'length' "$MESSAGES_FILE")
	maybe_compact_messages
	local after
	after=$(jq 'length' "$MESSAGES_FILE")
	[ "$before" -eq "$after" ]
}

@test "maybe_compact_messages: truncates when over 40 messages" {
	init_session
	# Add 50 messages
	for i in $(seq 1 50); do
		jq --arg msg "message $i" \
			'. += [{"role": "user", "content": $msg}]' \
			"$MESSAGES_FILE" > "$SESSION_DIR/tmp.json" && \
			mv "$SESSION_DIR/tmp.json" "$MESSAGES_FILE"
	done
	local before
	before=$(jq 'length' "$MESSAGES_FILE")
	[ "$before" -eq 50 ]

	maybe_compact_messages

	local after
	after=$(jq 'length' "$MESSAGES_FILE")
	[ "$after" -eq 40 ]
}

# ── build_system_prompt ──────────────────────────────────────

@test "build_system_prompt: includes working directory" {
	init_session
	local prompt
	prompt=$(build_system_prompt)
	[[ "$prompt" == *"Working directory:"* ]]
}

@test "build_system_prompt: includes platform info" {
	init_session
	local prompt
	prompt=$(build_system_prompt)
	[[ "$prompt" == *"Platform:"* ]]
}

@test "build_system_prompt: includes date" {
	init_session
	local prompt
	prompt=$(build_system_prompt)
	local today
	today=$(date +%Y-%m-%d)
	[[ "$prompt" == *"$today"* ]]
}

# ── build_request ────────────────────────────────────────────

@test "build_request: produces valid JSON" {
	# Need tools.sh for build_tools_json
	source "$PROJECT_ROOT/lib/tools.sh"
	init_session
	add_user_message "test"
	local request
	request=$(build_request)
	echo "$request" | jq -e '.model' > /dev/null
	echo "$request" | jq -e '.messages' > /dev/null
	echo "$request" | jq -e '.tools' > /dev/null
	echo "$request" | jq -e '.system' > /dev/null
	echo "$request" | jq -e '.stream == true' > /dev/null
}

@test "build_request: uses CLAUDE_MODEL env var" {
	source "$PROJECT_ROOT/lib/tools.sh"
	init_session
	add_user_message "test"
	CLAUDE_MODEL="claude-haiku-3"
	local request
	request=$(build_request)
	local model
	model=$(echo "$request" | jq -r '.model')
	[ "$model" = "claude-haiku-3" ]
}

@test "build_request: uses CLAUDE_MAX_TOKENS env var" {
	source "$PROJECT_ROOT/lib/tools.sh"
	init_session
	add_user_message "test"
	CLAUDE_MAX_TOKENS=4096
	local request
	request=$(build_request)
	local max
	max=$(echo "$request" | jq -r '.max_tokens')
	[ "$max" -eq 4096 ]
}

# ── save_session / resume_session ────────────────────────────

@test "save_session: creates session file" {
	init_session
	add_user_message "hello"
	save_session
	local session_file="$SESSIONS_DIR/${SESSION_ID}.json"
	[ -f "$session_file" ]
	local id
	id=$(jq -r '.id' "$session_file")
	[ "$id" = "$SESSION_ID" ]
}

@test "save_session: preserves message history" {
	init_session
	add_user_message "first message"
	add_user_message "second message"
	save_session
	local session_file="$SESSIONS_DIR/${SESSION_ID}.json"
	local count
	count=$(jq '.messages | length' "$session_file")
	[ "$count" -eq 2 ]
}

@test "resume_session: restores messages and state" {
	init_session
	add_user_message "restored message"
	TOTAL_INPUT_TOKENS=500
	TOTAL_OUTPUT_TOKENS=1000
	save_session
	local saved_id="$SESSION_ID"

	# Reset state manually (init_session doesn't reset counters)
	TURN_COUNT=0
	TOTAL_INPUT_TOKENS=0
	TOTAL_OUTPUT_TOKENS=0
	init_session

	# Resume
	resume_session "$saved_id"
	[ "$SESSION_ID" = "$saved_id" ]
	[ "$TURN_COUNT" -eq 1 ]
	[ "$TOTAL_INPUT_TOKENS" -eq 500 ]
	[ "$TOTAL_OUTPUT_TOKENS" -eq 1000 ]

	local content
	content=$(jq -r '.[0].content' "$MESSAGES_FILE")
	[ "$content" = "restored message" ]
}

@test "resume_session: fails for nonexistent session" {
	init_session
	run resume_session "nonexistent-session-id"
	[ "$status" -ne 0 ]
}

@test "resume_session: resumes by numeric index" {
	init_session
	add_user_message "indexed message"
	TOTAL_INPUT_TOKENS=100
	TOTAL_OUTPUT_TOKENS=200
	save_session
	local saved_id="$SESSION_ID"

	# Reset
	init_session
	TURN_COUNT=0
	TOTAL_INPUT_TOKENS=0
	TOTAL_OUTPUT_TOKENS=0

	# Resume by index 1 (most recent)
	resume_session "1"
	[ "$SESSION_ID" = "$saved_id" ]
	[ "$TURN_COUNT" -eq 1 ]
}

@test "resume_session: restores model from session" {
	init_session
	add_user_message "model test"
	CLAUDE_MODEL="claude-special-model"
	save_session
	local saved_id="$SESSION_ID"

	# Reset
	init_session
	CLAUDE_MODEL="default"

	resume_session "$saved_id"
	[ "$CLAUDE_MODEL" = "claude-special-model" ]
}

@test "resume_session: skips model restore when null" {
	init_session
	add_user_message "null model"
	save_session
	local saved_id="$SESSION_ID"

	# Manually remove model from saved file to simulate null
	local session_file="$SESSIONS_DIR/${saved_id}.json"
	jq '.model = null' "$session_file" > "$session_file.tmp" && mv "$session_file.tmp" "$session_file"

	init_session
	CLAUDE_MODEL="keep-this"

	resume_session "$saved_id"
	[ "$CLAUDE_MODEL" = "keep-this" ]
}

# ── get_session_cost with cache ─────────────────────────────

@test "get_session_cost: includes cache read and write costs" {
	init_session
	TOTAL_INPUT_TOKENS=0
	TOTAL_OUTPUT_TOKENS=0
	TOTAL_CACHE_READ=1000000
	TOTAL_CACHE_WRITE=1000000
	local cost
	cost=$(get_session_cost)
	# cache_read: 1M * 0.30 / 1M = 0.30
	# cache_write: 1M * 3.75 / 1M = 3.75
	# total: 4.05
	[ "$cost" = "4.0500" ]
}

# ── load_claude_md_files ────────────────────────────────────

@test "load_claude_md_files: finds CLAUDE.md in current directory" {
	local test_dir="$BATS_TEST_TMPDIR/project"
	mkdir -p "$test_dir"
	echo "# Project instructions" > "$test_dir/CLAUDE.md"

	cd "$test_dir"
	local output
	output=$(load_claude_md_files)
	[[ "$output" == *"Project instructions"* ]]
}

@test "load_claude_md_files: finds .claude/CLAUDE.md" {
	local test_dir="$BATS_TEST_TMPDIR/project2"
	mkdir -p "$test_dir/.claude"
	echo "# Hidden instructions" > "$test_dir/.claude/CLAUDE.md"

	cd "$test_dir"
	local output
	output=$(load_claude_md_files)
	[[ "$output" == *"Hidden instructions"* ]]
}

@test "load_claude_md_files: returns empty when no CLAUDE.md exists" {
	local test_dir="$BATS_TEST_TMPDIR/empty_project"
	mkdir -p "$test_dir"

	cd "$test_dir"
	# Should not error (may contain HOME claude.md, but no project one)
	run load_claude_md_files
	[ "$status" -eq 0 ]
}

# ── get_git_context ─────────────────────────────────────────

@test "get_git_context: returns empty outside git repo" {
	local test_dir="$BATS_TEST_TMPDIR/not_a_repo"
	mkdir -p "$test_dir"
	cd "$test_dir"
	local output
	output=$(get_git_context)
	[ -z "$output" ]
}

@test "get_git_context: shows branch and commits in git repo" {
	local repo="$BATS_TEST_TMPDIR/git_ctx_repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "initial"

	cd "$repo"
	local output
	output=$(get_git_context)
	[[ "$output" == *"Branch:"* ]]
	[[ "$output" == *"initial"* ]]
}

@test "get_git_context: shows uncommitted changes" {
	local repo="$BATS_TEST_TMPDIR/git_dirty_repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "initial"
	echo "modified" > "$repo/file.txt"

	cd "$repo"
	local output
	output=$(get_git_context)
	[[ "$output" == *"Uncommitted changes"* ]]
	[[ "$output" == *"file.txt"* ]]
}

# ── build_system_prompt with context ────────────────────────

@test "build_system_prompt: includes CLAUDE.md content when present" {
	init_session
	local test_dir="$BATS_TEST_TMPDIR/prompt_project"
	mkdir -p "$test_dir"
	echo "# Custom rule: always test" > "$test_dir/CLAUDE.md"

	cd "$test_dir"
	local prompt
	prompt=$(build_system_prompt)
	[[ "$prompt" == *"Project Instructions"* ]]
	[[ "$prompt" == *"Custom rule: always test"* ]]
}

@test "build_system_prompt: includes git context in git repo" {
	init_session
	local repo="$BATS_TEST_TMPDIR/prompt_repo"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email "test@test.com"
	git -C "$repo" config user.name "Test"
	echo "hello" > "$repo/file.txt"
	git -C "$repo" add . && git -C "$repo" commit -q -m "init commit"

	cd "$repo"
	local prompt
	prompt=$(build_system_prompt)
	[[ "$prompt" == *"Git Context"* ]]
	[[ "$prompt" == *"Branch:"* ]]
}

# ── list_sessions ───────────────────────────────────────────

@test "list_sessions: shows no sessions message when empty" {
	# Use a fresh empty sessions dir
	SESSIONS_DIR="$BATS_TEST_TMPDIR/empty_sessions"
	mkdir -p "$SESSIONS_DIR"
	# Re-enable print_dim so the message is captured
	print_dim() { echo "$1"; }
	export -f print_dim
	run list_sessions
	[ "$status" -eq 0 ]
	[[ "$output" == *"No saved sessions"* ]]
}

@test "list_sessions: lists saved sessions" {
	init_session
	add_user_message "session list test"
	save_session

	run list_sessions
	[ "$status" -eq 0 ]
	[[ "$output" == *"Saved sessions"* ]]
	[[ "$output" == *"$SESSION_ID"* ]]
}
