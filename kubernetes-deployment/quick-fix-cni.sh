#!/bin/bash

# Quick Fix Script for Kubernetes Networking Issues
# This script fixes the "ContainerCreating" issue by installing CNI plugins
# Run this on ALL nodes (master and workers) that have networking problems

set -e

echo "=============================================="
echo "Kubernetes CNI Quick Fix Script"
echo "=============================================="
echo ""
echo "This script will:"
echo "1. Install CNI plugins to /opt/cni/bin"
echo "2. Restart containerd"
echo "3. Verify the installation"
echo ""
echo "⚠️  Run this on ALL nodes experiencing networking issues"
echo ""

# Check if running as root
if [ "${EUID:-0}" -ne 0 ]; then 
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

echo "Step 1: Creating CNI directories..."
mkdir -p /opt/cni/bin
mkdir -p /etc/cni/net.d
echo "✅ Directories created"
echo ""

echo "Step 2: Downloading CNI plugins..."
cd /tmp
CNI_VERSION="v1.3.0"
CNI_URL="https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"

if [ -f "cni-plugins.tgz" ]; then
    echo "   CNI plugins archive already downloaded"
else
    wget -q --show-progress "$CNI_URL" -O cni-plugins.tgz
fi
echo "✅ Download complete"
echo ""

echo "Step 3: Installing CNI plugins..."
tar -xzf cni-plugins.tgz -C /opt/cni/bin
echo "✅ CNI plugins installed"
echo ""

echo "Step 4: Verifying installation..."
EXPECTED_PLUGINS=("bridge" "loopback" "portmap" "bandwidth" "firewall" "host-local" "tuning" "vlan")
MISSING=0

for plugin in "${EXPECTED_PLUGINS[@]}"; do
    if [ -f "/opt/cni/bin/$plugin" ]; then
        echo "   ✓ $plugin"
    else
        echo "   ✗ $plugin MISSING"
        MISSING=$((MISSING+1))
    fi
done

if [ $MISSING -gt 0 ]; then
    echo ""
    echo "⚠️  $MISSING plugins are missing"
    exit 1
fi
echo "✅ All essential plugins verified"
echo ""

echo "Step 5: Setting correct permissions..."
chmod +x /opt/cni/bin/*
echo "✅ Permissions set"
echo ""

echo "Step 6: Restarting containerd..."
systemctl restart containerd
sleep 3

if systemctl is-active --quiet containerd; then
    echo "✅ Containerd restarted successfully"
else
    echo "❌ Containerd failed to restart"
    echo "   Check logs: journalctl -u containerd -f"
    exit 1
fi
echo ""

echo "Step 7: Testing containerd..."
if crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock version >/dev/null 2>&1; then
    echo "✅ Containerd is responding correctly"
else
    echo "⚠️  Containerd may have issues"
    echo "   Check logs: journalctl -u containerd -f"
fi
echo ""

echo "Step 8: Checking Flannel configuration..."
if [ -f "/etc/cni/net.d/10-flannel.conflist" ]; then
    echo "✅ Flannel CNI configuration exists"
else
    echo "⚠️  Flannel CNI configuration not found"
    echo "   This is normal on worker nodes if Flannel hasn't run yet"
    echo "   On master: kubectl delete pods -n kube-flannel --all"
fi
echo ""

echo "=============================================="
echo "✅ CNI Fix Complete!"
echo "=============================================="
echo ""
echo "Next Steps:"
echo ""
echo "1. If this is a MASTER node:"
echo "   kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0"
echo "   kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s"
echo ""
echo "2. If this is a WORKER node:"
echo "   systemctl restart kubelet"
echo "   # Wait 2-3 minutes for the node to become Ready"
echo ""
echo "3. Verify cluster health from master:"
echo "   kubectl get nodes -o wide"
echo "   kubectl get pods -n kube-system"
echo "   kubectl get pods -n kube-flannel"
echo ""
echo "4. If pods are still stuck:"
echo "   kubectl delete pod <pod-name> --force --grace-period=0"
echo ""
echo "For more help, see TROUBLESHOOTING.md"
echo ""

# Cleanup
rm -f /tmp/cni-plugins.tgz

exit 0
