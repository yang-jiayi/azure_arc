#!/bin/bash
exec >installCAPI.log
exec 2>&1

sudo apt-get update

sudo sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config
sudo adduser staginguser --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
sudo echo "staginguser:ArcPassw0rd" | sudo chpasswd

# Injecting environment variables from Azure deployment
echo '#!/bin/bash' >> vars.sh
echo $adminUsername:$1 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_ID:$2 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_SECRET:$3 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_TENANT_ID:$4 | awk '{print substr($1,2); }' >> vars.sh
echo $vmName:$5 | awk '{print substr($1,2); }' >> vars.sh
echo $location:$6 | awk '{print substr($1,2); }' >> vars.sh
echo $stagingStorageAccountName:$7 | awk '{print substr($1,2); }' >> vars.sh
echo $logAnalyticsWorkspace:$8 | awk '{print substr($1,2); }' >> vars.sh
echo $capiArcDataClusterName:$9 | awk '{print substr($1,2); }' >> vars.sh
echo $templateBaseUrl:${10} | awk '{print substr($1,2); }' >> vars.sh
sed -i '2s/^/export adminUsername=/' vars.sh
sed -i '3s/^/export SPN_CLIENT_ID=/' vars.sh
sed -i '4s/^/export SPN_CLIENT_SECRET=/' vars.sh
sed -i '5s/^/export SPN_TENANT_ID=/' vars.sh
sed -i '6s/^/export vmName=/' vars.sh
sed -i '7s/^/export location=/' vars.sh
sed -i '8s/^/export stagingStorageAccountName=/' vars.sh
sed -i '9s/^/export logAnalyticsWorkspace=/' vars.sh
sed -i '10s/^/export capiArcDataClusterName=/' vars.sh
sed -i '11s/^/export templateBaseUrl=/' vars.sh

chmod +x vars.sh
. ./vars.sh

# Creating login message of the day (motd)
sudo curl -o /etc/profile.d/welcomeCAPI.sh ${templateBaseUrl}artifacts/welcomeCAPI.sh

# Syncing this script log to 'jumpstart_logs' directory for ease of troubleshooting
sudo -u $adminUsername mkdir -p /home/${adminUsername}/jumpstart_logs
while sleep 1; do sudo -s rsync -a /var/lib/waagent/custom-script/download/0/installCAPI.log /home/${adminUsername}/jumpstart_logs/installCAPI.log; done &

# Installing Azure CLI & Azure Arc extensions
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

sudo -u $adminUsername az extension add --name connectedk8s
sudo -u $adminUsername az extension add --name k8s-configuration
sudo -u $adminUsername az extension add --name k8s-extension

echo "Log in to Azure"
sudo -u $adminUsername az login --service-principal --username $SPN_CLIENT_ID --password=$SPN_CLIENT_SECRET --tenant $SPN_TENANT_ID
subscriptionId=$(sudo -u $adminUsername az account show --query id --output tsv)
export AZURE_RESOURCE_GROUP=$(sudo -u $adminUsername az resource list --query "[?name=='$stagingStorageAccountName']".[resourceGroup] --resource-type "Microsoft.Storage/storageAccounts" -o tsv)
az -v
echo ""

# Installing snap
sudo apt install snapd

# Installing jq
sudo apt install jq -y

# Installing kustomize
sudo snap install kustomize

# Set CAPI deployment environment variables
export KUBECTL_VERSION="1.28/stable" # Do not change!
export CLUSTERCTL_VERSION="1.5.2" # Do not change!
export CAPI_PROVIDER="azure" # Do not change!
export CAPI_PROVIDER_VERSION="1.7.6" # Do not change!
export KUBERNETES_VERSION="1.28.2" # Do not change!
export CALICO_VERSION="v3.25.2" # Do not change!
export AZURE_DISK_CSI_DRIVER_VERSION="1.29.0" # Do not change!
export K3S_VERSION="1.28.2+k3s1" # Do not change!
export AZURE_ENVIRONMENT="AzurePublicCloud" # Do not change!
export CONTROL_PLANE_MACHINE_COUNT="3" # Do not change!
export WORKER_MACHINE_COUNT="3"
export AZURE_LOCATION=$location # Name of the Azure datacenter location.
export CLUSTER_NAME=$(echo "${capiArcDataClusterName,,}") # Converting to lowercase case variable > # Name of the CAPI workload cluster. Must consist of lower case alphanumeric characters, '-' or '.', and must start and end with an alphanumeric character (e.g. 'example.com', regex used for validation is '[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*')
export AZURE_SUBSCRIPTION_ID=$subscriptionId
export AZURE_TENANT_ID=$SPN_TENANT_ID
export AZURE_CLIENT_ID=$SPN_CLIENT_ID
export AZURE_CLIENT_SECRET=$SPN_CLIENT_SECRET
export AZURE_CONTROL_PLANE_MACHINE_TYPE="Standard_D4s_v4"
export AZURE_NODE_MACHINE_TYPE="Standard_D8s_v4"

# Base64 encode the variables - Do not change!
export AZURE_SUBSCRIPTION_ID_B64="$(echo -n "$subscriptionId" | base64 | tr -d '\n')"
export AZURE_TENANT_ID_B64="$(echo -n "$SPN_TENANT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_ID_B64="$(echo -n "$SPN_CLIENT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_SECRET_B64="$(echo -n "$SPN_CLIENT_SECRET" | base64 | tr -d '\n')"

# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

# Installing kubectl
sudo snap install kubectl --channel=$KUBECTL_VERSION --classic

# Installing Rancher K3s cluster (single control plane)
echo ""
sudo mkdir ~/.kube
sudo -u $adminUsername mkdir /home/${adminUsername}/.kube
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik" INSTALL_K3S_VERSION=v${K3S_VERSION} sh -
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
sudo kubectl config rename-context default arcdatacapimgmt --kubeconfig /etc/rancher/k3s/k3s.yaml
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo cp /etc/rancher/k3s/k3s.yaml /home/${adminUsername}/.kube/config
sudo cp /etc/rancher/k3s/k3s.yaml /home/${adminUsername}/.kube/config-mgmt
sudo cp /etc/rancher/k3s/k3s.yaml /home/${adminUsername}/.kube/config.staging
sudo chown -R $adminUsername /home/${adminUsername}/.kube/
sudo chown -R staginguser /home/${adminUsername}/.kube/config.staging

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl config set-context arcdatacapimgmt

# Installing clusterctl
echo ""
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTERCTL_VERSION}/clusterctl-linux-amd64 -o clusterctl
sudo chmod +x ./clusterctl
sudo mv ./clusterctl /usr/local/bin/clusterctl
clusterctl version

# Installing Helm 3
echo ""
sudo snap install helm --classic

echo ""
echo "Making sure Rancher K3s cluster is ready..."
echo ""
sudo kubectl wait --for=condition=Available --timeout=60s --all deployments -A >/dev/null
sudo kubectl get nodes -o wide | expand | awk 'length($0) > length(longest) { longest = $0 } { lines[NR] = $0 } END { gsub(/./, "=", longest); print "/=" longest "=\\"; n = length(longest); for(i = 1; i <= NR; ++i) { printf("| %s %*s\n", lines[i], n - length(lines[i]) + 1, "|"); } print "\\=" longest "=/" }'
echo ""

# Creating a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"

# Converting the Rancher K3s cluster to a Cluster API management cluster
echo "Converting the Kubernetes cluster to a management cluster with the Cluster API Azure Provider (CAPZ)..."
clusterctl init --infrastructure=azure:v${CAPI_PROVIDER_VERSION} --wait-providers
echo "Making sure cluster is ready..."
echo ""
sudo kubectl wait --for=condition=Available --timeout=60s --all deployments -A >/dev/null
echo ""

# Creating CAPI Workload cluster yaml manifest
echo "Deploying Kubernetes workload cluster"
echo ""
sudo curl -o capz_kustomize/patches/AzureCluster.yaml --create-dirs ${templateBaseUrl}artifacts/capz_kustomize/patches/AzureCluster.yaml
sudo curl -o capz_kustomize/patches/Cluster.yaml ${templateBaseUrl}artifacts/capz_kustomize/patches/Cluster.yaml
sudo curl -o capz_kustomize/patches/KubeadmControlPlane.yaml ${templateBaseUrl}artifacts/capz_kustomize/patches/KubeadmControlPlane.yaml
sudo curl -o capz_kustomize/kustomization.yaml ${templateBaseUrl}artifacts/capz_kustomize/kustomization.yaml
sed -e "s|CAPI_PROVIDER_VERSION|v$CAPI_PROVIDER_VERSION|" -i capz_kustomize/kustomization.yaml
kubectl kustomize capz_kustomize/ > jumpstart.yaml
clusterctl generate yaml --from jumpstart.yaml > template.yaml

# Creating Microsoft Defender for Cloud audit secret
echo ""
echo "Creating Microsoft Defender for Cloud audit secret"
echo ""
curl -o audit.yaml https://raw.githubusercontent.com/Azure/Azure-Security-Center/master/Pricing%20%26%20Settings/Defender%20for%20Kubernetes/audit-policy.yaml

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: audit
type: Opaque
data:
  audit.yaml: $(cat "audit.yaml" | base64 -w0)
  username: $(echo -n "jumpstart" | base64 -w0)
EOF

# Deploying CAPI Workload cluster
echo ""
sudo kubectl apply -f template.yaml

echo ""
until sudo kubectl get cluster --all-namespaces | grep -q "Provisioned"; do echo "Waiting for Kubernetes control plane to be in Provisioned phase..." && sleep 20 ; done
echo ""
sudo kubectl get cluster --all-namespaces

echo ""
until sudo kubectl get kubeadmcontrolplane --all-namespaces | grep -q "true"; do echo "Waiting for control plane to initialize. This may take a few minutes..." && sleep 20 ; done
echo ""
sudo kubectl get kubeadmcontrolplane --all-namespaces
clusterctl get kubeconfig $CLUSTER_NAME > $CLUSTER_NAME.kubeconfig
sleep 120
echo ""
helm repo add projectcalico https://docs.tigera.io/calico/charts --kubeconfig=./$CLUSTER_NAME.kubeconfig && \
helm install calico projectcalico/tigera-operator --version $CALICO_VERSION --kubeconfig=./$CLUSTER_NAME.kubeconfig -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-azure/main/templates/addons/calico/values.yaml --namespace tigera-operator --create-namespace

echo ""
while true; do
  # Retrieve the list of nodes
  nodes=$(kubectl get nodes --kubeconfig=./$CLUSTER_NAME.kubeconfig -o json | jq -r '.items[].metadata.name')

  # Flag to keep track of readiness status
  all_ready=true

  # Iterate over each node and check its status
  for node in $nodes; do
    ready=$(kubectl get nodes $node --kubeconfig=./$CLUSTER_NAME.kubeconfig -o json | jq -r '.status.conditions[] | select(.type=="Ready") | .status')
    
    if [[ $ready != "True" ]]; then
      echo "Node $node is not ready."
      all_ready=false
    fi
  done

  # Check if all nodes are ready
  if [[ $all_ready == true ]]; then
    echo "All nodes are ready."
    break
  else
    echo "Waiting for 30 seconds..."
    sleep 30
  fi
done

echo ""
sudo kubectl --kubeconfig=./$CLUSTER_NAME.kubeconfig label node -l '!node-role.kubernetes.io/master' node-role.kubernetes.io/worker=worker
echo ""
sudo kubectl --kubeconfig=./$CLUSTER_NAME.kubeconfig get nodes -o wide | expand | awk 'length($0) > length(longest) { longest = $0 } { lines[NR] = $0 } END { gsub(/./, "=", longest); print "/=" longest "=\\"; n = length(longest); for(i = 1; i <= NR; ++i) { printf("| %s %*s\n", lines[i], n - length(lines[i]) + 1, "|"); } print "\\=" longest "=/" }'

# kubeconfig files housekeeping
echo ""
sudo -u $adminUsername rm -f /home/${adminUsername}/.kube/config.staging
clusterctl get kubeconfig $CLUSTER_NAME > /home/${adminUsername}/.kube/config

sudo service sshd restart

# Creating Storage Class with azure-managed-disk for the CAPI cluster
echo ""
sudo -u $adminUsername kubectl apply -f ${templateBaseUrl}artifacts/capiStorageClass.yaml

# Renaming CAPI cluster context name 
echo ""
sudo -u $adminUsername kubectl config rename-context "$CLUSTER_NAME-admin@$CLUSTER_NAME" "arcdata-capi"

# Onboarding the cluster to Azure Arc
echo ""
workspaceResourceId=$(sudo -u $adminUsername az resource show --resource-group $AZURE_RESOURCE_GROUP --name $logAnalyticsWorkspace --resource-type "Microsoft.OperationalInsights/workspaces" --query id -o tsv)
sudo -u $adminUsername az connectedk8s connect --name $capiArcDataClusterName --resource-group $AZURE_RESOURCE_GROUP --location $location --tags 'Project=jumpstart_azure_arc_data_services' --correlation-id "d009f5dd-dba8-4ac7-bac9-b54ef3a6671a"

# Enabling Microsoft Defender for Containers and Container Insights cluster extensions
echo ""
sudo -u $adminUsername az k8s-extension create -n "azure-defender" --cluster-name $capiArcDataClusterName --resource-group $AZURE_RESOURCE_GROUP --cluster-type connectedClusters --extension-type Microsoft.AzureDefender.Kubernetes --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceResourceId --debug
echo ""
sudo -u $adminUsername az k8s-extension create --name "azuremonitor-containers" --cluster-name $capiArcDataClusterName --resource-group $AZURE_RESOURCE_GROUP --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceResourceId

# Enabling Azure Policy for Kubernetes on the cluster
echo ""
sudo -u $adminUsername az k8s-extension create --name "arc-azurepolicy" --cluster-name $capiArcDataClusterName --resource-group $AZURE_RESOURCE_GROUP --cluster-type connectedClusters --extension-type Microsoft.PolicyInsights

# Deploying The Azure disk Container Storage Interface (CSI) Kubernetes driver
echo ""
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/v${AZURE_DISK_CSI_DRIVER_VERSION}/deploy/install-driver.sh -o install-driver.sh
sed -i 's/kubectl apply/sudo -u ${adminUsername} kubectl apply/g' install-driver.sh
source ./install-driver.sh v${AZURE_DISK_CSI_DRIVER_VERSION} snapshot --

# Copying workload CAPI kubeconfig file to staging storage account
echo ""
sudo -u $adminUsername az extension add --upgrade -n storage-preview
storageAccountRG=$(sudo -u $adminUsername az storage account show --name $stagingStorageAccountName --query 'resourceGroup' | sed -e 's/^"//' -e 's/"$//')
storageContainerName="staging-capi"
export localPath="/home/${adminUsername}/.kube/config"
storageAccountKey=$(sudo -u $adminUsername az storage account keys list --resource-group $storageAccountRG --account-name $stagingStorageAccountName --query [0].value | sed -e 's/^"//' -e 's/"$//')
sudo -u $adminUsername az storage container create -n $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey
sudo -u $adminUsername az storage azcopy blob upload --container $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey --source $localPath

# Uploading this script log to staging storage for ease of troubleshooting
echo ""
log="/home/${adminUsername}/jumpstart_logs/installCAPI.log"
sudo -u $adminUsername az storage azcopy blob upload --container $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey --source $log