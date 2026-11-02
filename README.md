# lab-1

GitOps สำหรับ Kubernetes homelab คลัสเตอร์เดียว สาม env (`dev`, `staging`, `prod`) ใช้ Argo CD เหตุผลการออกแบบอยู่ใน [docs/design.md](docs/design.md)

เวลาที่ใช้: _ ชั่วโมง

## สมมติฐานตอน bootstrap

- Kubernetes 1.30 ขึ้นไป อย่างน้อย 3 node, CNI รองรับ NetworkPolicy
- ทุก node มี `/var/lib/homelab` อยู่บนดิสก์แยกจาก OS
- Cloudflare
  - tunnel แบบ locally-managed หนึ่งตัว ใส่ tunnel ID ใน `infrastructure/cloudflared/config.yaml`
  - CNAME ไป `<tunnel-id>.cfargotunnel.com`: `app-dev`, `api-dev`, `app-staging`, `api-staging`, `app`, `api`
  - R2 bucket `homelab-pg-dev`, `homelab-pg-staging`, `homelab-pg-prod` กับ API token ที่เขียนได้เฉพาะ bucket ของตัวเอง ใส่ account ID ใน `infrastructure/cloudnative-pg/cluster/base/objectstore.yaml`
- age private key อยู่นอก repo เช่น `~/.config/sops/age/keys.txt`

## ก่อนใช้จริง

ไฟล์ `*.sops.yaml` เข้ารหัสด้วย public key ใน `.sops.yaml` ค่าข้างในเป็นค่าตัวอย่าง ถ้าไม่มี private key คู่กัน ให้เปลี่ยน key ใน `.sops.yaml` แล้วเขียนไฟล์เหล่านี้ใหม่ด้วย `sops -e -i <file>`

| ไฟล์ | ค่า |
| --- | --- |
| `infrastructure/cloudflared/secret/credentials.sops.yaml` | credentials.json ของ tunnel |
| `platform/env/secrets/<env>/r2-backup.sops.yaml` | R2 token ของ env นั้น |
| `infrastructure/minio/secret/root.sops.yaml` | root ของ MinIO |
| `infrastructure/minio/secret/loki-user.sops.yaml` | รหัส user `loki` |
| `infrastructure/loki/secret/s3.sops.yaml` | รหัส user `loki` ต้องตรงกับไฟล์บน |
| `infrastructure/kube-prometheus-stack/secret/grafana-admin.sops.yaml` | admin ของ Grafana |

## ลำดับลงครั้งแรก

```bash
kubectl create namespace argocd
kubectl create secret generic argocd-age -n argocd \
  --from-file=keys.txt="$HOME/.config/sops/age/keys.txt"

helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version 10.11.6 -n argocd -f bootstrap/argocd/values.yaml

kubectl apply -f bootstrap/argocd/root-app.yaml
```

prod ต้องกด sync เอง: `env-prod`, `postgres-prod`, `backend-prod`, `frontend-prod`

## ตรวจโดยไม่ต้องมีคลัสเตอร์

```bash
scripts/validate.sh
```

ต้องมี kustomize กับ helm ถ้ามี kubeconform จะตรวจ schema ด้วย ไดเรกทอรี secret ถูกข้ามถ้าไม่มี `ksops` และ `SOPS_AGE_KEY_FILE`
