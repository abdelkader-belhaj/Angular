# Kubernetes Cluster Networking Troubleshooting Guide

## Problem: Pods Stuck in "ContainerCreating" State

This guide addresses the common issue where Kubernetes pods cannot start and remain in `ContainerCreating` state, with symptoms including:

- CoreDNS pods stuck in `ContainerCreating`
- New deployments cannot start pods
- DNS resolution failures
- etcd timeout errors

## Root Cause

The primary cause is **missing CNI (Container Network Interface) plugins** in `/opt/cni/bin`. Without these plugins, containerd cannot set up networking for new pods.

## Quick Fix for Existing Cluster

If you already have a cluster deployed and experiencing this issue, follow these steps on **ALL nodes** (master and workers):

### Step 1: Install CNI Plugins Manually

```bash
# SSH into each node
ssh ubuntu@<node-ip>

# Create CNI directories
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

# Download and install CNI plugins
cd /tmp
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz

# Extract to the correct location
sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin

# Verify installation
ls -la /opt/cni/bin/
# You should see: bridge, loopback, portmap, bandwidth, firewall, etc.
```

### Step 2: Restart Containerd

```bash
# Restart containerd on all nodes
sudo systemctl restart containerd

# Verify containerd is running
sudo systemctl status containerd
```

### Step 3: Verify CNI Configuration

```bash
# Check Flannel configuration exists
ls -la /etc/cni/net.d/
# You should see: 10-flannel.conflist

# If missing, restart Flannel pods on the master
kubectl delete pods -n kube-flannel --all

# Wait for Flannel to recreate pods and generate config
kubectl wait --for=condition=Ready pod -l app=flannel -n kube-flannel --timeout=300s
```

### Step 4: Delete Stuck Pods

```bash
# On the master node, force delete any stuck pods
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# For example, to fix CoreDNS:
kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0

# Wait for new pods to be created
kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s
```

### Step 5: Verify Cluster Health

```bash
# Check all nodes are Ready
kubectl get nodes -o wide

# Check all system pods are Running
kubectl get pods -n kube-system
kubectl get pods -n kube-flannel

# Test pod creation
kubectl run test-nginx --image=nginx:alpine
kubectl wait --for=condition=Ready pod/test-nginx --timeout=120s
kubectl get pod test-nginx -o wide

# Cleanup test pod
kubectl delete pod test-nginx
```

## Verification Commands

### Check CNI Plugin Installation

```bash
# On each node, verify CNI plugins exist
ls -la /opt/cni/bin/
# Expected output should include: bridge, loopback, portmap, bandwidth, etc.

# Check permissions
sudo ls -la /opt/cni/bin/ | grep -E "bridge|loopback"
# All files should be executable (permissions like -rwxr-xr-x)
```

### Check Containerd Configuration

```bash
# Verify containerd is using systemd cgroup driver
sudo grep SystemdCgroup /etc/containerd/config.toml
# Should show: SystemdCgroup = true

# Check containerd is running
sudo systemctl status containerd

# Test containerd with crictl
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock version
```

### Check Flannel CNI

```bash
# Verify Flannel pods are running
kubectl get pods -n kube-flannel -o wide

# Check Flannel configuration
sudo cat /etc/cni/net.d/10-flannel.conflist

# Check Flannel subnet allocation
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

### Check Pod Networking

```bash
# Create a test deployment
kubectl create deployment nettest --image=nicolaka/netshoot --replicas=2 -- sleep 3600

# Wait for pods to be ready
kubectl wait --for=condition=Ready pod -l app=nettest --timeout=120s

# Get pod IPs
kubectl get pods -l app=nettest -o wide

# Test connectivity between pods
POD1=$(kubectl get pod -l app=nettest -o jsonpath='{.items[0].metadata.name}')
POD2_IP=$(kubectl get pod -l app=nettest -o jsonpath='{.items[1].status.podIP}')

# Ping from pod1 to pod2
kubectl exec -it $POD1 -- ping -c 3 $POD2_IP

# Test DNS
kubectl exec -it $POD1 -- nslookup kubernetes.default

# Cleanup
kubectl delete deployment nettest
```

## Common Issues and Solutions

### Issue 1: CNI Plugins Missing After Installation

**Symptom**: `/opt/cni/bin` directory is empty or missing critical plugins

**Solution**:
```bash
# Reinstall CNI plugins
sudo rm -rf /opt/cni/bin/*
cd /tmp
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin
sudo systemctl restart containerd
```

### Issue 2: Flannel Not Creating CNI Configuration

**Symptom**: `/etc/cni/net.d/10-flannel.conflist` doesn't exist

**Solution**:
```bash
# Delete and recreate Flannel pods
kubectl delete pods -n kube-flannel --all

# If that doesn't work, reinstall Flannel
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### Issue 3: CoreDNS Pods Won't Start

**Symptom**: CoreDNS pods stuck in ContainerCreating after fixing CNI

**Solution**:
```bash
# Force delete CoreDNS pods
kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0

# Wait for new pods
kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s
```

### Issue 4: Worker Nodes Show NotReady

**Symptom**: Worker nodes remain in NotReady state

**Solution**:
```bash
# On the affected worker node:
# 1. Check CNI plugins
ls -la /opt/cni/bin/

# 2. Check kubelet logs
sudo journalctl -u kubelet -f

# 3. Check Flannel pod on that node
kubectl get pods -n kube-flannel -o wide | grep <worker-node-name>

# 4. If Flannel pod is not running, check its logs
kubectl logs -n kube-flannel <flannel-pod-name>

# 5. Restart containerd and kubelet
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

### Issue 5: DNS Resolution Fails

**Symptom**: Pods cannot resolve DNS names

**Solution**:
```bash
# Check CoreDNS is running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# Test DNS from a pod
kubectl run dnstest --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default

# Check kube-dns service
kubectl get svc -n kube-system kube-dns
```

## Prevention: Deploy with Correct Configuration

To prevent this issue when deploying a new cluster, use the updated `playbook.yaml` that includes automatic CNI plugin installation:

```bash
# Clean up old cluster
ansible-playbook -i inventory.ini cleanup.yaml

# Deploy with fixed configuration
ansible-playbook -i inventory.ini playbook.yaml
```

The fixed playbook includes these critical steps:
1. Creates `/opt/cni/bin` and `/etc/cni/net.d` directories
2. Downloads and extracts CNI plugins v1.3.0
3. Verifies CNI plugin installation before proceeding
4. Properly configures containerd with systemd cgroup driver

## Diagnostic Script

Save this as `diagnose-k8s-networking.sh` and run on any node:

```bash
#!/bin/bash

echo "==================================="
echo "Kubernetes Networking Diagnostics"
echo "==================================="
echo ""

echo "1. CNI Plugin Installation:"
if [ -d "/opt/cni/bin" ]; then
    echo "   ✓ /opt/cni/bin exists"
    echo "   Plugins installed:"
    ls -la /opt/cni/bin/ | grep -E "bridge|loopback|portmap" | awk '{print "   - " $9}'
else
    echo "   ✗ /opt/cni/bin MISSING - THIS IS THE PROBLEM!"
fi
echo ""

echo "2. CNI Configuration:"
if [ -d "/etc/cni/net.d" ]; then
    echo "   ✓ /etc/cni/net.d exists"
    if [ "$(ls -A /etc/cni/net.d/)" ]; then
        echo "   Configuration files:"
        ls -la /etc/cni/net.d/ | grep -v "^total" | grep -v "^d" | awk '{print "   - " $9}'
    else
        echo "   ⚠ /etc/cni/net.d is EMPTY"
    fi
else
    echo "   ✗ /etc/cni/net.d MISSING"
fi
echo ""

echo "3. Containerd Status:"
sudo systemctl is-active --quiet containerd && echo "   ✓ containerd is running" || echo "   ✗ containerd is NOT running"
echo ""

echo "4. Containerd Configuration:"
if grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "   ✓ SystemdCgroup = true"
else
    echo "   ✗ SystemdCgroup is NOT set to true"
fi
echo ""

echo "5. Kubelet Status:"
sudo systemctl is-active --quiet kubelet && echo "   ✓ kubelet is running" || echo "   ⚠ kubelet is NOT running"
echo ""

echo "6. Network Interfaces:"
ip -br addr show | grep -E "cni|flannel|docker" || echo "   No CNI interfaces found"
echo ""

echo "==================================="
echo "Diagnosis Complete"
echo "==================================="
```

## Additional Resources

- [Kubernetes CNI Documentation](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [CNI Plugins GitHub](https://github.com/containernetworking/plugins)
- [Containerd Documentation](https://containerd.io/)

## Summary

The "ContainerCreating" issue is almost always caused by missing or misconfigured CNI plugins. The key fix is:

1. **Install CNI plugins** to `/opt/cni/bin` on all nodes
2. **Restart containerd** after installation
3. **Recreate stuck pods** to allow them to start with proper networking
4. **Verify Flannel** is running and creating CNI configuration

Following this guide should resolve the networking issues and get your cluster fully functional.
