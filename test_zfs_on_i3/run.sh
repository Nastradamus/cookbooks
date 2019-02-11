#!/bin/bash
# Provision script for i3 AWS nodes with NVME

# prepare server for ZFS or EXT4
# install postgres 
# tune postgres config for pgbench
# init 117GB dataset for pgbench
# run pgbench for 10 minutes

FSTYPE="$1"
TARGET_HOST="$2"

if [ -z "$FSTYPE" ] || [ -z "$TARGET_HOST" ]; then
  echo "USAGE: ./run fstype host" >&2
  exit 1
fi

date > results/${FSTYPE}.log
echo "####################" > "results/${FSTYPE}.log"

scp provision_and_test.sh ${TARGET_HOST}: 

ssh $TARGET_HOST "sudo ./provision_and_test.sh ${FSTYPE}" 2>&1 | tee -a "results/last.log"

echo "Saving artifacts..."
mkdir -p ./results >/dev/null 2>&1 || true
echo  >> "./results/${FSTYPE}_results.txt"
echo "############### pgbench ###############" >> "./results/${FSTYPE}_results.txt"
echo  >> "./results/${FSTYPE}_results.txt"

ssh ${TARGET_HOST} "cat /home/ubuntu/artifacts/pgbench_results.txt" >> "./results/${FSTYPE}_results.txt"


