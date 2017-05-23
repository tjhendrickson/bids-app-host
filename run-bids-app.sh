#!/bin/bash
set -eo pipefail

function pull_and_prune {
    DISK_AVAILABLE=$(curl -s --unix-socket /var/run/docker.sock http:/info | jq -r '.DriverStatus[] | select(.[0] | match("Data Space Available")) | .[1]')
    echo "Host disk space available: $DISK_AVAILABLE"
    # Check if there's at least 50 GB available
    if [[ $DISK_AVAILABLE == *GB ]] && [ ${DISK_AVAILABLE%.*} -ge 50 ]; then
        # Retry the pull once if it still fails here
        docker pull "$1" || { docker system prune --all --force && docker pull "$1"; }
    else
        # If there wasn't enough disk space, prune and then pull
        docker system prune --all --force
        docker pull "$1"
    fi
}

if [ -z "$BIDS_CONTAINER" ]; then
    echo "Error: Missing env variable BIDS_CONTAINER." && exit 1
elif [ -z "$BIDS_DATASET_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_DATASET_BUCKET." && exit 1
elif [ -z "$BIDS_OUTPUT_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_OUTPUT_BUCKET." && exit 1
elif [ -z "$BIDS_SNAPSHOT_ID" ]; then
    echo "Error: Missing env variable BIDS_SNAPSHOT_ID." && exit 1
elif [ -z "$BIDS_ANALYSIS_ID" ]; then
    echo "Error: Missing env variable BIDS_ANALYSIS_ID." && exit 1
elif [ -z "$BIDS_ANALYSIS_LEVEL" ]; then
    echo "Error: Missing env variable BIDS_ANALYSIS_LEVEL." && exit 1
fi

# Make sure the host docker instance is running
set +e # Disable -e because we expect docker ps to sometimes fail
ATTEMPTS=1
until docker ps &> /dev/null || [ $ATTEMPTS -eq 13 ]; do
    sleep 5
    ((ATTEMPTS++))
done
set -e

if [ $ATTEMPTS -eq 13 ]; then
    echo "Failed to find Docker service before timeout"
    exit 1
fi

AWS_CLI_CONTAINER=poldracklab/s4cmd:v2.0.1
pull_and_prune "$AWS_CLI_CONTAINER"
# Pull once, if pull fails, try to prune
# if the second pull fails this will exit early
pull_and_prune "$BIDS_CONTAINER"

# On exit, copy the output
function sync_output {
    docker run --rm -v "$BIDS_ANALYSIS_ID":/output $AWS_CLI_CONTAINER sync /output s3://"$BIDS_OUTPUT_BUCKET"/"$BIDS_SNAPSHOT_ID"/"$BIDS_ANALYSIS_ID"
    # Unlock these volumes
    docker rm -f "$AWS_BATCH_JOB_ID"-lock
}
trap sync_output EXIT

# Create volumes for snapshot/output if they do not already exist
docker volume create --name "$BIDS_SNAPSHOT_ID"
docker volume create --name "$BIDS_ANALYSIS_ID"

# Prevent a race condition where another container deletes these volumes
# after the syncs but before the main task starts
# Timeout after ten minutes to prevent infinite jobs
docker run --rm -d --name "$AWS_BATCH_JOB_ID"-lock -v "$BIDS_SNAPSHOT_ID":/snapshot -v "$BIDS_ANALYSIS_ID":/output $AWS_CLI_CONTAINER sh -c 'sleep 600'

# Sync those volumes
docker run --rm -v "$BIDS_SNAPSHOT_ID":/snapshot $AWS_CLI_CONTAINER sync s3://"$BIDS_DATASET_BUCKET"/"$BIDS_SNAPSHOT_ID" /snapshot
docker run --rm -v "$BIDS_ANALYSIS_ID":/output $AWS_CLI_CONTAINER sync s3://"$BIDS_OUTPUT_BUCKET"/"$BIDS_SNAPSHOT_ID"/"$BIDS_ANALYSIS_ID" /output

ARGUMENTS_ARRAY=( "$BIDS_ARGUMENTS" )

docker run --rm \
   -v "$BIDS_SNAPSHOT_ID":/snapshot:ro \
   -v "$BIDS_ANALYSIS_ID":/output \
   "$BIDS_CONTAINER" \
   /snapshot /output "$BIDS_ANALYSIS_LEVEL" \
   ${ARGUMENTS_ARRAY[@]}
