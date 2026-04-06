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

@test "is_safe_command: git log is safe" {
	run is_safe_command "git log --oneline"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git status is safe" {
	run is_safe_command "git status"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git diff is safe" {
	run is_safe_command "git diff HEAD"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git show is safe" {
	run is_safe_command "git show HEAD"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git branch is safe" {
	run is_safe_command "git branch -a"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: git push is not safe" {
	run is_safe_command "git push origin main"
	[ "$status" -ne 0 ]
}

@test "is_safe_command: git reset is not safe" {
	run is_safe_command "git reset --hard"
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

@test "ask_permission: deny mode allows safe commands" {
	PERMISSION_MODE="deny"
	run ask_permission "ls"
	[ "$status" -eq 0 ]
}

@test "ask_permission: deny mode allows safe git subcommands" {
	PERMISSION_MODE="deny"
	run ask_permission "git log --oneline"
	[ "$status" -eq 0 ]
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

# ── ask_permission: ask mode ────────────────────────────────

@test "ask_permission: ask mode allows safe commands without prompt" {
	PERMISSION_MODE="ask"
	run ask_permission "ls -la"
	[ "$status" -eq 0 ]
}

@test "ask_permission: deny mode allows safe commands like echo" {
	PERMISSION_MODE="deny"
	run ask_permission "echo hello"
	[ "$status" -eq 0 ]
}

# ── is_safe_command: additional commands ────────────────────

@test "is_safe_command: printf is safe" {
	run is_safe_command "printf hello"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: find is safe" {
	run is_safe_command "find . -name '*.sh'"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: wc is safe" {
	run is_safe_command "wc -l file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: head is safe" {
	run is_safe_command "head -n 10 file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: tail is safe" {
	run is_safe_command "tail -n 5 file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: sort is safe" {
	run is_safe_command "sort file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: rg is safe" {
	run is_safe_command "rg pattern"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: ag is safe" {
	run is_safe_command "ag pattern"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: pwd is safe" {
	run is_safe_command "pwd"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: date is safe" {
	run is_safe_command "date"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: whoami is safe" {
	run is_safe_command "whoami"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: uname is safe" {
	run is_safe_command "uname -a"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: env is safe" {
	run is_safe_command "env"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: which is safe" {
	run is_safe_command "which bash"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: file is safe" {
	run is_safe_command "file /bin/bash"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: stat is safe" {
	run is_safe_command "stat /tmp"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: du is safe" {
	run is_safe_command "du -sh ."
	[ "$status" -eq 0 ]
}

@test "is_safe_command: df is safe" {
	run is_safe_command "df -h"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: tree is safe" {
	run is_safe_command "tree ."
	[ "$status" -eq 0 ]
}

@test "is_safe_command: diff is safe" {
	run is_safe_command "diff file1 file2"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: type is safe" {
	run is_safe_command "type bash"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: uniq is safe" {
	run is_safe_command "uniq file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: less is safe" {
	run is_safe_command "less file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: more is safe" {
	run is_safe_command "more file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: md5 is safe" {
	run is_safe_command "md5 file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: shasum is safe" {
	run is_safe_command "shasum file.txt"
	[ "$status" -eq 0 ]
}

@test "is_safe_command: grep is safe" {
	run is_safe_command "grep pattern file.txt"
	[ "$status" -eq 0 ]
}

# ── tool_bash: additional cases ─────────────────────────────

@test "tool_bash: shows description when provided" {
	# Re-enable print_tool_header to capture output
	print_tool_header() { echo "TOOL: $1 $2"; }
	export -f print_tool_header
	run tool_bash '{"command": "echo hi", "description": "Say hi"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"hi"* ]]
}

@test "tool_bash: respects custom timeout" {
	run tool_bash '{"command": "echo fast", "timeout": 5}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"fast"* ]]
}

# ── tool_read: tilde expansion ──────────────────────────────

@test "tool_read: expands tilde in file path" {
	local target="$HOME/.claude_sh_test_read_$$"
	echo "tilde test" > "$target"
	run tool_read "{\"file_path\": \"~/.claude_sh_test_read_$$\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tilde test"* ]]
	rm -f "$target"
}

# ── tool_edit: tilde expansion ──────────────────────────────

@test "tool_edit: expands tilde in file path" {
	local target="$HOME/.claude_sh_test_edit_$$"
	echo "old value" > "$target"
	run tool_edit "{\"file_path\": \"~/.claude_sh_test_edit_$$\", \"old_string\": \"old value\", \"new_string\": \"new value\"}"
	[ "$status" -eq 0 ]
	[[ "$(cat "$target")" == *"new value"* ]]
	rm -f "$target"
}

# ── tool_write: tilde expansion ─────────────────────────────

@test "tool_write: expands tilde in file path" {
	local target="$HOME/.claude_sh_test_write_$$"
	run tool_write "{\"file_path\": \"~/.claude_sh_test_write_$$\", \"content\": \"tilde write\"}"
	[ "$status" -eq 0 ]
	[[ "$(cat "$target")" == "tilde write" ]]
	rm -f "$target"
}

# ── tool_glob: additional cases ─────────────────────────────

@test "tool_glob: uses current directory when path is empty" {
	mkdir -p "$BATS_TEST_TMPDIR/glob_cwd"
	touch "$BATS_TEST_TMPDIR/glob_cwd/test.sh"
	cd "$BATS_TEST_TMPDIR/glob_cwd"
	run tool_glob '{"pattern": "*.sh"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"test.sh"* ]]
}

@test "tool_glob: expands tilde in search path" {
	local target_dir="$HOME/.claude_sh_test_glob_$$"
	mkdir -p "$target_dir"
	touch "$target_dir/found.txt"
	run tool_glob "{\"pattern\": \"*.txt\", \"path\": \"~/.claude_sh_test_glob_$$\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"found.txt"* ]]
	rm -rf "$target_dir"
}

# ── tool_grep: additional cases ─────────────────────────────

@test "tool_grep: supports case_insensitive flag" {
	mkdir -p "$BATS_TEST_TMPDIR/grep_ci"
	echo "Hello World" > "$BATS_TEST_TMPDIR/grep_ci/test.txt"
	run tool_grep "{\"pattern\": \"hello\", \"path\": \"$BATS_TEST_TMPDIR/grep_ci\", \"case_insensitive\": true}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Hello World"* ]]
}

@test "tool_grep: supports glob file filter" {
	mkdir -p "$BATS_TEST_TMPDIR/grep_glob"
	echo "find me" > "$BATS_TEST_TMPDIR/grep_glob/target.sh"
	echo "find me" > "$BATS_TEST_TMPDIR/grep_glob/ignore.txt"
	run tool_grep "{\"pattern\": \"find me\", \"path\": \"$BATS_TEST_TMPDIR/grep_glob\", \"glob\": \"*.sh\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"target.sh"* ]]
}

@test "tool_grep: uses current directory when path is empty" {
	mkdir -p "$BATS_TEST_TMPDIR/grep_cwd"
	echo "cwd pattern" > "$BATS_TEST_TMPDIR/grep_cwd/file.txt"
	cd "$BATS_TEST_TMPDIR/grep_cwd"
	run tool_grep '{"pattern": "cwd pattern"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"cwd pattern"* ]]
}

@test "tool_grep: expands tilde in search path" {
	local target_dir="$HOME/.claude_sh_test_grep_$$"
	mkdir -p "$target_dir"
	echo "tilde grep" > "$target_dir/test.txt"
	run tool_grep "{\"pattern\": \"tilde grep\", \"path\": \"~/.claude_sh_test_grep_$$\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tilde grep"* ]]
	rm -rf "$target_dir"
}

@test "tool_grep: falls back to grep when rg is not available" {
	# Hide rg by overriding command -v
	command() {
		if [[ "$1" == "-v" ]] && [[ "$2" == "rg" ]]; then
			return 1
		fi
		builtin command "$@"
	}
	export -f command

	mkdir -p "$BATS_TEST_TMPDIR/grep_fallback"
	echo "fallback line" > "$BATS_TEST_TMPDIR/grep_fallback/test.txt"
	run tool_grep "{\"pattern\": \"fallback\", \"path\": \"$BATS_TEST_TMPDIR/grep_fallback\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fallback line"* ]]
}

@test "tool_grep: fallback grep supports case_insensitive" {
	command() {
		if [[ "$1" == "-v" ]] && [[ "$2" == "rg" ]]; then
			return 1
		fi
		builtin command "$@"
	}
	export -f command

	mkdir -p "$BATS_TEST_TMPDIR/grep_ci_fallback"
	echo "UPPER case" > "$BATS_TEST_TMPDIR/grep_ci_fallback/test.txt"
	run tool_grep "{\"pattern\": \"upper\", \"path\": \"$BATS_TEST_TMPDIR/grep_ci_fallback\", \"case_insensitive\": true}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"UPPER case"* ]]
}

# ── execute_tool: all dispatches ────────────────────────────

@test "execute_tool: dispatches Bash tool" {
	run execute_tool "Bash" "id-bash" '{"command": "echo dispatch_bash"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"dispatch_bash"* ]]
	[[ "$output" == *"tool_use_id"* ]]
}

@test "execute_tool: dispatches Write tool" {
	local target="$BATS_TEST_TMPDIR/dispatch_write.txt"
	run execute_tool "Write" "id-write" "{\"file_path\": \"$target\", \"content\": \"dispatched\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tool_use_id"* ]]
	[ -f "$target" ]
}

@test "execute_tool: dispatches Edit tool" {
	local target="$BATS_TEST_TMPDIR/dispatch_edit.txt"
	echo "before edit" > "$target"
	run execute_tool "Edit" "id-edit" "{\"file_path\": \"$target\", \"old_string\": \"before\", \"new_string\": \"after\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tool_use_id"* ]]
}

@test "execute_tool: dispatches Glob tool" {
	touch "$BATS_TEST_TMPDIR/dispatch_glob.sh"
	run execute_tool "Glob" "id-glob" "{\"pattern\": \"*.sh\", \"path\": \"$BATS_TEST_TMPDIR\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tool_use_id"* ]]
}

@test "execute_tool: dispatches Grep tool" {
	echo "grep target" > "$BATS_TEST_TMPDIR/dispatch_grep.txt"
	run execute_tool "Grep" "id-grep" "{\"pattern\": \"grep target\", \"path\": \"$BATS_TEST_TMPDIR\"}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"tool_use_id"* ]]
}

@test "execute_tool: marks result as error when tool fails" {
	run execute_tool "Read" "id-fail" '{"file_path": "/nonexistent/file"}'
	[ "$status" -eq 0 ]
	[[ "$output" == *"is_error"* ]]
	[[ "$output" == *"true"* ]]
}
