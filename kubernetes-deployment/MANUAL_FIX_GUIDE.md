# Manual Fix Guide for Existing Kubernetes Cluster

## Problem: Pods Stuck in "ContainerCreating" State

If your Kubernetes cluster is already deployed and experiencing issues with pods stuck in `ContainerCreating` state, follow this manual fix guide.

## Symptoms

- Pods remain in `ContainerCreating` for extended periods
- CoreDNS pods won't start
- New deployments fail to create pods
- `kubectl describe pod` shows CNI-related errors
- DNS resolution fails inside the cluster

## Quick Diagnosis

Run this on any node:

```bash
# Check if CNI plugins exist
ls -la /opt/cni/bin/
```

**If the directory is empty or missing**, you have the CNI plugin problem.

## Fix Steps

### Option 1: Automated Fix (Recommended)

Use the provided quick-fix script on **ALL nodes** (master and workers):

```bash
# Copy the script to each node
scp quick-fix-cni.sh ubuntu@<node-ip>:/tmp/

# SSH into each node and run
ssh ubuntu@<node-ip>
sudo bash /tmp/quick-fix-cni.sh
```

### Option 2: Manual Fix

Follow these steps on **each node** (master and workers):

#### 1. Install CNI Plugins

```bash
# Create directories
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

# Download CNI plugins
cd /tmp
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz

# Extract plugins
sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin

# Verify installation
ls -la /opt/cni/bin/
# Should show: bandwidth, bridge, dhcp, firewall, host-device, host-local, 
#              ipvlan, loopback, macvlan, portmap, ptp, sbr, static, tuning, 
#              vlan, vrf

# Set correct permissions
sudo chmod +x /opt/cni/bin/*
```

#### 2. Restart Containerd

```bash
# Restart containerd to pick up CNI plugins
sudo systemctl restart containerd

# Verify containerd is running
sudo systemctl status containerd

# Test containerd
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock version
```

#### 3. On Master Node: Restart System Pods

After fixing **all nodes**, on the **master node only**:

```bash
# Force delete CoreDNS pods
kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0

# Wait for CoreDNS to become ready
kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s

# Delete Flannel pods to regenerate CNI configuration
kubectl delete pods -n kube-flannel --all

# Wait for Flannel to become ready
kubectl wait --for=condition=Ready pod -l app=flannel -n kube-flannel --timeout=300s
```

#### 4. On Worker Nodes: Restart Kubelet

After fixing CNI plugins on worker nodes:

```bash
# On each worker node
sudo systemctl restart kubelet

# Check kubelet status
sudo systemctl status kubelet

# Check for errors
sudo journalctl -u kubelet -n 50
```

#### 5. Verify Cluster Health

Back on the master node:

```bash
# Wait for all nodes to become Ready (may take 2-3 minutes)
kubectl get nodes -w

# Check all system pods are Running
kubectl get pods -n kube-system
kubectl get pods -n kube-flannel

# All pods should be Running
```

#### 6. Fix Any Remaining Stuck Pods

```bash
# List any pods still in ContainerCreating
kubectl get pods --all-namespaces | grep ContainerCreating

# Force delete each stuck pod
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# The pod will be recreated and should start successfully
```

## Verification Tests

### Test 1: Create a Test Pod

```bash
kubectl run test-nginx --image=nginx:alpine
kubectl wait --for=condition=Ready pod/test-nginx --timeout=120s

# Check the pod status
kubectl get pod test-nginx -o wide

# Check pod details
kubectl describe pod test-nginx

# Cleanup
kubectl delete pod test-nginx
```

### Test 2: Test DNS Resolution

```bash
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default
```

Expected output:
```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

### Test 3: Test Pod-to-Pod Communication

```bash
# Create test deployment
kubectl create deployment nettest --image=nicolaka/netshoot --replicas=2 -- sleep 3600

# Wait for pods
kubectl wait --for=condition=Ready pod -l app=nettest --timeout=120s

# Get pod IPs
kubectl get pods -l app=nettest -o wide

# Test ping between pods
POD1=$(kubectl get pod -l app=nettest -o jsonpath='{.items[0].metadata.name}')
POD2_IP=$(kubectl get pod -l app=nettest -o jsonpath='{.items[1].status.podIP}')

kubectl exec -it $POD1 -- ping -c 3 $POD2_IP

# Expected: Successful ping with 0% packet loss

# Cleanup
kubectl delete deployment nettest
```

## Common Issues After Fix

### Issue: Nodes Still NotReady

**Solution:**
```bash
# On each NotReady node, check kubelet logs
sudo journalctl -u kubelet -f

# Check containerd logs
sudo journalctl -u containerd -f

# Verify CNI plugins are present
ls -la /opt/cni/bin/

# Verify Flannel pod is running on that node
kubectl get pods -n kube-flannel -o wide | grep <node-name>

# If Flannel pod is not Running, check its logs
kubectl logs -n kube-flannel <flannel-pod-name>
```

### Issue: Pods Still Won't Start

**Solution:**
```bash
# Check pod events
kubectl describe pod <pod-name> -n <namespace>

# Look for error messages at the bottom under "Events"

# Check CNI configuration exists
sudo ls -la /etc/cni/net.d/
# Should show: 10-flannel.conflist

# If missing, restart Flannel
kubectl delete pods -n kube-flannel --all
```

### Issue: DNS Still Fails

**Solution:**
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# Check kube-dns service
kubectl get svc -n kube-system kube-dns

# Restart CoreDNS
kubectl rollout restart deployment coredns -n kube-system
```

## Diagnostic Commands Reference

```bash
# Node level
sudo ls -la /opt/cni/bin/                    # Check CNI plugins
sudo ls -la /etc/cni/net.d/                  # Check CNI config
sudo systemctl status containerd             # Check containerd
sudo systemctl status kubelet                # Check kubelet
sudo journalctl -u containerd -f             # Containerd logs
sudo journalctl -u kubelet -f                # Kubelet logs

# Cluster level
kubectl get nodes -o wide                    # Node status
kubectl get pods -A -o wide                  # All pods
kubectl get pods -n kube-system              # System pods
kubectl get pods -n kube-flannel             # Flannel pods
kubectl describe node <node-name>            # Node details
kubectl describe pod <pod-name> -n <ns>      # Pod details
kubectl logs <pod-name> -n <ns>              # Pod logs
```

## Prevention

To prevent this issue in future deployments:

1. Use the provided `playbook.yaml` which includes CNI plugin installation
2. Always verify CNI plugins are installed before initializing Kubernetes
3. Use the provided `diagnose-networking.sh` script after deployment
4. Document your cluster setup process

## Need More Help?

1. Run the diagnostic script: `sudo bash diagnose-networking.sh`
2. Check the detailed [TROUBLESHOOTING.md](TROUBLESHOOTING.md) guide
3. Review Kubernetes documentation on CNI plugins
4. Check containerd and kubelet logs for specific errors

## Summary

The key steps to fix an existing cluster:

1. ✅ Install CNI plugins on **all nodes**: `/opt/cni/bin`
2. ✅ Restart containerd on **all nodes**
3. ✅ Delete and recreate stuck pods on **master node**
4. ✅ Restart kubelet on **worker nodes**
5. ✅ Verify cluster health and test pod creation

After these steps, your cluster should be fully functional!
