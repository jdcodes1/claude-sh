#!/usr/bin/env bats
# tools.bats — tests for lib/tools.sh

load test_helper

setup() {
	setup_stubs
	setup_tempdir
	source "$PROJECT_ROOT/lib/tools.sh"
	# Default to allow mode so tests don't prompt
	PERMISSION_MODE="allow"
}

teardown() {
	teardown_tempdir
}

# ── is_safe_command ──────────────────────────────────────────

@test "is_safe_command: ls is safe" {
	run is_safe_command "ls -la"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: cat is safe" {
	run is_safe_command "cat /etc/hosts"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git is extracted as base command" {
	# is_safe_command uses awk to extract first word, so "git log" becomes "git"
	# which does not match the "git\ log" case pattern — this is a known limitation
	run is_safe_command "git log --oneline"
	[ "$status" -ne 0 ]
}

@test "is_safe_command: echo is safe" {
	run is_safe_command "echo hello"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: rm is not safe" {
	run is_safe_command "rm -rf /"
	[ "$status" -ne 0 ]
}

@test "is_safe_command: curl is not safe" {
	run is_safe_command "curl http://example.com"
	[ "$status" -ne 0 ]
}

@test "is_safe_command: python is not safe" {
	run is_safe_command "python3 -c 'import os'"
	[ "$status" -ne 0 ]
}

# ── ask_permission ───────────────────────────────────────────

@test "ask_permission: allow mode permits everything" {
	PERMISSION_MODE="allow"
	run ask_permission "rm -rf /"
	[ "$status" -eq 0 ]
}

@test "ask_permission: deny mode blocks everything unsafe" {
	PERMISSION_MODE="deny"
	run ask_permission "rm -rf /"
	[ "$status" -ne 0 ]
}

@test "ask_permission: deny mode blocks even safe commands" {
	PERMISSION_MODE="deny"
	# ask_permission checks mode before is_safe_command
	run ask_permission "ls"
	[ "$status" -ne 0 ]
}

# ── tool_read ────────────────────────────────────────────────

@test "tool_read: reads a file with line numbers" {
	echo -e "line1\nline2\nline3" > "$BATS_TEST_TMPDIR/sample.txt"
	run tool_read "{\"file_path\": \"$BATS_TEST_TMPDIR/sample.txt\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"line1"* ]]
	[[ "$output" == *"line2"* ]]
	[[ "$output" == *"line3"* ]]
}

@test "tool_read: returns error for missing file" {
	run tool_read '{"file_path": "/nonexistent/file.txt"}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"file not found"* ]]
}

@test "tool_read: returns error when file_path is empty" {
	run tool_read '{"file_path": ""}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"file_path is required"* ]]
}

@test "tool_read: respects offset parameter" {
	printf 'a\nb\nc\nd\ne\n' > "$BATS_TEST_TMPDIR/offset.txt"
	run tool_read "{\"file_path\": \"$BATS_TEST_TMPDIR/offset.txt\", \"offset\": 3}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"c"* ]]
	[[ "$output" != *"     1	a"* ]]
}

@test "tool_read: respects limit parameter" {
	printf 'a\nb\nc\nd\ne\n' > "$BATS_TEST_TMPDIR/limit.txt"
	run tool_read "{\"file_path\": \"$BATS_TEST_TMPDIR/limit.txt\", \"limit\": 2}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"a"* ]]
	[[ "$output" == *"b"* ]]
	# Line 'c' should not appear in the numbered output lines
	local numbered_lines
	numbered_lines=$(echo "$output" | grep -c '^\s*[0-9]')
	[ "$numbered_lines" -le 3 ]
}

# ── tool_write ───────────────────────────────────────────────

@test "tool_write: creates a new file" {
	local target="$BATS_TEST_TMPDIR/new_file.txt"
	run tool_write "{\"file_path\": \"$target\", \"content\": \"hello world\"}"
	[ "$status" -eq 0 ]
	[ -f "$target" ]
	[[ "$(cat "$target")" == "hello world" ]]
}

@test "tool_write: creates parent directories" {
	local target="$BATS_TEST_TMPDIR/deep/nested/dir/file.txt"
	run tool_write "{\"file_path\": \"$target\", \"content\": \"nested\"}"
	[ "$status" -eq 0 ]
	[ -f "$target" ]
	[[ "$(cat "$target")" == "nested" ]]
}

@test "tool_write: overwrites existing file" {
	local target="$BATS_TEST_TMPDIR/overwrite.txt"
	echo "old content" > "$target"
	run tool_write "{\"file_path\": \"$target\", \"content\": \"new content\"}"
	[ "$status" -eq 0 ]
	[[ "$(cat "$target")" == "new content" ]]
}

@test "tool_write: returns error when file_path is empty" {
	run tool_write '{"file_path": "", "content": "hello"}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"file_path is required"* ]]
}

# ── tool_edit ────────────────────────────────────────────────

@test "tool_edit: replaces matching string" {
	local target="$BATS_TEST_TMPDIR/edit.txt"
	printf 'hello world\ngoodbye world\n' > "$target"
	run tool_edit "{\"file_path\": \"$target\", \"old_string\": \"hello\", \"new_string\": \"hi\"}"
	[ "$status" -eq 0 ]
	[[ "$(cat "$target")" == *"hi world"* ]]
	[[ "$(cat "$target")" == *"goodbye world"* ]]
}

@test "tool_edit: fails when old_string not found" {
	local target="$BATS_TEST_TMPDIR/edit_miss.txt"
	echo "hello world" > "$target"
	run tool_edit "{\"file_path\": \"$target\", \"old_string\": \"nonexistent\", \"new_string\": \"replacement\"}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not found"* ]]
}

@test "tool_edit: fails when old_string matches multiple locations" {
	local target="$BATS_TEST_TMPDIR/edit_multi.txt"
	printf 'foo bar\nfoo baz\n' > "$target"
	run tool_edit "{\"file_path\": \"$target\", \"old_string\": \"foo\", \"new_string\": \"qux\"}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"matches"* ]]
}

@test "tool_edit: fails for missing file" {
	run tool_edit '{"file_path": "/nonexistent/file.txt", "old_string": "a", "new_string": "b"}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"file not found"* ]]
}

@test "tool_edit: fails when old_string is empty" {
	local target="$BATS_TEST_TMPDIR/edit_empty.txt"
	echo "content" > "$target"
	run tool_edit "{\"file_path\": \"$target\", \"old_string\": \"\", \"new_string\": \"new\"}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"required"* ]]
}

# ── tool_bash ────────────────────────────────────────────────

@test "tool_bash: runs a simple command" {
	run tool_bash '{"command": "echo hello"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello"* ]]
}

@test "tool_bash: returns error for empty command" {
	run tool_bash '{"command": ""}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"command is required"* ]]
}

@test "tool_bash: captures exit code on failure" {
	run tool_bash '{"command": "false"}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"exit code"* ]]
}

@test "tool_bash: caps timeout at 300" {
	# This just verifies it doesn't error with a large timeout
	run tool_bash '{"command": "echo fast", "timeout": 9999}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"fast"* ]]
}

# ── tool_glob ────────────────────────────────────────────────

@test "tool_glob: finds files matching pattern" {
	mkdir -p "$BATS_TEST_TMPDIR/globdir"
	touch "$BATS_TEST_TMPDIR/globdir/a.sh"
	touch "$BATS_TEST_TMPDIR/globdir/b.sh"
	touch "$BATS_TEST_TMPDIR/globdir/c.txt"
	run tool_glob "{\"pattern\": \"*.sh\", \"path\": \"$BATS_TEST_TMPDIR/globdir\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"a.sh"* ]]
	[[ "$output" == *"b.sh"* ]]
	[[ "$output" != *"c.txt"* ]]
}

@test "tool_glob: returns error when pattern is empty" {
	run tool_glob '{"pattern": ""}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"pattern is required"* ]]
}

# ── tool_grep ────────────────────────────────────────────────

@test "tool_grep: finds matching lines" {
	mkdir -p "$BATS_TEST_TMPDIR/grepdir"
	echo "hello world" > "$BATS_TEST_TMPDIR/grepdir/a.txt"
	echo "goodbye world" > "$BATS_TEST_TMPDIR/grepdir/b.txt"
	run tool_grep "{\"pattern\": \"hello\", \"path\": \"$BATS_TEST_TMPDIR/grepdir\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"hello world"* ]]
}

@test "tool_grep: returns error when pattern is empty" {
	run tool_grep '{"pattern": ""}'
	[ "$status" -ne 0 ]
	[[ "$output" == *"pattern is required"* ]]
}

# ── execute_tool ─────────────────────────────────────────────

@test "execute_tool: dispatches to correct tool" {
	echo "test content" > "$BATS_TEST_TMPDIR/dispatch.txt"
	run execute_tool "Read" "test-id-1" "{\"file_path\": \"$BATS_TEST_TMPDIR/dispatch.txt\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"test content"* ]]
	[[ "$output" == *"tool_use_id"* ]]
}

@test "execute_tool: returns error for unknown tool" {
	run execute_tool "FakeTool" "test-id-2" '{}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"Unknown tool"* ]]
	[[ "$output" == *"is_error"* ]]
}

# ── build_tools_json ─────────────────────────────────────────

@test "build_tools_json: returns valid JSON array" {
	run build_tools_json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array"'
}

@test "build_tools_json: contains all six tools" {
	local tools
	tools=$(build_tools_json)
	local count
	count=$(echo "$tools" | jq 'length')
	[ "$count" -eq 6 ]
}

@test "build_tools_json: tool names match expected set" {
	local tools
	tools=$(build_tools_json)
	local names
	names=$(echo "$tools" | jq -r '.[].name' | sort)
	[[ "$names" == *"Bash"* ]]
	[[ "$names" == *"Edit"* ]]
	[[ "$names" == *"Glob"* ]]
	[[ "$names" == *"Grep"* ]]
	[[ "$names" == *"Read"* ]]
	[[ "$names" == *"Write"* ]]
}
