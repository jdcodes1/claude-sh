#!/usr/bin/env bash
# tools.sh — Tool definitions and execution

# Build tools JSON array for the API
build_tools_json() {
    cat <<'TOOLS'
[
  {
    "name": "Bash",
    "description": "Executes a bash command and returns its output. Use for running shell commands, installing packages, running tests, git operations, etc.",
    "input_schema": {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The bash command to execute"
        },
        "description": {
          "type": "string",
          "description": "Short description of what this command does"
        },
        "timeout": {
          "type": "number",
          "description": "Timeout in seconds (default 30, max 300)"
        }
      },
      "required": ["command"]
    }
  },
  {
    "name": "Read",
    "description": "Reads a file and returns its contents with line numbers. Use to understand code before modifying it.",
    "input_schema": {
      "type": "object",
      "properties": {
        "file_path": {
          "type": "string",
          "description": "Absolute path to the file to read"
        },
        "offset": {
          "type": "number",
          "description": "Line number to start reading from (1-indexed)"
        },
        "limit": {
          "type": "number",
          "description": "Maximum number of lines to read (default 2000)"
        }
      },
      "required": ["file_path"]
    }
  },
  {
    "name": "Edit",
    "description": "Performs string replacement in a file. The old_string must match exactly (including whitespace/indentation). Read the file first.",
    "input_schema": {
      "type": "object",
      "properties": {
        "file_path": {
          "type": "string",
          "description": "Absolute path to the file to edit"
        },
        "old_string": {
          "type": "string",
          "description": "The exact string to find and replace"
        },
        "new_string": {
          "type": "string",
          "description": "The replacement string"
        }
      },
      "required": ["file_path", "old_string", "new_string"]
    }
  },
  {
    "name": "Write",
    "description": "Creates or overwrites a file with the given content. Use for creating new files.",
    "input_schema": {
      "type": "object",
      "properties": {
        "file_path": {
          "type": "string",
          "description": "Absolute path to the file to write"
        },
        "content": {
          "type": "string",
          "description": "The content to write to the file"
        }
      },
      "required": ["file_path", "content"]
    }
  },
  {
    "name": "Glob",
    "description": "Finds files matching a glob pattern. Returns file paths sorted by modification time.",
    "input_schema": {
      "type": "object",
      "properties": {
        "pattern": {
          "type": "string",
          "description": "Glob pattern (e.g. '**/*.ts', 'src/**/*.js')"
        },
        "path": {
          "type": "string",
          "description": "Directory to search in (default: cwd)"
        }
      },
      "required": ["pattern"]
    }
  },
  {
    "name": "Grep",
    "description": "Searches file contents using ripgrep. Supports regex patterns.",
    "input_schema": {
      "type": "object",
      "properties": {
        "pattern": {
          "type": "string",
          "description": "Regex pattern to search for"
        },
        "path": {
          "type": "string",
          "description": "File or directory to search in (default: cwd)"
        },
        "glob": {
          "type": "string",
          "description": "File pattern filter (e.g. '*.js')"
        },
        "case_insensitive": {
          "type": "boolean",
          "description": "Case insensitive search"
        }
      },
      "required": ["pattern"]
    }
  }
]
TOOLS
}

# Execute a tool by name
# Args: tool_name tool_id input_json
# Returns: tool result as JSON string
execute_tool() {
    local tool_name="$1"
    local tool_id="$2"
    local input_json="$3"
    local result=""
    local is_error=false

    case "$tool_name" in
        Bash)   result=$(tool_bash "$input_json") ;;
        Read)   result=$(tool_read "$input_json") ;;
        Edit)   result=$(tool_edit "$input_json") ;;
        Write)  result=$(tool_write "$input_json") ;;
        Glob)   result=$(tool_glob "$input_json") ;;
        Grep)   result=$(tool_grep "$input_json") ;;
        *)
            result="Unknown tool: $tool_name"
            is_error=true
            ;;
    esac

    local exit_code=$?
    if (( exit_code != 0 )) && [[ "$is_error" == false ]]; then
        is_error=true
    fi

    # Return tool_result block
    if [[ "$is_error" == true ]]; then
        jq -n \
            --arg id "$tool_id" \
            --arg content "$result" \
            '{"type": "tool_result", "tool_use_id": $id, "content": $content, "is_error": true}'
    else
        jq -n \
            --arg id "$tool_id" \
            --arg content "$result" \
            '{"type": "tool_result", "tool_use_id": $id, "content": $content}'
    fi
}

# ── Tool Implementations ──────────────────────────────────────

# Permission mode: "ask" (default), "allow" (trust all), "deny" (block writes)
PERMISSION_MODE="${CLAUDE_SH_PERMISSIONS:-ask}"

# Commands that are always safe (read-only)
is_safe_command() {
    local cmd="$1"
    local base_cmd
    base_cmd=$(echo "$cmd" | awk '{print $1}')

    case "$base_cmd" in
        ls|cat|head|tail|wc|find|grep|rg|ag|git\ log|git\ status|git\ diff|\
        git\ show|git\ branch|echo|printf|pwd|date|whoami|uname|env|which|\
        file|stat|du|df|tree|less|more|sort|uniq|diff|md5|shasum|type)
            return 0
            ;;
    esac
    return 1
}

# Ask user for permission to run a command
ask_permission() {
    local command="$1"

    if [[ "$PERMISSION_MODE" == "allow" ]]; then
        return 0
    fi

    if [[ "$PERMISSION_MODE" == "deny" ]]; then
        return 1
    fi

    # Safe commands don't need permission
    if is_safe_command "$command"; then
        return 0
    fi

    # Interactive permission prompt
    printf '%b  Allow Bash:%b %s %b[y/n/a]%b ' "$YELLOW" "$RESET" "$command" "$DIM" "$RESET" >&2
    local answer
    read -rn1 answer </dev/tty
    printf '\n' >&2

    case "$answer" in
        y|Y) return 0 ;;
        a|A) PERMISSION_MODE="allow"; return 0 ;;
        *)   return 1 ;;
    esac
}

tool_bash() {
    local input="$1"
    local command timeout description
    command=$(echo "$input" | jq -r '.command // empty')
    timeout=$(echo "$input" | jq -r '.timeout // 30')
    description=$(echo "$input" | jq -r '.description // empty')

    if [[ -z "$command" ]]; then
        echo "Error: command is required"
        return 1
    fi

    # Cap timeout
    (( timeout > 300 )) && timeout=300

    # Display what we're running
    print_tool_header "Bash" "$description"
    printf '%b  $ %s%b\n' "$DIM" "$command" "$RESET"

    # Permission check (only in interactive mode)
    if [[ -t 0 ]]; then
        if ! ask_permission "$command"; then
            echo "Permission denied by user"
            return 1
        fi
    fi

    # Execute with timeout
    local output exit_code
    output=$(timeout "${timeout}s" bash -c "$command" 2>&1)
    exit_code=$?

    if (( exit_code == 124 )); then
        output+=$'\n'"(timed out after ${timeout}s)"
    fi

    # Show truncated output
    if [[ -n "$output" ]]; then
        print_tool_output "$output" 30
    fi

    # Return full output (may be large)
    if (( exit_code != 0 )); then
        printf '%s\n(exit code: %d)' "$output" "$exit_code"
        return 1
    else
        echo "$output"
    fi
}

tool_read() {
    local input="$1"
    local file_path offset limit
    file_path=$(echo "$input" | jq -r '.file_path // empty')
    offset=$(echo "$input" | jq -r '.offset // 1')
    limit=$(echo "$input" | jq -r '.limit // 2000')

    if [[ -z "$file_path" ]]; then
        echo "Error: file_path is required"
        return 1
    fi

    # Expand ~ if present
    file_path="${file_path/#\~/$HOME}"

    if [[ ! -f "$file_path" ]]; then
        echo "Error: file not found: $file_path"
        return 1
    fi

    print_tool_header "Read" "$file_path"

    # Read with line numbers, respecting offset and limit
    local output
    output=$(cat -n "$file_path" | tail -n "+${offset}" | head -n "$limit")

    local total_lines
    total_lines=$(wc -l < "$file_path")
    local shown_lines
    shown_lines=$(echo "$output" | wc -l)

    print_dim "  ($shown_lines of $total_lines lines)"
    echo "$output"
}

tool_edit() {
    local input="$1"
    local file_path old_string new_string
    file_path=$(echo "$input" | jq -r '.file_path // empty')
    old_string=$(echo "$input" | jq -r '.old_string // empty')
    new_string=$(echo "$input" | jq -r '.new_string // empty')

    if [[ -z "$file_path" ]] || [[ -z "$old_string" ]]; then
        echo "Error: file_path and old_string are required"
        return 1
    fi

    file_path="${file_path/#\~/$HOME}"

    if [[ ! -f "$file_path" ]]; then
        echo "Error: file not found: $file_path"
        return 1
    fi

    # Check if old_string exists in file
    if ! grep -qF "$old_string" "$file_path"; then
        echo "Error: old_string not found in $file_path"
        return 1
    fi

    # Count occurrences
    local count
    count=$(grep -cF "$old_string" "$file_path")
    if (( count > 1 )); then
        echo "Error: old_string matches $count locations. Provide more context to make it unique."
        return 1
    fi

    print_tool_header "Edit" "$file_path"

    # Use python3 for reliable multiline string replacement
    python3 -c "
import sys, os
file_path, old_str, new_str = sys.argv[1], sys.argv[2], sys.argv[3]
with open(file_path, 'r') as f:
    content = f.read()
content = content.replace(old_str, new_str, 1)
with open(file_path, 'w') as f:
    f.write(content)
" "$file_path" "$old_string" "$new_string"

    print_success "  Edited successfully"
    echo "Edited $file_path: replaced 1 occurrence"
}

tool_write() {
    local input="$1"
    local file_path content
    file_path=$(echo "$input" | jq -r '.file_path // empty')
    content=$(echo "$input" | jq -r '.content // empty')

    if [[ -z "$file_path" ]]; then
        echo "Error: file_path is required"
        return 1
    fi

    file_path="${file_path/#\~/$HOME}"

    # Create parent dirs if needed
    mkdir -p "$(dirname "$file_path")"

    print_tool_header "Write" "$file_path"

    printf '%s' "$content" > "$file_path"

    local lines
    lines=$(echo "$content" | wc -l)
    print_success "  Wrote $lines lines"
    echo "Wrote $file_path ($lines lines)"
}

tool_glob() {
    local input="$1"
    local pattern search_path
    pattern=$(echo "$input" | jq -r '.pattern // empty')
    search_path=$(echo "$input" | jq -r '.path // empty')

    if [[ -z "$pattern" ]]; then
        echo "Error: pattern is required"
        return 1
    fi

    [[ -z "$search_path" ]] && search_path="."
    search_path="${search_path/#\~/$HOME}"

    print_tool_header "Glob" "$pattern"

    local output
    # Use find with glob pattern, exclude .git
    output=$(find "$search_path" -path '*/.git' -prune -o -name "$pattern" -print 2>/dev/null | \
             head -n 100 | sort)

    # If simple glob doesn't work, try with bash globstar
    if [[ -z "$output" ]]; then
        output=$(cd "$search_path" && bash -O globstar -c "ls -1 $pattern 2>/dev/null" | head -n 100)
    fi

    local count
    count=$(echo "$output" | grep -c .)
    print_dim "  ($count files found)"
    echo "$output"
}

tool_grep() {
    local input="$1"
    local pattern search_path file_glob
    pattern=$(echo "$input" | jq -r '.pattern // empty')
    search_path=$(echo "$input" | jq -r '.path // empty')
    file_glob=$(echo "$input" | jq -r '.glob // empty')
    local case_insensitive
    case_insensitive=$(echo "$input" | jq -r '.case_insensitive // false')

    if [[ -z "$pattern" ]]; then
        echo "Error: pattern is required"
        return 1
    fi

    [[ -z "$search_path" ]] && search_path="."
    search_path="${search_path/#\~/$HOME}"

    print_tool_header "Grep" "$pattern"

    local args=("--no-heading" "--line-number" "--color=never")
    [[ "$case_insensitive" == "true" ]] && args+=("-i")
    [[ -n "$file_glob" ]] && args+=("--glob" "$file_glob")

    local output
    if command -v rg &>/dev/null; then
        output=$(rg "${args[@]}" "$pattern" "$search_path" 2>/dev/null | head -n 250)
    else
        # Fallback to grep
        local grep_args=("-rn" "--color=never")
        [[ "$case_insensitive" == "true" ]] && grep_args+=("-i")
        output=$(grep "${grep_args[@]}" "$pattern" "$search_path" 2>/dev/null | head -n 250)
    fi

    local count
    count=$(echo "$output" | grep -c . 2>/dev/null || echo 0)
    print_dim "  ($count matches)"
    echo "$output"
}
