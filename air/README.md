# Build AWX & Netbox lab on Air

1. Build your own lab with `netbox-awx.dot` and `netbox-awx.svg` files. Don't forget to:

* click "Apply template" in the "Advanced" tab
* in the "ZTP SCRIPT" uncomment the two lines after "SSH key authentication for Ansible"
* unexpire default passwords after the "Uncomment to unexpire and change the default cumulus user password" line.
* uncomment the next line after "Uncomment to make user cumulus passwordless sudo"

2. Enable SSH service and connect to the `netq-ts` server over SSH.

```
ssh ssh://ubuntu@worker04.air.nvidia.com:27230
cumulus@oob-mgmt-server:~$ ssh cumulus@netq-ts
cumulus@netq-ts:~$ sudo -i
root@netq-ts:~#
```

`netq-ts` is running a local Kubernetes cluster which is where AWX and Netbox will be deployed.


3. Enable local persistent volumes

```bash
cat << EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
```

4. Create persistent volumes for netbox

```bash
mkdir -p /root/0
mkdir -p /root/1
mkdir -p /root/2

for path in 0 1 2; do
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-$path
spec:
  capacity:
    storage: 8Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /root/$path
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - netq-ts
EOF
done
```

5. Install arkade (k8s app installer):

```bash
curl -sLS https://get.arkade.dev | sudo sh
echo "export PATH=$PATH:$HOME/.arkade/bin/" >> ~/.bashrc
echo "alias k=kubectl" >> ~/.bashrc
source ~/.bashrc
```

6. Install Helm

```bash
arkade get helm
```

7. Install stern (for logs)

```bash
arkade get stern
```

8. Install kubens and change into the new namespace

```bash
arkade get kubens
kubectl create ns automation && kubens automation
```

9. Install netbox pointing to `local-storage` for PVCs.

```bash
helm repo add bootc https://charts.boo.tc

helm install citc \
--set postgresql.postgresqlPostgresPassword=admin \
--set postgresql.postgresqlPassword=admin \
--set redis.auth.password=admin \
--set persistence.enabled=false \
--set persistence.storageClass=local-storage \
--set postgresql.global.storageClass=local-storage \
--set redis.global.storageClass=local-storage \
--set redis.replica.replicaCount=1 \
--set postgresql.image.tag=12 \
bootc/netbox
```

Wayt for netbox to be deployed:

```
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=netbox --timeout=600s
pod/citc-netbox-5dc5f649f6-d9fzs condition met
```

10. Expose netbox as nodeport service
```
kubectl expose service citc-netbox --port=8080 --type NodePort --name netbox-ext
```
11. Create a database for awx

```
kubectl exec -it citc-postgresql-0 -- env PGPASSWORD=admin psql -U postgres -c "CREATE DATABASE awx;"
```

12. Install AWX

```bash
git clone --depth=1 https://github.com/ansible/awx-operator.git && cd awx-operator/
git checkout tags/0.15.0
NAMESPACE=automation make deploy

cat << EOF > awx.yaml
---
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
spec:
  service_type: nodeport
  projects_persistence: false
  web_resource_requirements:
    requests: {}
    limits: {}
  task_resource_requirements:
    requests: {}
    limits: {}
  ee_resource_requirements:
    requests: {}
    limits: {}
EOF

cat << EOF > secret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: awx-postgres-configuration
stringData:
  host: citc-postgresql
  port: "5432"
  database: awx
  username: "postgres"
  password: "admin"
  sslmode: prefer
  type: unmanaged
type: Opaque
EOF

kubectl apply -f secret.yaml
kubectl apply -f awx.yaml

```

13. Wait for AWX to be installed


```
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=awx --timeout=600s
pod/awx-7f468c689f-rdpxb condition met
```

13. Save the values of NodePorts assigned to Netbox and AWX:

```bash
kubectl get svc | grep NodePort
awx-service                                       NodePort    10.110.157.179   <none>        80:32213/TCP     3m
netbox-ext                                        NodePort    10.100.7.63      <none>        8080:30329/TCP   4m36s
```

14. Check the AWX admin password

```bash
kubectl get secret awx-admin-password -o jsonpath='{.data.password}' | base64 --decode
Wqh8DgymK1RMVYMzVFtGSBYqbvBrQ0PS
```

15. Reconnect with SSH port forwarding

```bash
ssh -L 8080:192.168.200.250:30108 \
-L 8081:192.168.200.250:30100 \
ssh://cumulus@worker04.air.nvidia.com:27230
```

Netbox and AWX are now available at [localhost:8080](http://localhost:8080) (admin/admin) and [localhost:8081](http://localhost:8081) (admin/Wqh8DgymK1RMVYMzVFtGSBYqbvBrQ0PS) respectively.
