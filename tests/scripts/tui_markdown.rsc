# scripted headless markdown run (see tests/tui.sh)
# One assistant turn exercises block kinds and inline styling through the
# live streaming path (no tool card, so no full transcript rebuild).
resize 60 20
prompt show markdown
wait 400
print-screen
quit
