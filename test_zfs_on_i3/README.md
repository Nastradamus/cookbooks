##### Example

```bash
export AWS_HOST="ec2-1-2-3-4.eu-central-6.compute.amazonaws.com"

./run.sh zfs $AWS_HOST
./run.sh ext4 $AWS_HOST
```

Results are saved at `./results/zfs_results_timed.csv` or `./results/ext4_results_timed.csv`

##### Methodology (whole research)

- Results and methodology: https://gitlab.com/postgres-ai-team/nancy/issues/184
- Main task: https://gitlab.com/postgres-ai-team/nancy/issues/169


