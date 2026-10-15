# One Claude beside your code: the live cursor follows it through the files it
# reads, then its edit opens as an inline diff in the editor and :w accepts it.
Output editor.gif

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
Wait+Screen@30s /Claude Code v/
Sleep 2s
Show

Sleep 1s
# Two files read, so the preview moves between them (left to itself the model
# may grep for with_tax instead). The full path keeps the change to one edit:
# with an import it would be two diffs to accept.
Type@25ms "Read src/pricing.rs, then make Cart::total in src/cart.rs return the total with tax, calling crate::pricing::with_tax by its full path"
# Time to read the prompt before it is sent.
Sleep 1500ms
Enter

# The reads, on camera: the preview split below the file follows each one. The
# edit then opens as a diff in the editor window, focus moves into it, and the
# terminal's question names the editor.
Wait+Screen@90s /Opened changes in/
Sleep 600ms
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
