#!/usr/bin/env bats
# api.bats — tests for lib/api.sh

load test_helper

setup() {
	setup_stubs
	setup_tempdir
	source "$PROJECT_ROOT/lib/json.sh"
	source "$PROJECT_ROOT/lib/api.sh"

	# Set up a minimal session directory for temp files
	SESSION_DIR="$BATS_TEST_TMPDIR/session"
	mkdir -p "$SESSION_DIR"
	MESSAGES_FILE="$SESSION_DIR/messages.json"
	echo '[]' > "$MESSAGES_FILE"

	# Stub ANTHROPIC_API_KEY
	ANTHROPIC_API_KEY="sk-test-key"
}

teardown() {
	teardown_tempdir
}

# ── process_sse_event ────────────────────────────────────────

@test "process_sse_event: message_start extracts usage tokens" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local data='{"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":25}}}'
	process_sse_event "message_start" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	grep -q 'input_tokens=100' "$meta_file"
	grep -q 'cache_read=50' "$meta_file"
	grep -q 'cache_write=25' "$meta_file"
}

@test "process_sse_event: content_block_start text resets accumulator" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	echo "stale data" > "$text_accum"
	: > "$tool_json" "$current_block" "$meta_file"

	local data='{"content_block":{"type":"text","text":""}}'
	process_sse_event "content_block_start" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	# text_accum should be empty now
	[ ! -s "$text_accum" ]
	# current_block should have the block
	local block_type
	block_type=$(jq -r '.type' "$current_block")
	[ "$block_type" = "text" ]
}

@test "process_sse_event: content_block_start tool_use resets json accumulator" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$current_block" "$meta_file"
	echo "stale json" > "$tool_json"

	local data='{"content_block":{"type":"tool_use","id":"toolu_123","name":"Bash","input":{}}}'
	run process_sse_event "content_block_start" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	# tool_json should be empty now
	[ ! -s "$tool_json" ]
	# current_block should have the block
	local block_type
	block_type=$(jq -r '.type' "$current_block")
	[ "$block_type" = "tool_use" ]
}

@test "process_sse_event: content_block_delta text_delta accumulates text" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local data='{"delta":{"type":"text_delta","text":"Hello "}}'
	process_sse_event "content_block_delta" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	data='{"delta":{"type":"text_delta","text":"world"}}'
	process_sse_event "content_block_delta" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local accumulated
	accumulated=$(cat "$text_accum")
	[ "$accumulated" = "Hello world" ]
}

@test "process_sse_event: content_block_delta input_json_delta accumulates JSON" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local data='{"delta":{"type":"input_json_delta","partial_json":"{\"comma"}}'
	process_sse_event "content_block_delta" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	data='{"delta":{"type":"input_json_delta","partial_json":"nd\": \"ls\"}"}}'
	process_sse_event "content_block_delta" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local accumulated
	accumulated=$(cat "$tool_json")
	[ "$accumulated" = '{"command": "ls"}' ]
}

@test "process_sse_event: content_block_stop finalizes text block" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	printf 'Hello world' > "$text_accum"
	: > "$tool_json" "$meta_file"
	echo '{"type":"text","text":""}' > "$current_block"

	process_sse_event "content_block_stop" "" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local block_count
	block_count=$(jq 'length' "$blocks_file")
	[ "$block_count" -eq 1 ]

	local text
	text=$(jq -r '.[0].text' "$blocks_file")
	[ "$text" = "Hello world" ]
}

@test "process_sse_event: content_block_stop finalizes tool_use block" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$meta_file"
	printf '{"command": "ls"}' > "$tool_json"
	echo '{"type":"tool_use","id":"toolu_123","name":"Bash","input":{}}' > "$current_block"

	process_sse_event "content_block_stop" "" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local block_count
	block_count=$(jq 'length' "$blocks_file")
	[ "$block_count" -eq 1 ]

	local tool_name
	tool_name=$(jq -r '.[0].name' "$blocks_file")
	[ "$tool_name" = "Bash" ]

	local command
	command=$(jq -r '.[0].input.command' "$blocks_file")
	[ "$command" = "ls" ]
}

@test "process_sse_event: message_delta records stop_reason and output_tokens" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local data='{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":200}}'
	process_sse_event "message_delta" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	grep -q 'stop_reason=end_turn' "$meta_file"
	grep -q 'output_tokens=200' "$meta_file"
}

@test "process_sse_event: message_stop is a no-op" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	# Should not error
	process_sse_event "message_stop" "" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	# meta_file should still be empty
	[ ! -s "$meta_file" ]
}

@test "process_sse_event: error event prints error message" {
	local blocks_file="$SESSION_DIR/blocks.json"
	local text_accum="$SESSION_DIR/text_accum.txt"
	local tool_json="$SESSION_DIR/tool_json_accum.txt"
	local current_block="$SESSION_DIR/current_block.json"
	local meta_file="$SESSION_DIR/meta.txt"
	echo '[]' > "$blocks_file"
	: > "$text_accum" "$tool_json" "$current_block" "$meta_file"

	local data='{"error":{"message":"Overloaded"}}'
	run process_sse_event "error" "$data" \
		"$blocks_file" "$text_accum" "$tool_json" "$current_block" "$meta_file"

	[[ "$output" == *"Overloaded"* ]]
}

# ── stream_request ───────────────────────────────────────────

@test "stream_request: returns error when ANTHROPIC_API_KEY is empty" {
	ANTHROPIC_API_KEY=""
	run stream_request '{"model":"test"}'
	[ "$status" -eq 1 ]
	[[ "$output" == *"ANTHROPIC_API_KEY not set"* ]]
}

@test "stream_request: processes SSE stream from mock server" {
	# Create a mock curl that writes SSE events to the output file
	local mock_curl="$BATS_TEST_TMPDIR/mock_curl"
	cat > "$mock_curl" <<'SCRIPT'
#!/usr/bin/env bash
# Parse args to find the -o (output file) argument
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -w) shift 2 ;;
        *) shift ;;
    esac
done

# Write SSE events to the output file (FIFO)
{
    printf 'event: message_start\n'
    printf 'data: {"message":{"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    printf '\n'
    printf 'event: content_block_start\n'
    printf 'data: {"content_block":{"type":"text","text":""}}\n'
    printf '\n'
    printf 'event: content_block_delta\n'
    printf 'data: {"delta":{"type":"text_delta","text":"Hi"}}\n'
    printf '\n'
    printf 'event: content_block_stop\n'
    printf 'data: {}\n'
    printf '\n'
    printf 'event: message_delta\n'
    printf 'data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}\n'
    printf '\n'
    printf 'event: message_stop\n'
    printf 'data: {}\n'
    printf '\n'
} > "$output_file"

# Write HTTP 200 to the http_code_file (same dir as output)
session_dir=$(dirname "$output_file")
echo "200" > "$session_dir/http_code"
SCRIPT
	chmod +x "$mock_curl"

	# Override curl path
	curl() { "$mock_curl" "$@"; }
	export -f curl

	stream_request '{"model":"test"}'

	[ "$RESPONSE_STOP_REASON" = "end_turn" ]
	[ "$RESPONSE_INPUT_TOKENS" -eq 10 ]
	[ "$RESPONSE_OUTPUT_TOKENS" -eq 5 ]

	# Check that blocks were accumulated
	local block_count
	block_count=$(echo "$RESPONSE_CONTENT_BLOCKS" | jq 'length')
	[ "$block_count" -eq 1 ]

	local text
	text=$(echo "$RESPONSE_CONTENT_BLOCKS" | jq -r '.[0].text')
	[ "$text" = "Hi" ]
}

@test "stream_request: returns 2 on HTTP 429 rate limit" {
	# Create a mock curl script on PATH (function export won't reach background subshell)
	local mock_dir="$BATS_TEST_TMPDIR/mock_bin"
	mkdir -p "$mock_dir"
	cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -w) printf '429'; shift 2 ;;
        *) shift ;;
    esac
done
: > "$output_file"
MOCK
	chmod +x "$mock_dir/curl"
	PATH="$mock_dir:$PATH"

	run stream_request '{"model":"test"}'
	[ "$status" -eq 2 ]
}

@test "stream_request: returns 2 on HTTP 529" {
	CONSECUTIVE_529=0
	local mock_dir="$BATS_TEST_TMPDIR/mock_bin_529"
	mkdir -p "$mock_dir"
	cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -w) printf '529'; shift 2 ;;
        *) shift ;;
    esac
done
: > "$output_file"
MOCK
	chmod +x "$mock_dir/curl"
	PATH="$mock_dir:$PATH"

	run stream_request '{"model":"test"}'
	[ "$status" -eq 2 ]
}

@test "stream_request: returns 1 on non-retryable HTTP error" {
	local mock_dir="$BATS_TEST_TMPDIR/mock_bin_500"
	mkdir -p "$mock_dir"
	cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -w) printf '500'; shift 2 ;;
        *) shift ;;
    esac
done
: > "$output_file"
MOCK
	chmod +x "$mock_dir/curl"
	PATH="$mock_dir:$PATH"

	run stream_request '{"model":"test"}'
	[ "$status" -eq 1 ]
	[[ "$output" == *"HTTP 500"* ]]
}

@test "stream_request: defaults to end_turn when meta file has no stop_reason" {
	curl() {
		local output_file=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
				-o) output_file="$2"; shift 2 ;;
				-w) shift 2 ;;
				*) shift ;;
			esac
		done
		# Write empty SSE stream (just close the fifo)
		: > "$output_file"
		local session_dir
		session_dir=$(dirname "$output_file")
		echo "200" > "$session_dir/http_code"
	}
	export -f curl

	stream_request '{"model":"test"}'
	[ "$RESPONSE_STOP_REASON" = "end_turn" ]
	[ "$RESPONSE_INPUT_TOKENS" -eq 0 ]
	[ "$RESPONSE_OUTPUT_TOKENS" -eq 0 ]
}

# ── stream_request_with_retry ────────────────────────────────

@test "stream_request_with_retry: returns 0 on immediate success" {
	stream_request() { return 0; }
	export -f stream_request

	CONSECUTIVE_529=5
	run stream_request_with_retry '{"model":"test"}'
	[ "$status" -eq 0 ]
	# CONSECUTIVE_529 resets on success (can't check in run subshell,
	# but the function is exercised)
}

@test "stream_request_with_retry: retries on status 2 then succeeds" {
	# Use a counter file since each call is in same shell
	local counter_file="$BATS_TEST_TMPDIR/call_count"
	echo "0" > "$counter_file"

	# Redefine stream_request (not export — called in same shell)
	eval 'stream_request() {
		local count
		count=$(cat "'"$counter_file"'")
		count=$((count + 1))
		echo "$count" > "'"$counter_file"'"
		if (( count < 2 )); then
			return 2
		fi
		return 0
	}'

	# Override sleep to avoid waiting
	sleep() { :; }

	# Use run to avoid set -e propagation from bats into the retry loop
	run stream_request_with_retry '{"model":"test"}'
	[ "$status" -eq 0 ]

	local calls
	calls=$(cat "$counter_file")
	[ "$calls" -eq 2 ]
}

@test "stream_request_with_retry: gives up after MAX_RETRIES" {
	stream_request() { return 2; }
	export -f stream_request

	sleep() { :; }
	export -f sleep

	MAX_RETRIES=2
	run stream_request_with_retry '{"model":"test"}'
	[ "$status" -eq 1 ]
	[[ "$output" == *"Max retries"* ]]
}

@test "stream_request_with_retry: returns 1 immediately on fatal error" {
	stream_request() { return 1; }
	export -f stream_request

	run stream_request_with_retry '{"model":"test"}'
	[ "$status" -eq 1 ]
}
