-- V9 이후 Kubernetes 세 카드 본문 검수. 기존 ID와 질문을 유지한다.
UPDATE cards
SET content_md = $k8s_review_0$## 1. 제어 정보와 실제 패킷 경로를 구분한다

기준은 Kubernetes 1.34의 일반 Pod 네트워크다. CNI(Container Network Interface, 컨테이너 네트워크 인터페이스)는 네트워크 플러그인 연결 규약이며 구체적인 라우팅·터널·정책은 구현에 달린다. Kubernetes 네트워크 모델에서 Pod끼리 주소를 통해 통신할 수 있지만 NetworkPolicy(네트워크 정책), 외부 방화벽, 구현 설정이 허용한다는 전제가 있다. hostNetwork 등 예외도 별도로 본다.

Service는 변하는 백엔드 집합 앞의 안정된 접근점을 제공한다. Pod IP를 직접 호출할 수 있으면 Service 없이도 통신 가능하지만, 재생성으로 주소가 바뀌는 문제와 백엔드 발견을 애플리케이션이 떠안는다.

```mermaid
flowchart LR
    API[API 서버의 Service와 EndpointSlice] -. 감시 .-> DP[kube-proxy 또는 대체 데이터 플레인]
    C[클라이언트] --> VIP[Service 가상 IP와 포트]
    VIP --> DP
    DP --> POD[선택된 Pod IP와 targetPort]
    NET[노드 간 라우팅 또는 터널] --> POD
```

EndpointSlice는 패킷이 통과하는 프록시가 아니다. 백엔드 주소·포트·조건 등의 제어 정보이며 구현이 이를 규칙으로 반영한다. iptables 모드의 kube-proxy도 매 요청을 사용자 공간에서 직접 중계하는 서버로 생각하지 않는다. 대체 데이터 플레인은 kube-proxy 없이 Service 기능을 구현할 수 있다.

## 2. 일반 Service의 경로와 예외

Selector(선택 조건)에 맞는 Pod가 변경되면 컨트롤러가 EndpointSlice를 갱신한다. 가상 IP와 포트의 트래픽은 구현된 전달 규칙에 따라 적합한 백엔드로 간다. 연결 추적 때문에 HTTP 요청마다 백엔드가 균등하게 바뀐다고 보장할 수 없으며 긴 연결은 한 Pod에 부하를 집중시킬 수 있다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: card-api
spec:
  selector:
    app: card-api
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

클라이언트는 Service 80 포트로 연결하고 백엔드 프로세스는 Pod에서 8080으로 실제 수신해야 한다. containerPort 선언만으로 소켓이 열리는 것은 아니다. 이름형 targetPort라면 Pod의 해당 이름과도 맞아야 한다.

| 경우 | 차이 | 확인 |
|---|---|---|
| 일반 ClusterIP | 안정된 가상 IP | 주소군·포트·Endpoint 조건 |
| Headless Service | clusterIP: None, 일반 VIP 전달 경로 없음 | DNS의 백엔드 응답과 클라이언트 선택 |
| Selector 없는 Service | 자동 Pod 선택에 의존하지 않음 | 수동 또는 별도 관리 EndpointSlice |
| ExternalName | DNS 이름 별칭 | 백엔드 Pod 프록시로 오해하지 않기 |

Readiness(트래픽 수신 준비)는 백엔드 선택에 영향을 주지만, API 상태 변경과 모든 데이터 플레인 규칙 반영이 동시인 것은 아니다. 종료 중 연결 처리, `publishNotReadyAddresses`, 로컬 트래픽 정책에 따라 단순히 ready Pod 목록만 보고 결론 내리기 어렵다.

## 3. 외부 노출 방식 선택

| 방식 | 주요 요구 | 필요한 구현 |
|---|---|---|
| LoadBalancer Service | 외부 주소에서 포트 기반 서비스 노출 | 환경의 LB 컨트롤러·로드밸런서 지원 |
| Ingress | 호스트·경로 기반 HTTP(S) 라우팅 | Ingress 컨트롤러와 해당 클래스 |
| Gateway API | Gateway/Route 역할 분리와 표현력 있는 라우팅 | 설치된 API와 기능을 지원하는 컨트롤러 |

Ingress는 Service 타입이 아니다. Gateway API의 지원 프로토콜과 기능은 Route 종류·버전·구현에 따라 다르므로 “항상 모든 L4/L7 기능을 제공한다”고 말하지 않는다. Ingress 리소스를 만든다고 실제 프록시가 자동 설치되지도 않는다.

외부 프록시가 Service VIP를 통해 가는지 Endpoint를 직접 사용하는지는 구현에 달린다. 인증서 종료 위치, 원본 클라이언트 IP 보존, 신뢰할 프록시 헤더, 비용과 운영 소유권을 함께 결정한다. 내부 Service가 정상이어도 외부 경로의 DNS·인증서·Listener·라우트가 잘못되면 접근은 실패한다.

## 4. 통신 실패를 비교 실험으로 좁힌다

```bash
kubectl get service card-api -o yaml
kubectl get endpointslices -l kubernetes.io/service-name=card-api -o yaml
kubectl get pods -l app=card-api -o wide
kubectl get networkpolicy
```

동일한 클라이언트 Pod·네임스페이스·주소군에서 비교한다. 다른 위치의 노트북에서 Pod IP가 안 된다는 사실은 클러스터 내부 경로 실패의 증거가 아니다.

1. DNS 이름이 어떤 주소와 주소군으로 해석되는지 확인한다.
2. Endpoint 주소·포트와 ready/serving/terminating 조건을 실제 Pod 수신 포트와 대조한다.
3. 같은 출발점에서 Pod IP와 Service IP를 각각 호출해 서비스 전달 계층과 Pod 경로를 분리한다.
4. 같은 노드와 다른 노드의 Pod 경로를 비교해 노드 간 라우팅·터널·MTU(최대 전송 단위)를 좁힌다.
5. 출발 Pod의 egress와 도착 Pod의 ingress 정책, 네트워크 구현의 집행 여부, 외부 방화벽을 확인한다.

> **실무 함정**
>
> NetworkPolicy는 이를 집행하는 구현이 필요하다. 여러 정책의 허용 규칙은 합쳐지며 기본 격리 여부와 양쪽 방향을 확인한다. 정책 객체 하나가 존재한다는 사실만으로 모든 트래픽이 막힌다고 판단하지 않는다.

## 참고 자료

- [Kubernetes 1.34 Service](https://v1-34.docs.kubernetes.io/docs/concepts/services-networking/service/)
- [Kubernetes 1.34 EndpointSlice](https://v1-34.docs.kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [Kubernetes 1.34 NetworkPolicy](https://v1-34.docs.kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Kubernetes 1.34 Gateway API](https://v1-34.docs.kubernetes.io/docs/concepts/services-networking/gateway/)

패킷 캡처·CNI별 장애 재현은 이 문서 검수와 별도다.$k8s_review_0$
WHERE slug = 'infra-08-kubernetes-networking' AND source = 'MANUAL';
UPDATE cards
SET content_md = $k8s_review_1$## 1. Pod와 저장소는 수명이 다르다

기준은 **Kubernetes 1.34와 CSI(Container Storage Interface, 컨테이너 저장소 인터페이스) 기반 영속 저장소**다. PVC(PersistentVolumeClaim, 영속 볼륨 요청)는 용량·접근 모드 등을 요청하고 PV(PersistentVolume, 영속 볼륨)는 공급된 저장소를 표현한다. StorageClass(저장소 클래스)는 프로비저너·정책·바인딩 시점 등을 정의한다.

Pod가 없어져도 PVC와 외부 저장소가 남아 있으면 새 Pod가 같은 요청을 통해 데이터를 사용할 수 있다. 이것은 저장 계층의 내구성·백업·복제를 자동으로 보장한다는 뜻이 아니다. `emptyDir`처럼 Pod 수명에 연결된 저장소와 구분한다.

```mermaid
flowchart LR
    P[Pod] --> C[PVC]
    C --> V[바인딩된 PV]
    S[StorageClass] --> D[CSI 동적 공급]
    D --> V
    V --> B[외부 블록 또는 파일 저장소]
    V --> N[접근 모드와 노드 토폴로지 제약]
```

| 대상 | 책임 | 보장하지 않는 것 |
|---|---|---|
| PVC | 요청과 PV 바인딩 | 애플리케이션 데이터 복제 |
| PV | 외부 볼륨 참조·접근/회수 정책 | 모든 노드에서 즉시 재연결 |
| StorageClass | 공급 정책과 바인딩 시점 | 드라이버 미지원 기능 |
| StatefulSet | 안정적인 Pod 식별·저장소 연결 | DB 리더 선출·데이터 동기화 |

## 2. RWO는 한 Pod라는 뜻이 아니다

| 접근 모드 | 의미 | 적용 주의 |
|---|---|---|
| ReadWriteOnce, RWO | 한 노드에서 읽기/쓰기 마운트 | 같은 노드의 여러 Pod가 접근할 수 있음 |
| ReadOnlyMany, ROX | 여러 노드에서 읽기 전용 마운트 | 드라이버 지원과 실제 권한 정책 확인 |
| ReadWriteMany, RWX | 여러 노드에서 읽기/쓰기 마운트 | 애플리케이션의 동시 쓰기 정합성은 별도 |
| ReadWriteOncePod, RWOP | 클러스터에서 한 Pod의 읽기/쓰기 사용 | CSI 볼륨과 필요한 드라이버 구성 확인 |

RWO를 여러 노드의 공유 디스크로 사용하면 다중 연결 오류나 마운트 대기가 생길 수 있다. 반대로 RWO를 한 Pod의 독점 락으로 믿으면 같은 노드에서 경쟁 쓰기가 발생할 수 있다. RWX도 같은 파일을 여러 DB 프로세스가 안전하게 갱신하게 해주지는 않는다.

> **면접 포인트**
>
> 접근 모드는 파일 권한·분산 락·DB 복제 프로토콜을 대체하지 않는다. 단일 작성자 제약이 필요하면 RWOP 지원과 애플리케이션의 소유권·장애 복구를 함께 검토한다.

## 3. Zone과 바인딩 시점

Zone(가용 영역)에 종속된 디스크는 해당 저장소가 지원하는 토폴로지에 맞는 노드가 필요하다. 새 Pod가 다른 Zone에 배치됐다고 데이터가 자동으로 복사되지 않는다. 로컬 PV는 특정 노드에 종속될 수 있어 같은 Zone의 다른 노드도 충분하지 않다.

StorageClass의 `Immediate`는 PVC 생성 시 공급·바인딩을 진행할 수 있다. `WaitForFirstConsumer`는 소비 Pod의 배치 조건을 고려할 때까지 바인딩·공급을 미뤄 영역 불일치를 줄인다. 저장소 용량 부족이나 다른 배치 제약을 해결하는 만능 옵션은 아니다.

```text
진단 순서:
PVC Pending -> StorageClass / 공급 이벤트 / 소비 Pod 대기 확인
Pod Pending -> PV nodeAffinity / Pod affinity / 가용 노드 자원 확인
Attach 실패 -> 이전 연결 상태 / 드라이버 / 외부 볼륨 상태 확인
Mount 실패 -> 파일시스템 / 권한 / 노드 및 드라이버 이벤트 확인
```

노드 장애 후에는 기존 작성자의 중단 확인, 이전 연결 해제, 새 연결·마운트, 애플리케이션 로그 복구까지 시간이 든다. 살아 있는 작성자를 확인하지 않고 강제로 새 인스턴스를 열면 저장 시스템이 동시 접근을 막더라도 애플리케이션의 분할 뇌 위험을 별도로 관리해야 한다.

## 4. StatefulSet의 복제 수는 데이터 복제 수가 아니다

이름 `orders-db`의 StatefulSet에 `data` 템플릿을 두면 보통 `data-orders-db-0`, `data-orders-db-1`처럼 Pod 식별자별 PVC가 생성된다. 같은 식별자의 대체 Pod는 기존 PVC를 다시 사용한다.

```yaml
# StatefulSet spec의 일부. 실제로는 serviceName·selector·Pod template도 필요하다.
replicas: 3
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Retain
  whenScaled: Retain
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 20Gi
```

가상으로 3개 복제본이면 각각 최소 20Gi 요청이므로 총 요청은 60Gi다. 데이터가 세 PVC에 자동 복제되지는 않는다. DB 복제·쿼럼·초기 동기화·리더 교체는 애플리케이션이나 Operator(운영 제어기)가 담당한다. 위 예제의 StorageClass 생략은 클러스터 기본값에 의존하므로 운영에서는 실제 선택을 확인한다.

`volumeClaimTemplates`는 문서의 질문에서 말하는 템플릿에 대응하는 실제 필드명이다. 축소 후 다시 늘릴 때 기존 PVC를 재사용할 수 있지만 데이터의 시대와 클러스터 멤버십이 맞는지도 검사해야 한다.

## 5. 삭제·확장·백업은 각각 다른 정책이다

StatefulSet의 PVC 보존 정책과 PV의 Reclaim Policy(회수 정책)는 구분한다. `whenDeleted`/`whenScaled`는 해당 상황에서 PVC를 보존할지 결정한다. PVC가 삭제되면 PV의 `Retain`/`Delete` 및 공급자 동작에 따라 외부 저장소 수명이 달라진다. 기본 보존을 믿고 운영 삭제 경로 전체를 생략하지 않는다.

확장은 StorageClass의 허용과 드라이버·파일시스템 지원이 필요하며 PVC 요청을 늘리는 경로를 따른다. 마운트 상태 확장 가능 여부와 완료 상태를 확인한다. 용량 축소는 일반적인 PVC 확장 기능으로 지원되는 것으로 가정하지 않는다.

Crash-consistent Snapshot(장애 시점 수준 스냅샷)은 정상 커밋 경계에서의 애플리케이션 일관성을 항상 보장하지 않는다. DB 로그 복구·여러 볼륨의 동일 시점·외부 객체 저장소 참조를 고려한다. 필요한 경우 애플리케이션 백업 절차와 로그 보관을 함께 사용한다.

> **실무 함정 — 복제는 백업이 아니다**
>
> 실수로 삭제한 데이터가 복제본에도 반영될 수 있다. 별도 위치의 백업과 복원 테스트를 두고 RPO(복구 시 허용 데이터 손실)·RTO(복구 시간 목표)를 실제 복원으로 측정한다. Pod 재시작 성공만으로 저장소 복구를 검증했다고 말하지 않는다.

## 참고 자료

- [Kubernetes 1.34 Persistent Volumes](https://v1-34.docs.kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Kubernetes 1.34 StatefulSet](https://v1-34.docs.kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Kubernetes 1.34 StorageClass](https://v1-34.docs.kubernetes.io/docs/concepts/storage/storage-classes/)

이 예제는 개념 검수용이며 실제 CSI 드라이버의 장애·백업 복원 시험은 수행하지 않았다.$k8s_review_1$
WHERE slug = 'infra-09-kubernetes-storage' AND source = 'MANUAL';
UPDATE cards
SET content_md = $k8s_review_2$## 1. Phase와 화면의 STATUS는 같은 값이 아니다

기준은 Kubernetes 1.34다. Pod의 Phase(수명 단계)는 Pending, Running, Succeeded, Failed, Unknown 같은 상위 요약이다. `ContainerCreating`, `CrashLoopBackOff`, `ImagePullBackOff`는 컨테이너 상태나 kubectl 화면의 이유 표시이며 독립 Pod Phase가 아니다. Pending에는 스케줄링 대기뿐 아니라 컨테이너 준비 시간도 포함될 수 있다.

```mermaid
flowchart TD
    A[영향 범위와 변경 시각] --> B{Pod 객체 존재}
    B -->|없음| C[컨트롤러·Admission·Quota 이벤트]
    B -->|있음| D{노드 배정 여부}
    D -->|미배정| E[Scheduler·자원·배치/PVC 제약]
    D -->|배정됨| F[컨테이너 준비·이미지·볼륨·CNI]
    F --> G{프로세스 시작 후 반복 종료}
    G -->|예| H[종료 이유·이전 로그·Probe]
    G -->|아니오| I[준비 상태·Endpoint·통신 계층]
```

## 2. R1 — “Pending이면 서버를 늘리면 되나요?”

**답변 예시:** “먼저 spec.nodeName과 PodScheduled 조건, 이벤트를 봅니다. 미배정이면 요청 자원이 노드 Allocatable에 맞는지, Taint/Toleration·Affinity·Topology·PVC 바인딩 제약을 확인합니다. 이미 노드가 배정됐다면 이미지·볼륨·네트워크 준비 문제일 수 있습니다. Pod 자체가 없다면 ReplicaSet 이벤트와 Admission 거절부터 봅니다.”

```bash
kubectl describe deployment card-api
kubectl describe replicaset <replicaset-name>
kubectl describe pod <pod-name>
kubectl get pod <pod-name> -o yaml
kubectl get pvc
```

가상 노드 4개에 각각 CPU 1개씩 여유가 있어도 CPU 2개를 요청하는 Pod 하나를 쪼개 넣을 수는 없다. 총합 여유와 한 노드에 맞는지를 구분한다. 클러스터 확장도 맞는 노드 종류·영역·상한·공급이 있어야 진행된다.

| 증거 | 가설 | 다음 확인 |
|---|---|---|
| FailedScheduling, Insufficient cpu | 요청량을 수용할 노드 없음 | 노드별 요청 합계·확장 가능성 |
| untolerated taint | 허용되지 않은 노드 | Taint 목적과 Pod 정책 |
| volume node affinity conflict | 저장소 영역과 배치 충돌 | PV 토폴로지·StorageClass |
| Pod 없음, FailedCreate | Admission·Quota 등 생성 거절 | 컨트롤러 이벤트·정책 |
| nodeName 존재, 이미지 오류 | 노드 배정 후 준비 실패 | 이미지 주소·권한·레지스트리 |

**후속 압박:** “Toleration을 전부 허용하면 되죠?”

격리 목적의 노드나 장애 노드에 업무를 잘못 배치할 수 있다. 이벤트가 가리키는 의도를 확인하고 필요한 범위만 수정한다. Quota 거절을 Scheduler 자원 부족으로 혼동하지 않는다.

## 3. R2 — “CrashLoopBackOff에서 로그가 비어 있습니다”

**답변 예시:** “재시작 횟수, containerStatuses의 state와 lastState, 종료 코드와 이유를 봅니다. 현재 인스턴스가 아직 시작 중이면 현재 로그만으로 이전 실패를 알 수 없으므로 --previous도 수집합니다. 여러 컨테이너면 -c로 대상을 명시합니다. 로그가 없으면 실행 명령·설정·종료 신호·OOM·Probe 이벤트를 확인합니다.”

```bash
kubectl logs <pod-name> -c <container-name> --timestamps
kubectl logs <pod-name> -c <container-name> --previous --timestamps
kubectl describe pod <pod-name>
```

`--previous`는 보존된 이전 인스턴스 로그이며 모든 과거 재시작 로그를 복원하지 않는다. 이벤트·노드 로그·중앙 로그의 보존 시간을 확인한다. 토큰이나 환경 비밀을 진단 출력에 무분별하게 포함하지 않는다.

Exit Code 137만으로 OOM을 확정하지 않는다. 강제 종료도 같은 코드가 될 수 있으므로 종료 이유·메모리 시계열·노드 상태를 함께 본다. 프로세스가 정상 코드 0으로 바로 끝나도 `restartPolicy: Always`인 지속 서비스에서는 재시작이 반복될 수 있다.

Readiness 실패는 보통 트래픽 수신 준비를 내리는 것이며 그것만으로 컨테이너를 재시작하지 않는다. Liveness/Startup Probe 실패는 임계값에 따라 재시작을 유발할 수 있다. 느린 초기화를 Liveness 실패로 오인하면 시작을 끝내지 못하는 루프가 된다.

**후속 압박:** “Probe를 지우고 Limit을 올리면 끝 아닌가요?”

임시 완화와 원인 해결을 구분한다. 이전 정상 리비전과 설정 차이를 비교하고, 스키마·외부 계약과 롤백 호환성을 확인한다. 한 번에 한 가설을 바꾼 뒤 재시작·오류·지연·준비 시간을 측정한다.

## 4. R3 — “DNS는 되는데 Service 연결이 안 됩니다”

DNS 성공은 이름에서 주소를 얻었다는 뜻일 뿐 서버가 수신하거나 정책이 허용한다는 증거가 아니다. 같은 출발 Pod에서 다음 순서로 비교한다.

```bash
kubectl get service card-api -o yaml
kubectl get endpointslices -l kubernetes.io/service-name=card-api -o yaml
kubectl get pods -l app=card-api -o wide
kubectl get networkpolicy
```

**답변 예시:** “Service port/targetPort, selector, EndpointSlice 주소와 조건을 먼저 확인합니다. 동일 클라이언트에서 백엔드 Pod IP 직접 연결과 Service IP 연결을 비교합니다. Pod도 실패하면 수신 주소·포트·NetworkPolicy·CNI 경로를, Service만 실패하면 kube-proxy 또는 대체 규칙과 연결 추적을 봅니다. 같은 노드와 다른 노드 결과를 비교해 범위를 줄입니다.”

| 결과 | 다음 가설 | 주의 |
|---|---|---|
| Endpoint 없음 | selector·준비 상태·별도 관리 누락 | Headless/selector 없는 Service 차이 |
| Pod IP도 거절 | 수신 프로세스·포트·주소 | localhost만 바인딩했는지 |
| Pod IP도 시간 초과 | 정책·경로·방화벽 | 출발 egress와 도착 ingress 모두 |
| Pod 성공, Service 실패 | VIP 규칙·정책·주소군 | 항상 kube-proxy만 원인이라고 단정 금지 |
| 내부 성공, 외부 실패 | LB·Ingress/Gateway·TLS | 실제 프록시의 백엔드 연결 경로 확인 |

EndpointSlice는 제어 정보이며 패킷이 지나가는 서버가 아니다. 테스트 대상과 시점을 고정해야 갱신 중 Endpoint나 서로 다른 클라이언트 정책으로 잘못 비교하는 일을 줄인다.

## 5. 증거를 보존하고 복구 결과를 확인한다

> **면접 포인트**
>
> 정상 상태로 바뀐 Pod 수만 보지 말고 실제 요청 성공률·원래 지연·데이터 처리 누락을 확인한다. 한 Pod/노드/영역/전체 중 영향 범위를 기록하고 변경 시각, 리비전, 이벤트, 종료 이유, 연결 비교 결과를 담당 계층에 전달한다. 근거 없는 전체 재시작은 일시 회복과 함께 원인 증거를 지울 수 있다.

## 참고 자료

- [Kubernetes 1.34 Pod 수명](https://v1-34.docs.kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Kubernetes 1.34 Pod 진단](https://v1-34.docs.kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Kubernetes 1.34 Service](https://v1-34.docs.kubernetes.io/docs/concepts/services-networking/service/)
- [Kubernetes 1.34 Probe](https://v1-34.docs.kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)

명령은 진단 예시이며 실제 클러스터 장애 주입 결과는 아니다.$k8s_review_2$
WHERE slug = 'infra-11-kubernetes-troubleshooting-interview' AND source = 'MANUAL';
