# Alpine Bootstrap

Minimal AI-Host Bootstrap for Alpine Linux. Configures a modern CLI environment with container runtime, shell tooling, and SSH access.

## Quick Start

```sh
chmod +x alpine-bootstrap.sh
./alpine-bootstrap.sh
```

## Options

| Flag | Description |
|------|-------------|
| `--engine podman\|docker` | Select container engine (default: podman) |
| `--force-engine-switch` | Allow switching from saved engine choice |
| `--disable-testing-repos` | Disable edge/testing repositories |
| `--run-setup-apkrepos` | Run Alpine's interactive repo setup |
| `--skip-ssh-keys` | Skip GitHub SSH key bootstrap |
| `--no-bash` | Skip Bash tooling installation |
| `--no-fish` | Skip Fish shell installation |
| `--no-color` | Disable colored output |
| `--help` | Show help |

## What's Installed

**Container Runtime:** Podman (default) or Docker with Docker-compatible socket

**Guest Integration:** qemu-guest-agent

**CLI Tools:** atuin, btop, curl, dust, eza, fzf, jq, lazydocker, nushell, ripgrep, starship, trippy, wget, yq-go, zellij

**Shells:** Fish + Bash (both with completions for installed tools)

## Idempotent

Safe to run multiple times. State is persisted to `/etc/alpine-bootstrap/state.env`.

## Environment

Set `NO_COLOR=1` to disable colors.
