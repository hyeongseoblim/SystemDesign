---
area: BACKEND_ARCHITECTURE
mode: CONCEPT
coach: backend-architecture-coach
title: "Transactional Outbox & Idempotency — Dual-write · CDC · Exactly-once"
slug: backend-architecture-06-outbox-idempotency
difficulty: 4
summary: "\"DB 저장과 메시지 발행을 어떻게 원자적으로?\"는 이벤트 기반 시스템의 가장 실전적인 문제다. Outbox와 멱등성으로 유실·중복을 잡는다. Deep-dive는 🔥(Deep-dive)."
tags:
  - "Dual write"
  - "CDC"
  - "Exactly once"
questions:
  - "\"재고를 차감하고 `InventoryReserved`를 Kafka에 발행\"하는 코드에서 발행 직전 크래시 시 발생하는 문제를 설명하고, **Transactional Outbox**가 이를 어떻게 해결하는지 트랜잭션 경계를 그려 설명해보세요."
  - "Outbox는 \"유실 0\"은 보장하지만 \"중복 0\"은 보장하지 못합니다. 왜 그런지(릴레이 At-least-once) 설명하고, 소비 측에서 **Inbox/멱등성**으로 어떻게 중복을 흡수하는지 설명해보세요."
  - "\"Kafka가 exactly-once를 지원하니 멱등성은 필요 없다\"는 주장이 왜 틀린지, **delivery와 processing의 차이** 그리고 ack 유실 시나리오를 들어 반박해보세요."
---
## 1. Dual-write 문제 (이중 쓰기)

하나의 비즈니스 동작이 **서로 다른 두 시스템(DB + 메시지 브로커)에 써야** 할 때, 둘을 하나의 트랜잭션으로 묶을 수 없다. 사이에서 죽으면 불일치가 생긴다.

```mermaid
flowchart TB
    subgraph CASE1["케이스 A — DB 커밋 후 발행 실패"]
      A1["DB: 재고 예약 COMMIT ✅"] --> A2["💥 크래시"] --> A3["Kafka 발행 ❌\n→ 이벤트 유실"]
    end
    subgraph CASE2["케이스 B — 발행 후 DB 실패"]
      B1["Kafka 발행 ✅"] --> B2["💥 크래시"] --> B3["DB 커밋 ❌\n→ 유령 이벤트"]
    end

    style CASE1 fill:#fee2e2,stroke:#ef4444
    style CASE2 fill:#fff7ed,stroke:#ea580c
```

*DB와 브로커는 분리된 트랜잭션. 순서를 어떻게 바꿔도 그 사이 장애 시 불일치(유실/유령)가 발생한다.*

> **🎯 면접 포인트 (매우 단골)**
>
> "주문을 저장하고 이벤트를 발행하는데, 발행 직전에 서버가 죽으면?" → 이 한 질문이 Dual-write 이해를 검증한다. "try-catch로 재시도"는 부분 답. **"DB와 브로커를 한 트랜잭션에 못 묶으니 Outbox로 같은 DB 트랜잭션에 이벤트를 적재하고, 별도 릴레이가 발행한다"** 가 정답.

## 2. Transactional Outbox (트랜잭셔널 아웃박스)

핵심 아이디어: 비즈니스 데이터와 **발행할 이벤트를 같은 DB의 `outbox` 테이블에 한 트랜잭션으로** 저장한다. DB 트랜잭션이 원자성을 보장하므로 "데이터는 저장됐는데 이벤트는 없는" 상태가 불가능해진다. 발행은 나중에 별도 프로세스가 한다.

```mermaid
sequenceDiagram
    participant App as Inventory 서비스
    participant DB as DB (단일 트랜잭션)
    participant Relay as Message Relay
    participant K as Kafka

    Note over App,DB: 하나의 로컬 트랜잭션
    App->>DB: BEGIN
    App->>DB: 재고 예약 UPDATE
    App->>DB: outbox INSERT (InventoryReserved)
    App->>DB: COMMIT ✅ (원자적)

    Note over Relay,K: 비동기 발행 (별도 프로세스)
    Relay->>DB: outbox 미발행 row 조회
    Relay->>K: InventoryReserved 발행
    K-->>Relay: ack
    Relay->>DB: outbox row 발행완료 표시
```

*비즈니스 변경 + outbox INSERT가 한 트랜잭션 → 원자성 확보. 릴레이가 outbox를 읽어 발행 후 마킹.*

> **💡 outbox 테이블 스키마**
>
> `id` , `aggregate_type` , `aggregate_id` , `event_type` , `payload(JSON)` , `created_at` , `published_at(nullable)` . `published_at IS NULL` 인 row만 발행 대상. 멱등 발행 위해 `id` 를 메시지 키/Idempotency-Key로 사용.

## 3. 릴레이 방식 — 폴링 vs CDC

outbox를 어떻게 읽어 발행하느냐의 두 방식.

| 관점 | Polling Publisher (폴링) | CDC (Change Data Capture, 변경 데이터 캡처) |
| --- | --- | --- |
| 방식 | 주기적으로 `SELECT ... WHERE published_at IS NULL` | DB 트랜잭션 로그(binlog/WAL)를 구독 |
| 구현 난이도 | **간단** (앱 코드만) | 높음 (Debezium 등 인프라) |
| 지연 | 폴링 간격만큼 (수십~수백 ms) | **거의 실시간** |
| DB 부하 | 폴링 쿼리 부하 | 로그 읽기 (앱 DB 부하 적음) |
| 대표 도구 | 스케줄러 + 쿼리 | Debezium + Kafka Connect |

```mermaid
flowchart LR
    DB[("Order DB\n+ outbox 테이블")]
    DB -->|"binlog/WAL"| DBZ["Debezium\n(CDC 커넥터)"]
    DBZ -->|"변경 캡처"| KC["Kafka Connect"]
    KC --> K[("Kafka 토픽")]
    K --> C1["Inventory"]
    K --> C2["Shipping"]

    style DB fill:#dbeafe,stroke:#3b82f6
    style DBZ fill:#fef3c7,stroke:#f59e0b
    style K fill:#ede9fe,stroke:#8b5cf6
```

*CDC 방식 — Debezium이 트랜잭션 로그를 읽어 outbox 변경을 Kafka로. 폴링 부하 없이 실시간 발행.*

> **⚠️ 실무 함정**
>
> 릴레이는 **At-least-once** 다. 발행 후 "발행완료 마킹" 직전에 죽으면 같은 이벤트를 또 발행한다. 그래서 **컨슈머 멱등성이 필수 전제** . Outbox는 로컬 DB 변경과 발행 대기 기록의 원자성을 제공한다. 종단 전달은 DB 내구성, 릴레이 재시도, 브로커 보존과 소비 복구 조건에 의존하며 무조건적인 “유실 0”을 뜻하지 않는다.

## 4. Idempotency (멱등성) 보장

**멱등성**: 같은 요청/이벤트를 여러 번 처리해도 결과가 한 번 처리한 것과 동일. At-least-once 세상에서 중복을 흡수하는 핵심 무기.

### 구현 방법

| 방법 | 설명 | 적용 |
| --- | --- | --- |
| **Idempotency-Key** | 클라이언트가 고유 키 부여 → 서버가 키별 처리 결과 저장 | 결제 요청, 외부 API 호출 |
| **처리 이벤트 ID 기록** | 이미 처리한 `eventId`를 DB/Redis에 저장 후 중복 무시 | 이벤트 컨슈머 (Inbox) |
| **조건부 상태 전이** | 허용된 이전 상태·업무 버전을 WHERE로 검사해 반복과 역행 방지 | 상태 전이 |
| **유니크 제약** | DB unique index로 중복 INSERT 차단 | 주문번호·예약ID |

```mermaid
flowchart TB
    R["요청/이벤트 도착\n(idempotency-key 또는 eventId)"]
    R --> CK{"고유 키 원자적 선점\n성공했나?"}
    CK -->|"No"| SKIP["저장된 결과 반환\n(재처리 안 함)"]
    CK -->|"Yes"| PROC["비즈니스 처리"]
    PROC --> SAVE["키 + 결과 저장\n(같은 트랜잭션)"]
    SAVE --> DONE["응답"]

    style CK fill:#fef3c7,stroke:#f59e0b
    style SKIP fill:#dcfce7,stroke:#22c55e
    style PROC fill:#dbeafe,stroke:#3b82f6
```

*DB 내부 효과의 멱등 처리 — 고유 키 선점 → 업무 처리 → 결과 저장을 같은 트랜잭션으로 묶고, 실패하면 모두 롤백한다. 외부 결제는 이 경계에 포함되지 않는다.*

> **🎯 면접 포인트**
>
> "결제 버튼 더블클릭으로 두 번 요청되면?" → 클라이언트가 **같은 Idempotency-Key** 를 보내고, 서버는 키가 이미 있으면 첫 처리 결과를 그대로 반환. 로컬 키 선점과 결제 의도를 같은 DB 트랜잭션으로 저장하고, 외부 PG에는 안정된 멱등 키를 전달해 실행·조회·결과 불명 대사를 수행한다. **UNIQUE 제약은 원격 결제와 DB를 원자 커밋해주지 않는다.** 🔥(Deep-dive)

## 5. Inbox 패턴 (소비자 측 중복 제거)

Outbox가 발행 측이라면 **Inbox(인박스)**는 소비 측이다. 컨슈머가 처리한 `messageId`를 inbox 테이블에 기록하고, 이미 있으면 스킵한다. 메시지 처리와 inbox 기록을 같은 트랜잭션으로 묶어 "처리는 했는데 기록 안 됨 → 재처리"를 막는다.

```mermaid
sequenceDiagram
    participant K as Kafka
    participant C as Consumer
    participant DB as DB (트랜잭션)

    K->>C: InventoryReserved (messageId=abc)
    C->>DB: BEGIN
    C->>DB: INSERT inbox UNIQUE key ON CONFLICT DO NOTHING
    alt 삽입된 행 없음
        DB-->>C: 중복 → 스킵
        C->>DB: COMMIT (no-op)
    else 처음
        C->>DB: 비즈니스 처리 (배송 생성)
        Note over C,DB: 업무 실패 시 Inbox도 롤백
        C->>DB: COMMIT ✅
    end
    C->>K: offset commit
```

*Inbox 패턴 — 소비자·messageId 고유 키의 삽입 성공 여부로 업무 실행을 분기한다. 단순 존재 조회로 선점하지 않으며 DB 커밋 이후 Offset을 커밋한다.*

> **💡 Outbox + Inbox = 양쪽 안전**
>
> 발행 측 **Outbox** 로 유실 방지, 소비 측 **Inbox** 로 중복 제거. 둘을 합치면 At-least-once 위에서 **Effectively-once** 를 달성한다. 운송장 이벤트처럼 중복·유실이 치명적인 흐름의 표준 조합.

## 6. Exactly-once의 보장 경계

확인 응답을 받지 못한 발행자는 미전달과 응답 유실을 구분하기 어렵다. 그래서 전송 시도는 반복될 수 있다. 하지만 이를 근거로 모든 exactly-once 처리가 불가능하다고 말하면 안 된다. 트랜잭션과 중복 제거로 **정의된 관측 경계 안에서 한 번 반영한 결과**를 만들 수 있으며, 그 경계에 외부 DB·결제가 포함되는지 확인해야 한다.

```mermaid
flowchart LR
    P["Producer 발행"] -->|"메시지 전송"| B[("Broker")]
    B -.->|"ack 유실 💥"| P
    P --> Q{"재전송?"}
    Q -->|"Yes"| DUP["중복 위험"]
    Q -->|"No"| LOSS["유실 위험"]

    style Q fill:#fef3c7,stroke:#f59e0b
    style DUP fill:#fff7ed,stroke:#ea580c
    style LOSS fill:#fee2e2,stroke:#ef4444
```

*ack 유실 시 발행자는 진실을 알 수 없다. "정확히 한 번 전달"이 불가능한 근본 이유.*

> **🎯 면접 포인트 (고급)**
>
> "Kafka가 exactly-once 지원하지 않나요?" → Kafka의 EOS는 **"Kafka 내부 처리(read-process-write)"** 한정이지, 외부 시스템(DB·결제 API)까지의 end-to-end exactly-once delivery는 아니다. 현실 해법은 **"At-least-once 전송 + 멱등 컨슈머 = Effectively-once 처리"** . 이걸 구분하면 시니어 신호. 🔥(Deep-dive)

| 용어 | 의미 |
| --- | --- |
| 전송 시도·재전달 | 응답 유실 후 반복될 수 있음. 브로커의 중복 제거 범위와 구분 |
| Exactly-once / Effectively-once **processing** | 결과가 1번 처리한 것과 동일 — 멱등성으로 **달성 가능** |

## 7. 물류 적용 예제 — 재고 예약 + 운송장 이벤트

> **시나리오** — 재고 차감 트랜잭션과 `InventoryReserved` 이벤트 발행을 원자화, 운송장 이벤트는 멱등 소비.

```mermaid
sequenceDiagram
    participant OMS as OMS
    participant WMS as WMS (Inventory)
    participant DB as WMS DB
    participant Relay as CDC Relay
    participant K as Kafka
    participant TMS as TMS (Shipping)

    OMS->>WMS: ReserveInventory(orderId, idem-key)
    WMS->>DB: BEGIN
    WMS->>DB: 재고 available -= qty
    WMS->>DB: outbox INSERT(InventoryReserved)
    WMS->>DB: COMMIT ✅
    Relay->>K: InventoryReserved 발행 (CDC)
    K->>TMS: 구독 (messageId 중복 체크)
    TMS->>TMS: inbox 확인 → 운송장 발행 (멱등)
    Note over TMS: 중복 수신해도 동일 운송장 1개
```

*Outbox(WMS 발행 측) + Inbox(TMS 소비 측). 재고-이벤트 원자화 + 운송장 중복 방지 동시 달성.*

> **💡 정량 근거**
>
> Cut-off 직전 초당 수천 건 재고 예약 상황에서, Outbox 없이 "커밋 후 발행"이면 장애 시 **이벤트 유실율이 0이 아니다** (수천 건 중 일부 유실 = 배송 누락). Outbox는 유실율을 0으로, Inbox 멱등은 기사 앱 중복 스캔으로 인한 운송장 중복 발행을 0으로 만든다.

## 8. 함정과 실제 사례

| 함정 | 대응 |
| --- | --- |
| Outbox 없이 커밋 후 발행 | Transactional Outbox로 원자화 |
| 멱등성 없는 컨슈머 | Inbox / eventId 기록 / 유니크 제약 |
| Idempotency-Key 저장과 처리가 별도 트랜잭션 | 같은 트랜잭션 또는 유니크 제약으로 경쟁 차단 |
| outbox 테이블 무한 증가 | 발행 완료 row 주기적 아카이빙/삭제 |
| Exactly-once를 믿고 멱등 생략 | delivery≠processing 구분, 멱등 필수 |

| 회사 | 활용 |
| --- | --- |
| **토스 / 결제** | 결제 요청에 Idempotency-Key 표준 적용 — 더블 요청·재시도에도 단일 결제 보장 |
| **우아한형제들(배민)** | 주문 이벤트 발행에 Outbox 패턴으로 DB-Kafka 원자성 확보, 컨슈머 멱등 처리 |
| **쿠팡 / 물류** | 운송장 TrackingEvent를 CDC(Debezium류) + Kafka로, 중복 스캔은 멱등 소비로 흡수 |
| **Stripe** | `Idempotency-Key` 헤더를 공개 API 표준으로 — 네트워크 재시도 안전 |

> **🎯 면접 포인트 (종합)**
>
> 이 장의 세 핵심 — ① Dual-write는 Outbox로 ② 중복은 멱등(Inbox/Key)으로 ③ 전달 재시도와 한 번 반영되는 처리 결과의 경계를 구분 — 를 한 문장으로 엮어 답하면 분산 시스템 정합성에 대한 시니어 이해를 보여준다.

```sql
INSERT INTO consumer_inbox(consumer, event_id, processed_at)
VALUES (:consumer, :eventId, now())
ON CONFLICT (consumer, event_id) DO NOTHING;
```

> **부분 검수 — 2026-09-12**: 기존 두 번째 질문의 “유실 0”은 내구성과 재시도가 작동한다는 조건을 생략한 표현이다. 답변에서는 이 전제를 먼저 지적한다. 질문·답변 연결은 유지했다. 참고: [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html), [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/).
