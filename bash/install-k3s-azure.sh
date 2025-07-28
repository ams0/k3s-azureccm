#!/bin/bash

#change CIDR as needed
CIDR="10.244.0.0/16"

ufw allow 6443/tcp
ufw allow 443/tcp
ufw allow 22/tcp

# #change default SSH port
# echo "Port 2222" >>  /etc/ssh/sshd_config
# systemctl restart sshd


apt-get update 
apt-get install -y jq

RG=$(curl -sL -H "metadata:true" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | jq -r .compute.resourceGroupName)
SUB_ID=$(curl -sL -H "metadata:true" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | jq -r .compute.subscriptionId)
LOCATION=$(curl -sL -H "metadata:true" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | jq -r .compute.location)

#get tenantid from anonymous call to azure api
tempstring=$(curl -v https://management.azure.com/subscriptions/${SUB_ID}?api-version=2015-01-01 2>&1 | grep Bearer)
value=${tempstring#*t/}
tenantid=${value:0:36}

curl -sfL https://get.k3s.io | sh -s - server --tls-san k3sapi-${RG}.${LOCATION}.cloudapp.azure.com --cluster-cidr ${CIDR} --write-kubeconfig-mode 644 --disable-cloud-controller --disable traefik --disable servicelb

#install canal for network policies https://dev.to/jmarhee/network-policies-with-canal-and-flannel-on-k3s-11oe
curl -Ls https://docs.projectcalico.org/manifests/canal.yaml | sed -e 's|            # - name: CALICO_IPV4POOL_CIDR|            - name: CALICO_IPV4POOL_CIDR|g' -e "s|            #   value: \"192.168.0.0/16\"|              value: \"${CIDR}\"|g" | \
tee -a /var/lib/rancher/k3s/server/manifests/canal.yaml

mkdir /etc/kubernetes
cat << EOF > /etc/kubernetes/azure.json
{
    "cloud": "AzurePublicCloud",
    "tenantId": "${tenantid}",
    "subscriptionId": "${SUB_ID}",
    "resourceGroup": "${RG}",
    "vnetResourceGroup": "${RG}",
    "location": "${LOCATION}",
    "subnetName": "k3ssubnet",
    "securityGroupName": "k3snsg",
    "vnetName": "k3svnet",
    "vmType": "standard",
    "primaryAvailabilitySetName": "k3sas",
    "routeTableName": "k3srt",
    "cloudProviderBackoff": false,
    "useManagedIdentityExtension": true,
    "useInstanceMetadata": true,
    "loadBalancerSku": "Standard",
    "excludeMasterFromStandardLB": false
}
EOF

kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:cloud-controller-manager
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    k8s-app: cloud-controller-manager
rules:
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
      - update
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - "*"
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch
  - apiGroups:
      - ""
    resources:
      - services
    verbs:
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - services/status
    verbs:
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - serviceaccounts
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - persistentvolumes
    verbs:
      - get
      - list
      - update
      - watch
  - apiGroups:
      - "discovery.k8s.io"
    resources:
      - endpointslices
    verbs:
      - create
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - endpoints
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - coordination.k8s.io
    resources:
      - leases
    verbs:
      - get
      - create
      - update
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: system:cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:cloud-controller-manager
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
  - kind: User
    name: cloud-controller-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: system:cloud-controller-manager:extension-apiserver-authentication-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
  - apiGroup: ""
    kind: User
    name: cloud-controller-manager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloud-controller-manager
  namespace: kube-system
  labels:
    tier: control-plane
    component: cloud-controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      tier: control-plane
      component: cloud-controller-manager
  template:
    metadata:
      labels:
        tier: control-plane
        component: cloud-controller-manager
    spec:
      priorityClassName: system-node-critical
      hostNetwork: true
      serviceAccountName: cloud-controller-manager
      tolerations:
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      containers:
        - name: cloud-controller-manager
          image: mcr.microsoft.com/oss/kubernetes/azure-cloud-controller-manager:v1.33.2
          imagePullPolicy: IfNotPresent
          command: ["cloud-controller-manager"]
          args:
            - "--allocate-node-cidrs=true" # "false" for Azure CNI and "true" for other network plugins
            - "--cloud-config=/etc/kubernetes/azure.json"
            - "--cloud-provider=azure"
            - "--cluster-cidr=${CIDR}"
            - "--cluster-name=k8s"
            - "--controllers=*,-cloud-node" # disable cloud-node controller
            - "--configure-cloud-routes=true" # "false" for Azure CNI and "true" for other network plugins
            - "--leader-elect=true"
            - "--route-reconciliation-period=10s"
            - "--v=2"
            - "--secure-port=10267"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "4"
              memory: 2Gi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 10267
              scheme: HTTPS
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 5
          volumeMounts:
            - mountPath: /etc/kubernetes/azure.json
              name: azurejson
            - name: etc-ssl
              mountPath: /etc/ssl
              readOnly: true
            - name: msi
              mountPath: /var/lib/waagent/ManagedIdentity-Settings
              readOnly: true
      volumes:
        - name: azurejson
          hostPath:
            path: /etc/kubernetes/azure.json
            type: FileOrCreate
        - name: etc-ssl
          hostPath:
            path: /etc/ssl
        - name: msi
          hostPath:
            path: /var/lib/waagent/ManagedIdentity-Settings
EOF

#Blob fuse storage class
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/deploy/install-driver.sh | bash -s master blobfuse-proxy --
kubectl create -f https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/deploy/example/storageclass-blobfuse.yaml
kubectl scale deploy -n kube-system csi-blob-controller --replicas 1

#AzureDisk
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/deploy/install-driver.sh | bash -s master snapshot --
kubectl create -f https://raw.githubusercontent.com/kubernetes-sigs/azuredisk-csi-driver/master/deploy/example/storageclass-azuredisk-csi.yaml
kubectl scale deploy -n kube-system csi-azuredisk-controller --replicas 1

#AzureFiles
curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/master/deploy/install-driver.sh | bash -s master --
kubectl create -f https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/master/deploy/example/storageclass-azurefile-csi.yaml
kubectl create -f https://raw.githubusercontent.com/kubernetes-sigs/azurefile-csi-driver/master/deploy/example/storageclass-azurefile-nfs.yaml
kubectl scale deploy -n kube-system csi-azurefile-controller --replicas 1

cp /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml
chmod 0644 /tmp/k3s.yaml