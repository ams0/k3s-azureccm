# k3s-azureccm

K3s in azure with cloud controller manager

Simply run:

```
./k3s-azure.sh <resource group name>
```

This deploys:

- A resource group
- A managed identity with `Contributor` and `Network Contributor` roles
- A vnet and subnet
- An Azure Load Balancer with LB rules for SSH access and API access, with a public IP
- A Network Security Group and Route table
- A network interface
- An SSH key (from `~/.ssh/id_rsa.pub`) in Azure
- A Virtual Machine with Ubuntu 20.04 and k3s
- Retrieves the `k3s.yaml` file and exports it as `KUBECONFIG`
- Deploys the out-of-tree [Cloud Controller Manager for Azure](https://github.com/kubernetes-sigs/cloud-provider-azure)
- It re-uses the same Azure Loadbalancer used for SSH and API access, adding more Public IPs as LoadBalancer type services are created