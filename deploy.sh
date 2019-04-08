oc process  -f cronjob.yml \
   -p GIT_REPO=https://github.com/hoolia/backups.git \
   -p DIR=/backup/openshift \
   -p SCHEDULE="0 0 * * *" \
   -p DEPLOYMENT_TYPE=origin \
   -p VOLUME_SIZE=50Gi \
   -p NODE_SELECTOR='{"node-role.kubernetes.io/master": "true"}' \
 | oc create -f-

