# csmdemo

### shortcut to get env vars setup for shell 
```
export PROJECT=mesh-demo-01
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT} --format="value(projectNumber)")
gcloud config set project ${PROJECT}
cd ${HOME}/csmdemo
export WORKDIR=`pwd`
export KUBECONFIG=${WORKDIR}/csmdemo_kubeconfig
gcloud config set accessibility/screen_reader false
export CLUSTER_1_NAME=edge-to-mesh-01
export CLUSTER_2_NAME=edge-to-mesh-02
export PUBLIC_ENDPOINT=frontend.endpoints.${PROJECT}.cloud.goog
```

### new environment / context for ASM
```
export PROJECT=mesh-demo-01
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT} --format="value(projectNumber)")
gcloud config set project ${PROJECT}

# set up kubeconfig
cd ${HOME}/csmdemo
export WORKDIR=`pwd`
# touch csmdemo_kubeconfig # only need this once
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
  certificatemanager.googleapis.com \
  cloudtrace.googleapis.com \
  anthos.googleapis.com \
  servicenetworking.googleapis.com

export CLUSTER_1_NAME=edge-to-mesh-01
export CLUSTER_2_NAME=edge-to-mesh-02
export CLUSTER_1_REGION=us-central1
export CLUSTER_2_REGION=us-east4
export PUBLIC_ENDPOINT=frontend.endpoints.${PROJECT}.cloud.goog

# using Argolis, so need to create default VPC
gcloud compute networks create default --project=${PROJECT} --subnet-mode=auto --mtu=1460 --bgp-routing-mode=regional

# create clusters
gcloud container clusters create-auto --async \
${CLUSTER_1_NAME} --region ${CLUSTER_1_REGION} \
--release-channel rapid --labels mesh_id=proj-${PROJECT_NUMBER} \
--enable-private-nodes --enable-fleet

gcloud container clusters create-auto \
${CLUSTER_2_NAME} --region ${CLUSTER_2_REGION} \
--release-channel rapid --labels mesh_id=proj-${PROJECT_NUMBER} \
--enable-private-nodes --enable-fleet

gcloud container clusters get-credentials ${CLUSTER_1_NAME} \
    --region ${CLUSTER_1_REGION}

kubectl config rename-context gke_${PROJECT}_${CLUSTER_1_REGION}_${CLUSTER_1_NAME} ${CLUSTER_1_NAME}
kubectl config rename-context gke_${PROJECT}_${CLUSTER_2_REGION}_${CLUSTER_2_NAME} ${CLUSTER_2_NAME}
```

### enable mesh
```
gcloud container fleet mesh enable

gcloud container fleet mesh update \
    --management automatic \
    --memberships ${CLUSTER_1_NAME},${CLUSTER_2_NAME}
```

### deploy GKE Gateway and mesh ingress
```
kubectl --context=${CLUSTER_1_NAME} create namespace asm-ingress
kubectl --context=${CLUSTER_2_NAME} create namespace asm-ingress

kubectl --context=${CLUSTER_1_NAME} label namespace asm-ingress istio-injection=enabled
kubectl --context=${CLUSTER_2_NAME} label namespace asm-ingress istio-injection=enabled

openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
 -subj "/CN=frontend.endpoints.${PROJECT}.cloud.goog/O=Edge2Mesh Inc" \
 -keyout ${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.key \
 -out ${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.crt

kubectl --context ${CLUSTER_1_NAME} -n asm-ingress create secret tls \
 edge2mesh-credential \
 --key=${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.key \
 --cert=${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.crt
kubectl --context ${CLUSTER_2_NAME} -n asm-ingress create secret tls \
 edge2mesh-credential \
 --key=${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.key \
 --cert=${WORKDIR}/frontend.endpoints.${PROJECT}.cloud.goog.crt

kubectl --context ${CLUSTER_1_NAME} apply -k ${WORKDIR}/asm-ig/variant
kubectl --context ${CLUSTER_2_NAME} apply -k ${WORKDIR}/asm-ig/variant

gcloud container fleet multi-cluster-services enable

gcloud projects add-iam-policy-binding ${PROJECT} \
 --member "serviceAccount:${PROJECT}.svc.id.goog[gke-mcs/gke-mcs-importer]" \
 --role "roles/compute.networkViewer"

for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/mcs/svc_export.yaml
done
```

### create IP, DNS and TLS resources
```
gcloud compute addresses create mcg-ip --global

export MCG_IP=$(gcloud compute addresses describe mcg-ip --global --format "value(address)")
echo ${MCG_IP}

gcloud endpoints services deploy ${WORKDIR}/endpoints/dns-spec.yaml

gcloud certificate-manager certificates create mcg-cert \
    --domains="frontend.endpoints.${PROJECT}.cloud.goog"

gcloud certificate-manager maps create mcg-cert-map

gcloud certificate-manager maps entries create mcg-cert-map-entry \
    --map="mcg-cert-map" \
    --certificates="mcg-cert" \
    --hostname="frontend.endpoints.${PROJECT}.cloud.goog"
```

### create backend policies and load balancer
```
gcloud compute security-policies create edge-fw-policy \
    --description "Block XSS attacks"

gcloud compute security-policies rules create 1000 \
    --security-policy edge-fw-policy \
    --expression "evaluatePreconfiguredExpr('xss-stable')" \
    --action "deny-403" \
    --description "XSS attack filtering"

for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/policies/
done

gcloud container fleet ingress enable \
  --config-membership=${CLUSTER_1_NAME} \
  --location=${CLUSTER_1_REGION}

gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-multiclusteringress.iam.gserviceaccount.com" \
    --role "roles/container.admin"

for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do
    kubectl --context $CONTEXT apply -f ${WORKDIR}/gateway/
done
```

### enable Cloud Trace & Access Logging on the mesh
```
# this specific section only seems to enable access logging, not tracing, as this requires allow-listing
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/observability/enable.yaml
done

# so we use the telemetry API instead
# note: at CSM launch, tracing only samples @ 1%
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/observability/telemetry-for-tracing.yaml
done
```

### prepare workloads for tracing via Workload Identity
```
# create GSA for writing traces 
gcloud iam service-accounts create whereami-tracer \
    --project=${PROJECT}

gcloud projects add-iam-policy-binding ${PROJECT} \
    --member "serviceAccount:whereami-tracer@${PROJECT}.iam.gserviceaccount.com" \
    --role "roles/cloudtrace.agent"

# map to KSAs
gcloud iam service-accounts add-iam-policy-binding whereami-tracer@${PROJECT}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT}.svc.id.goog[frontend/whereami-frontend]"

gcloud iam service-accounts add-iam-policy-binding whereami-tracer@${PROJECT}.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT}.svc.id.goog[backend/whereami-backend]"
```

### configure default cluster-wide `ALLOW NONE` AuthorizationPolicy
```
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context $CONTEXT apply -f ${WORKDIR}/authz/allow-none.yaml
done
```

### deploy AuthorizationPolicy for ingress gateway
```
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/asm-ingress.yaml
done
```

### deploy demo `whereami` app for frontend and scaffolding for backend-v1
```
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT create ns backend
    kubectl --context=$CONTEXT label namespace backend istio-injection=enabled
    kubectl --context=$CONTEXT create ns frontend
    kubectl --context=$CONTEXT label namespace frontend istio-injection=enabled
    kubectl --context=$CONTEXT apply -k ${WORKDIR}/whereami-frontend/variant
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/frontend.yaml
done

# set up frontend virtualService
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/whereami-frontend/frontend-vs.yaml
done
```

# DEMO START

### check endpoint and verify that frontend service is responding

you should see responses from both regions, but only from the frontend service
```
watch -n 0.1 'curl -s https://frontend.endpoints.${PROJECT}.cloud.goog | jq'
```

note how requests are being bounced across regions - this isn't typically ideal because it increases latency and increases costs, especially once we add another service

### demo HTTP->HTTPS redirect

in a browser, navigate to `http://frontend.endpoints.mesh-demo-01.cloud.goog`

notice that browser will be redirected to `https://frontend.endpoints.mesh-demo-01.cloud.goog`

### deploy demo `whereami` app for backend-v1
```
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -k ${WORKDIR}/whereami-backend/variant-v1
done
```

hmmm, but it isn't working... why? because we have a default `ALLOW NONE` AuthorizationPolicy

### deploy AuthorizationPolicy for backend workload
```
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/authz/backend.yaml
done
```

### tracing demo pt. 1

check the trace console (or mesh console, which also includes traces) to verify that traces are there - also note that latency is inconsistent due to lack of locality

also point out how the `gce_service_account` reflects a GSA that has tracing access (trace agent, specifically)

### enable locality
```
# apply destinationRules for locality
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -f ${WORKDIR}/locality/
done
```

> note: after some time, demonstrate delta in trace latency

### tracing demo pt. 2

return to the trace console to see that latency has reduced

### test resiliency by 'failing' us-central1 ingress gateway pods
```
# first scale to zero to show failover
for CONTEXT in ${CLUSTER_1_NAME} 
do 
    kubectl --context=$CONTEXT -n asm-ingress scale --replicas=0 deployment/asm-ingressgateway
done

# then scale back up to restore ingress gateways in local region
for CONTEXT in ${CLUSTER_1_NAME}
do 
    kubectl --context=$CONTEXT -n asm-ingress scale --replicas=3 deployment/asm-ingressgateway
done
```

### demo traffic splitting for backend from v1 to v2
```
# start by setting up VS for splitting
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n backend apply -f ${WORKDIR}/traffic-splitting/vs-0.yaml
done

# deploy v2 of backend service
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT apply -k ${WORKDIR}/whereami-backend/variant-v2
done
```

### scratch 
```
# restart ingress gateway pods
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n asm-ingress rollout restart deployment asm-ingressgateway
done

# restart backend pods
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n backend rollout restart deployment whereami-backend
done

# restart frontend pods
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n frontend rollout restart deployment whereami-frontend
done

# remove backend service
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT delete -k ${WORKDIR}/whereami-backend/variant-v1
done

# remove PeerAuthentication policy
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n frontend delete -f ${WORKDIR}/mtls/
    kubectl --context=$CONTEXT -n backend delete -f ${WORKDIR}/mtls/
done

# remove locality 
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT delete -f ${WORKDIR}/locality/
done
```

### don't use
```
# set strict peer auth (mTLS) policy
for CONTEXT in ${CLUSTER_1_NAME} ${CLUSTER_2_NAME}
do 
    kubectl --context=$CONTEXT -n frontend apply -f ${WORKDIR}/mtls/
    kubectl --context=$CONTEXT -n backend apply -f ${WORKDIR}/mtls/
done
```