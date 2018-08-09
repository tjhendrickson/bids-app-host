#!/usr/bin/python3
from __future__ import print_function
import argparse
import os
import shutil
import nibabel
from glob import glob
from subprocess import Popen, PIPE
import subprocess
from os.path import expanduser

def run(command, env={}, cwd=None):
    merged_env = os.environ
    merged_env.update(env)
    merged_env.pop("DEBUG", None)
    print(command)
    process = Popen(command, stdout=PIPE, stderr=subprocess.STDOUT,
                    shell=True, env=merged_env, cwd=cwd)
    while True:
        line = process.stdout.readline()
        print(line)
        line = str(line)[:-1]
        if line == '' and process.poll() != None:
            break
    if process.returncode != 0:
        raise Exception("Non zero return code: %d"%process.returncode)


def pull_and_prune(**args):
    args.update(os.environ)
    container = "{container_hosting}"
    if "{container_hosting}" == "docker":
        registry = "docker://"
    elif "{container_hosting}" == "singularity":
        registry = "singularity://"
    cmd = 'singularity pull ' + registry + "{container_hosting}"
    cmd = cmd.format(**args)
    run(cmd)

def s3cmd_setup(**args):
    args.update(os.environ)
    cmd = shutil.copyfile("/etc/generic-msi.s3cfg", "{home}/.s3cfg")
    cmd = cmd.format(**args)
    run(cmd)
    f =open("{home}/.s3cfg", 'a')
    f=f.format(**args)
        f.write("access_key={access_key}")
        f.write("\n")
        f.write("secret_key={secret_key}")
        f.write("\n")







# On exit, copy the output
function sync_output {
    set +e
    singularity run -v "$AWS_BATCH_JOB_ID":/output $AWS_CLI_CONTAINER s3cmd sync --only-show-errors /output/data s3://"$OUTPUT_BUCKET"/"$BIDS_SNAPSHOT_ID"/"$BIDS_ANALYSIS_ID"
    SINGULARITY_EC=$?
    if (( $SINGULARITY_EC == 2 )); then
        echo "Warning: s3cmd s3 sync output returned status code 2"
        echo "Some files may not have been copied"
    else
        if (( $SINGULARITY_EC != 0 )); then
            # Pass any unhandled exit codes back to Batch
            exit $SINGULARITY_EC
        fi
    fi
    # Unlock these volumes
    #docker rm -f "$AWS_BATCH_JOB_ID"-lock || echo "No lock found for ${AWS_BATCH_JOB_ID}"
    #set -e

    # Cleanup at end of job
    docker_cleanup
}


def sync_output(**args):
    args.update(os.environ)
    cmd = 'singularity run -v {aws_batch_job_id}:/output {container} s3cmd s3  ' + \
      '--subject="{subject}" ' + \
      '--subjectDIR="{subjectDIR}" ' + \
      '--t1="{path}/{subject}/T1w/T1w_acpc_dc_restore.nii.gz" ' + \
      '--t1brain="{path}/{subject}/T1w/T1w_acpc_dc_restore_brain.nii.gz" ' + \
      '--t2="{path}/{subject}/T1w/T2w_acpc_dc_restore.nii.gz" ' + \
      '--printcom=""'
    cmd = cmd.format(**args)

parser = argparse.ArgumentParser(description='An S3/ECS wrapper container for managing BIDS apps. ' \
'Options: [ ] = optional; < > = user supplied value')
parser.add_argument('[--help, -h]', help='show usage information and exit')
parser.add_argument('--aws-access-key-id', help='AWS access keys to access s3 instance.')
parser.add_argument('--aws-secret-key', help='AWS secret key for s3 instance.')
parser.add_argument('--bids-analysis-id', help='A unique key for a combination of dataset and parameters.')
parser.add_argument('--bids-container', help='path.tag for BIDS app container.')
parser.add_argument('--bids-container-hosting', help='container hosting (singularity or docker) service of bids container.',
                    choices=['singularity', 'docker'], default='singularity')
parser.add_argument('--bids-dataset-bucket', help='S3 Bucket containing BIDS directories')
parser.add_argument('--output-bucket', help='Writable S3 Bucket for output. This must be globally unique.')
parser.add_argument('--bids-snapshot-id',help='The key to reference a particular BIDS directory')
parser.add_argument('--bids-analysis-level',help='The level of analysis to be performed (participant,group)',choices=['participant'])
parser.add_argument('--bids-arguments',help='Additional required parameters for the bids container')


args = parser.parse_args()

#set up s3cmd
s3cmd_setup(access_key=args.aws-access-key-id, secret_key=args.aws-secret-key, home=expanduser("~"))

#pull bids container
pull_and_prune(container=args.bids-container, container_hosting=args.bids-container-hosting)

