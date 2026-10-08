# scripted headless TUI run (see tests/tui.sh)
# The shrink-then-grow resize exercises grid_resize's row copy in both
# directions (the growth path used to read past the old grid).
#
# The composer is two full-width rules bracketing the input; the empty input
# shows the placeholder and there is no "> " marker.  A leading "/" opens the
# slash-command menu (fullscreen: above the composer).
resize 60 14
print-screen
type /
print-screen
key down
print-screen
key enter
wait 200
print-screen
key esc
type hello world
print-screen
resize 30 6
print-screen
resize 60 14
print-screen
prompt run the checks
wait 400
print-screen
quit
