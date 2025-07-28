# Deploy a single node Kubernetes cluster with Azure Cloud Controller Manager (CCM) support

This script deploys a single node Kubernetes cluster on Azure with the Azure Cloud Controller Manager (CCM) enabled. It uses `kubeadm` for the setup and configures the necessary components to allow Kubernetes to manage Azure resources. Just run:

```bash
./k3s-azure.sh <name> <location>
```

The script uses the default public key at `~/.ssh/id_rsa.pub`; also, it deploys an azure load balancer with one frontend IP and a backend pool with the node's private IP, with two probes for the SSH service and for the Kubernetes API server. It also creates a security group with rules to allow SSH and Kubernetes API traffic.

## Access

After the deployment, you can access the Kubernetes API server using the following command:

```bash
kubectl --kubeconfig kubeconfig get nodes
```

and you can SSH into the node using:

```bash
ssh  k3s@<public-ip-of-the-loadbalancer> -p 2222
```
