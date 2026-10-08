# busy submits queue and drain on idle (see tests/tui.sh)
# Turn 1 leaves the agent busy running a tool, so the next two prompts must
# enqueue instead of replacing the composer; the queue strip sits above the
# composer.  Waiting lets the run finish, after which the idle tick submits
# the queued messages in order.
resize 60 14
prompt run the checks
prompt queued one
prompt queued two
print-screen
wait 1000
print-screen
quit
