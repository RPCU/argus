# Manual Cluster Bootstrap Instructions

This document outlines the steps to manually bootstrap an OpenStack cluster before it is fully reconciled by Flux. These steps are crucial for the initial setup of a new cluster.

## Requirements

See [this document](https://docs.rpcu.io/onboarding/#prerequisites)

## Optionnal
You can execute all task with runme:

- In your terminal:
```sh {"excludeFromRunAll":"true"}
runme run --all --allow-unnamed
```

- Or in your browser
```sh {"excludeFromRunAll":"true"}
# Select your cluster kubeconfig and context first
runme open
```

## 1. Install Cilium

First, install Cilium using Helm. This will set up the Container Network Interface (CNI) for your Kubernetes cluster.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium -n kube-system --create-namespace -f ./infrastructure/cilium/values.yaml --version 1.18.6
```

## 2. Install Flux Operator

Next, install the Flux Operator. This operator is responsible for managing Flux installations.

```bash
kustomize build infrastructure/fluxcd/operator/ | kubectl apply -f -
echo "⏳ Waiting for flux-operator deployment to be ready..."
kubectl wait --for=condition=Available deployment/flux-operator -n flux-system --timeout=180s
```

## 3. Apply Patched Flux Instance

Finally, apply the patched Flux instance. This step will configure Flux to reconcile your cluster based on your Git repository.

```bash
kubectl apply -k clusters/openstack/infrastructure/fluxcd/
echo "⏳ Waiting for FluxInstance to be ready..."
kubectl wait --for=condition=Ready fluxinstance/flux -n flux-system  --timeout=180s
```
