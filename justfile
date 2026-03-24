# neural_link — multi-agent coordination service
# ──────────────────────────────────────────────

default_port := "9961"
bin_dir := env("HOME") / "bin"
opencode_cfg := env("HOME") / ".config/opencode/opencode.json"

default:
    @just --list

# ── Setup ──────────────────────────────────────

[group('setup')]
setup:
    gleam deps download

[group('setup')]
install: build
    gleam export erlang-shipment
    rm -f {{bin_dir}}/nlk {{bin_dir}}/neural_link
    printf '#!/bin/sh\nexec %s/build/erlang-shipment/entrypoint.sh run "$@"\n' "{{justfile_directory()}}" > {{bin_dir}}/nlk
    chmod +x {{bin_dir}}/nlk
    cp {{bin_dir}}/nlk {{bin_dir}}/neural_link
    @echo "Installed: {{bin_dir}}/nlk"
    @echo "Installed: {{bin_dir}}/neural_link"
    # Claude Code MCP registration (idempotent)
    claude mcp remove neural_link 2>/dev/null || true
    claude mcp add -s user -t http neural_link http://localhost:{{default_port}}/mcp
    @echo "Registered: neural_link MCP in Claude Code (http://localhost:{{default_port}}/mcp)"
    # OpenCode MCP registration (idempotent — skip if already present)
    if [ -f "{{opencode_cfg}}" ]; then \
      if jq -e '.mcp.neural_link == null' "{{opencode_cfg}}" > /dev/null 2>&1; then \
        jq '.mcp.neural_link = {"type":"http","url":"http://localhost:'"{{default_port}}"'/mcp","enabled":true}' \
          "{{opencode_cfg}}" > "{{opencode_cfg}}.tmp" && mv "{{opencode_cfg}}.tmp" "{{opencode_cfg}}"; \
        echo "Registered: neural_link MCP in OpenCode (http://localhost:{{default_port}}/mcp)"; \
      else \
        echo "Skipped: neural_link MCP already registered in OpenCode"; \
      fi; \
    else \
      echo "Skipped: OpenCode config not found at {{opencode_cfg}}"; \
    fi
    nlk start

[group('setup')]
uninstall:
    # Claude Code MCP deregistration
    claude mcp remove neural_link 2>/dev/null || true
    @echo "Removed: neural_link MCP from Claude Code"
    # OpenCode MCP deregistration (idempotent — skip if not present)
    if [ -f "{{opencode_cfg}}" ]; then \
      if jq -e '.mcp.neural_link != null' "{{opencode_cfg}}" > /dev/null 2>&1; then \
        jq 'delpaths([["mcp", "neural_link"]])' \
          "{{opencode_cfg}}" > "{{opencode_cfg}}.tmp" && mv "{{opencode_cfg}}.tmp" "{{opencode_cfg}}"; \
        echo "Removed: neural_link MCP from OpenCode"; \
      else \
        echo "Skipped: neural_link MCP not present in OpenCode"; \
      fi; \
    else \
      echo "Skipped: OpenCode config not found"; \
    fi
    rm -f {{bin_dir}}/nlk {{bin_dir}}/neural_link
    @echo "Removed: nlk and neural_link from {{bin_dir}}"

# ── Development ────────────────────────────────

[group('dev')]
build:
    gleam format
    gleam build

alias b := build

[group('dev')]
run port=default_port:
    NEURAL_LINK_PORT={{port}} gleam run -- start --foreground

# ── Testing ────────────────────────────────────

[group('test')]
test:
    gleam format
    gleam test

alias t := test

# ── Quality ────────────────────────────────────

[group('quality')]
fmt:
    gleam format

[group('quality')]
check:
    gleam format --check
    gleam build

alias c := check

# ── Hooks ──────────────────────────────────────

[group('setup')]
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    SETTINGS="$HOME/.claude/settings.json"
    SCRIPTS="{{justfile_directory()}}/scripts/hooks"
    # Ensure settings file exists
    mkdir -p "$(dirname "$SETTINGS")"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    # Hook definitions to inject
    SUBAGENT_START='{"matcher":"","hooks":[{"type":"command","command":"'"$SCRIPTS"'/subagent_start_state.sh","timeout":2000}]}'
    POST_TOOL_USE='{"matcher":"","hooks":[{"type":"command","command":"'"$SCRIPTS"'/post_tool_inbox_check.sh","timeout":2000}]}'
    # Remove any existing neural_link hooks, then add fresh ones
    # Filter matches exact script names to avoid removing unrelated hooks
    jq --argjson ss "$SUBAGENT_START" --argjson ptu "$POST_TOOL_USE" '
      def is_neural_link_hook: (.hooks[0].command // "") | test("scripts/hooks/(subagent_start_state|post_tool_inbox_check)\\.sh$");
      .hooks.SubagentStart = ((.hooks.SubagentStart // []) | map(select(is_neural_link_hook | not))) |
      .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(select(is_neural_link_hook | not))) |
      .hooks.SubagentStart += [$ss] |
      .hooks.PostToolUse += [$ptu]
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "✓ SubagentStart hook installed"
    echo "✓ PostToolUse hook installed"
    echo "  Settings: $SETTINGS"

[group('setup')]
uninstall-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    SETTINGS="$HOME/.claude/settings.json"
    [ -f "$SETTINGS" ] || { echo "No settings file found"; exit 0; }
    jq '
      def is_neural_link_hook: (.hooks[0].command // "") | test("scripts/hooks/(subagent_start_state|post_tool_inbox_check)\\.sh$");
      .hooks.SubagentStart = ((.hooks.SubagentStart // []) | map(select(is_neural_link_hook | not))) |
      .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(select(is_neural_link_hook | not))) |
      if .hooks.SubagentStart == [] then del(.hooks.SubagentStart) else . end |
      if .hooks.PostToolUse == [] then del(.hooks.PostToolUse) else . end |
      if .hooks == {} then del(.hooks) else . end
    ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    echo "✓ neural_link hooks removed from $SETTINGS"

# ── Cleanup ────────────────────────────────────

[group('dev')]
clean:
    gleam clean
