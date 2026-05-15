#!/bin/bash
set -e

# 1. 스크립트가 위치한 절대 경로를 계산
BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"

echo "=================================================================="
echo " 🚀 통합 클러스터 배포 스크립트 (Galera + 마이크로서비스) "
echo "[INFO] 배포 시작 위치: $BASEDIR"
echo "=================================================================="

# ============================================
# STEP 1: Worker 노드 자동 감지 및 PV 설정
# ============================================
echo ""
echo "[STEP 1] Worker 노드 감지 및 PV/디렉토리 자동 설정 중..."

# Worker 노드 자동 감지
WORKER_NODE=$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}' | head -1)

if [ -z "$WORKER_NODE" ]; then
  echo "❌ Worker 노드를 찾을 수 없습니다. 클러스터 상태를 확인하세요."
  exit 1
fi

echo "✅ 감지된 Worker 노드: $WORKER_NODE"

# Worker 노드 IP 자동 감지
WORKER_IP=$(kubectl get nodes "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "✅ Worker 노드 IP: $WORKER_IP"

# PV YAML의 nodeAffinity 자동 치환 (따옴표 있든 없든 모두 처리)
PV_FILE="$K8S_DIR/galera/01-galera-pv.yaml"
if [ -f "$PV_FILE" ]; then
    # 따옴표 있는 경우
    sed -i "s/\"test-worker[0-9]*\"/\"$WORKER_NODE\"/g" "$PV_FILE"
    # 따옴표 없는 경우 (- test-worker2 형식)
    sed -i "s/- test-worker[0-9]*$/- $WORKER_NODE/g" "$PV_FILE"
    # 일반 test-worker 패턴 (어디든)
    sed -i "s/test-worker[0-9]\+/$WORKER_NODE/g" "$PV_FILE"
    
    echo "✅ PV nodeAffinity 수정 완료:"
    grep -A2 "values:" "$PV_FILE" || true
else
    echo "❌ PV 파일을 찾을 수 없습니다: $PV_FILE"
    exit 1
fi

# Worker 노드에 디렉토리 자동 생성
echo "⏳ Worker 노드($WORKER_NODE)에 디렉토리 생성 중..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 kosa@$WORKER_IP \
  "sudo mkdir -p /mnt/data/galera/node0 /mnt/data/galera/node1 /mnt/data/galera/node2 && sudo chmod -R 777 /mnt/data/galera" 2>/dev/null && \
  echo "✅ Worker 노드 디렉토리 생성 완료" || \
  echo "⚠️  SSH 자동 생성 실패. 수동으로 실행해주세요:"
  echo "   ssh kosa@$WORKER_IP \"sudo mkdir -p /mnt/data/galera/node0 /mnt/data/galera/node1 /mnt/data/galera/node2 && sudo chmod -R 777 /mnt/data/galera\""

# ============================================
# STEP 2: MetalLB 설치 및 설정
# ============================================
echo ""
echo "[STEP 2] MetalLB 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

echo "⏳ MetalLB Pod Ready 대기 중..."
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

if [ -f "$K8S_DIR/metallb-config.yaml" ]; then
    kubectl apply -f "$K8S_DIR/metallb-config.yaml"
fi
echo "✅ MetalLB 설치 및 설정 완료"

# ============================================
# STEP 3: Ingress Controller 설치
# ============================================
echo ""
echo "[STEP 3] Ingress Controller 설치 중..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/baremetal/deploy.yaml

echo "⏳ Ingress Controller Ready 대기 중..."
sleep 10
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"type": "LoadBalancer"}}'
echo "✅ Ingress Controller 설치 완료"

# ============================================
# STEP 4: Secret 배포
# ============================================
echo ""
echo "[STEP 4] Secret(비밀번호/키) 배포 중..."
kubectl apply -f "$K8S_DIR/01-secret.yaml"
echo "✅ Secret 배포 완료"

# ============================================
# STEP 5: Galera 클러스터 배포 (이전 PV 자동 정리)
# ============================================
echo ""
echo "[STEP 5] Galera 클러스터 리소스 배포 중..."

# 이전 PV/PVC가 남아있으면 자동 정리 (nodeAffinity 충돌 방지)
echo "⏳ 이전 PV/PVC 정리 중..."
kubectl delete statefulset galera --ignore-not-found --timeout=30s 2>/dev/null || true
kubectl delete pvc data-galera-0 data-galera-1 data-galera-2 --ignore-not-found --timeout=30s 2>/dev/null || true
kubectl delete pv galera-pv-0 galera-pv-1 galera-pv-2 --ignore-not-found --timeout=30s 2>/dev/null || true
sleep 3

# 재배포
kubectl apply -f "$K8S_DIR/galera/00-galera-configmap.yaml"
kubectl apply -f "$K8S_DIR/galera/01-galera-pv.yaml"
kubectl apply -f "$K8S_DIR/galera/03-galera-services.yaml"
kubectl apply -f "$K8S_DIR/galera/02-galera-statefulset.yaml"

echo "⏳ Galera 클러스터 파드가 모두 준비될 때까지 대기합니다 (최대 5분)..."
kubectl rollout status statefulset/galera --timeout=300s
echo "✅ Galera 클러스터 배포 완료"

# ============================================
# STEP 6: 마이크로서비스 및 프론트엔드 배포
# ============================================
echo ""
echo "[STEP 6] 마이크로서비스 및 프론트엔드 배포 중..."
kubectl apply -f "$K8S_DIR/07-auth-server.yaml"
kubectl apply -f "$K8S_DIR/08-employee-server.yaml"
kubectl apply -f "$K8S_DIR/09-photo-service.yaml"
kubectl apply -f "$K8S_DIR/10-gateway.yaml"
kubectl apply -f "$K8S_DIR/11-nginx-deployment.yaml"
kubectl apply -f "$K8S_DIR/12-nginx-service.yaml"
kubectl apply -f "$K8S_DIR/13-ingress.yaml"
echo "✅ 어플리케이션 배포 완료"

# ============================================
# STEP 7: DB 테이블 초기화
# ============================================
echo ""
echo "[STEP 7] DB 테이블 생성 중..."
echo "⏳ galera-0 Pod Ready 재확인..."
kubectl wait --for=condition=ready pod/galera-0 --timeout=180s

kubectl cp "$BASEDIR/employee_server/database_create_tables.sql" galera-0:/tmp/init.sql
kubectl exec -it galera-0 -- mysql -u root -pkosa1004 employees -e "source /tmp/init.sql"
echo "✅ DB 테이블 생성 완료"

# ============================================
# 최종 결과 확인
# ============================================
echo ""
echo "=================================================================="
echo " 🎉 전체 배포가 성공적으로 완료되었습니다!"
echo "=================================================================="
echo ""
echo "[현재 Pod 상태]"
kubectl get pod
echo ""
echo "[Ingress 서비스 (EXTERNAL-IP 확인)]"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
echo "💡 EXTERNAL-IP가 할당되면 브라우저를 띄울 PC의 /etc/hosts 파일에 아래 내용을 추가하세요:"
echo "<EXTERNAL-IP>  myapp.local"
echo "=================================================================="