# Gluster OCS Geo-Replication
This playbook will get a list of all PVCs / Gluster Volumes on *Master* cluster and create corresponding PVCs / Gluster Volumes on *Slave* cluster and setup Gluster Geo-Replication (unidirectional from Master -> Slave).

## Assumptions
The playbook is to be run with a valid openshift login session towards the **master** cluster. Basically saying, do an `oc login` first.

## Disclaimers
* When adding a CNS **node**, it needs additional manual configuration, geo-replication doesn't auto-distribute.
* Gluster-Block doesn't support geo-replication, instead blockhost volume is geo-replicated, but cannot be promoted / used by pods. Only manual gluster mount supported.
* Deleting master PVCs will **not** delete slave PVCs.

## Architecture

### Workflow
* Playbook will talk to Master OpenShift API `oc get pvc --all-namespaces`
* Playbook will talk to Slave OpenShift API and duplicate all PVCs found on Master (`oc --context=master get pvc --all-namespaces |oc --context=slave create -f -`) 
* Playbook will wait on Slave to have provisioned all PVCs (`oc observe pvc |grep bound`)
* Playbook will then setup Gluster Geo-Replication between Master and Slave PVCs (`oc rsh pod/glusterfs-storage gluster volume geo-replication MASTER SLAVE create`)

* The Gluster **blockhost** volume is normally not visible in OpenShift, thereby not included when we do `oc get pvc --all-namespaces`.
  To solve this we simply create a PVC pointing to the blockhost gluster volume.

### Technique
* During **init** playbook run, it will need to talk to both the **Master OpenShift API** and the **Slave OpenShift API** to GET (reaD) the PVC object from master and POST (create) it to the slave.
* During `gluster volume geo-replication create` command the **Master Gluster** will talk to the **Slave Gluster** over TCP/24007 (using ssl encryption) to get Slave Volume Meta-data (volname, volsize).
* After `gluster volume geo-replication start` command the **Master Gluster** will start replicating data to the **Slave Gluster** over SSH (TCP/2222) (using rsync command).


## Prerequisites

### Network Firewall
For the clusters to communicate and replicate with each other, the following network access is required:
* From **master cluster** from **All CNS nodes**, To **slave cluster** to **All CNS Nodes** to Port **2222**, 
* From **master cluster** from **Bastion** (or whichever where ansible runs), To **slave cluster** to **Master-API (LB)** Port **443**, 


## Install

### Preparation steps
Fill in the **openshift_ca** variable.
Get the values from both Master and Slave clusters.
```
ssh slave-bastion
./tools/get-ca-certificate.sh
ssh master-bastion
./tools/get-ca-certificate.sh
vi georepl-setup.yml
# vars:
#   openshift_ca: |
#     _here_master_ca
#     _here_slave_ca 
```


### On Master and on Slave
```
ansible-playbook georepl-setup.yml
ansible-playbook georepl-setup-master.yml
```

### On Slave
```
ansible-playbook georepl-setup.yml
ansible-playbook georepl-setup-slave.yml
```

### Manual replication setup
This will setup replication for all PVC's found at that moment
```
ansible-playbook georepl-init.yml
```

## Improvements possible
* https://staged-gluster-docs.readthedocs.io/en/release3.7.0beta1/Administrator%20Guide/Geo%20Replication/#setting-up-the-environment-for-a-secure-geo-replication-slave
 * Use IP ACL
 * Use Mount-Broker (unpriviliged user instead of root)

## Manual failover
This will promote the slave to read/write and disable master->slave replicatoin
Run this playbook on the Slave (assuming Master is down).
```
ansible-playbook georepl-promote_slave.yml -o master_openshift_subnet=10.180.25.0/24
```
