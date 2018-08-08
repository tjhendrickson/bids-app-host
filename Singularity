Bootstrap: docker
From: ubuntu:xenial-20180726

%files
run-bids-app-singularity.sh /usr/local/bin/run-bids-app-singularity.sh

%environment

#set up environment for runtime
export BIDS_ANALYSIS_ID
export BIDS_CONTAINER
export BIDS_DATASET_BUCKET
export BIDS_OUTPUT_BUCKET
export BIDS_SNAPSHOT_ID
export BIDS_ANALYSIS_LEVEL
export BIDS_ARGUMENTS
export GOPATH=${HOME}/go
export PATH=/usr/local/go/bin:${PATH}:${GOPATH}/bin
export SINGULARITY_PULLFOLDER=/
export SINGULARITY_LOCALCACHEDIR=/tmp
export SINGULARITY_CACHEDIR=/tmp


%post

#make run-bids-app-singularity.sh executable
chmod +x /usr/local/bin/run-bids-app-singularity.sh

#make local folders
mkdir /snapshot && \
mkdir /output

#set up basic tools
apt-get update
apt-get install bash jq curl util-linux python dh-autoreconf build-essential libssl-dev uuid-dev libgpgme11-dev libarchive-dev git wget -y

#install golang 1.10.2
cd /tmp
wget https://dl.google.com/go/go1.10.2.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.10.2.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:${PATH}:/root/go/bin

#clone singularity repository
mkdir -p /root/go/src/github.com/singularityware
cd /root/go/src/github.com/singularityware
git clone https://github.com/singularityware/singularity.git
cd singularity
git fetch

#install golang dependencies
go get -u -v github.com/golang/dep/cmd/dep
cd /root/go/src/github.com/singularityware/singularity
dep ensure -v

#now install singularity
cd /root/go/src/github.com/singularityware/singularity
./mconfig
cd ./builddir
make
make install
cd ..
./mconfig -p /usr/local -b ./buildtree

#set up environment within container
export BIDS_ANALYSIS_ID
export BIDS_CONTAINER
export BIDS_DATASET_BUCKET
export BIDS_OUTPUT_BUCKET
export BIDS_SNAPSHOT_ID
export BIDS_ANALYSIS_LEVEL
export BIDS_ARGUMENTS
export GOPATH=${HOME}/go
export PATH=/usr/local/go/bin:${PATH}:${GOPATH}/bin
export SINGULARITY_PULLFOLDER=/
export SINGULARITY_LOCALCACHEDIR=/tmp
export SINGULARITY_CACHEDIR=/tmp


%runscript
/usr/local/bin/run-bids-app-singularity.sh


