<div align="center">

<pre>
 __      __  ___ __  __
 \ \ /\ / / / __|  \/  |
  \ V  V / | (_ | |\/| |
   \_/\_/   \___|_|  |_|
      WATCHDOG MANAGER
</pre>

### WG Watchdog Manager

A lightweight WireGuard recovery manager for KeeneticOS.

[![version](https://img.shields.io/badge/version-1.0.0-blue)](https://github.com/org1org/wg-watchdog/releases/latest)
![shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25)
![platform](https://img.shields.io/badge/platform-KeeneticOS%205%2B-009EE2)
![environment](https://img.shields.io/badge/environment-Entware-555555)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![CI](https://github.com/org1org/wg-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/org1org/wg-watchdog/actions/workflows/ci.yml)

[Features](#features) · [Installation](#installation) · [Usage](#usage) · [Configuration](#configuration) · [Русский](README.md)

</div>

## Features

- one independent job for each `WireguardN` interface;
- scheduled checks of the WireGuard server's tunnel address;
- restart only after a configurable number of consecutive failures;
- restart cooldown and a grace period after router boot;
- safe full-tunnel operation and an optional public reachability check;
- full-screen `wgwm` interface, manual checks and forced restart;
- recent events read directly from the KeeneticOS system log;
- transactional updates with SHA-256 verification and automatic rollback;
- runtime state stored in `/tmp` to avoid frequent writes to Entware storage.

WG Watchdog Manager never changes WireGuard keys, peers or interface settings.

## Requirements

- KeeneticOS 5 or newer;
- Entware;
- root SSH access;
- a configured WireGuard client interface.

The installer adds the `ndmq` and `cron` packages when required.

## Installation

```sh
wget -qO- https://raw.githubusercontent.com/org1org/wg-watchdog/main/install.sh | sh
```

Start the manager after installation:

```sh
wgwm
```

Select a WireGuard interface and choose **Configure watchdog**. The server tunnel
address and public Endpoint are taken from the peer configuration when available.

The program interface is currently in Russian; this README provides the complete
English usage reference.

## Usage

Each configured interface provides actions to:

- run a check immediately;
- view detailed status;
- view the latest 20 system log events;
- enable or disable its job;
- edit parameters;
- perform a confirmed forced restart;
- remove the watchdog job.

Main commands:

```sh
wgwm                 # full-screen manager
wgwm --plain         # plain text mode
wgwm --uninstall     # uninstall
```

Updates are installed from the main `wgwm` menu.

## Configuration

New jobs use these defaults:

| Setting | Default |
|---|---:|
| Check interval | 5 minutes |
| Ping requests | 3 |
| Ping timeout | 3 seconds |
| Failures before restart | 2 |
| Delay between `down` and `up` | 3 seconds |
| Post-restart check | after 15 seconds |
| Restart cooldown | 30 minutes |
| Router boot grace period | 180 seconds |

Every value can be configured independently for each interface.

### Local WireGuard port

For an outbound client tunnel, leave the **Listen port** field empty. A fixed
local port may prevent recovery after a long connection outage.

This is not the server port in Endpoint. Never remove the remote server address
or port.

## Uninstall

```sh
wgwm --uninstall
```

The manager can remove all jobs or preserve their configuration for a later
installation. Unrelated cron entries are left untouched.

## License

[MIT](LICENSE) © 2026 org1org
