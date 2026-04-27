# Alpine Bootstrap

Minimal AI-Host Bootstrap for Alpine Linux. It configures a modern CLI
environment with container runtime, shell tooling, and SSH access. The
bootstrap also detects whether Alpine is running in an LXC or a VM so it can
apply the right guest integration behavior.

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

## Runtime detection

The bootstrap detects whether Alpine is running in an `LXC` or a `VM` before
it installs packages and enables services. In VMs, it keeps
`qemu-guest-agent`. In LXCs, it skips both installation and service
enablement.

If detection is `unknown`, the bootstrap keeps the guest-agent behavior
best-effort and unchanged. That means it does not take the LXC-specific skip
path.

## What's Installed

The bootstrap installs a container runtime, core CLI tools, and shell support.
Some guest-integration behavior changes automatically based on whether Alpine
is running inside a VM or an LXC.

**Container Runtime:** Podman (default) or Docker with Docker-compatible
socket

**Guest integration:** `qemu-guest-agent` in VMs. Alpine LXCs skip both
installation and service enablement because the QEMU Guest Agent is not
needed there.

**CLI Tools:** atuin, btop, curl, dust, eza, fzf, jq, lazydocker, nushell,
ripgrep, starship, trippy, wget, yq-go, zellij

**Shells:** Fish + Bash (both with completions for installed tools)

## Proxmox LXC configuration

If you run this bootstrap inside a Proxmox LXC, apply the required container
settings on the Proxmox host. In this environment, the working configuration is
not limited to feature flags. You must also set specific `lxc.*` keys directly
in `/etc/pve/lxc/<CTID>.conf`. After you update the host-side config, restart
the container so Proxmox applies the changes. You can do that from the Proxmox
GUI or on the host with `pct stop <CTID> && pct start <CTID>`.

Use `pct` to apply the required Proxmox feature flags.

```sh
pct set <CTID> --features nesting=1,keyctl=1
```

Then make sure `/etc/pve/lxc/<CTID>.conf` contains these lines.

```ini
lxc.apparmor.profile: unconfined
lxc.cap.drop:␠
lxc.cgroup.relative: 0
```

<!-- prettier-ignore -->
> [!IMPORTANT]
> `␠` denotes a single trailing space after `lxc.cap.drop:`.
> Proxmox accepts this blank value, and removing that space changes the
> resulting config line.

<!-- prettier-ignore -->
> [!WARNING]
> `lxc.apparmor.profile: unconfined` weakens container isolation.
> Use it only when you accept that tradeoff for this container.

### Host-side helper script

This repo includes `pct-enable-docker.sh` to apply the required Proxmox
host-side settings idempotently for a single CTID. Run this script on the
Proxmox host, not inside the Alpine container. The script validates that `pct`
recognizes the CTID, shows container metadata before making changes, and then
asks for confirmation unless you pass `-y` or `--yes`.

```sh
./pct-enable-docker.sh <CTID>
./pct-enable-docker.sh --yes <CTID>
```

The script uses `pct config <CTID>` to read container configuration, including
its hostname, and `pct status <CTID>` to show current runtime state. Then it
updates `/etc/pve/lxc/<CTID>.conf` so it contains the required `lxc.*` lines,
and it runs `pct set <CTID> --features nesting=1,keyctl=1` for you.

### Example host configuration

This example shows the effective Proxmox host configuration this bootstrap
expects for the target container.

```ini
features: nesting=1,keyctl=1
lxc.apparmor.profile: unconfined
lxc.cap.drop:␠
lxc.cgroup.relative: 0
```

### QEMU Guest Agent in LXCs

Alpine LXCs do not need `qemu-guest-agent`, so the bootstrap skips both the
package install and service enablement there.

## Idempotent

Safe to run multiple times. State is persisted to
`/etc/alpine-bootstrap/state.env`.

## Environment

Set `NO_COLOR=1` to disable colors.
