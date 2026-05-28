# zyouz

A terminal multiplexer driven by a static config file.

zyouz splits your terminal into multiple panes using a declarative layout
defined in a single config file. No tabs, no session management, no plugins —
just panes.

## Install

### Homebrew

```sh
brew install YutaUra/tap/zyouz
```

### Nix

```sh
nix profile install github:YutaUra/zyouz
```

Or run without installing:

```sh
nix run github:YutaUra/zyouz
```

#### Home Manager

```nix
{
  inputs.zyouz.url = "github:YutaUra/zyouz";

  # In your home-manager configuration:
  imports = [ zyouz.homeModules.default ];

  programs.zyouz = {
    enable = true;
    config = ''
      .{
          .layouts = .{
              .{
                  .name = "default",
                  .root = .{ .command = .{"/bin/bash"} },
              },
          },
      }
    '';
  };
}
```

### Build from source

Requires [Zig](https://ziglang.org/) 0.15.2 or later.

```sh
git clone https://github.com/yutaura/zyouz.git
cd zyouz
zig build -Doptimize=ReleaseSafe
```

The binary is at `./zig-out/bin/zyouz`.

## Usage

```sh
zyouz              # use the "default" layout
zyouz dev           # use a named layout
zyouz --help        # show usage
zyouz --version     # show version
```

## Configuration

Config file location: `~/.config/zyouz/config.zon`

Override with the `ZYOUZ_CONFIG` environment variable.

### Minimal example

```zig
.{
    .layouts = .{
        .{
            .name = "default",
            .root = .{ .command = .{"/bin/bash"} },
        },
    },
}
```

### Split layout

```zig
.{
    .layouts = .{
        .{
            .name = "default",
            .root = .{
                .direction = .horizontal,
                .children = .{
                    .{
                        .command = .{ "nvim", "." },
                        .size = .{ .percent = 60 },
                        .mouse = .passthrough,
                        .name = "editor",
                    },
                    .{
                        .direction = .vertical,
                        .children = .{
                            .{
                                .command = .{ "npm", "run", "dev" },
                                .restart = .on_failure,
                                .name = "server",
                            },
                            .{ .command = .{"/bin/bash"}, .name = "shell" },
                        },
                    },
                },
            },
        },
    },
}
```

### Global options

| Option | Default | Description |
|--------|---------|-------------|
| `prefix_key` | `"ctrl-s"` | Key to enter command mode |
| `pane_gap` | `1` | Space between panes (cells) |
| `keymaps` | *(defaults)* | Custom key-action bindings (see [Keybindings](#keybindings)) |
| `exit_on_focus_change` | `false` | Exit command mode after moving focus |

### Pane options

| Option | Default | Description |
|--------|---------|-------------|
| `command` | *(required)* | Command and arguments |
| `name` | `null` | Label shown in pane border |
| `size` | `.equal` | `.equal`, `.{ .percent = N }`, or `.{ .fixed = N }` |
| `mouse` | `.capture` | `.capture` or `.passthrough` |
| `restart` | `.never` | `.never` or `.on_failure` |

### Split options

| Option | Default | Description |
|--------|---------|-------------|
| `direction` | *(required)* | `.horizontal` or `.vertical` |
| `children` | *(required)* | Array of child panes |
| `size` | `.equal` | Same as pane size |

## Keybindings

All input is forwarded to the focused pane. Press the **prefix key**
(`Ctrl+S` by default) to enter command mode.

### Default bindings

| Key | Action |
|-----|--------|
| `←` `↓` `↑` `→` | Move focus to adjacent pane |
| `Ctrl+Q` | Quit |
| *prefix key* | Send the prefix key itself to the pane |
| *any other key* | Exit command mode and forward to pane |

Arrow keys stay in command mode so you can press multiple directions in a row.

### Custom bindings

Override command-mode keybindings with the `keymaps` option.
Accepts: `ctrl-{a-z}`, `up`, `down`, `left`, `right`.

```zig
.{
    .prefix_key = "ctrl-s",
    .keymaps = .{
        .{ .key = "ctrl-q", .action = "quit" },
        .{ .key = "ctrl-h", .action = "focus_left" },
        .{ .key = "ctrl-j", .action = "focus_down" },
        .{ .key = "ctrl-k", .action = "focus_up" },
        .{ .key = "ctrl-l", .action = "focus_right" },
    },
    .layouts = .{ ... },
}
```

>[!WARNING]
>When `keymaps` is set, only the listed bindings apply - no defaults!
>Omit `keymaps` entirely to keep the default arrow-key bindings.

### Mouse

- Click a pane to focus it.
- Drag a border to resize panes.
- Scroll wheel scrolls pane history (unless mouse is set to passthrough).

## Building

```sh
zig build              # debug build
zig build test         # run all tests
zig build run          # build and run
zig build run -- dev   # build and run with a named layout
```
