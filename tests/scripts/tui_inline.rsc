# Owned inline region (S7): resize, submit a turn, resize mid-turn, quit.
# Run with --headless-capture so the raw region/commit bytes can be asserted.
resize 60 10
prompt run the checks
wait 300
resize 40 10
wait 300
quit
