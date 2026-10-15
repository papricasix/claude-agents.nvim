# Reviewing an edit in the editor: Claude proposes a change to src/cart.rs, it
# opens as an inline diff in the window beside the terminal, and :w accepts it.
Output diff-accept.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 12
Set TypingSpeed 35ms
# vhs captures well under its default 50 frames a second here and plays what it
# got at full rate, so the clip ran ~1.7x fast; at 20 the sleeps below are real.
Set Framerate 20

# Edits ask for approval, so they go through the editor's diff.
Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && DEMO_PERMISSION=default nvim -u "$DEMO_INIT" src/cart.rs`
Enter
Sleep 1500ms
Type " ac"
Wait+Screen@30s /Claude Code/
Sleep 2s
Show

Sleep 1s
Type@25ms "Rename the method total to subtotal in src/cart.rs only"
# Time to read the prompt before it is sent.
Sleep 1500ms
Enter
Sleep 1s

# The model reads the file and proposes the edit: the diff takes the editor
# window, focus moves into it, and the terminal's question names the editor.
Hide
Wait+Screen@90s /Opened changes in/
Sleep 600ms
Show
# Time to read the proposal, then `:w` typed, held, and run.
Sleep 3s
Type ":w"
Sleep 1200ms
Enter
# The window shows the accepted file at once; Claude writes it and reports.
Sleep 2500ms
Hide
Wait+Screen@120s /s · done/
Sleep 500ms
Show
# End hold, on the accepted file and Claude's report.
Sleep 3s
