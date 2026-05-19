# termite.sh

WhatsApp your terminal.

`termite.sh` is a small `wacli` companion that lets you link one WhatsApp chat
to a local shell. Send `ls -la`, `pwd`, or a longer shell command to your
self-chat; termite executes it locally and replies with the terminal output.
Short output is batched into a single WhatsApp message. Streaming output is
flushed as it arrives.

termite uses its own capped `wacli` store at `~/.termite/wacli` by default. It is
not meant to archive WhatsApp history; it keeps only enough local message state
to route live commands.

## Install

### Homebrew

```sh
brew tap adamzafir/termite https://github.com/adamzafir/termite
brew install termite
```

### npm

```sh
npm install -g https://github.com/adamzafir/termite/releases/download/v0.1.0/adamzafir-termite-0.1.0.tgz
```

### Manual

Install [`wacli`](https://wacli.sh/) and put termite on your PATH:

```sh
brew install steipete/tap/wacli
ln -sf "$PWD/termite" "$HOME/.local/bin/termite"
```

`wacli` pairs as a WhatsApp linked device. termite uses the local `wacli` SQLite
store for inbound messages and `wacli send text` for replies.

Homebrew installs `wacli`, `jq`, and `node` for you. The npm release package
installs the `termite` command only, so install `wacli` separately before first
use:

```sh
brew install steipete/tap/wacli
```

## Usage

Run once:

```sh
termite
```

If WhatsApp is not linked yet, termite opens the QR auth flow. After linking, it
auto-binds to your own WhatsApp JID, sends a connected notice, and starts a
background daemon from your current terminal session. Starting from the terminal
matters on macOS because it lets your `.zshrc` source Desktop/Documents-based
shell tools with the same privacy permissions your terminal already has.

Message yourself commands:

```text
pwd
ls -la
for i in 1 2 3; do echo "tick $i"; sleep 1; done
```

Small command output is sent in one reply. Longer or delayed output is flushed in
chunks while the command runs. If you send another command while one is still
running, termite queues it and runs it immediately after the active command
finishes. Non-zero exits are reported as `[exit N]`.

## Commands

```sh
termite               # authenticate if needed, bind self-chat, and run
termite start         # same as termite
termite quit          # stop the background daemon
termite caffeinate    # keep the Mac awake while termite is available
termite uncaffeinate  # stop termite's caffeinate process
termite auth          # pair WhatsApp through wacli only
termite link          # bind termite to the next chat that sends the link phrase
termite run           # foreground debug runner; auto-binds self-chat if possible
termite send "text"   # send a manual message to the linked chat
termite status        # inspect local config and cursor
termite reset         # remove termite state and stop its managed sync
```

`termite caffeinate` installs a separate LaunchAgent that runs
`/usr/bin/caffeinate -dim` so it survives terminal exits. macOS may still sleep
when a laptop lid is fully closed unless the machine is in a supported
clamshell/power setup.

## Configuration

```sh
TERMITE_PREFIX="!"                    # command prefix
TERMITE_REQUIRE_PREFIX=0              # allow raw self-chat commands by default
TERMITE_LINK_PHRASE="!link termite"   # phrase used during linking
TERMITE_SHELL="$SHELL"                # command shell; zsh/bash load aliases/functions
TERMITE_TERM=xterm-256color           # TERM exposed to command shells
TERMITE_COMMAND_HOME="$HOME"          # default directory for daemon commands
TERMITE_WACLI_STORE="$HOME/.termite/wacli" # isolated wacli store
TERMITE_STATE_DIR="$HOME/.termite"    # termite state
TERMITE_POLL_INTERVAL=0.2             # message polling interval
TERMITE_FLUSH_LINES=24                # batch short output into fewer messages
TERMITE_SEND_EXIT=errors              # errors | always | never
TERMITE_AUTH_IDLE_EXIT=3s             # stop auth bootstrap soon after idle
TERMITE_AUTH_MAX_MESSAGES=1           # cap auth bootstrap history
TERMITE_SYNC_MAX_MESSAGES=0           # live sync cap; 0 means unlimited
TERMITE_SYNC_MAX_DB_SIZE=0            # live DB cap; 0 means unlimited
TERMITE_ALLOW_GROUPS=0                # refuse group chats by default
TERMITE_IGNORE_SLASH_COMMANDS=1       # ignore /commands by default
TERMITE_SEND_CONNECTED=1              # send connected notice on daemon start
TERMITE_TYPING_INDICATOR=1            # show typing while commands run
TERMITE_BACKGROUND_MODE=terminal      # terminal | launchd
TERMITE_SCREEN_SESSION=termite        # detached screen name for terminal mode
TERMITE_CAFFEINATE_LABEL=sh.termite.caffeinate # launchd label for caffeinate
```

## Safety Model

termite executes shell commands from the linked WhatsApp chat. Treat the linked
chat like SSH access to the current user account. Use a private self-chat.
Groups are refused by default. Set `TERMITE_REQUIRE_PREFIX=1` if you want to
require commands like `!pwd` instead of raw self-chat messages like `pwd`.
