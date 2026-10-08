# sticky-bottom vs anchored scroll: turn 2 keeps the agent busy with a slow
# multi-line bash tool, so a headless script can page up while content grows.
# The first dump is pinned to the bottom (running card), the second is after
# PgUp (anchored), and the third after the card finishes must keep the same
# reading position rather than snapping back to the bottom.
resize 40 8
prompt run the checks
wait 300
print-screen
key pgup
print-screen
wait 2200
print-screen
quit
