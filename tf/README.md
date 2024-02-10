# Set your project
```bash
export PROJECT_ID=<INSERT_YOUR_PROJECT_ID>
gcloud config set core/project ${PROJECT_ID}
```

# Enable Cloudbuild and grant Cloudbuild SA owner role 
```bash
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format 'value(projectNumber)')
gcloud services enable cloudbuild.googleapis.com
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
gcloud projects add-iam-policy-binding ${PROJECT_ID} --member serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role roles/owner
```

# Building or destroying GCP resources
```bash
gcloud builds submit --substitutions=_PROJECT_ID=${PROJECT_ID}
gcloud builds submit --substitutions=_PROJECT_ID=${PROJECT_ID} --config=cloudbuild_destroy.yaml
```

To delete all firewall rules that begin with the string "vpc":
```bash
for rule in $(gcloud compute firewall-rules list --filter="name~^vpc" --format="value(name)"); do
    gcloud compute firewall-rules delete $rule --quiet
done
```
