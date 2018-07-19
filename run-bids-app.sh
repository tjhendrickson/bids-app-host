#!/bin/bash
set -eo pipefail

echo "Starting openneuro/bids-app-host:0.8.5"

docker info

# Get cgroup limit for host container, reserve 64MB and limit the BIDS container to this
BIDS_APP_MEMORY_LIMIT=$(( $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) - 67108864 ))

# Minimum supported version is 1.24
# This script is written based on the 1.29 reference but tested against
# 1.24 and 1.29
DOCKER_API_VERSION=1.29

#
# Function Description:
#  Show usage information for this script
#
usage()
{
	echo ""
	echo "  An S3/ECS wrapper container for managing BIDS apps. "
	echo ""
	echo "  Usage: run-bids-app.sh <options>"
	echo ""
	echo "  Options: [ ] = optional; < > = user supplied value"
	echo ""
	echo "   [--help] : show usage information and exit"
    echo "    --aws-access-key-id=AWS access keys to access s3 instance"
	echo "    --aws-secret-key=AWS secret key"
	echo "    --bids-analysis-id=A unique key for a combination of dataset and parameters"
	echo "    --bids-container=path:tag for BIDS app container"
	echo "    --bids-dataset-bucket=S3 Bucket containing BIDS directories"
	echo "    --bids-output-bucket=Writable S3 Bucket for output"
	echo "    --bids-snapshot-id=The key to reference which BIDS directory"
	echo "    --bids-analysis-level=Select for participant, group, etc"
	echo "    --bids-arguments=Additional required parameters"
	echo "   [--disable-prune=Prevents the container from removing images/volumes]"
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
	unset BIDS_OUTPUT_BUCKET
	unset BIDS_SNAPSHOT_ID
	unset BIDS_ANALYSIS_LEVEL
	unset BIDS_ARGUMENTS
	unset DISABLE_PRUNE

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
				g_path_to_study_folder=${argument#*=}
				index=$(( index + 1 ))
				;;
			--aws-secret-key=*)
				g_path_to_study_folder=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-analysis-id=*)
				g_subject=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-container=*)
				g_fmri_name=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-dataset-bucket=*)
				g_high_pass=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-output-bucket=*)
				g_reg_name=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-snapshot-id=*)
				g_low_res_mesh=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-analysis-level=*)
				g_final_fmri_res=${argument#*=}
				index=$(( index + 1 ))
				;;
			--bids-arguments=*)
				g_brain_ordinates_res=${argument#*=}
				index=$(( index + 1 ))
				;;
			--disable-prune=*)
				g_smoothing_fwhm=${argument#*=}
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
	if [ -z "${g_path_to_study_folder}" ]; then
		echo "ERROR: path to study folder (--path= or --study-folder=) required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_path_to_study_folder: ${g_path_to_study_folder}"
	fi

	if [ -z "${g_subject}" ]; then
		echo "ERROR: subject ID required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_subject: ${g_subject}"
	fi

	if [ -z "${g_fmri_name}" ]; then
		echo "ERROR: fMRI name required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_fmri_name: ${g_fmri_name}"
	fi

	if [ -z "${g_high_pass}" ]; then
		echo "ERROR: high pass required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_high_pass: ${g_high_pass}"
	fi

	if [ -z "${g_reg_name}" ]; then
		echo "ERROR: registration name required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_reg_name: ${g_reg_name}"
	fi

	if [ -z "${g_low_res_mesh}" ]; then
		echo "ERROR: low resolution mesh size required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_low_res_mesh: ${g_low_res_mesh}"
	fi

	if [ -z "${g_final_fmri_res}" ]; then
		echo "ERROR: final fMRI resolution required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_final_fmri_res: ${g_final_fmri_res}"
	fi

	if [ -z "${g_brain_ordinates_res}" ]; then
		echo "ERROR: brain ordinates resolution required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_brain_ordinates_res: ${g_brain_ordinates_res}"
	fi

	if [ -z "${g_smoothing_fwhm}" ]; then
		echo "ERROR: smoothing full width at half max value required"
		error_count=$(( error_count + 1 ))
	else
		log_Msg "g_smoothing_fwhm: ${g_smoothing_fwhm}"
	fi

	if [ ${error_count} -gt 0 ]; then
		echo "For usage information, use --help"
		exit 1
	fi
}

function docker_api_query {
    curl -s --unix-socket /var/run/docker.sock http:/$DOCKER_API_VERSION/$1
}

function docker_cleanup {
    if [ -z "DISABLE_PRUNE" ]; then
        # This is more aggressive than the default 3 hour cleanup of the ECS agent
        if [ $(docker_api_query version | jq -r '.ApiVersion') == '1.24' ]; then
            echo "Freeing space for app..."
            docker rmi $(docker images -f dangling=true)
            docker volume rm $(docker volume ls -f dangling=true -q)
        else
            echo "Freeing space for app with 'docker system prune'..."
            docker system prune --all --force
        fi
    fi
}

function pull_and_prune {
    IMAGE_SPACE_AVAILABLE=$(docker_api_query info | jq -r '.DriverStatus[] | select(.[0] | match("Data Space Available")) | .[1]')
    VOLUME_SPACE_USED=$(df -P /var/run/docker.sock | awk -F\  'FNR==2{ print $5 }')
    echo "Host image storage available: $IMAGE_SPACE_AVAILABLE"
    echo "Host volume storage used: $VOLUME_SPACE_USED"
    # Always clean up images at container start
    docker_cleanup
    set +eo pipefail
    # Allow for one retry if the first pull fails
    docker pull "$1" || { docker_cleanup && docker pull "$1"; }
    set -eo pipefail
}

if [ -z "$BIDS_CONTAINER" ]; then
    echo "Error: Missing env variable BIDS_CONTAINER." && exit 1
elif [ -z "$BIDS_DATASET_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_DATASET_BUCKET." && exit 1
elif [ -z "$BIDS_OUTPUT_BUCKET" ] && [ -z "$DEBUG" ]; then
    echo "Error: Missing env variable BIDS_OUTPUT_BUCKET." && exit 1
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
    docker run --rm -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER aws s3 sync --only-show-errors /output/data s3://"$BIDS_OUTPUT_BUCKET"/"$BIDS_SNAPSHOT_ID"/"$BIDS_ANALYSIS_ID"
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
OUTPUT_COMMAND="aws s3 sync --only-show-errors s3://${BIDS_OUTPUT_BUCKET}/${BIDS_SNAPSHOT_ID}/${BIDS_ANALYSIS_ID} /output/data"

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
