#!/bin/bash

USER='mongodb'
PASSWD='mongo321'
HUB_ACCOUNT='arasbav'
MY_PASSWORD='SREsre321#@!'
ZONE='europe-west1-b'
NAMESPACE='personio'
OWNER=`whoami`+'@gmail.com'
K8S='gke-mongodb-personio-api-cluster'


gce_sleep(){
    sleep $1
}

gce_zone(){
    gcloud config set compute/zone $1
}

gce_k8s(){
     gcloud container clusters create $1 
}

gce_disk(){
for i in $@; do
   gcloud compute disks create --size 10GB --type pd-standard pd-hdd-disk-$i
done
}

k8s_apply(){
    sed -e "s/VALUE/$NAMESPACE/g" ./YAML/$1 > /tmp/$1
    kubectl apply -f /tmp/$1
    rm -f /tmp/$1
}

k8s_namespace(){
    k8s_apply namespace.yaml
}

k8s_key_file(){
    KEYFILE=$(mktemp)
    /usr/bin/openssl rand -base64 741 > $KEYFILE
    kubectl -n $1 create secret generic shared-secret --from-file=internal-auth-mongodb-keyfile=$KEYFILE
    rm $KEYFILE
}

k8s_secret(){
    kubectl -n $1 create secret generic mongodb-credentials --from-literal="user=$2" --from-literal="password=$3"
}

k8s_admin(){
    sed -e "s/NAME/$OWNER/g" ./YAML/cluster_admin.yml > /tmp/cluster_admin.yml
    kubectl apply -f /tmp/cluster_admin.yml 
    rm -f /tmp/cluster_admin.yml
}

gce_persistant(){
    for i in $@; do
      sed -e "s/NUM/${i}/g" ./YAML/gce-hdd-persistentvolume.yaml > /tmp/gce-hdd-persistentvolume.yaml
      kubectl apply -f /tmp/gce-hdd-persistentvolume.yaml
    done
    rm -f /tmp/gce-hdd-persistentvolume.yaml
}	

k8s_mongo_db_service(){
    k8s_apply mongodb-service.yaml
}

k8s_mongo_db_deploy(){
    k8s_apply mongodb-deploy.yaml
}

k8s_wait_for_cluser(){
    until kubectl -n $1 --v=0 exec mongod-2 -c mongod-container -- mongo --quiet --eval 'db.getMongo()'; do
	echo " " 
	echo "----------------------------------------------------------"
	echo "PLEASE IGNORE BELOW ERROR messages during MongoDB cluster creation - creation takes around 3 minutes"
	gce_sleep 5
    done
    echo "...MongoDB containers are now running"
}

k8s_mdb_replica(){
    # Pods names in StatefulSets set are always this same
    kubectl -n $1 exec  mongod-0 -c mongod-container -- mongo --eval 'rs.initiate({_id: "MainRepSet", version: 1, members: [ {_id: 0, host: "mongod-0.mongodb-service.'$1'.svc.cluster.local:27017"}, {_id: 1, host: "mongod-1.mongodb-service.'$1'.svc.cluster.local:27017"}, {_id: 2, host: "mongod-2.mongodb-service.'$1'.svc.cluster.local:27017"} ]});'
}

k8s_mdb_relica_sync(){
    kubectl -n $1 exec mongod-0 -c mongod-container -- mongo --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'

    echo "Wait 20 seconds for Replica Set to be ready"
    gce_sleep 20 
    echo "MongoDB Replica Set created"
}

k8s_mdb_user(){
    kubectl -n $1 exec mongod-0 -c mongod-container -- mongo --eval 'db.getSiblingDB("admin").createUser({user:"'"${USER}"'",pwd:"'"${PASSWD}"'",roles: ["dbAdminAnyDatabase", "readWriteAnyDatabase"]});'
}

docker_start(){
    sudo service docker start
}

docker_hub(){
    echo "$1" | docker login --username $2 --password-stdin
}

docker_build(){
    docker build -t $1/personio_app:latest .
}

docker_push(){
    docker push $1/personio_app
}

flask_deploy(){
    k8s_apply flask-app.yaml
}

flask_service(){
    k8s_apply flask-service.yml
}

k8s_display(){
    kubectl get po --all-namespaces|grep -v kub
    kubectl get svc -n $1
}

gce_ingress(){
    ./ingress/create_ingress.sh $1
}

gce_tls(){
    ./ingress/tls.sh $1 $2
}

gce_ingress_resource(){
    k8s_apply tls_ingress.yml
}



# DEPLOY K8S with MongoDB, Flask APP and Ingress

echo "set zone to $ZONE"
gce_zone $ZONE

echo "deploy K8s $K8S in GCE cloud"
gce_k8s $K8S

echo "create namespace $NAMESPACE for project"
k8s_namespace $NAMESPACE

echo "create GCE disks for MongoDB database"
gce_disk 1 2 3

echo "create Persistent Volumes"
gce_persistant 1 2 3 

echo "Create keyfile for the MongoDB cluster as a K8s shared secret"
k8s_key_file $NAMESPACE

echo "Create K8s secret for Flask Application"
k8s_secret $NAMESPACE $USER $PASSWD

echo "Create Service for MongoDB database"
k8s_mongo_db_service

echo "Create MongoDB database - 3 member replica set for HA - StatefulSets with persistance storage"
k8s_mongo_db_deploy

echo "Waiting - 3 MongoDB replica set containers to come up (`date`)..."
k8s_wait_for_cluser $NAMESPACE

echo "Initiate MongoDB replica set - mandatory step for MongoDB installation"
k8s_mdb_replica $NAMESPACE

echo "Waitfor the MongoDB Replica Set to finish initialise..."
k8s_mdb_relica_sync $NAMESPACE

echo "Create MongoDB user $USER for Flask application"
k8s_mdb_user $NAMESPACE

echo "Start Docker"
docker_start

echo "Docker Build:  Login to Docker Hub"
docker_hub $MY_PASSWORD $HUB_ACCOUNT

echo "Docker Build:  Flask application - API to MongoDB database"
docker_build $HUB_ACCOUNT

echo "Push Docker Flask Application image to Docker Hub"
docker_push $HUB_ACCOUNT

echo "Deploy Flask App deployment - create Deployment with 3 Pods"
flask_deploy

echo "Create Flask Application service"
flask_service

echo "sleep for 15 seconds"
gce_sleep 15

echo "Display enviroment"
k8s_display $NAMESPACE

echo "NGINEX Ingress"
gce_ingress $ZONE

echo "TLS - create certificates"
gce_tls $ZONE $NAMESPACE

echo "Ingress Resource"
gce_ingress_resource


gce_sleep 5
echo "Finished, please test API"
echo "kubectl get ingress ingress-resource -n $NAMESPACE"
kubectl get ingress ingress-resource -n $NAMESPACE
echo "kubectl get service nginx-ingress-controller"
kubectl get service nginx-ingress-controller
