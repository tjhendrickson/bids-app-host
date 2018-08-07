#!/bin/bash
set -eo pipefail

echo "Starting openneuro/bids-app-host:0.8.5"

# Get cgroup limit for host container, reserve 64MB and limit the BIDS container to this
BIDS_APP_MEMORY_LIMIT=$(( $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) - 67108864 ))

#
# Function Description:
#  Show usage information for this script
#
usage()
{
	echo ""
	echo "  An S3/ECS wrapper container for managing BIDS apps. "
	echo ""
	echo "  Usage: run-bids-app.singularity.sh <options>"
	echo ""
	echo "  Options: [ ] = optional; < > = user supplied value"
	echo ""
	echo "   [--help] : show usage information and exit"
    echo "    --aws-access-key-id=AWS access keys to access s3 instance"
	echo "    --aws-secret-key=AWS secret key"
	echo "    --bids-analysis-id=A unique key for a combination of dataset and parameters"
	echo "    --bids-container=path:tag for BIDS app container"
	echo "    --bids-dataset-bucket=S3 Bucket containing BIDS directories"
	echo "    --output-bucket=Writable S3 Bucket for output"
	echo "    --bids-snapshot-id=The key to reference which BIDS directory"
	echo "    --bids-analysis-level=Select for participant, group, etc"
	echo "    --bids-arguments=Additional required parameters"
	echo ""
}

get_options()
{
	local arguments=($@)

	# initialize global output variables
	unset AWS_ACCESS_KEY_ID
	unset AWS_SECRET_KEY
	unset BIDS_ANALYSIS_ID
	unset BIDS_CONTAINER
	unset BIDS_DATASET_BUCKET
	unset OUTPUT_BUCKET
	unset BIDS_SNAPSHOT_ID
	unset BIDS_ANALYSIS_LEVEL
	unset BIDS_ARGUMENTS

	# parse arguments
	local num_args=${#arguments[@]}
	local argument
	local index=0

	while [ ${index} -lt ${num_args} ]; do
		argument=${arguments[index]}

		case ${argument} in
			--help)
				usage
				exit 1
				;;
			--aws-access-key-id=*)
				g_aws-access-key-id=${argument#*=}
				index=$(( index + 1 ))
				;;
			--aws-secret-key=*)
				g_aws-secret-key=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-analysis-id=*)
				g_bids-analysis-id=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-container=*)
				g_bids-container=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-dataset-bucket=*)
				g_bids-dataset-bucket=${argument#*=}
				index=$(( index + 1 ))
				;;
			--output-bucket=*)
				g_output-bucket=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-snapshot-id=*)
				g_bids-snapshot-id=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-analysis-level=*)
				g_bids-analysis-level=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-arguments=*)
				g_bids-arguments=${argument#*=}
				index=$(( index + 1 ))
				;;
			*)
				usage
				echo "ERROR: unrecognized option: ${argument}"
				echo ""
				exit 1
				;;
		esac
	done

	local error_count=0
	# check required parameters
	if [ -z "${g_aws-access-key-id}" ]; then
		echo "ERROR: aws access key id (--aws-access-key-id) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_aws-access-key-id: ${g_aws-access-key-id}"
	fi

	if [ -z "${g_aws-secret-key}" ]; then
		echo "ERROR: aws secret key (--aws-secret-key) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_aws-secret-key: ${g_aws-secret-key}"
	fi

	if [ -z "${g_bids-analysis-id}" ]; then
		echo "ERROR: bids analysis id (--bids-analysis-id) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-analysis-id: ${g_bids-analysis-id}"
	fi

	if [ -z "${g_bids-container}" ]; then
		echo "ERROR: bids container (--bids-container) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-container: ${g_bids-container}"
	fi

	if [ -z "${g_bids-dataset-bucket}" ]; then
		echo "ERROR: bids dataset bucket (--bids-dataset-bucket) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-dataset-bucket: ${g_bids-dataset-bucket}"
	fi

	if [ -z "${g_output-bucket}" ]; then
		echo "ERROR: output bucket (--output-bucket) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_output-bucket: ${g_output-bucket}"
	fi

	if [ -z "${g_bids-snapshot-id}" ]; then
		echo "ERROR: bids snapshot id (--bids-snapshot-id) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-snapshot-id: ${g_bids-snapshot-id}"
	fi

	if [ -z "${g_bids-analysis-level}" ]; then
		echo "ERROR: bids analysis level (--bids-analysis-level) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-analysis-level: ${g_bids-analysis-level}"
	fi

	if [ -z "${g_bids-arguments}" ]; then
		echo "ERROR: bids app arguments (--bids-arguments) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_bids-arguments: ${g_bids-arguments}"
	fi

	if [ ${error_count} -gt 0 ]; then
		echo "For usage information, use --help"
		exit 1
	fi
}

function pull_and_prune {
    set +eo pipefail
    # Allow for one retry if the first pull fails
    docker pull "$1" || { docker_cleanup && docker pull "$1"; }
    set -eo pipefail
}

if [ -z "$BIDS_CONTAINER" ]; then
    echo "Error: Missing env variable BIDS_CONTAINER." && exit 1
elif [ -z "$BIDS_DATASET_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_DATASET_BUCKET." && exit 1
elif [ -z "$OUTPUT_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable OUTPUT_BUCKET." && exit 1
elif [ -z "$BIDS_INPUT_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_INPUT_BUCKET." && exit 1
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

AWS_CLI_CONTAINER=infrastructureascode/aws-cli:1.11.89
pull_and_prune "$AWS_CLI_CONTAINER"
# Pull once, if pull fails, try to prune
# if the second pull fails this will exit early
pull_and_prune "$BIDS_CONTAINER"

# On exit, copy the output
function sync_output {
    set +e
    docker run --rm -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER aws s3 sync --only-show-errors /output/data s3://"$OUTPUT_BUCKET"/"$BIDS_SNAPSHOT_ID"/"$BIDS_ANALYSIS_ID"
    DOCKER_EC=$?
    if (( $DOCKER_EC == 2 )); then
        echo "Warning: aws s3 sync output returned status code 2"
        echo "Some files may not have been copied"
    else
        if (( $DOCKER_EC != 0 )); then
            # Pass any unhandled exit codes back to Batch
            exit $DOCKER_EC
        fi
    fi
    # Unlock these volumes
    docker rm -f "$AWS_BATCH_JOB_ID"-lock || echo "No lock found for ${AWS_BATCH_JOB_ID}"
    set -e

    # Cleanup at end of job
    docker_cleanup
}

# On EXIT or SIGTERM, sync results
trap sync_output EXIT SIGTERM

# Create volumes for snapshot/output if they do not already exist
echo "Creating snapshot volume:"
docker volume create --name "$BIDS_SNAPSHOT_ID"
echo "Creating output volume:"
docker volume create --name "$AWS_BATCH_JOB_ID"

# Check for file input hash "array" string
# right now we are only supporting a single file
# left this is an array so we can support multi file in the future
if [ "$INPUT_HASH_LIST" ]; then
    echo "Input file hash array found"
    # Convert hash list into a bash array
    INPUT_BASH_ARRAY=( `echo ${INPUT_HASH_LIST}` )
    for hash in "${INPUT_BASH_ARRAY[@]}"
    do
        HASH_INCLUDES+="--include *$hash* "
        HASH_STRING+="$hash"
    done
    # Create input volume
    echo "Creating input volume:"
    docker volume create --name "${BIDS_INPUT_BUCKET}_${HASH_STRING}"
    # Input command to copy input files from s3. Again only single file support right now.  Hence ${INPUT_BASH_ARRAY[0]}
    docker run --rm -v "${BIDS_INPUT_BUCKET}_${HASH_STRING}":/input $AWS_CLI_CONTAINER flock /input/lock aws s3 cp s3://${BIDS_INPUT_BUCKET}/ /input/data --recursive --exclude \* $HASH_INCLUDES
fi

# Prevent a race condition where another container deletes these volumes
# after the syncs but before the main task starts
# Timeout after ten minutes to prevent infinite jobs
if [ "$INPUT_HASH_LIST" ]; then
    docker run --rm -d --name "$AWS_BATCH_JOB_ID"-lock -v "$BIDS_SNAPSHOT_ID":/snapshot -v "$AWS_BATCH_JOB_ID":/output -v "$BIDS_INPUT_BUCKET_$HASH_STRING":/input $AWS_CLI_CONTAINER sh -c 'sleep 600'
else
    docker run --rm -d --name "$AWS_BATCH_JOB_ID"-lock -v "$BIDS_SNAPSHOT_ID":/snapshot -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER sh -c 'sleep 600'
fi
# Sync those volumes
SNAPSHOT_COMMAND="aws s3 sync --only-show-errors s3://${BIDS_DATASET_BUCKET}/${BIDS_SNAPSHOT_ID} /snapshot/data"
OUTPUT_COMMAND="aws s3 sync --only-show-errors s3://${OUTPUT_BUCKET}/${BIDS_SNAPSHOT_ID}/${BIDS_ANALYSIS_ID} /output/data"

# Only copy the participants needed for this analysis
if [ "$BIDS_ANALYSIS_LEVEL" = "participant" ]; then
    OPTION="${BIDS_ARGUMENTS##*--participant_label }"
    PARTICIPANTS="${OPTION%% --*}"
    EXCLUDE="--exclude sub-* --exclude participants.tsv --exclude phenotype/*"
    INCLUDES=""
    for PART in ${PARTICIPANTS[@]}
    do
        INCLUDES+="--include sub-${PART}/* "
    done
    SNAPSHOT_COMMAND="aws s3 sync --only-show-errors ${EXCLUDE} ${INCLUDES} s3://${BIDS_DATASET_BUCKET}/${BIDS_SNAPSHOT_ID} /snapshot/data"
fi

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    docker run --rm -v "$BIDS_SNAPSHOT_ID":/snapshot $AWS_CLI_CONTAINER flock /snapshot/lock $SNAPSHOT_COMMAND
    docker run --rm -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER flock /output/lock $OUTPUT_COMMAND
else
    docker run --rm -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" -v "$BIDS_SNAPSHOT_ID":/snapshot $AWS_CLI_CONTAINER flock /snapshot/lock $SNAPSHOT_COMMAND
    docker run --rm -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER flock /output/lock $OUTPUT_COMMAND
fi

ARGUMENTS_ARRAY=( "$BIDS_ARGUMENTS" )

if [ "$INPUT_HASH_LIST" ]; then
    COMMAND_TO_RUN="docker run -it --rm \
           -m \"$BIDS_APP_MEMORY_LIMIT\" \
           -v \"$BIDS_SNAPSHOT_ID\":/snapshot:ro \
           -v \"$AWS_BATCH_JOB_ID\":/output \
           -v \"${BIDS_INPUT_BUCKET}_${HASH_STRING}\":/input:ro \
           \"$BIDS_CONTAINER\" \
           /snapshot/data /output/data \"$BIDS_ANALYSIS_LEVEL\" \
           ${ARGUMENTS_ARRAY[@]}"
else
    COMMAND_TO_RUN="docker run -it --rm \
           -m \"$BIDS_APP_MEMORY_LIMIT\" \
           -v \"$BIDS_SNAPSHOT_ID\":/snapshot:ro \
           -v \"$AWS_BATCH_JOB_ID\":/output \
           \"$BIDS_CONTAINER\" \
           /snapshot/data /output/data \"$BIDS_ANALYSIS_LEVEL\" \
           ${ARGUMENTS_ARRAY[@]}"
fi

mapfile BIDS_APP_COMMAND <<EOF
    $COMMAND_TO_RUN
EOF

echo "Running $BIDS_CONTAINER"
echo "_______________________________________________________"

# Wrap with script so we have a PTY available regardless of parent shell
script -f -e -q -c "$BIDS_APP_COMMAND" /dev/null
