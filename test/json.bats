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

@test "cleanup_session: exits nonzero when SESSION_DIR does not exist" {
	# [[ -d ... ]] && rm short-circuits to false when dir is missing
	SESSION_DIR="/nonexistent/path/$$"
	run cleanup_session
	[ "$status" -ne 0 ]
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
