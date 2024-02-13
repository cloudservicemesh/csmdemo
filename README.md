# csmdemo

### environment / context
```
export PROJECT=csm001
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT} --format="value(projectNumber)")
gcloud config set project ${PROJECT}
### replace the following section as needed
export REGION_1=us-central1
export REGION_2=us-west2
export CONFIG_CLUSTER=gke-config-improved-donkey
export CLUSTER_US_CENTRAL1_A=gke-us-central1-a-smiling-vervet
export CLUSTER_US_CENTRAL1_B=gke-us-central1-b-delicate-hermit
export CLUSTER_US_WEST2_A=gke-us-west2-a-sweet-mako
export CLUSTER_US_WEST2_B=gke-us-west2-b-happy-gar

# set up kubeconfig
cd ${HOME}/csmdemo
export WORKDIR=`pwd`
touch csmdemo_kubeconfig
export KUBECONFIG=${WORKDIR}/csmdemo_kubeconfig

# make stuff easier to read
gcloud config set accessibility/screen_reader false

# make sure APIs are enabled
gcloud services enable \
  container.googleapis.com \
  mesh.googleapis.com \
  gkehub.googleapis.com \
  multiclusterservicediscovery.googleapis.com \
  multiclusteringress.googleapis.com \
  trafficdirector.googleapis.com \
  certificatemanager.googleapis.com

# set up kube contexts and rename
gcloud container clusters get-credentials ${CONFIG_CLUSTER} \
    --zone ${REGION_1}-a
kubectl config rename-context gke_${PROJECT}_${REGION_1}-a_${CONFIG_CLUSTER} gke-config

gcloud container clusters get-credentials ${CLUSTER_US_CENTRAL1_A} \
    --zone ${REGION_1}-a
kubectl config rename-context gke_${PROJECT}_${REGION_1}-a_${CLUSTER_US_CENTRAL1_A} gke-us-central1-0

gcloud container clusters get-credentials ${CLUSTER_US_CENTRAL1_B} \
    --zone ${REGION_1}-b
kubectl config rename-context gke_${PROJECT}_${REGION_1}-b_${CLUSTER_US_CENTRAL1_B} gke-us-central1-1

gcloud container clusters get-credentials ${CLUSTER_US_WEST2_A} \
    --zone ${REGION_2}-a
kubectl config rename-context gke_${PROJECT}_${REGION_2}-a_${CLUSTER_US_WEST2_A} gke-us-west2-0

gcloud container clusters get-credentials ${CLUSTER_US_WEST2_B} \
    --zone ${REGION_2}-b
kubectl config rename-context gke_${PROJECT}_${REGION_2}-b_${CLUSTER_US_WEST2_B} gke-us-west2-1
```

### create cluster ingress
```
# namespace setup
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT create namespace asm-ingress
    kubectl --context=$CONTEXT label namespace asm-ingress istio-injection=enabled
done

for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do
    kubectl --context $CONTEXT apply -k ${WORKDIR}/asm-ig/variant
done
```