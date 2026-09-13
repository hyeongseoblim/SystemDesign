# 기존 콘텐츠 점검 — 2026-09-12

## 점검 범위와 판정 원칙

저장소의 수동 카드 129개 전체에 대해 프론트매터·목차·본문 구조·출처 링크·질문별 해설 연결을 조사했다. 이는 운영 DB 전수 조회나 129개 전체 문장의 사실 검증을 완료했다는 뜻이 아니다. **33개는 본문·질문 3개를 대조해 심층 보강했고, 2개는 확인한 오류 구간만 정정했다. 나머지 94개는 구조 점검 상태**로 남긴다. 기존 10개 해설의 과거 검수와 이번 검수도 구분한다.

분량 2,000자는 보강 후보를 찾는 신호이며 합격 기준이 아니다. 긴 본문이나 참고 링크 하나가 정확성·완결성을 보장하지 않는다. 특히 외부 링크가 있어도 모든 기업 사례·수치가 그 출처에서 확인됐다고 간주하지 않는다. 모드별로 DESIGN은 요구·용량·데이터·실패·대안, INTERVIEW는 질문별 근거와 후속 압박, REVIEW는 문제 코드·반례·수정·검증을 확인해야 한다.

## 전체 기준선

변경 전 본문 2,000자 미만 67개, 본문 HTTPS 출처가 있는 카드 23개, 질문별 점검 해설 10개/30문항이었다. 이번 변경은 카드 수를 늘리지 않고 본문 35개를 수정하고 신규 해설 29개/87문항을 추가했으며 기존 해설 3개/9문항도 갱신했다. 기존 카드의 slug·메타데이터·질문 순서·질문 문구는 변경하지 않았다.

| 영역 | 카드 | 본문 2,000자 미만(변경 후) | 본문 출처 있음 | 질문별 해설 있음 |
|---|---:|---:|---:|---:|
| AI | 15 | 15 | 8 | 1 |
| BACKEND_ARCHITECTURE | 15 | 7 | 6 | 6 |
| BACKEND_DEV | 15 | 8 | 7 | 4 |
| CS | 11 | 5 | 1 | 0 |
| DATABASE | 15 | 6 | 7 | 4 |
| INFRA | 13 | 2 | 4 | 4 |
| LOGISTICS | 19 | 0 | 10 | 11 |
| SYSTEM_DESIGN | 26 | 5 | 9 | 9 |

## 확인한 문제와 수정

| 우선순위 | 카드 | 발견 내용 | 조치 |
|---|---|---|---|
| P0 | 트랜잭션 격리 심화 | COUNT를 읽지만 업무 조건을 검사하지 않는 예제; Predicate Lock 설명 부족 | 조건 검사·두 세션 재현·새 트랜잭션 재시도 보강 |
| P0 | 멱등 소비자 | ON CONFLICT 이후 삽입 결과에 따른 업무 실행 분기 누락 | Inbox와 업무 키·트랜잭션·영향 행 수를 연결 |
| P0 | RDBMS vs NoSQL | 오류 응답도 CAP 가용성이라는 정의; Dynamo/DynamoDB 혼동; QUORUM도 항상 A라는 분류 | 원 논문·공식 문서 기준 부분 정정 |
| P0 | 인덱스·락 면접 | 격리수준으로 갱신 유실을 막지 못한다는 DBMS 무관 일반화 | PostgreSQL RR 동시 갱신 중단을 구분 |
| P1 | 분산 락 | 같은 Token의 중복·순서 및 저장소가 아직 새 Token을 모르는 경계 누락 | 소유권당 한 쓰기 예제·관측 경계·외부 자원 제약 보강 |
| P1 | 메시지 큐 | 처리율과 파티션 개수를 비교하는 단위 오류; 제품 유형 구분 부족 | 측정 처리율로 나누는 계산, Standard/FIFO·Queue/Stream 분리 |
| P1 | 이벤트 기반·Outbox | exactly-once 전면 불가능, 무조건적인 유실 0 표현 | 전달 시도와 관측 결과·내구성·재시도 조건을 분리 |
| P1 | MSA vs Monolith | 근거 없는 p99 2~5배·인력 1.5~2배 일반화 | 가상 계산과 측정 기준으로 대체 |

추가 배치에서 발견한 핵심 문제도 다음과 같이 보강했다.

| 카드 묶음 | 발견 내용 | 조치 |
|---|---|---|
| 재고·동시성 | 낙관적 UPDATE는 락이 없다는 설명, Redis 감소/복원 사이 장애, 예약 TTL과 업무 복구 혼동 | 내부 잠금·고유 예약 키·상태 전이 원자성·Redis 이중 쓰기 경계 |
| 복원력·구현 면접 | PG 호출을 DB 트랜잭션에 넣은 수정본, UNIQUE 예외 catch 후 같은 트랜잭션 사용, 저장 없는 Fallback | 영속 명령·UNKNOWN 상태 대사·충돌 영향 행 분기·DB 커밋 후 ACK |
| 합의·복제 | Quorum 최신값 단정·Raft 과거 임기 커밋 조건 누락·리더 로컬 읽기 가정 | 고정 구성 전제·현재 임기·읽기 권한 확인·CRAQ 버전 예제 |
| 분산 시계 | HLC 수신 시 네 분기 누락 | 실행 코드·시계 역행/수신 인과성 회귀 검사 |
| 물류 스캔·파이프라인 | 단말 순번과 전역 업무 버전 혼동, 재생 중 외부 효과·추가 유입 누락 | 정정 승인·Checkpoint·Shadow 전환·재생 알림 분리 |
| 운송사·배차 | 라벨 결과 불명 재시도, 주문 버전만으로 기사 중복 제안 방지 불충분 | 외부 참조 대사·주문/기사 양쪽 제안 점유·목적 함수 단위 |

참고 근거는 각 수정 카드의 본문과 해설 `sources`에 연결했다. 기존 Outbox 질문의 “유실 0” 문구는 저장된 질문 연결을 유지하면서 본문에서 생략된 전제를 명시했다. 이후 질문 자체를 개정하려면 질문 ID를 보존하는 별도 갱신과 기존 답변의 의미 변화 안내를 함께 설계한다.

## 다음 심층 검수 순서

1. **재고·동시성 경로**: database-07, backend-02/04/07은 이번에 보강했다. backend-03과 database-02도 9월 13일 보강했다. database-03도 이후 배치에서 보강했다. 다음은 database-08의 잔여 본문과 거래·격리 설명을 맞추고 실제 DB 두 세션 장애 재현을 추가한다.
2. **합의·복제·메시징**: system-design-07/17/18은 이번에 보강했다. system-design-06/14의 메시징·다중 리전과 architecture-04/07은 9월 13일 추가 배치에서 보강했다.
3. **물류 업무 모델**: logistics-13/14/16/19는 이번에 보강했다. logistics-10/11/12도 보강했다. logistics-15/17/18도 보강했다. 다음은 logistics-01~09의 남은 기업 사례와 운영 설명을 검수한다. 이벤트 보정, 배송 약속, 원장 대사, 기사 할당의 상태 전이 예제와 질문별 해설을 채운다. logistics-01~07의 기업별 설명은 공개 근거와 가상 설계를 분리한다.
4. **AI/LLM 15개**: 보안·도구 실행·평가부터. 짧은 개요에서 실패 입력→판단→복구 예제로 확장하고 API·프로토콜 버전을 명시한다.
5. **DB·백엔드·인프라·CS 잔여**: 같은 주제의 CONCEPT·INTERVIEW·REVIEW를 묶어 용어와 정답 기준이 충돌하지 않는지 비교한다.

## 반영과 검증

`ContentSeeder`는 기존 slug를 건너뛰므로 Markdown 수정만으로 기존 DB가 갱신되지 않는다. `V9__review_existing_content.sql`은 수정한 32개 MANUAL 카드의 `content_md`만 갱신한다. 새 DB에서는 이후 시더가 같은 본문을 적재한다. V8 및 기존 Flyway 파일은 수정하지 않는다.

V9 배치는 API와 Web에 모두 반영했다. 2026-09-13에 V9와 Web 해설 34개 배포를 완료했다. [배포 기록](deployment-2026-09-13.md)을 참고한다. 후속 V10 세 카드와 해설 37개/111문항도 운영 반영하고 DB·API·웹 응답을 검증했다. 기존 질문·카드 ID를 바꾸지 않아 저장된 학습 기록과 답변 연결을 유지한다.

검증 결과는 아래 별도 절에 기록한다. 본문의 SQL은 학습용 예제이며 실제 DB의 두 세션 실행·장애 주입은 별도 검증 범위다.

## 검증 결과

- `bash scripts/check-content.sh`: 전체 129개 콘텐츠 계약 통과. YAML·slug/topicKey·질문 수·표·Mermaid/코드블록 존재 검사다.
- `node --test scripts/study.test.cjs`: 9개 통과. 해설 34개/102문항 일치, V8 유지, V9 32개 본문 일치와 UPDATE 범위를 확인했다.
- `python3 scripts/content-examples.test.py`: 3개 통과. HLC 시계 역행, 수신 네 분기와 1,024개 입력 조합에서 로컬·원격 사건 이후 순서를 확인했다.
- `npm run build` (`apps/web`): 성공. 새 해설 JSON과 TypeScript 연결을 확인했다.
- `git diff --check`: 통과. 수정 카드 32개의 프론트매터가 기준 커밋과 동일한 것도 확인했다.
- CI Web 작업에 학습/본문 회귀 검사와 HLC 예제 검사를 추가했다. 새 CI 구성은 아직 원격 실행 전이다.

PostgreSQL 동시 세션은 9월 13일 임시 로컬 18.4에서 아래 4개 시나리오를 검증했다. 문서 기준 버전 17에서의 실행, MySQL 8.4 실행, Spring 프록시 통합 실행, Redis 장애 주입·모바일 Mermaid 렌더는 수행하지 않았다. 운영 V9 적용은 이후 배포에서 검증했다. Node에서 Mermaid 파싱을 시도했지만 DOMPurify의 브라우저 DOM 의존성으로 실행되지 않아 다이어그램 렌더 검증으로 계산하지 않는다.

## 2026-09-13 심층 검수 추가

- `backend-03-transaction`: SERIALIZABLE 불변식 보장과 재시도 전제, REQUIRED rollback-only, REQUIRES_NEW의 예외 전파·커넥션 대기, 자기 호출 대안, readOnly 힌트, 외부 결제 UNKNOWN과 보상 실패를 정정했다. 오래된 HTML 링크와 무조건적인 2PC/Saga 분류를 제거했다.
- `database-02-lock-isolation`: 스냅샷과 최신 잠금 읽기, 갭 잠금 공존, 인덱스 스캔과 테이블 X 락의 차이, ORDER BY의 잠금 순서 단정, 교착과 잠금 시간 초과의 롤백 범위를 보강했다.
- 두 카드의 기존 질문별 해설 6문항을 본문과 다시 대조했다. 신규 해설 카드를 추가한 것은 아니므로 전체는 24개/72문항이다.
- `PG_BIN=/opt/homebrew/opt/postgresql@18/bin python3 scripts/content-postgres.test.py`: PostgreSQL 18.4 임시 클러스터의 독립 세션으로 4개 통과. RC 스냅샷 갱신, RR 스냅샷 유지 및 동시 갱신 40001, RR 쓰기 편향, SERIALIZABLE 중단 및 새 판단으로 불변식 유지까지 확인했다. 임시 서버는 종료·정리했다.
- 이 검사는 본문에서 SQL을 자동 추출한 검사가 아니라 해당 설명의 재현 시나리오다. 운영 DB 연결을 받지 않고 TCP도 열지 않는다. PostgreSQL 실행 파일이 필요한 별도 수동 검사이며 기본 CI에는 추가하지 않았다.

## 2026-09-13 MVCC·Saga 추가 배치

- `database-03-mvcc-internals`: BEGIN/첫 일관 읽기 시점, 트랜잭션 ID만으로 가시성 판단 불가, PostgreSQL 옛 버전의 회수 가능 시점, WAL과 데이터 쓰기·Checkpoint, HOT 조건·fillfactor·일반 VACUUM과 FULL을 다시 정리했다.
- `backend-architecture-04-saga`: 모놀리스도 외부 결제가 로컬 롤백에 참여하지 않는 경계, 2PC/CAP 혼동, Pivot·승인/Capture·집하 구분, 호출 전 명령 기록과 상태/다음 명령의 원자성을 보강했다. 확인되지 않은 기업 도입 사례와 단계 수로 패턴을 결정하는 규칙을 제거했다.
- `backend-architecture-07-interview-saga`: 4개 면접 라운드를 재작성했다. 미해결 상태·알림이 최종 복구를 증명한다는 주장을 제거하고, 외부 성공 후 기록 전 장애·무조건 환불의 위험·실물 반품 재고를 구분했다. 기존 질문의 불가능한 무조건적 보장 전제는 해설에서 명시적으로 검토한다.
- 신규 해설 3개/9문항을 추가해 전체 **27개/81문항**이다.
- 임시 PostgreSQL 18.4 검사를 **6개**로 확장했다. 기존 격리수준 4개 외에 본문 SQL을 직접 추출해 중복 보상 수량 1회 복원, 다음 명령 UNIQUE 충돌 시 상태 롤백 및 재처리 시 명령 1회 생성을 검증했다. 외부 제공자 장애와 MySQL 실행 검증을 대신하지 않는다.

## 2026-09-13 배송 약속·원장·식별 추가 배치

- `logistics-10-order-promise`: ATP 예약 중복 차감·재고 개수/작업 건수 단위 혼동을 정정했다. 제품별 CTP 범위와 자체 물류 제약 검사를 구분하고, 실제 Hold 없는 토큰·분산 원자 재검증 단정·합배송 이동 캘린더·최초 약속 기준 지표를 보강했다.
- `logistics-11-inventory-ledger`: 출발과 실제 입고 사이 IN_TRANSIT 계정을 추가하고, 기입마다 동일 UNIQUE 업무 키를 쓰는 결함을 거래 헤더 키로 수정했다. 합계 0만으로 충분하지 않은 불변식, Sequence 할당/커밋 역전, Snapshot 처리 기준점, 실사 중 이동과 정정 절차를 보강했다.
- `logistics-12-sku-barcode-serial`: SKU/표현/GTIN/SSCC, 품목+로트/시리얼 식별 범위, 포장 환산, GS1 필드 구분, 포함 관계 이력과 재포장·지연 스캔을 확장했다. GS1 검색 결과와 공식 AI 참조를 사용했으며 일부 GS1 상세 페이지는 직접 열기에서 403/시간 초과가 있었다. 자체 스키마를 표준 구현으로 주장하지 않는다.
- 신규 해설 3개/9문항을 추가해 전체 **30개/90문항**이다.
- PostgreSQL 18.4 임시 검사 **8개 통과**: 원장 본문 스키마의 균형·중복 업무/음수 수량 거절과 Sequence 기준점의 늦은 커밋 누락 반례를 추가했다. 임시 클러스터 종료·정리 완료. 실제 공급망 엔진·스캐너·운영 원장 연동 검증은 아니다.

## 2026-09-13 배송망·운영 면접·슬로팅 추가 배치

- `logistics-15-rocket-delivery-design`: 종단 시각의 단순 max 계산을 단계별 작업·적재·출발 캘린더 계산으로 수정했다. 동일 단위 용량 추정, API/계획 모델, 부분 예약·폭증 배분·장애 영향 조회·최초 약속 지표를 추가했다.
- `logistics-17-fulfillment-operations-interview`: 세 라운드를 질문·답변·후속 압박으로 확장했다. 단위/가동률 이중 계산, 병목과 공급 부족/하류 차단, 안정 상태와 큐 증가, Wave 대기, 부분 피킹 예외와 재합류를 구분했다.
- `logistics-18-slotting-optimization`: ABC 기준, Lift/조건부 확률·표본, 실제 피킹 단위, 시간/금액 단위·기간별 손익분기, 실물 이동과 전후 실험 교란을 보강했다.
- 신규 해설 3개/9문항으로 전체 **33개/99문항**이다. 계산값은 본문의 가정을 기준으로 확인했으며 현장 실험·물류 최적화 엔진 실행 결과는 아니다. 기존 PostgreSQL 검사는 이 배치의 배송망/슬로팅 정확도를 증명하지 않는다.

## 2026-09-13 Kubernetes 자원 관리 추가 검수

- `infra-12-kubernetes-resource-management`: Kubernetes 1.34 Linux 컨테이너별 설정을 기준으로 Admission 기본값, Request/Limit과 CPU 가중치, OOM/노드 압박 축출, QoS의 한계, JVM 전체 메모리와 HPA Request 분모·노드 여유를 보강했다.
- 신규 해설 1개/3문항으로 전체 **34개/102문항**이다. 8Gi 노드 과밀과 HPA 예제는 단순 가정 계산이다. 실제 Kubernetes 부하·OOM·축출·HPA 실행은 수행하지 않았다.

## 2026-09-13 배포 후속 검수

- `infra-09-kubernetes-storage`: Kubernetes 1.34 기준 RWO와 RWOP, 토폴로지/WaitForFirstConsumer, replica별 PVC와 데이터 복제의 차이, StatefulSet 보존/PV 회수 정책, 백업 복구를 보강했다.
- 해설 전체는 35개/105문항이다. 이 후속 본문은 `V10__review_kubernetes_content.sql`로 분리하며 V9는 변경하지 않는다. 실제 CSI 장애·복원 시험은 수행하지 않았다.
- 아래 기존 검증 기록은 V9 배치의 결과다. 배포 상태와 후속 검증은 별도 배포 기록에서 구분한다.

## Kubernetes 네트워킹·장애 면접 후속

네트워킹과 장애 면접 2개를 추가 검수했다. EndpointSlice의 제어 정보와 패킷 경로, Pod Phase와 STATUS 이유, Admission 거절과 스케줄링/준비 실패, 이전 로그와 Probe, 동일 출발점 연결 비교를 보강했다. 해설 전체는 37개/111문항이며 스토리지와 함께 V10 세 카드로 배포한다. 실제 CNI·Probe 장애 주입은 수행하지 않았다.

## 카드별 점검표

`구조 점검`은 사실 검수 통과를 의미하지 않는다. 본문 글자 수는 프론트매터 제외, 공백 포함이다. “점검 해설 없음”은 Web의 질문별 체크리스트가 없다는 뜻이며 본문 속 모범 답변 유무와 다르다.

| 카드 | 모드·난이도 | 본문 글자 | 이번 상태 | 확인·후속 과제 |
|---|---|---:|---|---|
| [ai-01-transformer-fundamentals](../apps/api/src/main/resources/content/ai-01-transformer-fundamentals.md) | CONCEPT · 3 | 1,136 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-02-token-context-window](../apps/api/src/main/resources/content/ai-02-token-context-window.md) | CONCEPT · 3 | 971 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [ai-03-prompt-structured-output](../apps/api/src/main/resources/content/ai-03-prompt-structured-output.md) | CONCEPT · 3 | 1,048 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-04-embedding-vector-search](../apps/api/src/main/resources/content/ai-04-embedding-vector-search.md) | CONCEPT · 3 | 1,007 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [ai-05-production-rag-design](../apps/api/src/main/resources/content/ai-05-production-rag-design.md) | DESIGN · 4 | 1,255 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-06-hybrid-retrieval-reranking](../apps/api/src/main/resources/content/ai-06-hybrid-retrieval-reranking.md) | CONCEPT · 4 | 959 | 구조 점검 | 짧은 본문 / 본문 출처 없음 |
| [ai-07-tool-calling-mcp](../apps/api/src/main/resources/content/ai-07-tool-calling-mcp.md) | CONCEPT · 4 | 1,214 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-08-reliable-agent-workflow](../apps/api/src/main/resources/content/ai-08-reliable-agent-workflow.md) | DESIGN · 5 | 1,215 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [ai-09-evaluation-observability](../apps/api/src/main/resources/content/ai-09-evaluation-observability.md) | CONCEPT · 4 | 1,200 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-10-prompt-injection-security-review](../apps/api/src/main/resources/content/ai-10-prompt-injection-security-review.md) | REVIEW · 5 | 1,423 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-11-inference-serving-design](../apps/api/src/main/resources/content/ai-11-inference-serving-design.md) | DESIGN · 5 | 1,317 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-12-finetuning-lora-quantization](../apps/api/src/main/resources/content/ai-12-finetuning-lora-quantization.md) | CONCEPT · 4 | 1,306 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [ai-13-multimodal-pipeline-design](../apps/api/src/main/resources/content/ai-13-multimodal-pipeline-design.md) | DESIGN · 4 | 1,082 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [ai-14-production-llm-system-interview](../apps/api/src/main/resources/content/ai-14-production-llm-system-interview.md) | INTERVIEW · 5 | 1,155 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [ai-15-llm-integration-code-review](../apps/api/src/main/resources/content/ai-15-llm-integration-code-review.md) | REVIEW · 4 | 1,271 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-01-api-design](../apps/api/src/main/resources/content/backend-01-api-design.md) | CONCEPT · 3 | 8,583 | 구조 점검 | 점검 해설 없음 |
| [backend-02-concurrency](../apps/api/src/main/resources/content/backend-02-concurrency.md) | CONCEPT · 3 | 8,214 | 심층 보강 | volatile 복합 연산, DB 잠금 범위, Redis 보상 코드·언어 태그 정정 |
| [backend-03-transaction](../apps/api/src/main/resources/content/backend-03-transaction.md) | CONCEPT · 3 | 6,345 | 심층 보강 | 직렬성 보장·전파/예외·readOnly·프록시·외부 결제 경계 |
| [backend-04-resilience-idempotency](../apps/api/src/main/resources/content/backend-04-resilience-idempotency.md) | CONCEPT · 3 | 7,765 | 심층 보강 | 외부 결제 상태 머신, 영속 명령, Retry/CB 순서·DB 커밋 후 ACK |
| [backend-05-testing](../apps/api/src/main/resources/content/backend-05-testing.md) | CONCEPT · 3 | 4,793 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [backend-06-observability](../apps/api/src/main/resources/content/backend-06-observability.md) | CONCEPT · 3 | 5,300 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [backend-07-interview-concurrency](../apps/api/src/main/resources/content/backend-07-interview-concurrency.md) | INTERVIEW · 4 | 6,718 | 심층 보강 | 중복/갱신 유실 구분, UNIQUE 예외 처리, 결제·Outbox 수정본 재작성 |
| [backend-08-jvm-memory](../apps/api/src/main/resources/content/backend-08-jvm-memory.md) | CONCEPT · 4 | 1,749 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-09-gc-g1-zgc](../apps/api/src/main/resources/content/backend-09-gc-g1-zgc.md) | CONCEPT · 4 | 1,729 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [backend-10-gc-diagnostics](../apps/api/src/main/resources/content/backend-10-gc-diagnostics.md) | CONCEPT · 4 | 1,033 | 구조 점검 | 짧은 본문 / 점검 해설 없음 |
| [backend-11-http-client-design](../apps/api/src/main/resources/content/backend-11-http-client-design.md) | DESIGN · 4 | 973 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-12-null-safety-review](../apps/api/src/main/resources/content/backend-12-null-safety-review.md) | REVIEW · 3 | 960 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-13-jvm-incident-interview](../apps/api/src/main/resources/content/backend-13-jvm-incident-interview.md) | INTERVIEW · 4 | 1,048 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-14-thread-pool-sizing](../apps/api/src/main/resources/content/backend-14-thread-pool-sizing.md) | CONCEPT · 4 | 967 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-15-file-streaming-design](../apps/api/src/main/resources/content/backend-15-file-streaming-design.md) | DESIGN · 4 | 1,047 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-01-msa-vs-monolith](../apps/api/src/main/resources/content/backend-architecture-01-msa-vs-monolith.md) | CONCEPT · 3 | 4,416 | 심층 보강 | 논리/물리 DB·가용성 독립 가정·p99·쓰기 전환과 롤백 |
| [backend-architecture-02-ddd](../apps/api/src/main/resources/content/backend-architecture-02-ddd.md) | CONCEPT · 3 | 7,025 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-03-event-driven](../apps/api/src/main/resources/content/backend-architecture-03-event-driven.md) | CONCEPT · 3 | 4,204 | 심층 보강 | 스키마 호환 방향·흐름 소유권·Delta/Snapshot·버전 누락과 재처리 |
| [backend-architecture-04-saga](../apps/api/src/main/resources/content/backend-architecture-04-saga.md) | CONCEPT · 4 | 5,569 | 심층 보강 | 2PC 경계·Pivot·외부 결제 명령·상태/Outbox 원자성 |
| [backend-architecture-05-cqrs-event-sourcing](../apps/api/src/main/resources/content/backend-architecture-05-cqrs-event-sourcing.md) | CONCEPT · 4 | 5,712 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [backend-architecture-06-outbox-idempotency](../apps/api/src/main/resources/content/backend-architecture-06-outbox-idempotency.md) | CONCEPT · 4 | 4,259 | 심층 보강 | 장애 시점·eventId/파티션 키·Inbox 분기·외부 API 결과 불명 |
| [backend-architecture-07-interview-saga](../apps/api/src/main/resources/content/backend-architecture-07-interview-saga.md) | INTERVIEW · 4 | 5,268 | 심층 보강 | 보상 미해결 관리·외부/로컬/전달 경계·집하/반품 4라운드 |
| [backend-architecture-08-aggregate-boundary](../apps/api/src/main/resources/content/backend-architecture-08-aggregate-boundary.md) | CONCEPT · 4 | 1,948 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-09-aggregate-reference](../apps/api/src/main/resources/content/backend-architecture-09-aggregate-reference.md) | CONCEPT · 4 | 1,601 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-10-entity-value-object](../apps/api/src/main/resources/content/backend-architecture-10-entity-value-object.md) | CONCEPT · 3 | 929 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-11-idempotent-consumer-design](../apps/api/src/main/resources/content/backend-architecture-11-idempotent-consumer-design.md) | DESIGN · 4 | 3,757 | 심층 보강 | 삽입 결과 분기, 업무 키, 보존·재처리·외부 효과 |
| [backend-architecture-12-order-orchestration-design](../apps/api/src/main/resources/content/backend-architecture-12-order-orchestration-design.md) | DESIGN · 5 | 1,022 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-13-boundary-interview](../apps/api/src/main/resources/content/backend-architecture-13-boundary-interview.md) | INTERVIEW · 4 | 874 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-14-rich-domain-model](../apps/api/src/main/resources/content/backend-architecture-14-rich-domain-model.md) | CONCEPT · 3 | 946 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [backend-architecture-15-message-recovery-interview](../apps/api/src/main/resources/content/backend-architecture-15-message-recovery-interview.md) | INTERVIEW · 5 | 967 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [cs-01-ds-algo](../apps/api/src/main/resources/content/cs-01-ds-algo.md) | CONCEPT · 3 | 8,429 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [cs-02-os](../apps/api/src/main/resources/content/cs-02-os.md) | CONCEPT · 3 | 8,114 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [cs-03-network](../apps/api/src/main/resources/content/cs-03-network.md) | CONCEPT · 3 | 6,899 | 구조 점검 | 점검 해설 없음 |
| [cs-04-concurrency-theory](../apps/api/src/main/resources/content/cs-04-concurrency-theory.md) | CONCEPT · 3 | 5,447 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [cs-05-complexity](../apps/api/src/main/resources/content/cs-05-complexity.md) | CONCEPT · 3 | 5,636 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [cs-06-interview-fundamentals](../apps/api/src/main/resources/content/cs-06-interview-fundamentals.md) | INTERVIEW · 3 | 9,268 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [cs-07-io-multiplexing](../apps/api/src/main/resources/content/cs-07-io-multiplexing.md) | CONCEPT · 4 | 947 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [cs-08-socket-internals](../apps/api/src/main/resources/content/cs-08-socket-internals.md) | CONCEPT · 4 | 987 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [cs-09-os-network-interview](../apps/api/src/main/resources/content/cs-09-os-network-interview.md) | INTERVIEW · 4 | 1,048 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [cs-10-virtual-memory](../apps/api/src/main/resources/content/cs-10-virtual-memory.md) | CONCEPT · 4 | 946 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [cs-11-data-structures-interview](../apps/api/src/main/resources/content/cs-11-data-structures-interview.md) | INTERVIEW · 4 | 909 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-01-index-explain](../apps/api/src/main/resources/content/database-01-index-explain.md) | CONCEPT · 3 | 9,534 | 구조 점검 | 버전·수치·질문 대응 정밀 검수 |
| [database-02-lock-isolation](../apps/api/src/main/resources/content/database-02-lock-isolation.md) | CONCEPT · 3 | 5,648 | 심층 보강 | 스냅샷/잠금 읽기·갭/스캔 범위·키 순차 접근·전체 재시도 |
| [database-03-mvcc-internals](../apps/api/src/main/resources/content/database-03-mvcc-internals.md) | CONCEPT · 4 | 5,577 | 심층 보강 | 읽기 뷰·버전 수명·WAL/Checkpoint·HOT·Freeze 조건 |
| [database-04-sharding-partitioning-replication](../apps/api/src/main/resources/content/database-04-sharding-partitioning-replication.md) | CONCEPT · 4 | 5,518 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [database-05-rdbms-vs-nosql](../apps/api/src/main/resources/content/database-05-rdbms-vs-nosql.md) | CONCEPT · 3 | 7,931 | 부분 정정 | CAP 가용성 정의, 제품 고정 분류, Dynamo 혼동 정정; 기타 기능은 후속 검수 |
| [database-06-query-tuning](../apps/api/src/main/resources/content/database-06-query-tuning.md) | CONCEPT · 3 | 7,147 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [database-07-inventory-concurrency](../apps/api/src/main/resources/content/database-07-inventory-concurrency.md) | CONCEPT · 4 | 5,361 | 심층 보강 | 조건부 갱신·중복 예약·만료/결제 경쟁·Redis 내구성·이중 쓰기 |
| [database-08-interview-index-lock](../apps/api/src/main/resources/content/database-08-interview-index-lock.md) | INTERVIEW · 4 | 12,526 | 부분 정정 | R3 갱신 유실의 MySQL·PostgreSQL 차이 정정; 나머지 라운드는 후속 검수 |
| [database-09-index-access-optimization](../apps/api/src/main/resources/content/database-09-index-access-optimization.md) | CONCEPT · 4 | 2,319 | 구조 점검 | 점검 해설 없음 |
| [database-10-index-write-cost](../apps/api/src/main/resources/content/database-10-index-write-cost.md) | CONCEPT · 4 | 1,552 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-11-clustered-index-pk](../apps/api/src/main/resources/content/database-11-clustered-index-pk.md) | CONCEPT · 4 | 951 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-12-zero-downtime-migration](../apps/api/src/main/resources/content/database-12-zero-downtime-migration.md) | DESIGN · 5 | 925 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-13-index-antipattern-review](../apps/api/src/main/resources/content/database-13-index-antipattern-review.md) | REVIEW · 4 | 917 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-14-statistics-histogram](../apps/api/src/main/resources/content/database-14-statistics-histogram.md) | CONCEPT · 4 | 879 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [database-15-query-antipattern-review](../apps/api/src/main/resources/content/database-15-query-antipattern-review.md) | REVIEW · 4 | 890 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [infra-01-aws-core](../apps/api/src/main/resources/content/infra-01-aws-core.md) | CONCEPT · 3 | 9,624 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [infra-02-kubernetes](../apps/api/src/main/resources/content/infra-02-kubernetes.md) | CONCEPT · 3 | 6,982 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [infra-03-iac-terraform](../apps/api/src/main/resources/content/infra-03-iac-terraform.md) | CONCEPT · 3 | 5,579 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [infra-04-cicd-deploy-strategy](../apps/api/src/main/resources/content/infra-04-cicd-deploy-strategy.md) | CONCEPT · 3 | 5,784 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [infra-05-observability-stack](../apps/api/src/main/resources/content/infra-05-observability-stack.md) | CONCEPT · 3 | 5,463 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 |
| [infra-06-sre-incident](../apps/api/src/main/resources/content/infra-06-sre-incident.md) | CONCEPT · 3 | 5,290 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [infra-07-interview-incident](../apps/api/src/main/resources/content/infra-07-interview-incident.md) | INTERVIEW · 3 | 12,539 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [infra-08-kubernetes-networking](../apps/api/src/main/resources/content/infra-08-kubernetes-networking.md) | CONCEPT · 4 | 3,617 | 심층 보강 | EndpointSlice 제어 정보·실제 전달 경로·정책·외부 노출 |
| [infra-09-kubernetes-storage](../apps/api/src/main/resources/content/infra-09-kubernetes-storage.md) | CONCEPT · 4 | 4,023 | 심층 보강 | RWO/RWOP·영역 바인딩·PVC 보존/회수·복제/백업 |
| [infra-10-commerce-spike-design](../apps/api/src/main/resources/content/infra-10-commerce-spike-design.md) | DESIGN · 5 | 1,007 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [infra-11-kubernetes-troubleshooting-interview](../apps/api/src/main/resources/content/infra-11-kubernetes-troubleshooting-interview.md) | INTERVIEW · 4 | 4,423 | 심층 보강 | Phase/STATUS·미생성/미배정/준비·이전 로그·연결 비교 |
| [infra-12-kubernetes-resource-management](../apps/api/src/main/resources/content/infra-12-kubernetes-resource-management.md) | CONCEPT · 4 | 4,379 | 심층 보강 | Admission·QoS·OOM/축출·HPA 분모·장애/배포 여유 |
| [infra-13-warehouse-edge-design](../apps/api/src/main/resources/content/infra-13-warehouse-edge-design.md) | DESIGN · 5 | 982 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [logistics-01-oms-order-management](../apps/api/src/main/resources/content/logistics-01-oms-order-management.md) | CONCEPT · 3 | 6,940 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-02-wms-warehouse](../apps/api/src/main/resources/content/logistics-02-wms-warehouse.md) | CONCEPT · 3 | 8,549 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-03-tms-transportation](../apps/api/src/main/resources/content/logistics-03-tms-transportation.md) | CONCEPT · 3 | 10,907 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-04-fulfillment-inventory](../apps/api/src/main/resources/content/logistics-04-fulfillment-inventory.md) | CONCEPT · 4 | 9,103 | 구조 점검 | 본문 출처 없음 / 기업 언급 출처 확인 |
| [logistics-05-last-mile-routing](../apps/api/src/main/resources/content/logistics-05-last-mile-routing.md) | CONCEPT · 4 | 8,971 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-06-returns-reverse-logistics](../apps/api/src/main/resources/content/logistics-06-returns-reverse-logistics.md) | CONCEPT · 3 | 7,561 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-07-case-studies](../apps/api/src/main/resources/content/logistics-07-case-studies.md) | CONCEPT · 3 | 10,551 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-08-dispatch-optimization](../apps/api/src/main/resources/content/logistics-08-dispatch-optimization.md) | DESIGN · 5 | 9,194 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-09-interview-domain](../apps/api/src/main/resources/content/logistics-09-interview-domain.md) | INTERVIEW · 4 | 6,550 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [logistics-10-order-promise](../apps/api/src/main/resources/content/logistics-10-order-promise.md) | CONCEPT · 4 | 3,848 | 심층 보강 | ATP/CTP 범위·단위·실제 Hold·결제 경쟁·합배송 캘린더 |
| [logistics-11-inventory-ledger](../apps/api/src/main/resources/content/logistics-11-inventory-ledger.md) | CONCEPT · 4 | 4,356 | 심층 보강 | 이동 중 계정·거래 단위 키·커밋 순서와 Snapshot·실사 정정 |
| [logistics-12-sku-barcode-serial](../apps/api/src/main/resources/content/logistics-12-sku-barcode-serial.md) | CONCEPT · 3 | 3,752 | 심층 보강 | GS1 식별 범위·포장 환산·원문/매핑 개정·집계 계보 |
| [logistics-13-scan-event-correction-design](../apps/api/src/main/resources/content/logistics-13-scan-event-correction-design.md) | DESIGN · 4 | 2,649 | 심층 보강 | 단말 순번 범위·정정 권한·Shadow 투영 전환 |
| [logistics-14-carrier-gateway-design](../apps/api/src/main/resources/content/logistics-14-carrier-gateway-design.md) | DESIGN · 4 | 2,855 | 심층 보강 | 라벨 결과 불명·상태 매핑·Webhook 저장·Polling 용량 |
| [logistics-15-rocket-delivery-design](../apps/api/src/main/resources/content/logistics-15-rocket-delivery-design.md) | DESIGN · 5 | 3,824 | 심층 보강 | 종단 선후 관계·동일 단위 용량·계획 API·부분 예약/폭증 |
| [logistics-16-realtime-dispatch-design](../apps/api/src/main/resources/content/logistics-16-realtime-dispatch-design.md) | DESIGN · 5 | 3,441 | 심층 보강 | 공간 후보 Recall·주문/기사 양쪽 제안 점유·목적 함수 단위 |
| [logistics-17-fulfillment-operations-interview](../apps/api/src/main/resources/content/logistics-17-fulfillment-operations-interview.md) | INTERVIEW · 4 | 3,736 | 심층 보강 | 병목/Starvation/Blocking·Wave 대기·부분 피킹 예외 |
| [logistics-18-slotting-optimization](../apps/api/src/main/resources/content/logistics-18-slotting-optimization.md) | CONCEPT · 4 | 3,391 | 심층 보강 | 친화도 표본·총 작업 비용/기간·실물 재배치·실험 비교 |
| [logistics-19-event-pipeline-interview](../apps/api/src/main/resources/content/logistics-19-event-pipeline-interview.md) | INTERVIEW · 5 | 3,312 | 심층 보강 | 세 라운드 실패 입력·권위 있는 버전·재생 및 외부 효과 분리 |
| [system-design-01-fundamentals](../apps/api/src/main/resources/content/system-design-01-fundamentals.md) | CONCEPT · 3 | 9,595 | 구조 점검 | 본문 출처 없음 / 기업 언급 출처 확인 |
| [system-design-02-capacity-estimation](../apps/api/src/main/resources/content/system-design-02-capacity-estimation.md) | CONCEPT · 3 | 7,441 | 구조 점검 | 본문 출처 없음 / 기업 언급 출처 확인 |
| [system-design-03-networking](../apps/api/src/main/resources/content/system-design-03-networking.md) | CONCEPT · 3 | 11,765 | 구조 점검 | 점검 해설 없음 |
| [system-design-04-data-storage](../apps/api/src/main/resources/content/system-design-04-data-storage.md) | CONCEPT · 3 | 8,354 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-05-caching](../apps/api/src/main/resources/content/system-design-05-caching.md) | CONCEPT · 3 | 9,999 | 구조 점검 | 본문 출처 없음 / 기업 언급 출처 확인 |
| [system-design-06-messaging-async](../apps/api/src/main/resources/content/system-design-06-messaging-async.md) | CONCEPT · 4 | 8,937 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-07-consistency-consensus](../apps/api/src/main/resources/content/system-design-07-consistency-consensus.md) | CONCEPT · 4 | 5,201 | 심층 보강 | CAP 정의·Quorum 전제·Raft 현재 임기/읽기·2PC/Saga 경계 |
| [system-design-08-case-rate-limiter](../apps/api/src/main/resources/content/system-design-08-case-rate-limiter.md) | DESIGN · 4 | 7,921 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-09-case-url-shortener](../apps/api/src/main/resources/content/system-design-09-case-url-shortener.md) | DESIGN · 4 | 10,884 | 구조 점검 | 점검 해설 없음 |
| [system-design-10-case-delivery-tracking](../apps/api/src/main/resources/content/system-design-10-case-delivery-tracking.md) | DESIGN · 4 | 11,171 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-11-case-newsfeed](../apps/api/src/main/resources/content/system-design-11-case-newsfeed.md) | DESIGN · 4 | 7,920 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-12-case-chat](../apps/api/src/main/resources/content/system-design-12-case-chat.md) | DESIGN · 4 | 8,971 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-13-case-search-autocomplete](../apps/api/src/main/resources/content/system-design-13-case-search-autocomplete.md) | DESIGN · 4 | 8,975 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-14-multi-region](../apps/api/src/main/resources/content/system-design-14-multi-region.md) | CONCEPT · 5 | 8,936 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-15-interview-framework](../apps/api/src/main/resources/content/system-design-15-interview-framework.md) | INTERVIEW · 4 | 8,990 | 구조 점검 | 본문 출처 없음 / 점검 해설 없음 / 기업 언급 출처 확인 |
| [system-design-16-lsm-vs-btree](../apps/api/src/main/resources/content/system-design-16-lsm-vs-btree.md) | CONCEPT · 4 | 2,366 | 구조 점검 | 점검 해설 없음 |
| [system-design-17-replication-protocols](../apps/api/src/main/resources/content/system-design-17-replication-protocols.md) | CONCEPT · 4 | 3,249 | 심층 보강 | CRAQ 버전별 읽기·지연/처리율·장애 재구성 절차 |
| [system-design-18-distributed-clocks](../apps/api/src/main/resources/content/system-design-18-distributed-clocks.md) | CONCEPT · 5 | 3,636 | 심층 보강 | HLC 네 분기 실행 예제·LWW 반례·Commit Wait 수치 |
| [system-design-19-cdn-origin-shield](../apps/api/src/main/resources/content/system-design-19-cdn-origin-shield.md) | CONCEPT · 4 | 846 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [system-design-20-social-graph-design](../apps/api/src/main/resources/content/system-design-20-social-graph-design.md) | DESIGN · 4 | 916 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [system-design-21-distributed-lock-design](../apps/api/src/main/resources/content/system-design-21-distributed-lock-design.md) | DESIGN · 5 | 3,098 | 심층 보강 | 소유권당 한 번 쓰기 SQL, Token 재시도와 만료의 경계 |
| [system-design-22-session-management-design](../apps/api/src/main/resources/content/system-design-22-session-management-design.md) | DESIGN · 4 | 1,054 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [system-design-23-unique-id-design](../apps/api/src/main/resources/content/system-design-23-unique-id-design.md) | DESIGN · 4 | 908 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [system-design-24-storage-index-interview](../apps/api/src/main/resources/content/system-design-24-storage-index-interview.md) | INTERVIEW · 5 | 878 | 구조 점검 | 짧은 본문 / 본문 출처 없음 / 점검 해설 없음 |
| [system-design-25-transaction-isolation](../apps/api/src/main/resources/content/system-design-25-transaction-isolation.md) | CONCEPT · 5 | 3,494 | 심층 보강 | 두 세션 재현, 업무 조건 검사, SSI·전체 재시도 |
| [system-design-26-message-queue-selection](../apps/api/src/main/resources/content/system-design-26-message-queue-selection.md) | DESIGN · 4 | 3,390 | 심층 보강 | Queue·Stream·Standard·FIFO 구분, 처리율 단위, 순서 복구 |

## 2026-09-13 이벤트·Outbox 후속 심층 검수

기존 부분 정정 2개를 심층 검수로 전환했다. 출처 없는 기업 사례·무조건 유실율 0·단계 수만으로 조정 방식 선택·필드 추가 무조건 호환 설명을 제거했다. 실패 복구 표, 이벤트 ID/파티션 키 구분, 버전 누락과 Snapshot/Delta 계약, 외부 API 결과 불명 처리를 보강했다.

누적 심층 32개·부분 3개, 해설 38개/114문항이다. 본문을 변경한 고유 카드 수는 35개로 동일하다. V11에 후속 본문을 분리하고 배포된 V9/V10은 유지한다. 실제 Kafka·CDC·외부 API 장애 주입은 수행하지 않았다.

## 2026-09-13 MSA 비교 후속 심층 검수

물리 DB 공유와 데이터 소유권, 가용성 곱셈의 독립 가정, 시간/요청 SLI, 종단 p99 추론의 한계를 정정했다. 고정 팀 수·무조건 핵심 마지막·라우팅만으로 롤백한다는 설명을 가상 조건과 데이터 이전 절차로 보강했다. 출처 없는 기업 사례를 제거했다.

누적 심층 33개·부분 2개, 고유 변경 본문 35개, 해설 39개/117문항이다. V12로 후속 반영한다. 본문의 Python 계산을 실행해 99.5010%·43.71시간을 확인했고 실제 부하·장애 검증으로 계산하지 않는다.

V11·V12는 `01c6099`로 운영 배포하고 DB·API·MSA 웹 응답을 확인했다. 상세 근거는 [배포 기록](deployment-2026-09-13.md)을 참고한다.
