# The live cursor riding along: Claude reads and edits shop/cart.py while the
# preview split follows it and shows the edit as an inline diff.
Output live-cursor.gif

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 12
Set TypingSpeed 35ms
# vhs's default 50 frames a second drops frames and plays the clip too fast.
Set Framerate 20

Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && DEMO_PERMISSION=acceptEdits nvim -u "$DEMO_INIT" shop/cart.py`
Enter
Sleep 1500ms
Type " ac"
Wait+Screen@30s /Claude Code v/
Sleep 1500ms
Show

Type "Add a one-line docstring to every method in shop/cart.py"
# Time to read the prompt before it is sent.
Sleep 1500ms
Enter
# The CLI prints the edit's result once it has landed; the preview shows it inline.
Wait+Screen@60s /Update\(shop\/cart\.py\)/
# End hold, on the preview with the edit inline. It closes after 4s of quiet
# (`live_cursor.clear_delay_ms`), so the hold stays under that.
Sleep 3500ms
