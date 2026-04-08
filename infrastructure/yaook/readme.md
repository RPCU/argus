## labels

```sh
op_and_os_labels="any.yaook.cloud/api=true infra.yaook.cloud/any=true operator.yaook.cloud/any=true key-manager.yaook.cloud/barbican-any-service=true block-storage.yaook.cloud/cinder-any-service=true compute.yaook.cloud/nova-any-service=true ceilometer.yaook.cloud/ceilometer-any-service=true key-manager.yaook.cloud/barbican-keystone-listener=true gnocchi.yaook.cloud/metricd=true infra.yaook.cloud/caching=true network.yaook.cloud/neutron-northd=true network.yaook.cloud/neutron-ovn-agent=true compute.yaook.cloud/hypervisor=true compute.yaook.cloud/hypervisor-type=qemu"

op_and_os_nodes="lucy makise quinn"

for node in ${=op_and_os_nodes}; do
   kubectl label node "$node" ${=op_and_os_labels}
done
```

## Ceph client

```yaml
apiVersion: ceph.rook.io/v1
kind: CephClient
metadata:
  name: glance
  namespace: rook-ceph
spec:
  caps:
    mon: 'profile rbd'
    osd: 'profile rbd pool=rdb-pool'
```
