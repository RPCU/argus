```bash
╭─ impure khoa@totoro ☸ kubernetes-admin@openstack in  …/argus on  main
╰─❯ kubectl get secret rook-ceph-client-glance -n rook-ceph -o yaml \
   | yq 'del(.metadata.uid)' \
   | yq 'del(.metadata.creationTimestamp)' \
   | yq 'del(.metadata.resourceVersion)' \
   | yq 'del(.metadata.ownerReferences)' \
   | yq 'del(.metadata.namespace)' \
   | kubectl apply -n yaook -f -

╭─ impure khoa@totoro ☸ kubernetes-admin@openstack in  …/argus on  main
╰─❯ kubectl get secret rook-ceph-client-cinder -n rook-ceph -o yaml \
   | yq 'del(.metadata.uid)' \
   | yq 'del(.metadata.creationTimestamp)' \
   | yq 'del(.metadata.resourceVersion)' \
   | yq 'del(.metadata.ownerReferences)' \
   | yq 'del(.metadata.namespace)' \
   | kubectl apply -n yaook -f -


╭─ impure khoa@totoro ☸ kubernetes-admin@openstack in  …/argus on  main
╰─❯ kubectl get secret rpcu-root -n cert-manager -o yaml \
   | yq 'del(.metadata.uid)' \
   | yq 'del(.metadata.creationTimestamp)' \
   | yq 'del(.metadata.resourceVersion)' \
   | yq 'del(.metadata.ownerReferences)' \
   | yq 'del(.metadata.namespace)' \
   | kubectl apply -n yaook -f -
```
