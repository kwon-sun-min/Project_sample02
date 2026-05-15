#!/bin/bash
set -e

echo "========================================="
echo "  Master 노드 배포 스크립트"
echo "========================================="

# ============================================
# STEP 1: Worker 노드 자동 감지 및 PV 설정
# ============================================
echo ""
echo "[STEP 1] Worker 노드 감지 및 PV YAML 수정 중..."
WORKER_NODE=$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}' | head -1)

if [ -z "$WORKER_NODE" ]; then
  echo "❌ Worker 노드를 찾을 수 없습니다. 클러스터 상태를 확인하세요."
  exit 1
fi

echo "✅ Worker 노드: $WORKER_NODE"
sed -i "s/- test-worker.*/- $WORKER_NODE/" ~/Project_sample02/k8s/03-pv.yaml
echo "✅ 03-pv.yaml 수정 완료"
cat ~/Project_sample02/k8s/03-pv.yaml | grep -A2 "values:"

# ============================================
# STEP 2: Kubernetes 리소스 적용 (metallb-config, ingress 제외)
# ============================================
echo ""
echo "[STEP 2] Kubernetes 리소스 적용 중..."
cd ~/Project_sample02/k8s
for f in *.yaml; do
  if [[ "$f" == "metallb-config.yaml" || "$f" == "13-ingress.yaml" ]]; then
    echo "⏭ 나중에 적용: $f"
    continue
  fi
  kubectl apply -f "$f"
done
echo "✅ K8s 리소스 적용 완료"

# ============================================
# STEP 3: MetalLB 설치
# ============================================
echo ""
echo "[STEP 3] MetalLB 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

echo "MetalLB Pod Ready 대기..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.17.128.240-172.17.128.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF

# metallb-config.yaml도 적용
kubectl apply -f ~/Project_sample02/k8s/metallb-config.yaml
echo "✅ MetalLB 설치 완료"

# ============================================
# STEP 4: Ingress Controller 설치
# ============================================
echo ""
echo "[STEP 4] Ingress Controller 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml

echo "Ingress Controller Ready 대기..."
sleep 10
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"type": "LoadBalancer"}}'

# 13-ingress.yaml 적용
kubectl apply -f ~/Project_sample02/k8s/13-ingress.yaml
echo "✅ Ingress Controller 설치 완료"

# ============================================
# STEP 5: DB 테이블 생성
# ============================================
echo ""
echo "[STEP 5] DB 테이블 생성 중..."
echo "MySQL Pod Ready 대기..."
kubectl wait --for=condition=ready pod/mysql-0 --timeout=180s

kubectl cp ~/Project_sample02/employee_server/database_create_tables.sql mysql-0:/tmp/init.sql
kubectl exec -it mysql-0 -- mysql -u root -pkosa1004 employees -e "source /tmp/init.sql"
echo "✅ DB 테이블 생성 완료"

# ============================================
# 최종 결과 확인
# ============================================
echo ""
echo "========================================="
echo "  🎉 전체 배포 완료!"
echo "========================================="
echo ""
echo "[Pod 상태]"
kubectl get pod
echo ""
echo "[Ingress 서비스]"
kubectl get svc -n ingress-nginx
echo ""
echo "EXTERNAL-IP가 할당되면 맥북 /etc/hosts에 추가하세요:"
echo "<EXTERNAL-IP>  myapp.local"