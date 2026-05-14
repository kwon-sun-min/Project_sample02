#!/bin/bash



echo "[COMMON] 1. 시스템 업데이트 및 필수 패키지 설치"
apt-get update && apt-get install -y apt-transport-https ca-certificates curl gpg

echo "[COMMON] 2. 스왑 비활성화"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "[COMMON] 3. 커널 모듈 로드 및 네트워크 설정"
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "[COMMON] 4. 컨테이너 런타임 (containerd) 설치"
apt-get install -y containerd

echo "[COMMON] 5. containerd 설정 (systemd cgroup 드라이버 사용)"
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "[COMMON] 6. 쿠버네티스 패키지 설치 (kubelet, kubeadm, kubectl)"
# Google Cloud public signing key 추가
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Kubernetes apt repository 추가
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
KUBE_VERSION="1.30.1-1.1"
apt-get install -y kubelet=${KUBE_VERSION} kubeadm=${KUBE_VERSION} kubectl=${KUBE_VERSION}
apt-mark hold kubelet kubeadm kubectl

echo "[COMMON] 모든 노드 공통 설정 완료."
echo "================================================================================================="

echo "$(hostname -I | awk '{print $1}') master1.co.kr" | sudo tee -a /etc/hosts

echo "[MASTER] 쿠버네티스 클러스터 초기화 (kubeadm init)"
kubeadm init --kubernetes-version=v1.30.1 --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint="master1.co.kr:6443"

echo "[MASTER] kubectl 설정"
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml

echo "[MASTER] 마스터 노드 설정 완료."
echo "[MASTER] 워커 노드를 클러스터에 조인시키려면 아래 join 명령어를 복사하여 워커 노드에서 실행하세요."
kubeadm token create --print-join-command

#쉘 구문 자동완성 플러그 추가 
echo  -e "\n쉘 구문 자동완성 플러그 추가 "
apt install bash-completion

#아래7 구문 쉘에서 실행 
echo  -e "\n아래 구문 쉘에서 실행 "
source <(kubectl completion bash)
source <(kubeadm completion bash)

#다음에 로그인시 실행될 수 있도록 .bashrc 맨 마지막에 아래 구문 추가함 
echo  -e "\n다음에 로그인시 실행될 수 있도록 .bashrc 맨 마지막에 아래 구문 추가함 "
echo "source <(kubectl completion bash)" >> .bashrc
echo "source <(kubeadm completion bash)" >> .bashrc

# sudo로 실행해도 실제 유저 홈에 설정
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
mkdir -p $REAL_HOME/.kube
cp -i /etc/kubernetes/admin.conf $REAL_HOME/.kube/config
chown $(id -u $REAL_USER):$(id -g $REAL_USER) $REAL_HOME/.kube/config

kubeadm token create --print-join-command