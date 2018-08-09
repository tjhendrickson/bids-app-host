#!/usr/bin/python3
from __future__ import print_function
import argparse
import os
import shutil
from glob import glob
from subprocess import Popen, PIPE
import subprocess
from os.path import expanduser
import pdb

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


def pull_and_prune(container, container_hosting):
    pdb.set_trace()
    if container_hosting == "docker":
        registry = "docker://"
    elif container_hosting == "singularity":
        registry = "shub://"
    cmd = 'singularity pull ' + registry + container
    run(cmd)

def s3cmd_setup(access_key, secret_key, home_dir):
    shutil.copyfile('/etc/generic-msi.s3cfg', home_dir + '/.s3cfg')
    with open(home_dir + '/.s3cfg', 'a') as f:
        f.write("access_key = %s\n" % access_key)
        f.write("secret_key = %s\n" % secret_key)

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

parser = argparse.ArgumentParser(description='An S3/ECS wrapper container for managing BIDS apps. ')
parser.add_argument('--aws-access-key-id', help='AWS access keys to access s3 instance.')
parser.add_argument('--aws-secret-key', help='AWS secret key for s3 instance.')
parser.add_argument('--bids-container', help='path.tag for BIDS app container.')
parser.add_argument('--bids-container-hosting', help='container hosting (singularity or docker) service of bids container.',
                    choices=['singularity', 'docker'], default='singularity')
"""
parser.add_argument('--bids-analysis-id', help='A unique key for a combination of dataset and parameters.')
parser.add_argument('--bids-dataset-bucket', help='S3 Bucket containing BIDS directories')
parser.add_argument('--output-bucket', help='Writable S3 Bucket for output. This must be globally unique.')
parser.add_argument('--bids-snapshot-id',help='The key to reference a particular BIDS directory')
parser.add_argument('--bids-analysis-level',help='The level of analysis to be performed (participant,group)',choices=['participant'])
parser.add_argument('--bids-arguments',help='Additional required parameters for the bids container')
"""

args = parser.parse_args()

#set up s3cmd
s3cmd_setup(access_key=args.aws_access_key_id, secret_key=args.aws_secret_key,home_dir=expanduser("~"))

#pull bids container
pull_and_prune(container=args.bids_container, container_hosting=args.bids_container_hosting)
