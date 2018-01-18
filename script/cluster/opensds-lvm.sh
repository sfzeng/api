#!/bin/bash

# Copyright 2017 The OpenSDS Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ETCD_DIR=etcd-v3.2.0-linux-amd64
ETCD_ENDPOINT=localhost:2379,localhost:2380
OPENSDS_DIR=${HOME}/gopath/src/github.com/opensds/opensds
IMAGE_PATH=${HOME}/lvm.img
DEIVCE_PATH=$(losetup -f)
VG_NAME=opensds-vg001

# Install some lvm tgt and open-iscsi tools.
sudo apt-get install -y lvm2
sudo apt-get install -y tgt
sudo apt-get install -y open-iscsi

if [ -z $HOME ];then
	echo "home path not exist"
	exit
fi

if [ ! -f ${IMAGE_PATH} ]; then
	dd if=/dev/zero of=${IMAGE_PATH} bs=1GB count=20
fi

if losetup -a|grep -w "${HOME}/lvm.img"; then
    DEIVCE_PATH=$(losetup -a|grep "${HOME}/lvm.img"| awk -F ':' '{print $1}')
fi

if ! pvs $DEIVCE_PATH; then
	# Create a new physical volume.
	losetup ${DEIVCE_PATH} ${IMAGE_PATH}
	pvcreate ${DEIVCE_PATH}
fi

if ! vgs $VG_NAME; then
	# Add pv in volume group.
	vgcreate ${VG_NAME} ${DEIVCE_PATH}
fi

# Run etcd daemon in background.
cd ${HOME}/${ETCD_DIR}
if lsof -i:2380 || lsof -i:2379 ;then
    etcd -initial-advertise-peer-urls http://127.0.0.1:52380  -listen-client-urls http://127.0.0.1:52379  \
    -advertise-client-urls http://127.0.0.1:52379 -listen-peer-urls http://127.0.0.1:52380 > nohup.out 2> nohup.err < /dev/null &
    ETCD_ENDPOINT=localhost:52379,localhost:52380
else
    nohup sudo ./etcd > nohup.out 2> nohup.err < /dev/null &
    ETCD_ENDPOINT=localhost:2379,localhost:2380
fi
# Create opensds config dir.
mkdir -p /etc/opensds
mkdir -p /etc/opensds/driver

# Config opensds backend info.

cat > /etc/opensds/opensds.conf << OPENSDS_GLOABL_CONFIG_DOC
[osdslet]
api_endpoint = 0.0.0.0:50040
graceful = True
log_file = /var/log/opensds/osdslet.log
socket_order = inc

[osdsdock]
api_endpoint = localhost:50050
log_file = /var/log/opensds/osdsdock.log
# Specify which backends should be enabled, sample,ceph,cinder,lvm and so on.
enabled_backends = lvm

[lvm]
name = lvm
description = LVM Test
driver_name = lvm
config_path = /etc/opensds/driver/lvm.yaml

[database]
endpoint = $ETCD_ENDPOINT
driver = etcd
OPENSDS_GLOABL_CONFIG_DOC

cat > /etc/opensds/driver/lvm.yaml << OPENSDS_LVM_CONFIG_DOC
pool:
  $VG_NAME:
    diskType: NL-SAS
    AZ: default
OPENSDS_LVM_CONFIG_DOC

# Run osdsdock and osdslet daemon in background.
cd ${OPENSDS_DIR}
sudo build/out/bin/osdsdock -daemon
sudo build/out/bin/osdslet -daemon
