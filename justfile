# neural_link — multi-agent coordination service
# ──────────────────────────────────────────────

default_port := "8080"
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
    ln -sf {{justfile_directory()}}/build/erlang-shipment/entrypoint.sh {{bin_dir}}/nlk
    ln -sf {{justfile_directory()}}/build/erlang-shipment/entrypoint.sh {{bin_dir}}/neural_link
    @echo "Installed: {{bin_dir}}/nlk → entrypoint.sh"
    @echo "Installed: {{bin_dir}}/neural_link → entrypoint.sh"

[group('setup')]
uninstall:
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
