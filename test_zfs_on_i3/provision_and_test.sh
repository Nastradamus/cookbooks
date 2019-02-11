#!/bin/bash

# only for i3 AWS instances (with NVME)
# copy to server and run as root

export DEBIAN_FRONTEND=noninteractive
export PG_SERVER_VERSION=11

alias pgbench="/usr/lib/postgresql/${PG_SERVER_VERSION}/bin/pgbench"

re="^(ext4|zfs)"
if ! [[ "$1" =~ $re ]]; then
  echo "ERROR: first argument should be 'zfs' or 'ext4'" >&2
  exit 1
else
  FSTYPE="$1"
fi

set -eux -o pipefail

# wait apt-get or dpkg
wait_apt() {
  while $(ps auxww | grep -e "dpkg" -e "apt-" | grep -v grep >/dev/null 2>&1); do
    echo "WARNING: waiting apt-get or dpkg..."
    sleep 1
  done
}

setup_repo() {
  wait_apt
  if $(apt-cache search postgresql-$PG_SERVER_VERSION | grep postgres >/dev/null); then
    # exit if needed version found
    return 0
  fi
  echo "Setup apt repository..."
  wait_apt
  apt-get update
  apt-get install -y wget ca-certificates
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
  echo "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main $PG_SERVER_VERSION" > /etc/apt/sources.list.d/pgdg.list
  apt-get update
  echo OK
}

stop_kill_postgres() {
  if $(ps auxww | grep postgres | grep -v grep >/dev/null); then
    echo "Stopping Postgres" 
    killall postgres
    sleep 5
  fi
  if $(ps auxww | grep postgres | grep -v grep >/dev/null); then
    echo "Can't just stop. Killing..."
    echo "Killing Postgres" 
    killall -s 9 postgres
    sleep 5
  fi
  if $(ps auxww | grep postgres | grep -v grep >/dev/null); then
    echo "ERROR: can't stop postgres."
    exit 2
  fi
  echo OK
}

reset_state() {
  # First, kill postgress
  stop_kill_postgres

  # Destroy zfs/ext4, clear disk
  if $(zpool list | grep zpool >/dev/null); then
    echo "Destroying zfs pool..."
    zfs unmount -f /mnt/postgresql
    zpool destroy -f zpool
    echo OK
  fi
  if $(mount | grep nvme >/dev/null); then
    echo "Unmounting ext4..."
    umount -f /dev/nvme0n1
    echo OK
  fi

  # clear fs
  echo "Wiping fs..."
  wipefs -f -a /dev/nvme0n1
  echo OK

  if [[ -e "/var/lib/postgresql" ]] || [[ -h "/var/lib/postgresql" ]]; then
    echo "Clearing Postgres directory..."
    rm -rf /var/lib/postgresql
    echo OK
  fi

  # drop all caches
  echo "Dropping caches..."
  echo 3 > /proc/sys/vm/drop_caches
  echo OK
}

general_tuning() {
  # Set scaling_governor to performance mode
  echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
  # Disable swap
  echo 0 > /proc/sys/vm/swappiness
}

prepare_zfs() {
  # build kernel modules (takes ~5-10 minutes)
  #wait_apt
  #apt-get update
  #apt-get install -y zfsutils-linux zfs-dkms # consumes 5 minutes on i3.large

  rm -rf /mnt/postgresql >/dev/null 2>&1 || true

  # create slightly tuned zfs pool and filesystem
  zpool create -O compression=on -O atime=off -O recordsize=8k -m /mnt/postgresql zpool /dev/nvme0n1
  
  # limit ARC cache to 20GB:
  echo "21474836480" > /sys/module/zfs/parameters/zfs_arc_max
}

prepare_ext4() {
  echo "Making ext4 fs..."
  mkfs.ext4 /dev/nvme0n1
  echo OK

  rm -rf /mnt/postgresql >/dev/null 2>&1 || true
  mkdir -p /mnt/postgresql

  echo "Mounting..."
  mount -o noatime \
        -o data=writeback \
        -o barrier=0 \
        -o nobh \
        /dev/nvme0n1 /mnt/postgresql
  echo OK

  # Tune scheduler for SSD
  echo "Setting scheduler to noop..."
  echo "noop" > /sys/block/nvme0n1/queue/scheduler
  echo OK
}

prepare_postgres() {

  # put postgres into new FS
  ln -s /mnt/postgresql /var/lib/postgresql

  # make fake dir for apt-get purge if directory was deleted on previous steps
  if $(id postgres >/dev/null 2>&1); then
    mkdir -p "/var/lib/postgresql/${PG_SERVER_VERSION}/main" || true
    chown -R postgres:postgres "/var/lib/postgresql/${PG_SERVER_VERSION}"
  fi
  
  # purge
  wait_apt
  apt-get -y purge postgresql-${PG_SERVER_VERSION} || true

  # install postgres (re-init)
  wait_apt
  apt-get install -y postgresql-${PG_SERVER_VERSION}
  stop_kill_postgres

  # prepare config:
  echo "
data_directory = '/var/lib/postgresql/${PG_SERVER_VERSION}/main'
hba_file = '/etc/postgresql/${PG_SERVER_VERSION}/main/pg_hba.conf'
ident_file = '/etc/postgresql/${PG_SERVER_VERSION}/main/pg_ident.conf'
external_pid_file = '/var/run/postgresql/${PG_SERVER_VERSION}-main.pid'
listen_addresses = '*'
logging_collector = off
log_destination = 'csvlog'
max_connections = 800
fsync = on
ssl = off
autovacuum = off
shared_buffers = 11GB
work_mem = 64MB
effective_cache_size = 64GB
wal_level = minimal
full_page_writes = off
wal_log_hints = off
checkpoint_timeout = 120min
max_wal_size = 40GB
min_wal_size = 10GB
checkpoint_completion_target = 1.0
hot_standby = off
max_wal_senders = 0
# vacuum tuning (for speed up dataset creation)
maintenance_work_mem = 2GB
vacuum_cost_delay = 1ms
vacuum_cost_page_hit = 1
vacuum_cost_page_miss = 10
vacuum_cost_page_dirty = 1
vacuum_cost_limit = 1700
" > /etc/postgresql/${PG_SERVER_VERSION}/main/postgresql.conf

  echo "local   all all trust" > /etc/postgresql/$PG_SERVER_VERSION/main/pg_hba.conf
  echo "host all  all    0.0.0.0/0  md5" >> /etc/postgresql/$PG_SERVER_VERSION/main/pg_hba.conf

  pg_ctlcluster ${PG_SERVER_VERSION} main start

  echo "Waiting while postgres starts..."
  sleep 5

  psql -Upostgres -d postgres -c "select" >/dev/null
  echo "Postgres is running"
}

prepare_bench_dataset() {
  echo "prepare test database for pgbench"
  psql -Upostgres -d postgres -c "create database test"
  psql -Upostgres -d postgres -d test -c "alter system set fsync TO 'off'"
  echo "Creating dataset ~120GB..."
  pgbench -U postgres -d test -s 8000 -i > /var/log/postgresql/pgbench_create.log 2>&1 || echo "ERROR: pgbench -i failed"
  echo "Dataset was created"
  psql -Upostgres -d postgres -d test -c "alter system set fsync TO 'on'"
  psql -Upostgres -f - <<EOF
\l+ test
EOF
  echo "Ready for pgbench!"
}

run_bench() {

  echo "################### BENCHMARK ####################"
  pg_ctlcluster ${PG_SERVER_VERSION} main stop -m f
  sleep 3
  pg_ctlcluster ${PG_SERVER_VERSION} main start
  sleep 3
  echo 3 > /proc/sys/vm/drop_caches
  mkdir -p "/home/ubuntu/artifacts" >/dev/null 2>&1 || true
  echo "Running benchmark... for 10 minutes"
  #pgbench -j8 -c100 -T600 -r -Mprepared -Upostgres test 2>&1 | tee "${results_file}"

  local results_file="/home/ubuntu/artifacts/pgbench_results.txt"
  echo "time_s | TPS | latency_ms | stddev" > "$results_file"
  pgbench -j8 -c100 -T600 -P 10 -r -Mprepared -Upostgres test 2>&1 | \
          grep -F "progress: " | grep -F "stddev" | \
          awk '{ print  $2, $4, $7, $10}' >> "$results_file"
  echo "ALL DONE"
  echo "Artifact saved at: '$results_file'"
}

main() {
  reset_state # recreate NVME partition
  general_tuning # tune Linux
  if [[ "$FSTYPE" == "zfs" ]]; then
    prepare_zfs # format NVME with ZFS znd tune ZFS
  elif [[ "$FSTYPE" == "ext4" ]]; then
    prepare_ext4 # format VNME with ext4 and tune ext4
  fi
  setup_repo # add postgresql repo from postgresql.org
  prepare_postgres # setup or resetup postgres on NVME
  prepare_bench_dataset # pgbench -i
  run_bench # run benchmark and save results into directory
}

main

# end of file
