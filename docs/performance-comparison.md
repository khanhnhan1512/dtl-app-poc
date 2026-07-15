# Performance Comparison: DTL App vs Chrome

## Metrics and method

There are two things to look at: how much memory each browser uses, and how much CPU each one uses while idle.

Memory is measured as PSS (Proportional Set Size). A browser does not run as a single process. Both Chrome and DTL App are built on Chromium and split into a main process, one process per page, a GPU process, and a few helpers. PSS is the total memory across all of those processes, and it splits shared memory fairly between them instead of counting it once per process, so the total is not inflated. It is read straight from the kernel:

```bash
for pid in $(pgrep -f chrome); do
  awk '/^Pss:/ {s+=$2} END {print s}' /proc/$pid/smaps_rollup
done | awk '{t+=$1} END {printf "%.0f MB\n", t/1024}'
```

Idle CPU is the percentage of CPU the app uses when it is open but nobody is touching it. This shows whether the app keeps working in the background and drains battery. It is averaged over ten one-second samples taken with no interaction:

```bash
for i in $(seq 10); do
  top -b -n 1 | grep -i chrome | awk '{s+=$9} END {print s+0}'
  sleep 1
done | awk '{sum+=$1; n++} END {printf "%.1f%%\n", sum/n}'
```

The two commands above measure Chrome. Replacing `chrome` with `dtl-app` in the `pgrep` and `grep` gives the same measurements for DTL App.

Each figure was taken under the same conditions: after the page had finished loading and the app had been left idle for about 30 seconds.

## Results

### Memory

Each browser opened a single `tool-1` page from a clean start, on the same VM. The figures are PSS, measured three times each:

| | Run 1 | Run 2 | Run 3 | Average |
|---|---|---|---|---|
| DTL App | 250 MB | 249 MB | 249 MB | ~249 MB |
| Chrome | 453 MB | 452 MB | 452 MB | ~452 MB |

DTL App is the lighter of the two, using a little over half of what Chrome uses for the same page.

That looks odd at first, because DTL App runs on Chromium just as Chrome does. The difference is that DTL App is stripped down to a single locked page, without the tabs, extensions, and background services a full browser like Chrome keeps running. It is the same engine underneath, running a smaller configuration.

### CPU when idle

Idle CPU was measured with both apps open on `tool-1` and no interaction, averaged over ten seconds:

| | Idle CPU |
|---|---|
| DTL App | 0.0% |
| Chrome | 0.0% |

Both sit at zero. A web app does nothing while the user is not interacting with it, so neither one runs in the background using CPU or draining battery.