#!/bin/bash

MASTER=`hostname |sed s/bastion/master-0/`

echo "    openshift_ca: |"
ssh $MASTER cat /etc/origin/master/ca.crt |sed 's/^/      /g'

