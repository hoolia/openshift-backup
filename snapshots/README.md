# Backup of OpenShift Container Storage (Gluster)

## Introduction

"OpenShift Container Platform" (OCP) ships with the optional storage add-on: "OpenShift Container Storage" (OCS) (formally known a "Container Native Storage" (CNS)).
"OpenShift Container Storage" is based on Gluster and provides File, Block & Object storage.
This "Backup-Controller" will make periodic backups of Gluster-Block and Gluster-File Persistent Volumes (PV) using the Kubernetes native "Snapshot-Controller".

## Gluster technology background
* Heketi = API in front of a Gluster cluster so that OpenShift can talk / delegate storage commands
* Gluster Volume = the "original" Network Shared File storage that you can mount at clients (openshift-nodes)
* Gluster Block Volume = a RAW image (file) (aka "Virtual Disk"), shared hosted on a "traditional" Gluster (file) Volume
* "blockhost" Volume = the Gluster-File volume that is hosting the Gluster-Block RAW images.

## Kubernetes technology background
* StorageClass = Specification of Storage Backends available for OpenShift / end-users to consume.
* "Persistent Volume" (PV) = The specification of a storage volume hosted by a storage backend (contains: which storage-backend, url, authentication, volume-name, etc. Basically: all the `mount` details)
* "Persistent Volume Claim" (PVC) = The interface/spec for the end-user to request (aka "Claim") dynamically provisioned storage.
* "VolumeSnapshot" = a "snapshot request" spec of a "PV".
* "VolumeSnapshotData" = a "snapshot result"

## Default Kubernetes Workflow:
* **Creating Volumes:**
  * An end-user creates a PVC object where it specifies which $STORAGECLASS (storage-backend) to use and the desired $SIZE of the new volume requested.
  * OpenShift relays the PVC object to the $STORAGECLASS (storage-backend), in this case "Heketi" (API for Gluster).
  * Heketi talks to Gluster to create a Gluster Volume.
  * Heketi responds to OpenShift with mount details (volume-name, gluster-endpoints) by creating a PV object.
  * OpenShift binds the PVC to the PV.
  * End-user uses the PVC inside a Deployment to mount the volume at $MOUNTPATH
* **Creating Snapshots:**
  * An end-user creates a "VolumeSnapshot" object, stating the $PVC that needs to be snapshotted
  * A "snapshot-controller" Pod is deployed during installation that listens to CRUD changes of VolumeSnapshot objects and now picks up this snapshot request, in this case of a Gluster-File PVC.
  * The "snapshot-controller" uses the `gluster snapshot create` command to create a snapshot of the gluster volume.
  * The "snapshot-controller" responds to OpenShift with the result (snapshot-name) by creating a "VolumeSnapshotData" object.
* **Restoring Snapshots:**
  * (A "snapshot-promoter" StorageClass is registered during installation of the "snapshot-controller".)
  * The end-user creates a PVC object specifying the $VOLUMESNAPSHOT object to restore and the $STORAGECLASS=snapshot-promoter to use.
  * The snapshot-promoter storageclass tells OpenShift to relay the PVC object to the "snapshot-controller" Pod.
  * The "snapshot-controller" reads the PVC object and extracts the $SNAPSHOT_NAME. It then uses the `gluster snapshot activate` command to create a new Gluster Volume from that snapshot.
  * The "snapshot-controller" then responds back to OpenShift with the result (volume-name) by creating a PV object.
  * OpenShift then binds the PVC request to the responded PV.
  * The end-user can then use the PVC inside a Deployment / Pod to mount the snapshot and copy data.

## Goal
The above procedure describes a fully self-service (for end-user), but "manual" approach of defining /Volume Snapshots/.
The goal is:
* to automate the creation of Snapshots. 
* to copy the data from snapshot to another external storage
* to have a fully self-service manual restore procedure

## Architecture
**Nice event-driven serverless architecture**
Kubernetes already provides the "*Snapshot-Controller*" with support for Gluster. All we need to do is to automate the creation of VolumeSnapshot requests. For that reason we invented the "*Backup-Controller*". The "*Backup-Controller*" is a small daemon running in a Pod that will listen to PVC objects being Created/Updated/Deleted (CRUD) and automatically creates a "*take-snapshot*" CronJob object for each PVC being created.

### Workflow
* **Automatically Creating Snapshots:**
  * **Gluster-File:**
    * A "*backup-controller*" Pod (running the `monitor-pvc.sh` script) has been deployed during installation and listens to CRUD changes of PVC objects.
    * A `create-cronjob.sh` script is triggered on Create changes of PVC objects.
      * If the PVC is of type Gluster-File, then based on the installed "*backup/cronjob*" template it will create a Cronjob object (specifying schedule,retention,pvc).
    * The Cronjob will trigger a Job (running the `daily.sh` script) on the specified scheduled time.
      * The `daily.sh` script will first, based on the "*backup/snapshot*" template, delete old *VolumeSnapshot* objects that are past retention.
        * The "*Snapshot-Controller*", listening to VolumeSnapshot CRUD changes, will pick up the deletion request, and execute a `gluster snapshot delete`.
      * The `daily.sh` script will then , based on the "*backup/snapshot*" template, create new *VolumeSnapshot* object + a *snapshot-promoter* *PVC* that tries to mount that *VolumeSnapshot*, both suffixed with the current date.
    * The "*Snapshot-Controller*" will pick up the VolumeSnapshot request and create a Gluster Volume Snapshot, updating the *VolumeSnaphot* object with $STATE=done/ready.
    * The "*Snapshot-Controller*" will pick up the snapshot-promoter *PVC* request, at first fails because the snapshot is not ready, but keeps on retrying, and eventually will do a `gluster snapshot activate` and create a *PV* object that gets bound to the requested *PVC*.
    * The "*Backup-Controller*", listening to PVC CRUD changes, picks up the snapshot-promoter *PVC*, and, based on the "*backup/job*" template, creates a *Job* object that will mount the *snapshot PVC* (source), mount the "*BackupDisk*" (destination) and runs the `copy-volume.sh` script immediately.
      * The `copy-volume.sh` will do a simple `rsync -va /source /destination`.
  * **Gluster-Block:**
    * By executing the `ansible-playbook install-block-volume.yml`, a "*gluster-blockhost*" PVC inside the "*backup*" project is created that point to the *blockhost* Gluster-File Volume that is hosting the Gluster-Block volumes.
    * Since the "*blockhost*" volume is a Gluster-File Volume we can create automated snapshots as usual using the above *Gluster-File* procedure.
    * The only Gotcha is that we can only snapshot the *whole* blockhost volume with all the Gluster-Block volume images on it.

* **Restoring Snapshots:**
  * **Restoring from Gluster PV Snapshot:**
    * **Gluster-File:**
      * The snapshot is already ready to be mounted
      * As stated in previous *Creating Snapshot* procedure a *snapshot-promoter PVC* is created with the name $ORIGINAL_PVC-$DATE in the same project as the $ORIGINAL_PVC.
      * This *snapshot PVC* can, at any time, be mounted by the end-user.
      * A convenience template has been creates to ease the restore process
      ```
      oc project enduser
      oc scale --replicas=0 dc/myapp
      oc new-app --template=backup/restore -p NAME=mypvc -p DATE=20181202
      oc rsh dc/restore-mypvc
      #> restore.sh
      oc scale --replicas=1 dc/myapp
      oc new-app --template=backup/restore -p NAME=mypvc -p DATE=20181202 |oc delete -f -
      ``` 
      * These *snapshot PVCs* are automatically cleaned up after $RETENTION.
    * **Gluster-Block:**
      * The "*backup*" project contains a PVC "gluster-blockhost", which is also being snapshotted every day.
      * These *blockhost snapshot PVCs* are ready to be mounted (same as above with *Gluster-File*).
      * Run the *restore Pod* (as above) and copy the Gluster-Block RAW image file back
      ```
      oc -n enduser-project scale --replicas=0 dc/myapp
      oc project backup
      oc new-app --template=restore -p NAME=gluster-blockhost -p DATE=20181202
      oc rsh dc/restore-gluster-blockhost
      #> rsync -va /destination/block-meta/blockvol_bec28a80f51058b6ffed9fc56017d7db /source/block-meta/
      #> rsync -va /destination/block-store/4b20dcac-2e3b-40d2-b0f5-9fd3c34fbed8 /source/block-store/
      oc delete cm,dc -l template=restore
      oc -n enduser-project scale --replicas=1 dc/myapp
      ```
  * **Restoring from external BackupDisk:**
    * TODO (replace in restore template the /destination mount with hostPath of BackupDisk) (requires *Privileged*)

### Gotcha's
* The *Job* will retry 6 times and will give up after 4 hours of running.
* Multiple Jobs will run simultaniously at scheduled time (for each PVC its own backup *Job*).
* When using hostPath as the backup destination you need to pin the Backup Pods to that node using a *NodeSelector*.
* It is recommended to enable the (Azure) CloudProvider in OpenShift so that you can use a dynamically provisioned AzureDisk PVC as the backup destionation.
  * It is recommended to have the "*Backup-Controller*" dynamicaly create an AzureDisk PVC for each tenant/project for added security seggragation on backup storage level.
* Currently the "*Backup-Controller*" assumes it is running on a host with the `oc` binary installed (any *master* node).
* The project-name is currently hard-coded to "backup"
   
## Installation
Run below playbook on any machine that is able to SSH to 1st OpenShift Master node (using "hosts: masters[0]").
Or run the playbook directly on the 1st master machine (using "hosts: localhost; connection: local").
```
ansible-playbook install-snapshot-controller.yaml -e NODE_SELECTOR=geo2-master-0
ansible-playbook install-backup-controller.yaml   -e NODE_SELECTOR=geo2-master-0 -e SCHEDULE="0 0 * * *" -e RETENTION="2days"
ansible-playbook install-block-volume.yaml        -e NODE_SELECTOR=geo2-master-0
```

