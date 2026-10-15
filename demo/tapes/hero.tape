# The agents view: two agents at work on one project at once, beside the
# project's earlier conversations, each with what it changed.
# seed
Output hero.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 12
Set TypingSpeed 25ms
Set PlaybackSpeed 1.25
Set Framerate 20

# Off camera: open the view. It offers the newest seeded conversation, the
# release check, so the first frame shows its subagents, shells and monitor.
Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && DEMO_PERMISSION=acceptEdits nvim -u "$DEMO_INIT"`
Enter
Sleep 1500ms
Type " aA"
Wait+Screen@30s /not running/
# Longer than the key badge stays up, so the recording does not open on it.
Sleep 2500ms
Show

# Time to take in the view before anything happens.
Sleep 2500ms
# The first agent: `a` on the offer screen, its badge on screen before the cut.
# Its start-up is cut; a new agent lands on top of the list, selected, with the
# cursor in its terminal.
Type "a"
Sleep 1200ms
Hide
Wait+Screen@30s /accept edits on/
Sleep 800ms
Show
Type "Add doc comments to src/cart.rs and src/pricing.rs."
Sleep 1500ms
Enter
Sleep 2s

# Up from the top wraps to the oldest conversation; start the second agent there.
Ctrl+P
Sleep 1500ms
Type "a"
Sleep 1200ms
Hide
Wait+Screen@30s /accept edits on/
Sleep 800ms
Show
Type "Add doc comments to src/inventory.rs."
Sleep 1500ms
Enter
# Until the second agent reports, the first still at work beside it.
Wait+Screen@90s /s · done/
Sleep 1s
Screenshot hero.png
# End hold.
Sleep 3s
