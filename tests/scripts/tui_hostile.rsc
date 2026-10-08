# Hostile scrollback capture: a tool card whose name and argument preview carry
# terminal escapes must never reach stdout as raw ESC/OSC/C1 (see tests/tui.sh).
resize 60 14
prompt hostile
wait 800
quit
