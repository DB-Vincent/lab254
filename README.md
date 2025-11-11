# lab254

Lab254 is my personal homelab running Kubernetes

## Prerequisites

- `talosctl`
- `talhelper`

## Setting up the cluster

1. Update the `talos/talconfig.yaml` file to match your environment
2. Run `task talos:generate-config` to generate the Talos machine configurations
3. Run `task talos:apply-config IP=<MACHINE_IP>` for each machine you want to set up
4. Wait for the machines to reboot..
5. Run `task bootstrap:talos` to bootstrap your Talos cluster
6. Run `task talos:fetch-kubeconfig` to retrieve the cluster's kubeconfig file 
7. Set the retrieved kubeconfig file as the one `kubectl` should use: `export KUBECONFIG=$(pwd)/talos/clusterconfig/kubeconfig`
8. Run `task bootstrap:network` to set up Cilium as the CNI.

## Setting up flux

### Configure SOPS

To create the SOPS key, run:

```shell
task sops:setup
```

Replace `<insert your key here>` with your newly created public key in the `.sops.yaml` file at the root of this repository.

Create the `cluster-secrets.sops.yaml` file in `./kubernetes/flux/vars/` with the following content:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-secrets
  namespace: flux-system
stringData:
  SOME_SECRET: SOME_VALUE
```

Create the `github-deploy-key.sops.yaml` file in `./kubernetes/bootstrap/` with the following content:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-deploy-key
  namespace: flux-system
type: Opaque
data:
  identity: YOUR_BASE64_ENCODED_PRIVATE_KEY_USED_TO_PULL_SOURCE_CODE
  known_hosts: A_BASE64_ENCODED_KNOWN_HOSTS_ENTRY
```

The base64 encoded private key can be generated with the following command:

```shell
base64 -w 0 <private_key_path>
```

The known hosts entry can be generated with the following command:

```shell
ssh-keyscan github.com | base64 -w 0
```

Now, encrypt all your `*.sops.yaml` files to avoid leaking any sensitive information when pushing to your Git repository:

```shell
task sops:encrypt-all
```

### Deploy Flux

Adjust Github repository link in `kubernetes/flux/config/cluster.yaml` to match your repository.

**Important:** commit & push changes to git repository before deploying Flux.

```shell
task flux:setup
```