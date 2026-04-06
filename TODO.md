# TODO

- Add missing tools (that're useful anyway)
  - [ ] websearch
  - [ ] webfetch
- Bugs found by test suite
  - [x] `is_safe_command` extracts only first word via `awk '{print $1}'`, so multi-word case patterns like `git\ log` never match
  - [x] `ask_permission` in `deny` mode returns 1 before checking `is_safe_command`, blocking read-only commands like `ls`
  - [x] `cleanup_session` returns nonzero when `SESSION_DIR` is empty or nonexistent (`[[ -d ... ]] && rm` short-circuits)
