# The agents view, read: it opens on a release check whose subagents ran shells
# beside a monitor, and <CR> opens what each pane lists — an edit in Activity,
# a file in Changes, a subagent in Tasks. Then <C-n> moves the selection, the
# panes following it, and `m` flags a session.
# seed: four finished conversations (demo/seed.sh), "Release check" the newest.
Output agents-switch.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 12
Set TypingSpeed 35ms
# Lower than vhs's default 50, so frame capture keeps up and the GIF plays at
# the pace the sleeps below set.
Set Framerate 20
Set PlaybackSpeed 1.2

Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && nvim -u "$DEMO_INIT"`
Enter
Sleep 1500ms
Type " aA"
Wait+Screen@30s /Release/
Wait+Screen@30s /Inventory/
Wait+Screen@30s /Member/
Wait+Screen@30s /Cart/
# Longer than the key badge stays up, so the recording does not open on it.
Sleep 2500ms
Show

# The view opens on the newest conversation: its tasks, activity and changes.
Sleep 3s

# Activity: <CR> on the newest row opens that one edit.
Tab
Sleep 600ms
Tab
Sleep 1200ms
Enter
Sleep 3500ms
Type "q"
Sleep 1200ms

# Changes: <CR> on a file shows everything the session did to it.
Tab
Sleep 1200ms
Enter
Sleep 3500ms
Type "q"
Sleep 1200ms

# Tasks: below the monitor, a subagent; <CR> opens what it did, its shell included.
# `gg` first: the pane's cursor is not always on the top row (no badge for it).
Tab
Sleep 1200ms
Type "gg"
Down
Sleep 800ms
Enter
Sleep 4s
Type "q"
Sleep 1200ms

# Back to the sessions: the next one, every pane following, then a flag.
Tab
Sleep 600ms
Tab
Sleep 1200ms
Ctrl+N
Sleep 2500ms
Type "m"
# End hold, on the flagged session.
Sleep 3s
