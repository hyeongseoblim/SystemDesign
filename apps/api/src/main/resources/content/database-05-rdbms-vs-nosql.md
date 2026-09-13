---
area: DATABASE
mode: CONCEPT
coach: database-coach
title: "RDBMS vs NoSQL — CAP 관점 선택과 데이터 모델링"
slug: database-05-rdbms-vs-nosql
difficulty: 3
summary: "CAP·PACELC 관점에서 RDBMS와 NoSQL 4종을 분류하고, Query-first 모델링 패턴과 선택 가이드를 Trade-off 표로 정리한다."
tags:
  - "RDBMS"
  - "NoSQL"
  - "CAP"
  - "PACELC"
  - "데이터 모델링"
questions:
  - "\"CAP 정리에서 셋 중 둘을 고른다\"는 설명이 왜 오해를 부르는지 지적하고, PACELC가 CAP의 어떤 빈틈을 메우는지 설명하세요. DynamoDB와 PostgreSQL을 PACELC 분류로 각각 배치해 보세요."
  - "Cassandra/DynamoDB의 \"Query-first modeling\"이 RDBMS 설계와 무엇이 다른지 설명하고, 데이터를 의도적으로 중복(denormalize) 저장하는 이유를 비용 관점에서 정당화하세요. 핫 파티션 회피책도 1가지 드세요."
  - "물류 서비스를 설계 중입니다. 주문·결제, 운송장 추적 타임라인, 세션 캐시 — 각각 어떤 저장소(RDBMS / Wide-column / KV)를 고르겠습니까? 정합성 요구와 접근 패턴을 근거로 polyglot persistence를 정당화하세요."
---
## 1. CAP 정리와 PACELC 확장

**CAP 정리(CAP Theorem)**는 네트워크 분할을 허용하는 분산 읽기·쓰기 모델에서 선형화 가능성과 모든 정상 노드의 요청 완료를 동시에 보장할 수 없다는 결과다.

- **Consistency(일관성)**: Linearizability(선형화 가능성). 완료된 쓰기 뒤에 시작한 읽기는 그 쓰기 또는 그 이후 쓰기와 일치해야 하며, 동시 연산은 실제 시간 순서와 양립하는 하나의 순서로 설명된다.
- **Availability(가용성)**: 실패하지 않은 노드가 받은 요청이 결국 해당 연산을 완료한다. 모든 읽기·쓰기에 오류만 반환하는 것으로 이 조건을 만족시킬 수는 없다. 실무의 가용성 SLO와도 구분한다.
- **Partition tolerance(분할 내성)**: 노드 집합 사이 메시지가 전달되지 않는 실행도 고려한다. 분할 중 모든 기능이 정상이라는 뜻은 아니다.

> **실무 함정 — CAP의 흔한 오해**
>
> "세 개 중 둘을 고른다"는 표현은 오해를 부른다. 분산 시스템에서 **네트워크 분할(P)은 선택이 아니라 필연** 이다. 따라서 실제 선택은 **분할이 발생했을 때 C와 A 중 무엇을 포기하느냐** 다. CP 시스템은 일관성을 위해 응답을 거부(가용성 포기)하고, AP 시스템은 응답을 위해 오래된 값을 허용(일관성 포기)한다.

### PACELC — CAP의 빈틈을 메우다

CAP은 분할 상황만 다룬다. **PACELC**는 평상시(분할 없을 때)의 트레이드오프까지 명시한다: **분할 시(P) A vs C, 그렇지 않으면(Else, E) L(Latency) vs C(Consistency)**. 즉 정상 운영 중에도 강한 일관성을 위해 지연을 감수할지, 낮은 지연을 위해 일관성을 느슨하게 할지의 선택이 항상 존재한다.

| 구성·연산 | 분할 시 확인할 것 | 평상시 확인할 것 |
| --- | --- | --- |
| 관계형 DB + 복제 | 리더 선출·동기 확인·분할된 쓰기 차단 | 읽기 대상·격리·복제 지연 |
| DynamoDB 읽기 | 리전·테이블 유형과 연산 보장 | 일관된 읽기 선택 가능 여부·비용 |
| Cassandra ONE / QUORUM | 필요한 복제본 응답 수 충족 여부 | 지연·쓰기 충돌 해결·읽기 정책 |
| MongoDB replica set | 과반·리더 가용성과 쓰기 확인 정책 | read concern·write concern·read preference |

제품 하나를 고정된 AP/CP로 분류하지 않는다. Cassandra QUORUM은 필요한 수의 응답을 받지 못하는 분할 구간에서 요청을 완료할 수 없으므로 “언제나 A 유지”가 아니다. 단일 노드 PostgreSQL을 그 자체로 분산 CAP 분류에 넣는 것도 범위가 맞지 않는다. DynamoDB의 강한 읽기는 모든 인덱스·연산에서 지원되는 옵션이 아니며 실제 API 문서로 확인한다.

```mermaid
flowchart TB
  START["데이터 저장소 선택"]
  Q1{"강한 일관성과트랜잭션 필수?"}
  Q2{"네트워크 분할 시가용성 우선?"}
  Q3{"단순 key 조회 위주?"}
  START --> Q1
  Q1 -->|"예 (주문·결제·잔액)"| RDBMS["RDBMSPostgreSQL / MySQL"]
  Q1 -->|"아니오"| Q2
  Q2 -->|"예 (항상 응답 우선)"| Q3
  Q2 -->|"아니오 (일관성 우선)"| CP["MongoDB / HBase"]
  Q3 -->|"예"| KV["KV — Redis / DynamoDB"]
  Q3 -->|"아니오 (대용량 쓰기)"| WC["Wide-column — Cassandra"]
```

*데이터 저장소 선택 트리 — 일관성 요구가 첫 분기*

> **면접 포인트**
>
> "왜 PACELC가 CAP보다 실무적인가?"에 답할 수 있어야 한다. 핵심: CAP은 네트워크 분할 상황을 다루며, 그 발생 빈도를 99.9% 같은 보편 수치로 정해주지는 않는다. CAP은 이 평상시를 전혀 설명하지 못한다. PACELC의 **EL vs EC** 가 실제 시스템(DynamoDB의 eventually consistent read vs strongly consistent read)의 일상적 선택을 정확히 모델링한다.

## 2. NoSQL 4종 분류

NoSQL은 단일 기술이 아니라 데이터 모델에 따른 4개 계열이다. 각자 다른 접근 패턴에 최적화돼 있다.

| 유형 | 데이터 모델 | 강점 | 약점 | 대표 / 사용처 |
| --- | --- | --- | --- | --- |
| Key-Value (KV) | key → opaque value | 초저지연 단순 조회, 캐시 | 값 내부 질의 불가, 범위 검색 약함 | Redis, DynamoDB · 세션·캐시·카운터 |
| Document | key → JSON/BSON 문서 | 유연한 스키마, 중첩 구조 한 번에 읽기 | 다중 문서 트랜잭션·복잡 조인 약함 | MongoDB · 카탈로그·CMS·프로필 |
| Wide-column | partition key → row → 동적 컬럼 | 대용량 쓰기, 시계열, 선형 확장 | 임의 질의 불가(쿼리 우선 설계 강제) | Cassandra, HBase · 로그·이력·IoT |
| Graph | node + edge(관계) | 다단계 관계 탐색(친구의 친구) | 대규모 수평 확장 어려움 | Neo4j · 추천·소셜·사기탐지 |

```mermaid
flowchart LR
  subgraph KV["Key-Value"]
    direction TB
    k1["user:1234"] --> v1["세션 토큰 값"]
  end
  subgraph DOC["Document"]
    direction TB
    d1["order:9001"] --> dv1["문서items 배열 중첩address 객체 포함"]
  end
  subgraph WC["Wide-column"]
    direction TB
    p1["partition waybill_7"] --> r1["ts1 → status DELIVERED"]
    p1 --> r2["ts2 → status SCANNED"]
  end
  subgraph GR["Graph"]
    direction TB
    g1["User A"] -->|FOLLOWS| g2["User B"]
    g2 -->|FOLLOWS| g3["User C"]
  end
```

*4개 NoSQL 계열의 데이터 모델 형태 대조*

> **실무 함정 — Document DB는 schema-less가 아니다**
>
> MongoDB가 "스키마가 없다"는 말은 **DB가 스키마를 강제하지 않는다** 는 뜻일 뿐, 스키마는 여전히 **애플리케이션 코드 안에** 존재한다. 검증을 앱이 떠안으므로, 필드 누락·타입 불일치가 런타임까지 숨는다. 그래서 실무에서는 JSON Schema validation을 DB에 걸거나 ODM(Mongoose 등)으로 스키마를 다시 강제하는 경우가 많다.

## 3. 모델링 패턴 — Query-first의 세계

RDBMS는 **정규화된 스키마를 먼저 설계**하고 쿼리는 나중에 자유롭게 짠다. NoSQL(특히 Cassandra·DynamoDB)은 정반대 — **Query-first modeling(쿼리 우선 모델링)**이다. "어떤 쿼리를 칠 것인가"를 먼저 정하고, 그 쿼리가 단일 partition 조회로 끝나도록 테이블을 역설계한다. 조인이 없으므로 데이터를 의도적으로 중복(denormalize) 저장한다.

### DynamoDB — Partition key + Sort key, Single-table design

DynamoDB의 primary key는 **Partition key(PK)** 단독, 또는 **PK + Sort key(SK)** 조합이다. PK는 데이터를 물리 파티션에 분산하고, SK는 한 파티션 내 정렬·범위 조회를 가능하게 한다. **Single-table design**은 여러 엔티티(주문·주문항목·고객)를 *하나의 테이블*에 PK/SK 패턴으로 욱여넣어, 관련 데이터를 같은 파티션에 모으고 단일 쿼리로 함께 읽는 기법이다.

```kotlin
# 한 테이블에 여러 엔티티 — PK로 묶고 SK로 종류 구분
PK = "USER#1234"   SK = "PROFILE"          → 사용자 프로필
PK = "USER#1234"   SK = "ORDER#9001"       → 주문 1
PK = "USER#1234"   SK = "ORDER#9002"       → 주문 2

# 단일 Query로 "이 사용자의 프로필 + 모든 주문"을 한 번에
Query: PK = "USER#1234"   (SK begins_with 등으로 필터)
```

> **실무 함정 — Cassandra/DynamoDB 핫 파티션**
>
> partition key가 한쪽으로 쏠리면 그 파티션을 가진 노드만 과부하( **hot partition** ). 예: PK를 "오늘 날짜"로 잡으면 모든 쓰기가 한 파티션으로. 회피책은 **composite key** 로 카디널리티를 높이거나(예: `date#shard_no` ), 고른 분포의 키(user_id)를 PK 앞단에 두는 것. DynamoDB는 partition당 처리량(WCU/RCU) 상한이 있어 핫 파티션이 throttling으로 직결된다.

### MongoDB — Embed vs Reference

1:N·N:1 관계를 문서에 어떻게 담을지의 결정이다. 기준은 단 하나 — **"한 번에 함께 읽는 단위인가"**.

```mermaid
flowchart TB
  Q1{"항상 부모와함께 읽히나?"}
  Q2{"자식 수가제한적인가?"}
  Q3{"자식이 독립적으로변경/조회되나?"}
  Q1 -->|"예"| Q2
  Q1 -->|"아니오"| REF["Reference참조 ID만 저장"]
  Q2 -->|"예 (수십 개 이하)"| Q3
  Q2 -->|"아니오 (무한 증가)"| REF
  Q3 -->|"아니오"| EMBED["Embed문서 안에 중첩"]
  Q3 -->|"예 (재고처럼 자주 갱신)"| REF
```

*MongoDB Embed vs Reference 결정 흐름 — 16MB 문서 한계와 변경 빈도가 관건*

- **Embed(임베드)**: 주문 ↔ 주문항목처럼 함께 생성·조회되고 수가 제한적이면 중첩. 1회 read로 끝나 빠름.
- **Reference(참조)**: 게시글 ↔ 댓글(무한 증가)처럼 자식이 폭발하거나 독립적으로 갱신되면 ID 참조. 단, 16MB 문서 크기 한계도 임베드 회피 사유.

### Redis 자료구조 매핑

| 자료구조 | 적합 용도 | 물류/서비스 예시 |
| --- | --- | --- |
| String | 캐시, 카운터(INCR) | API 응답 캐시, 일별 주문 카운트 |
| Hash | 객체 필드 묶음 | 세션 객체, 배송 상태 필드 |
| List | 큐, 최근 N개 | 작업 큐, 최근 본 상품 |
| Set | 중복 제거, 집합 연산 | 오늘 주문한 사용자 집합 |
| Sorted Set | 랭킹, 우선순위 큐 | 실시간 인기 상품, 배차 우선순위 |
| Stream | 이벤트 로그, 소비자 그룹 | 주문 이벤트 파이프라인 |

> **실무 사례**
>
> **Amazon Dynamo(2007)** 논문은 장바구니 같은 서비스에서 장애 중 가용성을 높이기 위해 버전 관리와 애플리케이션 충돌 해결을 사용한 사례를 설명한다. 논문의 Dynamo를 현재 관리형 서비스 DynamoDB와 동일시하지 않는다. 별도의 가상 설계로 시청 이력을 사용자 키에 따라 분산할 수 있지만, 특정 기업의 현행 파티션 키나 선형 확장을 출처 없이 단정하지 않는다.

> **면접 포인트**
>
> "왜 Cassandra에선 데이터를 중복 저장하나?"라는 질문의 정답: **조인이 없기 때문** . 같은 데이터를 "조회 패턴 A용 테이블"과 "조회 패턴 B용 테이블"에 각각 denormalize해 둔다. 쓰기 비용·정합성 관리를 읽기 성능(단일 partition 조회)과 맞바꾼 것 — 디스크는 싸고 읽기 지연은 비싸다는 철학이다.

## 4. 선택 가이드 — Trade-off 정리

> **기본 원칙 — RDBMS first**
>
> **RDBMS를 먼저 고려하고, NoSQL은 명확한 이유가 있을 때만 도입한다.** 트랜잭션·강한 일관성·유연한 ad-hoc 쿼리·성숙한 생태계는 RDBMS의 압도적 강점이다. PostgreSQL은 JSONB로 document 기능, 파티셔닝·논리 복제까지 흡수해 "NoSQL이 필요한 순간"을 한참 뒤로 미룬다. NoSQL은 (1) 단일 노드 쓰기 한계 초과, (2) 명확한 단일 접근 패턴, (3) 유연 스키마가 본질적일 때 정당화된다.

| 요구 | 적합 선택 | 근거 |
| --- | --- | --- |
| 트랜잭션·강한 일관성 (주문·결제·잔액) | RDBMS (PostgreSQL/MySQL) | ACID, 다중 행 트랜잭션, FK 제약 |
| 대용량 쓰기·시계열 이력 | Cassandra (Wide-column) | 선형 쓰기 확장, 쿼리 우선 모델링 |
| 초저지연 캐시·세션·카운터 | Redis (KV) | 인메모리, 풍부한 자료구조 |
| 유연 스키마 카탈로그·프로필 | MongoDB (Document) | 중첩 문서 한 번에 read |
| 관계 탐색·추천 | Neo4j (Graph) | 다단계 그래프 순회 최적화 |

### Polyglot persistence (다중 저장소)

현실의 대규모 서비스는 한 DB로 통일하지 않는다. **도메인별로 최적 저장소를 혼용**한다(polyglot persistence). 단, 저장소가 늘면 운영·정합성 비용이 커지므로 "정말 필요한 만큼만" 늘리는 균형이 핵심이다.

> **물류 도메인 매핑 — 한 서비스 안의 polyglot**
>
> **주문·결제 (OMS)** → **RDBMS**: 재고 차감·결제는 강한 일관성·트랜잭션 필수. 토스·배민의 주문 핵심부. **운송장 추적 타임라인 (TMS)** → **Cassandra/Wide-column**: 운송장 ID를 partition key로, 스캔 이벤트가 시간순 append. 쿠팡·CJ대한통운 규모의 배송 이력 쓰기 폭주를 흡수. **캐시·세션·실시간 배차 우선순위** → **Redis**: Sorted Set으로 라스트마일 배차 큐, 조회 캐시.

> **면접 포인트**
>
> "우리 서비스에 NoSQL 도입하자"는 제안을 받으면, 시니어라면 먼저 **"어떤 접근 패턴 때문에? RDBMS로는 왜 안 되나?"** 를 되묻는다. NoSQL을 "성능이 좋아서" 도입하면 ad-hoc 쿼리 불가, 트랜잭션 부재, 운영 부담이라는 비용이 뒤늦게 터진다. **접근 패턴과 정합성 요구** 가 결정 요인이라는 점을 분명히 하라.

## 이해도 확인 Q&A

아래 3문항에 직접 답을 적어보세요. 자동 저장되며, 하단 버튼으로 전체를 복사해 피드백을 요청할 수 있습니다.

> **부분 검수 — 2026-09-12**: CAP 정의, 제품 단위 분류, Dynamo 사례를 정정했다. 다른 모델링·제품 기능은 후속 검수 대상이다.

## 참고

- [Gilbert·Lynch: CAP 원 논문](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf)
- [Amazon Dynamo 원 논문](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf)
- [DynamoDB 읽기 일관성](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html)
- [Cassandra Dynamo architecture](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html)
