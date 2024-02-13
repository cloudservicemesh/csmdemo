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

### enable MCS
```
gcloud container fleet multi-cluster-services enable

gcloud projects add-iam-policy-binding csm001 \
 --member "serviceAccount:csm001.svc.id.goog[gke-mcs/gke-mcs-importer]" \
 --role "roles/compute.networkViewer"

# this can take a while to be ready - otherwise you'll get a warning about making sure CRDs are installed first
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/mcs/svc_export.yaml
done
```

### create public IP address, DNS record, and TLS certificate resources
```
gcloud compute addresses create mcg-ip --global

export MCG_IP=$(gcloud compute addresses describe mcg-ip --global --format "value(address)")
echo ${MCG_IP}

cat <<EOF > ${WORKDIR}/endpoints/dns-spec.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "frontend.endpoints.csm001.cloud.goog"
x-google-endpoints:
- name: "frontend.endpoints.csm001.cloud.goog"
  target: "${MCG_IP}"
EOF

gcloud endpoints services deploy ${WORKDIR}/endpoints/dns-spec.yaml

gcloud certificate-manager certificates create mcg-cert \
    --domains="frontend.endpoints.csm001.cloud.goog"

gcloud certificate-manager maps create mcg-cert-map

gcloud certificate-manager maps entries create mcg-cert-map-entry \
    --map="mcg-cert-map" \
    --certificates="mcg-cert" \
    --hostname="frontend.endpoints.csm001.cloud.goog"
```

### create policies for LB and apply to clusters
```
gcloud compute security-policies create edge-fw-policy \
    --description "Block XSS attacks"

gcloud compute security-policies rules create 1000 \
    --security-policy edge-fw-policy \
    --expression "evaluatePreconfiguredExpr('xss-stable')" \
    --action "deny-403" \
    --description "XSS attack filtering"

for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/policies/cloud-armor.yaml
    kubectl --context $CONTEXT apply -f ${WORKDIR}/policies/ingress-gateway-healthcheck.yaml
done
```