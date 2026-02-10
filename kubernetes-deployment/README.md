# Kubernetes Deployment with Ansible

This directory contains Ansible playbooks and tools for deploying a production-ready Kubernetes cluster with proper CNI configuration.

## 🔧 Problem Solved

This deployment fixes the common **"Pods stuck in ContainerCreating"** issue caused by missing CNI (Container Network Interface) plugins. The updated playbook ensures:

- ✅ CNI plugins are properly installed on all nodes
- ✅ Containerd is configured with systemd cgroup driver
- ✅ Flannel CNI is correctly deployed
- ✅ All networking components are verified before proceeding

## 📁 Files

- **`playbook.yaml`** - Main deployment playbook with CNI fixes
- **`cleanup.yaml`** - Cleanup playbook for resetting nodes
- **`inventory.ini`** - Sample inventory file (edit with your IPs)
- **`TROUBLESHOOTING.md`** - Comprehensive troubleshooting guide
- **`diagnose-networking.sh`** - Diagnostic script for network issues

## 🚀 Quick Start

### 1. Configure Inventory

Edit `inventory.ini` with your server IPs:

```ini
[masters]
master1 ansible_host=YOUR_MASTER_IP ansible_user=ubuntu ansible_become=yes

[workers]
worker1 ansible_host=YOUR_WORKER1_IP ansible_user=ubuntu ansible_become=yes
worker2 ansible_host=YOUR_WORKER2_IP ansible_user=ubuntu ansible_become=yes

[k8s_cluster:children]
masters
workers
```

### 2. Clean Existing Cluster (if any)

```bash
ansible-playbook -i inventory.ini cleanup.yaml
```

### 3. Deploy Kubernetes Cluster

```bash
ansible-playbook -i inventory.ini playbook.yaml
```

The deployment takes approximately 10-15 minutes and includes:
- System preparation and kernel module loading
- Containerd installation and configuration
- **CNI plugin installation** (critical fix)
- Kubernetes components installation
- Cluster initialization
- Flannel CNI deployment
- Worker node joining
- Cluster verification

### 4. Verify Deployment

SSH into the master node:

```bash
ssh ubuntu@<master-ip>

# Check all nodes are Ready
kubectl get nodes -o wide

# Check all system pods are Running
kubectl get pods -n kube-system
kubectl get pods -n kube-flannel

# Test pod creation
kubectl run test-nginx --image=nginx:alpine
kubectl wait --for=condition=Ready pod/test-nginx --timeout=120s
kubectl delete pod test-nginx
```

## 🔍 Troubleshooting

### If Pods Are Stuck in ContainerCreating

1. **Run the diagnostic script** on any node:
   ```bash
   # Copy script to node
   scp diagnose-networking.sh ubuntu@<node-ip>:/tmp/
   
   # Run on the node
   ssh ubuntu@<node-ip>
   chmod +x /tmp/diagnose-networking.sh
   sudo /tmp/diagnose-networking.sh
   ```

2. **Check CNI plugins are installed**:
   ```bash
   ls -la /opt/cni/bin/
   # Should show: bridge, loopback, portmap, bandwidth, etc.
   ```

3. **If CNI plugins are missing**, install them manually:
   ```bash
   sudo mkdir -p /opt/cni/bin
   cd /tmp
   wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
   sudo tar -xzf cni-plugins-linux-amd64-v1.3.0.tgz -C /opt/cni/bin
   sudo systemctl restart containerd
   ```

4. **Delete stuck pods** to allow recreation:
   ```bash
   kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0
   ```

For detailed troubleshooting steps, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 📊 What's Different From Standard Deployments

This playbook includes critical fixes not present in many standard Kubernetes deployments:

### 1. **Explicit CNI Plugin Installation**
```yaml
- name: Download CNI plugins
  get_url:
    url: https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
    dest: /tmp/cni-plugins.tgz

- name: Extract CNI plugins
  unarchive:
    src: /tmp/cni-plugins.tgz
    dest: /opt/cni/bin
    remote_src: yes
```

**Why**: Many deployments assume CNI plugins are pre-installed or will be installed by the CNI provider, but this often fails.

### 2. **Verification Steps**
```yaml
- name: Verify CNI plugins are installed
  shell: ls -la /opt/cni/bin/ | grep -E "bridge|loopback|portmap"
  register: cni_verify
  failed_when: cni_verify.rc != 0
```

**Why**: Fail early if CNI plugins are missing rather than proceeding with a broken configuration.

### 3. **Proper Containerd Configuration**
```yaml
- name: Configure containerd to use systemd cgroup driver
  replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'
```

**Why**: Kubernetes requires systemd cgroup driver for proper resource management.

### 4. **Auto-Detection of Internal IP**
```yaml
- name: Detect internal IP address (auto)
  set_fact:
    internal_ip: "{{ ansible_default_ipv4.address }}"
```

**Why**: Handles environments with floating IPs (like OpenStack) where SSH IP differs from internal IP.

## 🧪 Testing Network Connectivity

### Test 1: Basic Pod Creation
```bash
kubectl run test-nginx --image=nginx:alpine
kubectl wait --for=condition=Ready pod/test-nginx --timeout=120s
kubectl delete pod test-nginx
```

### Test 2: Pod-to-Pod Communication
```bash
# Create test deployment
kubectl create deployment nettest --image=nicolaka/netshoot --replicas=2 -- sleep 3600

# Get pod IPs
kubectl get pods -l app=nettest -o wide

# Test ping between pods
POD1=$(kubectl get pod -l app=nettest -o jsonpath='{.items[0].metadata.name}')
POD2_IP=$(kubectl get pod -l app=nettest -o jsonpath='{.items[1].status.podIP}')
kubectl exec -it $POD1 -- ping -c 3 $POD2_IP

# Cleanup
kubectl delete deployment nettest
```

### Test 3: DNS Resolution
```bash
kubectl run dnstest --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default
```

## 📋 Requirements

- Ubuntu 22.04 LTS on all nodes
- Ansible 2.9+ on control machine
- SSH access to all nodes with sudo privileges
- At least 2 GB RAM and 2 CPUs per node
- Network connectivity between all nodes
- Unique hostname for each node
- Disabled swap on all nodes (playbook handles this)

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Master Node                              │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │ API Server │  │ Controller   │  │   Scheduler  │        │
│  │            │  │   Manager    │  │              │        │
│  └────────────┘  └──────────────┘  └──────────────┘        │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │   etcd     │  │   CoreDNS    │  │   Flannel    │        │
│  └────────────┘  └──────────────┘  └──────────────┘        │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
┌───────────▼──────┐ ┌──────▼──────┐ ┌─────▼──────────┐
│   Worker Node 1  │ │ Worker Node 2│ │ Worker Node N  │
│  ┌────────────┐  │ │ ┌────────────┐│ │ ┌────────────┐│
│  │  kubelet   │  │ │ │  kubelet   ││ │ │  kubelet   ││
│  │ containerd │  │ │ │ containerd ││ │ │ containerd ││
│  │  Flannel   │  │ │ │  Flannel   ││ │ │  Flannel   ││
│  │ CNI Plugins│  │ │ │ CNI Plugins││ │ │ CNI Plugins││
│  └────────────┘  │ │ └────────────┘│ │ └────────────┘│
│                  │ │               │ │                │
│  [App Pods]      │ │  [App Pods]   │ │  [App Pods]    │
└──────────────────┘ └───────────────┘ └────────────────┘
```

## 🔐 Security Considerations

- All nodes use Ubuntu 22.04 LTS with latest security patches
- Kubernetes components are held at specific versions (1.28.2) to prevent unexpected upgrades
- Containerd uses systemd cgroup driver for better security isolation
- Network policies can be added via Kubernetes NetworkPolicy resources
- Consider enabling RBAC and Pod Security Standards for production

## 🆘 Support

If you encounter issues:

1. Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common problems and solutions
2. Run `diagnose-networking.sh` on affected nodes
3. Check kubelet logs: `sudo journalctl -u kubelet -f`
4. Check containerd logs: `sudo journalctl -u containerd -f`
5. Describe stuck pods: `kubectl describe pod <pod-name> -n <namespace>`

## 📚 Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [CNI Plugins](https://github.com/containernetworking/plugins)
- [Containerd](https://containerd.io/)

## 📝 License

This deployment configuration is provided as-is for educational and production use.
