#!/bin/bash

BASEDIR=$(dirname "$(readlink -f "$0")")
K8S_DIR="$BASEDIR/k8s"

echo "=================================================================="
echo "[INFO] 초기화 시작 위치: $BASEDIR"
echo "=================================================================="

# 1. 프론트엔드 및 네트워크(Ingress, MetalLB) 리소스 삭제
echo "[INFO] [1/5] 프론트엔드 및 네트워크 리소스 삭제..."
kubectl delete -f "$K8S_DIR/13-ingress.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/12-nginx-service.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/11-nginx-deployment.yaml" --ignore-not-found
if [ -f "$K8S_DIR/metallb-config.yaml" ]; then
    kubectl delete -f "$K8S_DIR/metallb-config.yaml" --ignore-not-found
fi

# 2. 마이크로서비스(백엔드) 리소스 삭제
echo "[INFO] [2/5] 백엔드 마이크로서비스 삭제..."
kubectl delete -f "$K8S_DIR/10-gateway.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/09-photo-service.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/08-employee-server.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/07-auth-server.yaml" --ignore-not-found

# 3. Galera 클러스터 삭제 (StatefulSet, Service, ConfigMap)
echo "[INFO] [3/5] Galera 클러스터 삭제..."
kubectl delete -f "$K8S_DIR/galera/02-galera-statefulset.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/03-galera-services.yaml" --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/00-galera-configmap.yaml" --ignore-not-found

# 4. Secret 삭제
echo "[INFO] [4/5] Secret 삭제..."
kubectl delete secret mariadb-secret ceph-secret --ignore-not-found

# 5. 스토리지(PVC 및 PV) 삭제
echo "[INFO] [5/5] 스토리지(PVC 및 PV) 삭제..."
# StatefulSet으로 생성된 PVC는 yaml 파일에 없으므로 라벨이나 이름으로 직접 삭제해야 합니다.
kubectl delete pvc data-galera-0 data-galera-1 data-galera-2 --ignore-not-found
kubectl delete -f "$K8S_DIR/galera/01-galera-pv.yaml" --ignore-not-found

echo "=================================================================="
echo "[SUCCESS] 쿠버네티스 리소스 삭제 완료!"
echo "⚠️ 주의: DB 데이터를 완전히 초기화하려면 워커 노드(test-worker2)에서"
echo "아래 명령어를 실행하여 디스크의 실제 데이터를 지워주세요."
echo "sudo rm -rf /mnt/data/galera/node0/* /mnt/data/galera/node1/* /mnt/data/galera/node2/*"
echo "=================================================================="
