# neural_link — multi-agent coordination service
# ──────────────────────────────────────────────

default_port := "9961"
bin_dir := env("HOME") / "bin"

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
    claude mcp remove neural_link 2>/dev/null || true
    claude mcp add -s user -t http neural_link http://localhost:{{default_port}}/mcp
    @echo "Registered: neural_link MCP (http://localhost:{{default_port}}/mcp)"

[group('setup')]
uninstall:
    claude mcp remove neural_link 2>/dev/null || true
    rm -f {{bin_dir}}/nlk {{bin_dir}}/neural_link
    @echo "Removed nlk and neural_link from {{bin_dir}}"

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

# ── Cleanup ────────────────────────────────────

[group('dev')]
clean:
    gleam clean
