#!/bin/bash

echo -e "ATTENTION: This command should be run on the bastion server of the slave cluster\n"

echo -n "    slave_openshift_hostname: "
grep masterilb /etc/hosts |cut -d' ' -f1
echo -n "    slave_openshift_token: '"

SECRET=`oc -n glusterfs get sa georepl -o jsonpath='{.secrets[0].name}'`
oc -n glusterfs get secret $SECRET -o jsonpath='{.data.token}' |base64 -d

echo -e "'\n"
