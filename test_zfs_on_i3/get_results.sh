#!/bin/bash

# Get results of pgbench in markdown

set -eu -o pipefail

INPUT_FNAME="$1"

OUT=$(grep -e "latency average =" -e "xcluding connections establishing" ${INPUT_FNAME})

# echo "$OUT" | grep -o -E [0-9]+\.[0-9]+

echo "latency|TPS"
echo "-------|---"

while read -r line; do
  if [[ "$line" =~ "latency average" ]]; then
    echo -n "$line" | grep -o -E [0-9]+\.[0-9]+ | tr -d '\n'
    echo -n "|"
  elif [[ "$line" =~ "xcluding connections establishing" ]]; then
    echo -n "$line" | grep -o -E [0-9]+\.[0-9]+
  fi
done <<<"${OUT}"
