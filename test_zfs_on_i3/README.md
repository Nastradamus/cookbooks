##### Example

```bash
#cat ~/.ssh/config
#
#Host *.compute.amazonaws.com
#	User ubuntu
#       StrictHostKeyChecking no

export AWS_HOST="ec2-1-2-3-4.eu-central-6.compute.amazonaws.com"

for i in 1 2 3; do
  ./run.sh zfs $AWS_HOST
  ./run.sh ext4 $AWS_HOST
done

# get results in Markdown format:
cd results
./get_results.sh results/zfs_results.txt
./get_results.sh results/ext4_results.txt
```

##### Methodology (whole research)

https://gitlab.com/postgres-ai-team/postgres-checkup/issues/294#note_140020735

