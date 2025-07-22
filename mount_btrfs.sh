#!/bin/bash

set -eo pipefail

if [[ ${RUNNER_DEBUG:-0} -eq 1 ]]; then
    echo "Debug mode enabled"
    set -x
fi

# Options used to mount
BTRFS_MOUNT_OPTS=${BTRFS_MOUNT_OPTS:-"compress-force=zstd:2"}
# Location where the loopback file will be placed.
_BTRFS_LOOPBACK_FILE=${_BTRFS_LOOPBACK_FILE:-/mnt/btrfs_loopback}
# Percentage of the total space to use. Max: 1.0, Min: 0.0
BTRFS_LOOPBACK_FREE=${_BTRFS_LOOPBACK_FREE:-"0.8"}
# Temporary directory for the loopback mount
_LOOPBACK_MOUNT=/tmp/mnt/btrfs_loopback

# Result of $(dirname "$_BTRFS_LOOPBACK_FILE")
btrfs_pdir="$(dirname "$_BTRFS_LOOPBACK_FILE")"

# Install btrfs-progs
sudo apt-get install -y btrfs-progs

# Create loopback file
sudo mkdir -p "$btrfs_pdir" && sudo chown "$(id -u)":"$(id -g)" "$btrfs_pdir"
_final_size=$(
    findmnt --target "$btrfs_pdir" --bytes --df --json |
        jq -r --arg freeperc "$BTRFS_LOOPBACK_FREE" \
            '.filesystems[0].avail * ($freeperc | tonumber) | round'
)
truncate -s "$_final_size" "$_BTRFS_LOOPBACK_FILE"
unset -v _final_size

# # Stop docker services
# sudo systemctl stop docker

# Format btrfs loopback
sudo mkfs.btrfs -f "$_BTRFS_LOOPBACK_FILE"

# Mount
mkdir -p "$_LOOPBACK_MOUNT" && chmod 755 "$_LOOPBACK_MOUNT"
sudo systemd-mount "$_BTRFS_LOOPBACK_FILE" "$_LOOPBACK_MOUNT" \
    ${BTRFS_MOUNT_OPTS:+ --options="${BTRFS_MOUNT_OPTS}"}

declare -A mounts
mounts=(
    [docker]=/var/lib/docker
    [podman]=/var/lib/containers
    [podman_rootless]=$(podman system info --format '{{.Store.GraphRoot}}' | sed 's|/storage$||')
)

mkdir -p "$(podman system info --format '{{.Store.GraphRoot}}' |
    sed 's|/storage$||')"           # Create podman local container storage beforehand
sudo mkdir -p "/var/lib/containers" # Create podman rootful container storage beforehand

for dir in "${!mounts[@]}"; do
    sudo btrfs subvolume create "$_LOOPBACK_MOUNT/$dir"
    mkdir -p "${mounts[$dir]}" || :
    sudo chmod 755 "${mounts[$dir]}" || :
    sudo cp -r "${mounts[$dir]}"/. "$_LOOPBACK_MOUNT/$dir"/
    sudo mount --bind "$_LOOPBACK_MOUNT/$dir" "${mounts[$dir]}"
    sudo chmod 755 "${mounts[$dir]}" || :
done

sudo umount "$_LOOPBACK_MOUNT"

# # Restart docker services
# sudo systemctl start docker
