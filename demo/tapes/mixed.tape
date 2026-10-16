# Claude Code and OpenCode side by side: a Claude agent and an OpenCode agent
# at work on one project at once, in the same agents view, beside the project's
# earlier conversations; OpenCode's row is marked ◇.
# seed
Output mixed.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 12
Set TypingSpeed 25ms
Set PlaybackSpeed 1.25
Set Framerate 20

# Off camera: open the view on the seeded history, `ga` offering OpenCode.
Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && DEMO_PERMISSION=acceptEdits DEMO_OPENCODE=1 nvim -u "$DEMO_INIT"`
Enter
Sleep 1500ms
Type " aA"
Wait+Screen@30s /not running/
# Longer than the key badge stays up, so the recording does not open on it.
Sleep 2500ms
Show

Sleep 2000ms
# A Claude agent: `a` on the offer screen. Its start-up is cut.
Type "a"
Sleep 1200ms
Hide
Wait+Screen@30s /accept edits on/
Sleep 800ms
Show
Type "Add doc comments to src/cart.rs."
Sleep 1500ms
Enter
Sleep 2s

# Up from the top wraps to the oldest conversation; from there `ga` starts an
# agent under a profile, and `o` picks OpenCode. Its start-up is cut too.
Ctrl+P
Sleep 1500ms
Type "ga"
Sleep 2s
Type "o"
Sleep 1200ms
Hide
Wait+Screen@60s /Haiku 4\.5/
Sleep 800ms
Show
Type "Add doc comments to src/inventory.rs."
Sleep 1500ms
Enter
# OpenCode closes a turn with its timing line.
Wait+Screen@120s /tok\/s/
Sleep 2500ms

# Down to the Claude agent, done beside it. The still waits out the key badge.
Ctrl+N
Wait+Screen@60s /· done/
Sleep 2500ms
Screenshot mixed.png
# End hold.
Sleep 3s
