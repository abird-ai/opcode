# Esc aborts a busy run and returns the queue to the editor (see tests/tui.sh)
# The first prompt starts a tool run; the second enqueues.  The slash menu's
# Esc dismisses the menu only; a second Esc aborts and restores the queue.
resize 60 14
prompt run the checks
prompt keep me
print-screen
type /
key esc
key esc
wait 0
print-screen
quit
