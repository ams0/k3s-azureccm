#Deploys a VM with k3s with CCM (cloudcontroller-manager) for azure
#https://docs.microsoft.com/en-us/azure/aks/out-of-tree

RESOURCE_GROUP=$1
LOCATION=${2:-swedencentral}
echo "Creating resource group '${RESOURCE_GROUP}'.."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
echo "Done"

echo "Creating vnet 'k3svnet' .."
az network vnet create -g "${RESOURCE_GROUP}" --location "${LOCATION}" -n k3svnet --address-prefixes 10.224.60.0/23 
echo "Done"

echo "Creating managed identity 'k3sid' and assigning Contributor role to vnet .."
PRINCIPAL_ID=$(az identity create -g "${RESOURCE_GROUP}" --location "${LOCATION}" --name k3sid -o tsv --query principalId)
RG_ID=$(az group show -g "${RESOURCE_GROUP}" -o tsv --query 'id')
echo "wait for AAD propagation.."
sleep 60
az role assignment create --role "Contributor" --assignee ${PRINCIPAL_ID} --scope ${RG_ID}
az role assignment create --role "Network Contributor" --assignee ${PRINCIPAL_ID} --scope ${RG_ID}
echo "Done"

echo "Creating NSG 'k3snsg'.."
az network nsg create  -g "${RESOURCE_GROUP}" --location "${LOCATION}" --name k3snsg
az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name k3snsg --name Allow-SSH-All --access Allow --protocol Tcp --direction Inbound --priority 300 --source-address-prefix Internet --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22
az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name k3snsg --name Allow-API-All --access Allow --protocol Tcp --direction Inbound --priority 301 --source-address-prefix Internet --source-port-range "*" --destination-address-prefix "*" --destination-port-range 6443

echo "Done"

echo "Creating route table 'k3srt'.."
az network route-table create -g "${RESOURCE_GROUP}" --location "${LOCATION}" --name k3srt
echo "Done"

echo "Creating subnet 'k3ssubnet'.."
az network vnet subnet create -g "${RESOURCE_GROUP}" --vnet-name k3svnet --name k3ssubnet --address-prefixes 10.224.60.0/24 --route-table k3srt --nsg k3snsg
echo "Done"

echo "Creating network interface 'k3snic'.."
az network nic create -g "${RESOURCE_GROUP}" --location "${LOCATION}" -n k3snic --subnet k3ssubnet --vnet-name k3svnet  --private-ip-address 10.224.60.10
echo "Done"

# echo "Creating route 'k3sroute'.."
# az network route-table route create -g "${RESOURCE_GROUP}"  --address-prefix 10.244.0.0/24 -n k3sroute --route-table-name k3srt --next-hop-type VirtualAppliance --next-hop-ip-address 10.224.60.10
# echo "Done"

echo "Creating publicip 'k3sip' with name DNS ${RESOURCE_GROUP}api.${LOCATION}.cloudapp.azure.com.."
az network public-ip create --sku Standard  -g "${RESOURCE_GROUP}" --location "${LOCATION}" --allocation-method Static -n k3sip --dns-name k3sapi-${RESOURCE_GROUP}
echo "Done"

echo "Creating lb "${LB_NAME}" and backed address pool for k3s API and SSH access.."
LB_NAME=k8s
az network lb create --sku Standard -g "${RESOURCE_GROUP}" --location "${LOCATION}" -n "${LB_NAME}" --backend-pool-name k3spool --frontend-ip-name k3sip --public-ip-address k3sip 
az network lb address-pool create -g "${RESOURCE_GROUP}"  --lb-name "${LB_NAME}" -n sshpool --backend-address name=k3sap ip-address=10.224.60.10 subnet=k3ssubnet --vnet k3svnet
az network lb probe create --lb-name "${LB_NAME}" -g "${RESOURCE_GROUP}" --port 22 -n sshprobe --protocol Tcp
az network lb inbound-nat-rule create --lb-name "${LB_NAME}" -g "${RESOURCE_GROUP}" --frontend-ip-name k3sip -n ssh24 --backend-pool-name sshpool --backend-port 22 --protocol Tcp --frontend-port-range-start  2224 --frontend-port-range-end 2224
az network lb probe create --lb-name "${LB_NAME}" -g "${RESOURCE_GROUP}" --port 6443 -n apiprobe --protocol Tcp
az network lb rule create --lb-name "${LB_NAME}" -g "${RESOURCE_GROUP}" --frontend-ip-name k3sip -n apirule --backend-port 6443  --protocol Tcp --frontend-port 6443 --backend-pool-name sshpool --probe-name apiprobe
#az network lb address-pool address add --ip-address 10.224.60.10 --lb-name "${LB_NAME}"  -n k3svm  --pool-name k3spool -g "${RESOURCE_GROUP}" --subnet k3ssubnet --vnet k3svnet
#az network lb inbound-nat-rule create --backend-port 22 --lb-name "${LB_NAME}" -n SSH --protocol Tcp -g "${RESOURCE_GROUP}" --backend-pool-name k3spool --frontend-ip-name k3sip --frontend-port-range-end 50000 --frontend-port-range-start 50000
#az network lb inbound-nat-rule create --backend-port 6443 --lb-name "${LB_NAME}" -n api --protocol Tcp -g "${RESOURCE_GROUP}" --backend-pool-name k3spool --frontend-ip-name k3sip --frontend-port-range-end 6443 --frontend-port-range-start 6443
echo "Done"

echo "Creating SSH public key 'k3skey${RESOURCE_GROUP}' from ~/.ssh/id_rsa.pub.."
PUBKEY=$(cat ~/.ssh/id_rsa.pub)
az sshkey create -n k3skey${RESOURCE_GROUP} -g "${RESOURCE_GROUP}" --location "${LOCATION}" --public-key "${PUBKEY}"
echo "Done"

echo "Creating VM 'k3s'.."
ID_RESOURCEID=$(az identity show -g "${RESOURCE_GROUP}" -n k3sid -o tsv --query id)
sleep 5
az vm availability-set create -g "${RESOURCE_GROUP}" --location "${LOCATION}" -n k3sas
az vm create -g "${RESOURCE_GROUP}" --location "${LOCATION}" -n k3s --availability-set k3sas  --image  Canonical:ubuntu-24_04-lts:server:latest --assign-identity ${ID_RESOURCEID} \
--size Standard_B4ms  --ssh-key-name k3skey${RESOURCE_GROUP} \
--nics k3snic --admin-username k3s --custom-data install-k3s-azure.sh
echo "Done"

echo "Retrieving k3s-${RESOURCE_GROUP}.yaml"
sleep 60
scp -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -P 2224 k3s@k3sapi-${RESOURCE_GROUP}.${LOCATION}.cloudapp.azure.com:/tmp/k3s.yaml ./k3s-${RESOURCE_GROUP}.yaml
sed -i.bak "s;https://127.0.0.1:6443;https://k3sapi-${RESOURCE_GROUP}.${LOCATION}.cloudapp.azure.com:6443;g" k3s-${RESOURCE_GROUP}.yaml

echo "Testing the cluster.."
export KUBECONFIG=./k3s-${RESOURCE_GROUP}.yaml
kubectl cluster-info
echo "Done. Now run yourself: export KUBECONFIG=./k3s-${RESOURCE_GROUP}.yaml to access the cluster"
# curling newly create PIPs takes 30 sec
# deleting the svc takes a bit 

