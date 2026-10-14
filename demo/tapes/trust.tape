# Not a shot: accept Claude Code's "trust this folder" question for the demo
# project once, so it never appears in a recording. render.sh runs it before
# the shots. Harmless when the folder is already trusted: Down and Enter then
# land on an empty prompt, which submits nothing.
Output trust.gif

Set Shell "bash"
Set Width 1000
Set Height 600

Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && claude --setting-sources project,local --strict-mcp-config --model haiku`
Enter
Sleep 6s
Down
Enter
Sleep 3s
Ctrl+C
Ctrl+C
Sleep 1s
# vhs refuses a recording with no visible frame at all
Show
Sleep 100ms
