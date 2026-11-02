# GitOps homelab

## เป้าหมาย

- หลัง bootstrap ทุกอย่างในคลัสเตอร์มาจาก Git แก้ที่ Git แล้ว Argo CD ทำให้คลัสเตอร์ตรงกัน ไม่มี `kubectl apply` มือ
- สาม env ใช้ base เดียวกัน overlay เก็บเฉพาะค่าที่ต่างกัน
- ไม่มี secret แบบ plaintext ใน Git
- node ตายหนึ่งตัว prod ยังรับ request และไม่เสียข้อมูล


## Topology

คลัสเตอร์เดียว สาม env เป็น namespace `dev`, `staging`, `prod`

เลือกแบบนี้เพราะโฮมแล็บมีเครื่องไม่มาก ถ้าแยกคลัสเตอร์ต้องมี control plane สามชุด ข้อเสียคือ operator, CRD, Gateway controller ใช้ร่วมกัน อัปเกรดตัวพวกนี้กระทบทุก env พร้อมกัน ส่วนที่แยกได้ก็แยก: AppProject ต่อ env, ResourceQuota ต่อ namespace, NetworkPolicy default-deny

```
ผู้ใช้ → Cloudflare (TLS) → tunnel → cloudflared
  → Service edge (Envoy) → HTTPRoute → frontend / backend → Postgres
```

| Namespace | ของที่รัน |
| --- | --- |
| `argocd` | Argo CD |
| `cert-manager` | cert-manager (ใช้กับ plugin backup ของ CNPG) |
| `cnpg-system` | CloudNativePG operator, barman-cloud plugin |
| `envoy-gateway-system` | controller ของ Envoy Gateway |
| `edge` | Gateway, Envoy proxy, cloudflared |
| `observability` | Prometheus, Alertmanager, Grafana, Loki, Alloy |
| `object-store` | MinIO |
| `local-path-storage` | local-path-provisioner |
| `dev` `staging` `prod` | backend, frontend, Postgres, NetworkPolicy, quota |

| | dev | staging | prod |
| --- | --- | --- | --- |
| backend, frontend | 1 replica | HPA 2–4 | HPA 2–4 |
| Postgres | 1 instance | 2 | 3 |
| backup เก็บ | 7 วัน | 7 วัน | 30 วัน |
| sync | อัตโนมัติ | อัตโนมัติ | กดเอง |
| quota (requests) | 2 CPU / 4Gi | 2 CPU / 4Gi | 4 CPU / 8Gi |

## โครง repo

```
bootstrap/argocd/     values ของ Argo CD กับ root Application
clusters/homelab/     AppProject กับ ApplicationSet ทั้งหมด ดูที่นี่ที่เดียวว่าอะไรลงคลัสเตอร์
platform/env/         namespace, NetworkPolicy, quota, secret ต่อ env
infrastructure/       operator, Gateway, tunnel, storage, observability, MinIO
apps/<app>/           base, components/ha (PDB + HPA), overlays/dev|staging|prod
scripts/validate.sh   render ทุกอย่างโดยไม่ต้องมีคลัสเตอร์ CI รันตัวนี้
```

- ของที่เขียนเองเป็น Kustomize ส่วน chart ของ upstream ใช้ Helm values เวอร์ชัน chart อยู่ใน `clusters/homelab/infrastructure-helm.yaml` ที่เดียว
- Argo CD ดูแลตัวเองด้วย chart และ values ชุดเดียวกับที่ใช้ตอน bootstrap
- ไม่ใช้ sync wave เพราะ wave ไม่มีผลกับ Application ที่ ApplicationSet สร้าง ทุก app ตั้ง retry (backoff ถึง 10 นาที) กับ `SkipDryRunOnMissingResource` app ที่ต้องใช้ CRD จะล้มรอบแรก แล้วผ่านเองเมื่อ CRD มาถึง
- Cluster ของ CNPG ตั้ง `Prune=false,Delete=false` ลบออกจาก Git หรือลบ app แล้วฐานข้อมูลยังอยู่

## Promotion

- image tag อยู่ที่ `images` ใน `apps/<app>/overlays/<env>/kustomization.yaml` เท่านั้น
- tag ใหม่ลง dev ก่อน ขึ้น staging คือ PR ที่ก็อป tag จาก dev ขึ้น prod คือ PR ที่ก็อปจาก staging ค่าที่ต่างตาม env (hostname, replica, HPA, จำนวน instance) อยู่ใน overlay จึงไม่ถูกก็อปไปด้วย
- dev กับ staging sync เองเมื่อ merge ส่วน prod ต้องกด sync และกดไม่ได้ตั้งแต่ศุกร์ 17:00 ถึงจันทร์ 09:00 (sync window ใน AppProject `prod`)

## Secret

SOPS + age ไฟล์ `*.sops.yaml` เข้ารหัสแค่ `data` กับ `stringData` ดู diff ได้ว่าแก้ key ไหน repo server ของ Argo CD ถอดด้วย KSOPS private key ใส่มือครั้งเดียวตอน bootstrap เป็น Secret `argocd-age` ไม่อยู่ใน Git

- ไม่ใช้ Sealed Secrets เพราะ key ผูกกับ controller ในคลัสเตอร์ คลัสเตอร์หายเมื่อไร ไฟล์ใน Git ถอดไม่ได้ ต้อง seal ใหม่ทั้งหมด age key เก็บไว้นอกคลัสเตอร์ได้
- ไม่ใช้ External Secrets เพราะต้องมี Vault หรือ secret manager อีกตัว ถ้าลง Vault ในคลัสเตอร์ต้องมีคน unseal และข้อมูลไปกองบน hostPath อีกก้อน
- รหัส Postgres ให้ CNPG สร้าง (`postgres-app`) Git มีแค่ชื่อ secret
- ข้อเสีย: key เดียวใช้ทุก env ใครถอด dev ได้ก็ถอด prod ได้ ถ้าต้องแยก เพิ่ม creation rule ต่อ path ใน `.sops.yaml`

## hostPath

local-path-provisioner สร้างไดเรกทอรีใต้ `/var/lib/homelab/local-path` บน node ที่ pod ไปลง StorageClass `hostpath` ตั้ง `Retain`

- PV ผูกกับ node pod ย้าย node ไม่ได้ ถ้า node ตาย ข้อมูลบน node นั้นหายไปด้วย จึงให้แอป replicate เอง: Postgres prod มี 3 instance, staging มี 2 ตั้ง anti-affinity แบบ required ให้อยู่คนละ node ใช้ streaming replication ของ Postgres
- WAL กับ base backup รายวันส่งออกไป R2 ถ้าคลัสเตอร์หายทั้งก้อน กู้ด้วย `bootstrap.recovery` จาก R2
- node ตายถาวร: instance บน node นั้นจะค้าง Pending ต้องลบ PVC กับ pod ของ instance นั้น CNPG จะสร้างใหม่บน node อื่นจาก primary
- ไม่มี quota ดิสก์ ดิสก์เต็มกระทบทุก pod บน node นั้น ให้ `/var/lib/homelab` เป็นดิสก์หรือ partition แยกจาก OS alert `NodeFilesystemSpaceFillingUp` กับ `KubePersistentVolumeFillingUp` มากับ kube-prometheus-stack
- dev มี Postgres instance เดียว จึง drain node ที่ instance นั้นอยู่ไม่ได้ เพราะ PDB ของ primary กันไว้ ก่อน maintenance ให้เปิด `nodeMaintenanceWindow` ใน Git แล้วปิดหลังเสร็จ

## Tunnel

tunnel ตัวเดียวแบบ locally-managed ตาราง hostname อยู่ใน `infrastructure/cloudflared/config.yaml` ไม่ใช้ token เพราะ token mode เก็บ routing ไว้ที่ dashboard ของ Cloudflare ไม่ได้อยู่ใน Git

- cloudflared 2 replica กระจายคนละ node และมี PDB ทุก hostname ชี้ไปที่ Service `edge` ของ Envoy แล้วให้ HTTPRoute แยกต่อ เพิ่ม hostname คือแก้ `config.yaml` + เพิ่ม HTTPRoute + เพิ่ม CNAME
- config สร้างด้วย configMapGenerator ชื่อมี hash แก้แล้ว pod rollout เอง เพราะ cloudflared ไม่ reload config
- hostname ชั้นเดียว (`app-dev.example.com` ไม่ใช่ `dev.apps.example.com`) เพราะ Universal SSL แบบฟรีครอบแค่ `*.example.com` ชื่อสองชั้นต้องซื้อ Advanced Certificate Manager
- TLS จบที่ Cloudflare ช่วง cloudflared ไป Envoy เป็น HTTP ในคลัสเตอร์
- ไม่มี public IP ไม่กระทบ GitOps เพราะ Argo CD ดึงจาก Git เอง ไม่ต้องรับ webhook
- ข้อเสีย: tunnel กับ credential ชุดเดียวใช้ทุก env tunnel ล่มคือล่มทุก env ถ้าต้องแยก ทำ Deployment ต่อ env ได้โดยไม่ต้องแก้แอป

## Observability

Metrics: Prometheus ชุดเดียว เก็บ 2 วัน ดูใน Grafana

- backend: ServiceMonitor ที่ `/metrics`
- frontend: nginx ไม่มี metrics ใช้ metric ของ Envoy แยกตาม route แทน
- Envoy proxy, Envoy Gateway controller, cloudflared: PodMonitor ใน `infrastructure/kube-prometheus-stack/monitors`
- Postgres: PodMonitor อยู่กับ Cluster ของแต่ละ env (`enablePodMonitor` ของ CNPG deprecate แล้ว)
- MinIO: ServiceMonitor จาก chart

Logs: stdout ของทุก pod → Alloy → Loki → Grafana

- Alloy อ่าน log ผ่าน Kubernetes API ไม่ต้อง mount `/var/log` ของ node
- access log ของ Envoy เป็น JSON มี `client_ip` ที่อ่านจาก `CF-Connecting-IP` เพราะทุก request ที่ Envoy เห็นมาจาก IP ของ pod cloudflared
- Loki เก็บ 7 วัน chunk อยู่ใน MinIO

Grafana ไม่เปิดออก tunnel ใช้ `kubectl port-forward` ถ้าจะเปิด ให้เพิ่ม hostname คู่กับ Cloudflare Access

## Object storage

ใช้สองที่ แยกตามว่าข้อมูลหายได้แค่ไหน

- R2 เก็บ backup ของ Postgres backup ต้องอยู่นอกคลัสเตอร์ ถ้าอยู่บน hostPath ชุดเดียวกับ DB ก็ไม่ใช่ backup ระบบนี้มีบัญชี Cloudflare อยู่แล้วเพราะ tunnel และ R2 ไม่คิดค่า egress แยก bucket กับ token ต่อ env (`homelab-pg-<env>`) token ของ dev เขียน bucket ของ prod ไม่ได้
- MinIO ในคลัสเตอร์เก็บ chunk ของ Loki log หายได้ และไม่ควรส่งออกนอกบ้านทุกบรรทัด Loki ใช้ user `loki` แยกจาก root
- chart MinIO ปัก image `RELEASE.2024-12-18` ถ้าจะใช้ยาว เปลี่ยนเป็น Garage หรือ SeaweedFS ได้ Loki ใช้แค่ S3 API

## ของที่อยู่นอก Git

- ติดตั้ง Argo CD ครั้งแรก กับ Secret `argocd-age`
- สร้าง tunnel, CNAME, R2 bucket และ token
- ดิสก์ `/var/lib/homelab` บนทุก node
