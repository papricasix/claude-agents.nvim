#!/usr/bin/env bash
# Give the demo project a history: three finished conversations that each
# changed something, and a release check whose subagents ran background shells
# beside a monitor, so the agents view opens on real titles, counts, activity
# and tasks. Runs a real `claude` (haiku), all four at once.
#
# Usage: seed.sh <project-dir>

set -euo pipefail

dir="${1:?usage: seed.sh <project-dir>}"
cd "$dir"

# The prompt goes before the options: a trailing prompt is swallowed by the
# variadic --allowedTools. Stdin is closed, or print mode waits three seconds
# for input whenever it is a pipe.
run() {
  local name="$1" prompt="$2"
  claude -p "$prompt" --name "$name" --model haiku \
    --setting-sources project,local --strict-mcp-config \
    --permission-mode acceptEdits --allowedTools "Read,Edit,Write" --disallowedTools "Bash" \
    </dev/null >/dev/null
}

# The release check fills the Tasks pane: a monitor, and two subagents that each
# start a background shell. It runs interactively, in a pty: print mode writes a
# subagent's transcript without the tool results' `toolUseResult` (measured
# against CLI 2.1.299), and with it the `backgroundTaskId` that tells a
# background shell from a quick one, so the shells would be missing from the tree.
#
# An interactive CLI never exits by itself. The driver below stops it once the
# conversation is over: the main thread has ended its turn, every background
# task and subagent it or a subagent started has reported its end (so each row
# reads done, not stopped), and nothing has been written for a few seconds. It
# fails, and with it the seeding, if that takes longer than a few minutes.
#
# The prompt lifts the project's no-commands rule (CLAUDE.md) for these commands
# alone, and the model is offered only the tools the check needs, the commands
# allowed by prefix. Tool search is off: the Monitor tool is otherwise loaded
# with a ToolSearch call first, an extra row in Activity.
release_check() {
  ENABLE_TOOL_SEARCH=false python3 -I - claude "$1" --name "Release check" --model haiku \
    --setting-sources project,local --strict-mcp-config \
    --permission-mode acceptEdits --tools "Agent,Bash,Monitor,Read,Edit,Write" \
    --allowedTools "Agent,Monitor,Read,Edit,Write,Bash(sleep *),Bash(cargo *),Bash(echo *)" <<'PY'
import fcntl, glob, json, os, pty, re, select, signal, struct, sys, termios, time, uuid

QUIET_S, LIMIT_S = 5, 180
sid = str(uuid.uuid4())
argv = sys.argv[1:] + ["--session-id", sid]
store = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ["HOME"], ".claude")


def entries(path):
    with open(path) as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                pass


def finished():
    found = glob.glob(os.path.join(store, "projects", "*", sid + ".jsonl"))
    if not found:
        return False
    main = found[0]
    paths = [main] + glob.glob(os.path.join(main[: -len(".jsonl")], "subagents", "*.jsonl"))
    try:
        if time.time() - max(os.stat(p).st_mtime for p in paths) < QUIET_S:
            return False
    except OSError:
        return False
    launched, ended, last = set(), set(), None
    for path in paths:
        for entry in entries(path):
            result = entry.get("toolUseResult")
            if isinstance(result, dict):
                for key in ("backgroundTaskId", "taskId"):
                    if isinstance(result.get(key), str):
                        launched.add(result[key])
                if result.get("status") == "async_launched" and isinstance(result.get("agentId"), str):
                    launched.add(result["agentId"])
            text = entry.get("content") if entry.get("type") == "queue-operation" else None
            if text is None and entry.get("type") == "user":
                text = entry.get("message", {}).get("content")
            # A subagent that finished its reply while a shell of its own runs on
            # says so with a status too; it has not ended.
            if isinstance(text, str) and "<status>" in text and "waiting on its own background work" not in text:
                ended.update(re.findall(r"<task-id>([^<]+)</task-id>", text))
            if path == main and entry.get("type") == "assistant":
                last = entry
    return last is not None and last.get("message", {}).get("stop_reason") == "end_turn" and launched <= ended


pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

screen, done, start = b"", False, time.time()
while time.time() - start < LIMIT_S:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            break
        screen = (screen + data)[-8192:]
    if finished():
        done = True
        break

os.kill(pid, signal.SIGTERM)
deadline = time.time() + 10
while not os.waitpid(pid, os.WNOHANG)[0]:
    if time.time() >= deadline:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        break
    try:
        if select.select([fd], [], [], 0.2)[0]:
            os.read(fd, 65536)
    except OSError:
        time.sleep(0.2)

if not done:
    text = re.sub(r"\x1b\[[0-9;?<>=]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b.", "", screen.decode("utf-8", "replace"))
    tail = [line.strip() for line in re.split(r"[\r\n]+", text) if line.strip()][-15:]
    sys.stderr.write("seed.sh: the release check did not finish; its screen ended with:\n" + "\n".join(tail) + "\n")
    sys.exit(1)
PY
}

run "Cart: remove items" \
  "Add a remove_item(&mut self, sku: &str) method to Cart in src/cart.rs. Change nothing else." &
sleep 2
run "Member discount" \
  "Add a member_discount(amount: f64) -> f64 function to src/pricing.rs that takes 10% off. Change nothing else." &
sleep 2
run "Inventory tests" \
  "Write tests/inventory.rs with tests for Inventory::reserve in src/inventory.rs, including the not-enough-stock error." &
sleep 2
# Started last and by far the slowest (about twenty seconds against ten), so it
# is the newest conversation of the four: the top row, and the one the view
# opens on.
release_check "Release check for acme-shop. For this task the monitor and the subagents may run the shell commands written below, although CLAUDE.md says not to run commands; run no others, do not change them, and run no command yourself. Steps, in order:

1. Start exactly one monitor: with the Monitor tool, description \"Release checklist\", watch this command: for i in 1 2 3; do echo \"check \$i\"; sleep 1; done
2. In one message, launch two general-purpose subagents with the Agent tool, each with run_in_background set to true, with exactly these descriptions and prompts:
   - description \"Compile the package\", prompt: \"Run this command with the Bash tool, with run_in_background set to true and the description 'Check the crate': sleep 1 && cargo check -q && echo checked. Then read src/cart.rs, then read src/inventory.rs. If the command has not finished by then, reply only with: Waiting for the crate check. Once you are notified that it finished, reply in one line with how it ended. Run no other commands.\"
   - description \"Smoke-test pricing\", prompt: \"Run this command with the Bash tool, with run_in_background set to true and the description 'Price a cart': sleep 2 && cargo test -q --lib pricing. Then read src/pricing.rs, then read tests/cart.rs. If the command has not finished by then, reply only with: Waiting for the price check. Once you are notified that it finished, reply in one line with how it ended. Run no other commands.\"
3. Wait for the subagents without calling any tool (no sleep, no second monitor); their reports arrive on their own. When both have reported that they finished, create CHANGELOG.md (it does not exist yet) with a \"## 1.0.0\" heading and one bullet per check, and edit README.md to add the line \"Current release: 1.0.0 (see CHANGELOG.md).\" after its description. Then reply with one short line." &
release=$!
status=0
wait "$release" || status=$?
wait
exit "$status"
