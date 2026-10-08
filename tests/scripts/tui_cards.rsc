# tool cards: running spinner, finished ok/err cards, collapse/expand and the
# "... (+N lines)" marker, over a deterministic replay (see tests/tui.sh).
# Turn 1 is an unknown tool (err card), turn 2 a slow five-line bash command
# (running card, then a collapsed body), turn 3 the closing text.
resize 60 20
prompt run the checks
wait 300
print-screen
wait 2000
print-screen
key ctrl-o
print-screen
quit
