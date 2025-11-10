# lab254

Lab254 is my personal homelab running Kubernetes

## Prerequisites

- `talosctl`
- `talhelper`

## Setting up the lab 

1. Update the `talos/talconfig.yaml` file to match your environment
2. Run `task talos:generate-config` to generate the Talos machine configurations
3. Run `task talos:apply-config IP=<MACHINE_IP>` for each machine you want to set up
4. Wait for the machines to reboot..
5. Run `task bootstrap:talos` to bootstrap your Talos cluster
6. Run `task talos:fetch-kubeconfig` to retrieve the cluster's kubeconfig file 
7. Set the retrieved kubeconfig file as the one `kubectl` should use: `export KUBECONFIG=$(pwd)/kubeconfig`
8. Run `task bootstrap:network` to set up Cilium as the CNI.
