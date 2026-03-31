#!/usr/bin/env bash
# api.sh — Anthropic API client with SSE streaming via FIFO pipe

MAX_RETRIES=3
CONSECUTIVE_529=0

# Stream a request with automatic retry on rate limits
stream_request_with_retry() {
    local request_body="$1"
    local attempt=0
    local delay=1

    while (( attempt <= MAX_RETRIES )); do
        stream_request "$request_body"
        local status=$?

        if (( status == 0 )); then
            CONSECUTIVE_529=0
            return 0
        fi

        # Check if it was a retryable error (rate limit)
        if (( status == 2 )); then
            attempt=$((attempt + 1))
            if (( attempt > MAX_RETRIES )); then
                print_error "Max retries ($MAX_RETRIES) exceeded"
                return 1
            fi
            print_warning "Rate limited. Retrying in ${delay}s... (attempt $attempt/$MAX_RETRIES)"
            sleep "$delay"
            delay=$((delay * 2))
            # Restart spinner for retry
            start_spinner
        else
            return 1
        fi
    done
    return 1
}

# Stream a request to the Claude API and process events in real-time
# Returns: 0 on success, 1 on fatal error, 2 on retryable error (rate limit)
stream_request() {
    local request_body="$1"

    # Reset response state
    RESPONSE_CONTENT_BLOCKS="[]"
    RESPONSE_STOP_REASON=""
    RESPONSE_INPUT_TOKENS=0
    RESPONSE_OUTPUT_TOKENS=0
    RESPONSE_CACHE_READ=0
    RESPONSE_CACHE_WRITE=0

    # Temp files for accumulating state
    local blocks_file="$SESSION_DIR/blocks.json"
    local meta_file="$SESSION_DIR/meta.txt"
    local text_accum_file="$SESSION_DIR/text_accum.txt"
    local tool_json_file="$SESSION_DIR/tool_json_accum.txt"
    local current_block_file="$SESSION_DIR/current_block.json"

    echo '[]' > "$blocks_file"
    : > "$meta_file"
    : > "$text_accum_file"
    : > "$tool_json_file"
    : > "$current_block_file"

    local api_key="${ANTHROPIC_API_KEY}"
    local api_url="${ANTHROPIC_API_URL:-https://api.anthropic.com}"

    if [[ -z "$api_key" ]]; then
        print_error "ANTHROPIC_API_KEY not set"
        return 1
    fi

    stop_spinner

    # Create a FIFO for real-time streaming
    local fifo="$SESSION_DIR/sse_fifo"
    [[ -p "$fifo" ]] && rm -f "$fifo"
    mkfifo "$fifo"

    # Track curl's HTTP response code via a file
    local http_code_file="$SESSION_DIR/http_code"
    : > "$http_code_file"

    # Launch curl in background, writing SSE stream to the FIFO
    (
        local code
        code=$(curl -sS -w '%{http_code}' \
            --no-buffer \
            -o "$fifo" \
            -X POST "${api_url}/v1/messages" \
            -H "content-type: application/json" \
            -H "x-api-key: ${api_key}" \
            -H "anthropic-version: 2023-06-01" \
            -d "$request_body" 2>/dev/null)
        echo "$code" > "$http_code_file"
    ) &
    local curl_pid=$!

    # Parse SSE events from the FIFO in real-time
    local current_event="" current_data=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if [[ "$line" == event:* ]]; then
            current_event="${line#event: }"
        elif [[ "$line" == data:* ]]; then
            current_data="${line#data: }"
        elif [[ -z "$line" ]] && [[ -n "$current_event" ]]; then
            process_sse_event "$current_event" "$current_data" \
                "$blocks_file" "$text_accum_file" "$tool_json_file" \
                "$current_block_file" "$meta_file"
            current_event=""
            current_data=""
        fi
    done < "$fifo"

    # Wait for curl to finish
    wait "$curl_pid" 2>/dev/null

    # Check HTTP status
    local http_code
    http_code=$(cat "$http_code_file" 2>/dev/null)

    if [[ -n "$http_code" ]] && [[ "$http_code" != "200" ]] && [[ "$http_code" != "000" ]]; then
        if [[ "$(cat "$blocks_file")" == "[]" ]]; then
            rm -f "$fifo"
            # Rate limit errors are retryable
            if [[ "$http_code" == "429" ]] || [[ "$http_code" == "529" ]]; then
                if [[ "$http_code" == "529" ]]; then
                    CONSECUTIVE_529=$((CONSECUTIVE_529 + 1))
                fi
                return 2
            fi
            print_error "API returned HTTP $http_code"
            return 1
        fi
    fi

    rm -f "$fifo"

    # Read final state
    RESPONSE_CONTENT_BLOCKS=$(cat "$blocks_file")
    RESPONSE_STOP_REASON=$(grep '^stop_reason=' "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2)
    RESPONSE_INPUT_TOKENS=$(grep '^input_tokens=' "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2)
    RESPONSE_OUTPUT_TOKENS=$(grep '^output_tokens=' "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2)
    RESPONSE_CACHE_READ=$(grep '^cache_read=' "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2)
    RESPONSE_CACHE_WRITE=$(grep '^cache_write=' "$meta_file" 2>/dev/null | tail -1 | cut -d= -f2)

    RESPONSE_INPUT_TOKENS=${RESPONSE_INPUT_TOKENS:-0}
    RESPONSE_OUTPUT_TOKENS=${RESPONSE_OUTPUT_TOKENS:-0}
    RESPONSE_CACHE_READ=${RESPONSE_CACHE_READ:-0}
    RESPONSE_CACHE_WRITE=${RESPONSE_CACHE_WRITE:-0}
    RESPONSE_STOP_REASON=${RESPONSE_STOP_REASON:-end_turn}

    printf '\n'
}

# Process a single SSE event — called in real-time as events arrive
process_sse_event() {
    local event="$1" data="$2"
    local blocks_file="$3" text_accum_file="$4" tool_json_file="$5"
    local current_block_file="$6" meta_file="$7"

    case "$event" in
        message_start)
            local input_tokens cache_read cache_write
            input_tokens=$(echo "$data" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null)
            cache_read=$(echo "$data" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null)
            cache_write=$(echo "$data" | jq -r '.message.usage.cache_creation_input_tokens // 0' 2>/dev/null)
            {
                echo "input_tokens=$input_tokens"
                echo "cache_read=$cache_read"
                echo "cache_write=$cache_write"
            } >> "$meta_file"
            ;;

        content_block_start)
            local block_type
            block_type=$(echo "$data" | jq -r '.content_block.type // empty' 2>/dev/null)

            if [[ "$block_type" == "text" ]]; then
                : > "$text_accum_file"
                echo "$data" | jq -c '.content_block' > "$current_block_file"
            elif [[ "$block_type" == "tool_use" ]]; then
                : > "$tool_json_file"
                echo "$data" | jq -c '.content_block' > "$current_block_file"
                # Show tool name as it starts
                local tool_name
                tool_name=$(echo "$data" | jq -r '.content_block.name // empty' 2>/dev/null)
                if [[ -n "$tool_name" ]]; then
                    printf '\n%b  [calling %s...]%b' "$DIM" "$tool_name" "$RESET"
                fi
            fi
            ;;

        content_block_delta)
            local delta_type
            delta_type=$(echo "$data" | jq -r '.delta.type // empty' 2>/dev/null)

            if [[ "$delta_type" == "text_delta" ]]; then
                local text
                text=$(echo "$data" | jq -r '.delta.text // empty' 2>/dev/null)
                # Print to terminal in real-time (this is the streaming magic)
                printf '%s' "$text"
                # Also accumulate for history
                printf '%s' "$text" >> "$text_accum_file"
            elif [[ "$delta_type" == "input_json_delta" ]]; then
                local partial
                partial=$(echo "$data" | jq -r '.delta.partial_json // empty' 2>/dev/null)
                printf '%s' "$partial" >> "$tool_json_file"
            fi
            ;;

        content_block_stop)
            local block block_type
            block=$(cat "$current_block_file")
            block_type=$(echo "$block" | jq -r '.type // empty' 2>/dev/null)

            if [[ "$block_type" == "text" ]]; then
                local full_text text_escaped finalized
                full_text=$(cat "$text_accum_file")
                text_escaped=$(jq -Rs '.' <<< "$full_text")
                finalized=$(echo "$block" | jq --argjson text "$text_escaped" '.text = $text')
                jq --argjson block "$finalized" '. += [$block]' "$blocks_file" > "${blocks_file}.tmp" && \
                    mv "${blocks_file}.tmp" "$blocks_file"

            elif [[ "$block_type" == "tool_use" ]]; then
                local tool_json parsed_input finalized
                tool_json=$(cat "$tool_json_file")
                parsed_input=$(echo "$tool_json" | jq -c '.' 2>/dev/null || echo '{}')
                finalized=$(echo "$block" | jq --argjson input "$parsed_input" '.input = $input')
                jq --argjson block "$finalized" '. += [$block]' "$blocks_file" > "${blocks_file}.tmp" && \
                    mv "${blocks_file}.tmp" "$blocks_file"
                printf '\n'
            fi
            ;;

        message_delta)
            local stop_reason output_tokens
            stop_reason=$(echo "$data" | jq -r '.delta.stop_reason // empty' 2>/dev/null)
            output_tokens=$(echo "$data" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
            {
                echo "stop_reason=$stop_reason"
                echo "output_tokens=$output_tokens"
            } >> "$meta_file"
            ;;

        message_stop)
            ;;

        error)
            local error_msg
            error_msg=$(echo "$data" | jq -r '.error.message // .message // "Unknown error"' 2>/dev/null)
            print_error "Stream error: $error_msg"
            ;;
    esac
}
