##  1. Installation de Cilium & Bootstrap Flux

```bash
# Installation de Cilium
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.0.0.5 \
  --set k8sServicePort=6443 \
  --set l2announcements.enabled=true \
  --set socketLB.hostNamespaceOnly=true \
  --set envoy.enabled=false \
  --set cni.exclusive=false \
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16 \
  --set ipam.operator.clusterPoolIPv4MaskSize=23

# Bootstrap de FluxCD
kubectl apply -f plateform/flux/bundle.yaml

kubectl apply -f plateform/flux/instance.yaml -n flux-system