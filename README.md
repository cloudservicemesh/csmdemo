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
for CONTEXT in gke-config gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
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

for CONTEXT in gke-config gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/policies/cloud-armor.yaml
    kubectl --context $CONTEXT apply -f ${WORKDIR}/policies/ingress-gateway-healthcheck.yaml
done
```

### designate config cluster for fleet
```
# use update instead of enable to change this value
gcloud container fleet ingress enable \
  --config-membership=gke-config

gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-multiclusteringress.iam.gserviceaccount.com" \
    --role "roles/container.admin"
```

### deploy the gateway (LB) & HTTPRoute resources to the config cluster
```
kubectl --context=gke-config apply -f ${WORKDIR}/gateway/frontend-gateway.yaml
kubectl --context=gke-config apply -f ${WORKDIR}/gateway/default-httproute.yaml
kubectl --context=gke-config apply -f ${WORKDIR}/gateway/default-httproute-redirect.yaml
```

### enable Cloud Trace & Access Logging on the mesh
```
# this specific section only seems to enable access logging, not tracing, as this requires allow-listing
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/observability/enable.yaml
done

# so we use the telemetry API instead
# note: at CSM launch, tracing only samples @ 1%
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/observability/telemetry-for-tracing.yaml
done
```

### prepare workloads for tracing via Workload Identity
```
# create GSA for writing traces 
gcloud iam service-accounts create whereami-tracer \
    --project=csm001

gcloud projects add-iam-policy-binding csm001 \
    --member "serviceAccount:whereami-tracer@csm001.iam.gserviceaccount.com" \
    --role "roles/cloudtrace.agent"

# map to KSAs
gcloud iam service-accounts add-iam-policy-binding whereami-tracer@csm001.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:csm001.svc.id.goog[frontend/whereami-frontend]"

gcloud iam service-accounts add-iam-policy-binding whereami-tracer@csm001.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:csm001.svc.id.goog[backend/whereami-backend]"
```

### configure default cluster-wide `ALLOW NONE` AuthorizationPolicy
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/authz/allow-none.yaml
done
```

### deploy AuthorizationPolicy for ingress gateway & frontend workload
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/asm-ingress.yaml
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/frontend.yaml
done
```

### deploy demo `whereami` app for frontend and scaffolding for backend-v1
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT create ns backend
    kubectl --context=$CONTEXT label namespace backend istio-injection=enabled
    kubectl --context=$CONTEXT create ns frontend
    kubectl --context=$CONTEXT label namespace frontend istio-injection=enabled
    kubectl --context=$CONTEXT apply -k ${WORKDIR}/whereami-frontend/variant
done

# set up virtualService
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/whereami-frontend/frontend-vs.yaml
done
```

### test endpoint
```
watch -n 0.1 'curl -s https://frontend.endpoints.csm001.cloud.goog | jq'
```

### deploy demo `whereami` app for backend-v1
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT apply -k ${WORKDIR}/whereami-backend/variant-v1
done
```

### deploy AuthorizationPolicy for backend workload
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/backend.yaml
done
```

### enable locality
```
# apply destinationRules
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/locality/
done
```

> note: after some time, demonstrate delta in trace latency

### scratch 
```
# restart ingress gateway pods
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT -n asm-ingress rollout restart deployment asm-ingressgateway
done

# restart backend pods
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT -n backend rollout restart deployment whereami-backend
done

# restart frontend pods
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT -n frontend rollout restart deployment whereami-frontend
done

# remove backend service
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT delete -k ${WORKDIR}/whereami-backend/variant-v1
done

# remove PeerAuthentication policy
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT -n frontend delete -f ${WORKDIR}/mtls/
    kubectl --context=$CONTEXT -n backend delete -f ${WORKDIR}/mtls/
done

# remove locality 
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT delete -f ${WORKDIR}/locality/
done
```

### don't use
```
# or do i need to manually add to TF-generated SAs? (don't think so)
#gcloud projects add-iam-policy-binding csm001     --member "serviceAccount:tf-gke-gke-us-central1-06ab@csm001.iam.gserviceaccount.com"     --role "roles/cloudtrace.agent"
#gcloud projects add-iam-policy-binding csm001     --member "serviceAccount:tf-gke-gke-us-central1-hl8c@csm001.iam.gserviceaccount.com"     --role "roles/cloudtrace.agent"
#gcloud projects add-iam-policy-binding csm001     --member "serviceAccount:tf-gke-gke-us-west2-a--bllw@csm001.iam.gserviceaccount.com"     --role "roles/cloudtrace.agent"
#gcloud projects add-iam-policy-binding csm001     --member "serviceAccount:tf-gke-gke-us-west2-b--8ptm@csm001.iam.gserviceaccount.com"     --role "roles/cloudtrace.agent"
```

### set strict peer auth (mTLS) policy
```
for CONTEXT in gke-us-central1-0 gke-us-central1-1 gke-us-west2-0 gke-us-west2-1
do 
    kubectl --context=$CONTEXT -n frontend apply -f ${WORKDIR}/mtls/
    kubectl --context=$CONTEXT -n backend apply -f ${WORKDIR}/mtls/
done
```