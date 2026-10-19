#!/usr/bin/env bash
# Test for git bisect run: good (exit 0) if max_batch is within the API limit of 437.
batch=$(grep '^max_batch=' config.txt | cut -d= -f2)
[ -n "$batch" ] || exit 125        # can't test this commit: tell bisect to skip it
[ "$batch" -le 437 ]
