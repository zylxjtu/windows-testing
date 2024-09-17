# 
# Steps for CAPZ setup : https://capz.sigs.k8s.io/developers/development.html#setting-up


#!/bin/bash

SCRIPT_PATH=$(realpath "${BASH_SOURCE[0]}")
SCRIPT_ROOT=$(dirname "${SCRIPT_PATH}")

source $SCRIPT_ROOT/capz.properties

logFormat(){
     echo "--[`date "+%Y/%m/%d %H:%M:%S"`] -- LOG -- $@" 
}

cd $HOME

# Install go 
logFormat "  ---------------------- Installing go - version $GO_VERSION ----------------------"
curl -LO https://go.dev/dl/go$GO_VERSION.linux-$OS_ARCHITECTURE.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go$GO_VERSION.linux-$OS_ARCHITECTURE.tar.gz
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export GOROOT=/usr/local/go/


# Get the source $CAPZ_REPO_VERSION - last known stable version on 03/11/2022
logFormat " ---------------------- Cloning capz latest release - $CAPZ_REPO_VERSION  ----------------------"
git clone https://github.com/kubernetes-sigs/cluster-api-provider-azure -b release-$CAPZ_REPO_VERSION cluster-api-provider-azure

logFormat " ---------------------- Resolving dependencies for capz repository  ---------------------- "
# Get the source $CAPZ_REPO_VERSION - last known stable version on 03/11/2022
go get -d sigs.k8s.io/cluster-api-provider-azure@v$CAPZ_REPO_VERSION
cd cluster-api-provider-azure

make verify-modules
make modules
hack/ensure-go.sh

cd $HOME

# Install Helm
logFormat "  ---------------------- Helm  ----------------------"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# -kubectl
logFormat " ---------------------- Installing latest versiom of kubectl  ----------------------"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$OS_ARCHITECTURE/kubectl"
curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$OS_ARCHITECTURE/kubectl.sha256"
echo "$(<kubectl.sha256)  kubectl" | sha256sum --check
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install Clusterctl
logFormat "  ---------------------- Clusterctl  ----------------------"
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.5.3/clusterctl-linux-amd64 -o clusterctl
chmod +x ./clusterctl
mv ./clusterctl /usr/local/bin/clusterctl
clusterctl version

# Install Az cli
logFormat "  ---------------------- Az cli  ----------------------"
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

#Install azcopy
logFormat "  ---------------------- azcopy  ----------------------"
cd /usr/local/bin
curl -sL https://aka.ms/downloadazcopy-v10-linux | tar --strip-components=1 --exclude=*.txt -xzvf -
chmod +x azcopy

# Git clone windows testing repo
cd $HOME
logFormat "  ---------------------- Cloning windows testing repository  ----------------------"
git clone https://github.com/zylxjtu/windows-testing.git windows-testing

# Exporting environment variables for persistance in the system
echo 'export PATH=$PATH:/usr/local/go/bin' >> $HOME/.bashrc
echo 'export GOPATH=$HOME/go' >> $HOME/.bashrc
echo 'export GOBIN=$GOPATH/bin' >> $HOME/.bashrc
echo 'export GOROOT=/usr/local/go/' >> $HOME/.bashrc
echo 'export PATH=$PATH:$HOME' >> $HOME/.bashrc
