# Scrollback Ctrl+O: the last finished card is the tail output, so toggling
# must erase its printed rows and reprint it expanded (see tests/tui.sh).
resize 60 20
prompt run the checks
wait 1500
key ctrl-o
wait 200
quit
