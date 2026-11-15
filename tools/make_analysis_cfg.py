#!/usr/bin/env python3
"""Build engine/analysis.cfg from KataGo's analysis_example.cfg.

Copy the example and set these keys (add if absent,
replace if present). Everything else keeps KataGo's own documented defaults.
"""
import re
import sys

SRC = "engine/analysis_example.cfg"
DST = "engine/analysis.cfg"

REQUIRED = {
    # The whole app reads winrate/scoreLead from Black's point of view.
    "reportAnalysisWinratesAs": "BLACK",
    # Ko/superko must be judged against the whole game, not just after the root.
    "ignorePreRootHistory": "false",
    "numAnalysisThreads": "2",
    "numSearchThreadsPerAnalysisThread": "8",
    "nnMaxBatchSize": "16",
    # Startup chatter goes to stderr; the app drains it into a log view.
    "logToStderr": "false",
}

# Nothing else is tuned: the example's own defaults are kept for everything the
# script does not set, so a GPU box and this CPU box share one config.


def main() -> int:
    overrides = dict(REQUIRED)
    lines = open(SRC, encoding="utf-8").read().splitlines()
    seen = set()
    out = []
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.*)$", line.strip())
        if m and m.group(1) in overrides:
            key = m.group(1)
            out.append("%s = %s" % (key, overrides[key]))
            seen.add(key)
        else:
            out.append(line)
    header = [
        "# KataGo analysis-engine config for go_game.",
        "# Generated from analysis_example.cfg by tools/make_analysis_cfg.py.",
        "# Keys the app relies on are set below; per-query settings sent by the",
        "# app (maxVisits, includeOwnership, ...) override these defaults.",
    ]
    missing = sorted(set(overrides) - seen)
    tail = ["", "# Added because they are absent from the example:"]
    for key in missing:
        tail.append("%s = %s" % (key, overrides[key]))
    text = "\n".join(header + out + tail) + "\n"
    open(DST, "w", encoding="utf-8").write(text)
    print("wrote %s (%d bytes), set %d keys, added %d" % (DST, len(text), len(seen), len(missing)))
    for key in sorted(overrides):
        where = "replaced" if key in seen else "added"
        print("  %-34s %-8s %s" % (key, overrides[key], where))
    return 0


if __name__ == "__main__":
    sys.exit(main())
