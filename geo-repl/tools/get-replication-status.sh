#!/bin/bash

echo -e "ATTENTION: This command should be run on the bastion server of the master cluster\n"

oc -n glusterfs rsh ds/glusterfs-storage bash -c "gluster volume list |xargs -L1 -I% gluster volume geo-replication % status"

