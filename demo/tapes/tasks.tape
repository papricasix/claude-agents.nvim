# The Tasks pane, live: an agent runs /release-check (a monitor and three
# subagents, one of them building the crate in the background), and <CR> opens
# a running subagent and then the build, each following along as it works.
Output tasks.gif

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

# Off camera: open the view on the empty project and start an agent. The agent
# may run shells, start subagents and a monitor; tool search is off, or the
# Monitor tool is loaded with a ToolSearch call first.
Hide
Type `cd "$DEMO_PROJECT" && export PATH="$DEMO_PATH" && clear && ENABLE_TOOL_SEARCH=false DEMO_PERMISSION=acceptEdits DEMO_TOOLS=Agent,Bash,Monitor,Read nvim -u "$DEMO_INIT"`
Enter
Sleep 1500ms
Type " aA"
Wait+Screen@30s /in this project yet/
Type "a"
Wait+Screen@30s /accept edits on/
# Longer than the key badge stays up, so the recording does not open on it.
Sleep 2500ms
Show

Sleep 1s
Type "/release-check"
# Time to read the command's description in the CLI's menu.
Sleep 1500ms
Enter
# The model's start is cut: until all three subagents are listed in Tasks.
Hide
Wait+Screen@90s /Review the cart/
Sleep 300ms
Show
# Until the build's shell is listed under the subagent that started it: the
# rows below it move down when it appears, and the keys below count rows.
Wait+Screen@60s /\$ Release build/
Sleep 1500ms

# Out of the terminal and round to the Tasks pane.
Ctrl+\
Ctrl+N
Sleep 700ms
Tab
Sleep 350ms
Tab
Sleep 350ms
Tab
Sleep 350ms
Tab
Sleep 900ms

# The subagent testing the pricing, below the monitor, the build and its shell:
# its calls as it makes them, until it is done.
Type "gg"
Down
Down
Down
Sleep 700ms
Enter
Wait+Screen@60s /· ✓ done/
Sleep 1500ms
Type "q"
Sleep 900ms

# The release build, above it under the subagent that started it: the output
# as it streams, to its last line.
Up
Sleep 700ms
Enter
# (The header shows the command itself, so its last word is no sign of the end;
# the status line is.)
Wait+Screen@90s /✓ exit 0/
Sleep 2s
Type "q"
Sleep 1200ms

# Back into the agent's terminal, which follows its output again, for the
# summary once every task has ended.
Type "i"
Wait+Screen@90s /Release check done/
# End hold.
Sleep 3s
