# Noctalia plugins

Plugins for the [Noctalia](https://noctalia.dev) shell. Each plugin lives in its own directory with a `plugin.toml`. `catalog.toml` is the index a host uses to list what this repository ships.

## Plugins

| Directory | Id | What it shows |
| --- | --- | --- |
| [`grok-usage`](grok-usage/README.md) | `linnovs/grok-usage` | This week's Grok allowance on the bar, with the reset countdown in an attached panel |
| [`codex-usage`](codex-usage/README.md) | `linnovs/codex-usage` | ChatGPT Codex allowance left, reset countdowns, today pace, and calendar tokens |

Install a plugin from this repository in Noctalia, then add its bar widget from the bar's widget picker. `grok-usage` needs a one-time `grok login`; `codex-usage` needs ChatGPT sign-in through `codex login`. See each plugin's README for the panel, settings, and IPC commands.

## License

The repository itself is Apache License 2.0. See [LICENSE](LICENSE). Each plugin names its own license in `plugin.toml`.
