#!/usr/bin/env python3
"""Prints train.py arguments from train_config.json (the workflow passes them through).
`python train_args.py stages` prints just the number of 6-hour training stages."""
import json
import os
import sys

c = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "train_config.json")))
t = c["train"]
if len(sys.argv) > 1 and sys.argv[1] == "stages":
    print(t.get("stages", 1))
elif len(sys.argv) > 1 and sys.argv[1] == "chunks_run":
    print(c["chunks_run"])
else:
    args = [f"--{k} {v}" for k, v in t.items()]
    args.append(f"--budget_hours {t['hours'] * t.get('stages', 1)}")
    print(" ".join(args))
