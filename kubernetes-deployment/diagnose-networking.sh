#!/bin/bash

# Kubernetes Networking Diagnostics Script
# Run this on any Kubernetes node to diagnose networking issues

echo "==================================="
echo "Kubernetes Networking Diagnostics"
echo "==================================="
echo ""

echo "1. CNI Plugin Installation:"
if [ -d "/opt/cni/bin" ]; then
    echo "   ✓ /opt/cni/bin exists"
    echo "   Plugins installed:"
    ls -la /opt/cni/bin/ 2>/dev/null | grep -E "bridge|loopback|portmap|bandwidth|firewall" | awk '{print "   - " $9 " (" $5 " bytes)"}'
    
    PLUGIN_COUNT=$(ls /opt/cni/bin/ 2>/dev/null | wc -l)
    if [ "$PLUGIN_COUNT" -lt 10 ]; then
        echo "   ⚠ WARNING: Only $PLUGIN_COUNT plugins found (expected 10+)"
    fi
else
    echo "   ✗ /opt/cni/bin MISSING - THIS IS THE PROBLEM!"
    echo "   FIX: Run the following commands:"
    echo "        sudo mkdir -p /opt/cni/bin"
    echo "        cd /tmp && wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz"
    echo "        sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin"
    echo "        sudo systemctl restart containerd"
fi
echo ""

echo "2. CNI Configuration:"
if [ -d "/etc/cni/net.d" ]; then
    echo "   ✓ /etc/cni/net.d exists"
    if [ "$(ls -A /etc/cni/net.d/)" ]; then
        echo "   Configuration files:"
        ls -la /etc/cni/net.d/ 2>/dev/null | grep -v "^total" | grep -v "^d" | awk '{print "   - " $9}'
    else
        echo "   ⚠ /etc/cni/net.d is EMPTY (Flannel should create 10-flannel.conflist)"
    fi
else
    echo "   ✗ /etc/cni/net.d MISSING"
    echo "   FIX: sudo mkdir -p /etc/cni/net.d"
fi
echo ""

echo "3. Containerd Status:"
if sudo systemctl is-active --quiet containerd; then
    echo "   ✓ containerd is running"
    sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock version 2>&1 | grep -q "Version:" && echo "   ✓ crictl can connect to containerd" || echo "   ⚠ crictl cannot connect to containerd"
else
    echo "   ✗ containerd is NOT running"
    echo "   FIX: sudo systemctl start containerd"
fi
echo ""

echo "4. Containerd Configuration:"
if [ -f "/etc/containerd/config.toml" ]; then
    if grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
        echo "   ✓ SystemdCgroup = true"
    else
        echo "   ✗ SystemdCgroup is NOT set to true"
        echo "   FIX: Edit /etc/containerd/config.toml and set SystemdCgroup = true, then restart containerd"
    fi
    
    if grep -q "\[plugins.\"io.containerd.grpc.v1.cri\".cni\]" /etc/containerd/config.toml; then
        echo "   ✓ CNI configuration section exists"
    else
        echo "   ⚠ CNI configuration section missing"
    fi
else
    echo "   ✗ /etc/containerd/config.toml MISSING"
    echo "   FIX: sudo containerd config default > /etc/containerd/config.toml"
fi
echo ""

echo "5. Kubelet Status:"
if sudo systemctl is-active --quiet kubelet; then
    echo "   ✓ kubelet is running"
else
    echo "   ⚠ kubelet is NOT running"
    echo "   FIX: sudo systemctl start kubelet"
fi
echo ""

echo "6. Network Interfaces:"
echo "   CNI/Pod networking interfaces:"
ip -br addr show 2>/dev/null | grep -E "cni|flannel|veth" && FOUND=1 || FOUND=0
if [ $FOUND -eq 0 ]; then
    echo "   ⚠ No CNI interfaces found (expected after pods start)"
fi
echo ""

echo "7. Kernel Modules:"
for mod in overlay br_netfilter; do
    if lsmod | grep -q "^$mod"; then
        echo "   ✓ $mod module loaded"
    else
        echo "   ✗ $mod module NOT loaded"
        echo "   FIX: sudo modprobe $mod"
    fi
done
echo ""

echo "8. Sysctl Settings:"
for setting in "net.bridge.bridge-nf-call-iptables" "net.bridge.bridge-nf-call-ip6tables" "net.ipv4.ip_forward"; do
    VALUE=$(sysctl -n $setting 2>/dev/null)
    if [ "$VALUE" = "1" ]; then
        echo "   ✓ $setting = 1"
    else
        echo "   ✗ $setting = $VALUE (should be 1)"
        echo "   FIX: sudo sysctl -w $setting=1"
    fi
done
echo ""

echo "9. Firewall Status:"
if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "Status: active"; then
        echo "   ⚠ UFW firewall is ACTIVE (may block Kubernetes networking)"
        echo "   FIX: sudo ufw disable (or configure proper rules)"
    else
        echo "   ✓ UFW firewall is inactive"
    fi
else
    echo "   ℹ UFW not installed"
fi
echo ""

echo "==================================="
echo "Diagnosis Complete"
echo "==================================="
echo ""

# Summary
ISSUES=0
[ ! -d "/opt/cni/bin" ] && ISSUES=$((ISSUES+1))
PLUGIN_COUNT=$(ls -A /opt/cni/bin/ 2>/dev/null | wc -l)
[ "$PLUGIN_COUNT" -lt 10 ] && ISSUES=$((ISSUES+1))
! sudo systemctl is-active --quiet containerd && ISSUES=$((ISSUES+1))
! sudo systemctl is-active --quiet kubelet && ISSUES=$((ISSUES+1))

if [ $ISSUES -eq 0 ]; then
    echo "✅ No critical issues detected"
    echo ""
    echo "If pods are still stuck in ContainerCreating:"
    echo "1. Check pod events: kubectl describe pod <pod-name>"
    echo "2. Check kubelet logs: sudo journalctl -u kubelet -f"
    echo "3. Check containerd logs: sudo journalctl -u containerd -f"
    echo "4. Restart containerd: sudo systemctl restart containerd"
    echo "5. Delete stuck pods: kubectl delete pod <pod-name> --force --grace-period=0"
else
    echo "⚠️  Found $ISSUES critical issue(s) - see above for fixes"
fi

echo ""
echo "For more help, see TROUBLESHOOTING.md"
