---
area: BACKEND_ARCHITECTURE
mode: DESIGN
coach: backend-architecture-coach
title: "멱등 이벤트 소비 파이프라인 설계"
slug: backend-architecture-11-idempotent-consumer-design
topicKey: backend-architecture-257
difficulty: 4
summary: "At-least-once 전달에서 Inbox, 비즈니스 트랜잭션, 재시도와 DLQ를 결합해 중복 부작용을 막는다."
tags:
  - "Idempotency"
  - "Inbox"
  - "Retry"
  - "DLQ"
questions:
  - "메시지 ACK 직전에 프로세스가 죽을 때 중복 처리를 막는 트랜잭션 경계를 설명해보세요."
  - "Event ID 중복 제거만으로 충분하지 않은 장기 재전송·업무 키 사례는 무엇인가요?"
  - "DLQ 메시지를 수정 후 재처리할 때 순서와 멱등성을 어떻게 보장하나요?"
---
> **검수 기준 — 2026-09-12**
>
> PostgreSQL 17의 로컬 트랜잭션을 사용하는 가상 배송 포인트 적립 예제다. At-least-once(최소 한 번 전달)에서 메시지 중복을 허용하되, 동일 업무 효과를 반복 커밋하지 않도록 설계한다.

## 1. 커밋과 ACK 사이에는 틈이 있다

소비자가 포인트를 적립하고 ACK(Acknowledgement, 처리 확인)를 보내기 전에 종료되면 Broker(메시지 중개 서버)는 같은 이벤트를 다시 보낼 수 있다. 반대로 ACK를 먼저 보내면 DB 실패 시 처리할 이벤트가 남지 않을 수 있다.

Inbox(수신 처리 기록)의 고유 키와 포인트 변경을 **같은 DB 트랜잭션**으로 커밋한다. ACK는 그 뒤에 보낸다. Kafka를 사용한다면 여기서 ACK에 해당하는 것은 처리 완료 Offset(소비 위치)의 커밋이며, 병렬 처리 중 미완료 메시지를 건너뛰어 커밋해서는 안 된다.

```mermaid
sequenceDiagram
    participant B as Broker
    participant C as Consumer
    participant D as Database
    B->>C: delivery-completed E
    C->>D: begin; insert inbox(E)
    C->>D: insert grant; update points
    C->>D: commit
    Note over C: ACK 전에 종료
    B->>C: redeliver E
    C->>D: inbox insert returns no row
    C-->>B: ACK without repeated effect
```

## 2. 삽입 성공 여부가 업무 실행을 결정한다

다음은 연습용 최소 스키마다. 이벤트 ID는 문자열이며 소비자 이름은 처리 책임을 나타낸다. 서로 다른 소비자가 같은 이벤트를 각자 처리할 수 있도록 복합 키를 쓴다.

```sql
CREATE TABLE consumer_inbox (
    consumer text NOT NULL,
    event_id text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, event_id)
);
CREATE TABLE point_grants (
    shipment_id text NOT NULL,
    benefit_type text NOT NULL,
    account_id bigint NOT NULL,
    amount bigint NOT NULL CHECK (amount > 0),
    PRIMARY KEY (shipment_id, benefit_type)
);
```

```text
begin transaction
insert inbox(consumer, event_id) ON CONFLICT DO NOTHING RETURNING event_id
if no row returned:
    commit; ACK; stop

insert point_grant(shipment_id, benefit_type, account_id, amount)
    ON CONFLICT DO NOTHING RETURNING shipment_id
if inserted:
    update account balance by amount
    require exactly one account row updated, otherwise rollback
else:
    compare existing grant account and amount
    if different: rollback and isolate inconsistent event
commit
ACK
```

위 코드는 트랜잭션 제어 의사코드다. `ON CONFLICT DO NOTHING`만 실행한 뒤 영향 행 수와 무관하게 잔액을 더하면 중복 제거가 아니다. 업무 검증·계정 갱신이 실패할 때 Inbox도 롤백되어야 한다. 실제 구현은 모든 예외 경로에서 커밋·ACK 여부를 테스트한다.

## 3. Event ID와 업무 키를 따로 둔다

운송사 재전송이 새 Event ID를 발급해도 같은 배송 완료에 대한 포인트는 한 번이어야 한다. `shipment_id + benefit_type`이 업무 키다. 하나의 배송에 정상적으로 여러 적립이 가능한 정책이라면 키에 정책 버전이나 적립 회차처럼 그 권리를 구분하는 값을 넣는다.

Inbox 보존 기간은 “최근 하루면 충분”처럼 임의로 정하지 않는다. 예를 들어 7일 브로커 재생과 30일 운영 재전송을 허용한다면 하루 뒤 Event ID를 지워서는 그 구간의 중복을 흡수할 수 없다. 오래된 이벤트를 거절하거나, 필요한 기간 기록을 보존하거나, 장기 업무 키로 막는 정책을 고른다.

가정: 초당 100건을 30일 기록하면 259,200,000행이다. 행당 100바이트로만 계산해도 약 25.9GB이며 인덱스·로그·복제 비용은 추가다. 정리 정책과 재생 계약을 함께 결정해야 하는 이유다.

| 실패 지점 | DB 결과 | 재전달 시 행동 |
|---|---|---|
| Inbox 삽입 전 종료 | 없음 | 처음부터 처리 |
| Inbox 삽입 후 업무 실패 | 모두 롤백 | 다시 실행 |
| 커밋 후 ACK 전 종료 | 모두 반영 | Event ID 중복으로 건너뜀 |
| 새 Event ID로 같은 적립 | 기존 업무 키 있음 | 내용 검증 후 반복 적립 생략 |
| 계정·금액이 다른 동일 업무 키 | 데이터 불일치 | 조용히 무시하지 않고 격리 |

## 4. DLQ 재처리와 순서

DLQ(Dead Letter Queue, 처리 실패 격리 큐)는 오류를 없애는 장치가 아니다. 메시지 원문, 원래 Event ID, 업무 키, 실패 원인, 적용한 코드·스키마 버전을 보존한다. 운영자가 내용을 수정한다면 원본과 수정 이력을 남기고, 보정 이벤트인지 동일 작업 재시도인지 구분한다.

운송장 상태 11번이 실패했는데 12번을 먼저 적용하면 “발송 전 취소” 같은 규칙이 깨질 수 있다. 상태 버전 검사로 공백을 격리하고 원장을 조회하거나 해당 키를 일시 중지한다. 재처리할 때 Inbox를 일괄 삭제하면 이미 성공한 이벤트도 다시 실행될 수 있다.

## 5. 외부 효과는 다른 경계다

메일·결제 API는 이 DB 트랜잭션에 참여하지 않는다. Outbox(발행 대기 기록)에 요청을 함께 커밋하고 별도 전달자가 상대의 멱등 키로 호출한다. 응답 유실 시 상대의 처리 상태를 확인한다. 상대가 중복 방지나 상태 조회를 제공하지 않으면 “정확히 한 번 결제”를 이 설계만으로 약속할 수 없다.

> **면접 포인트** — 중복을 어디서 판별하고, 어떤 변경을 함께 커밋하고, 언제 ACK하는지 설명한다. 이후 장기 재생·다른 Event ID·외부 효과·순서 공백까지 실패 지점을 넓힌다.

## 참고

- [Chris Richardson: Idempotent Consumer](https://microservices.io/patterns/communication-style/idempotent-consumer.html) — 처리 ID와 업무 갱신의 트랜잭션 경계.
- [PostgreSQL 17: INSERT](https://www.postgresql.org/docs/17/sql-insert.html) — ON CONFLICT와 RETURNING.
- [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/) — 소비 위치와 외부 시스템 처리 경계.
