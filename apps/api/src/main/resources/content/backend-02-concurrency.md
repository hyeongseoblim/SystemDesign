---
area: BACKEND_DEV
mode: CONCEPT
coach: backend-dev-coach
title: "동시성 — 스레드·락·메모리 가시성·재고 차감"
slug: backend-02-concurrency
difficulty: 3
summary: "동시성은 \"코드가 동작하는가\"와 \"동시에 1만 건이 들어와도 동작하는가\"를 가르는 영역이다. 6년차 면접에서는 **재고 차감 Race Condition을 코드로 풀 수 있느냐**가 합격선이다."
tags:
  - "스레드"
  - "메모리"
  - "가시성"
  - "재고"
  - "차감"
questions:
  - "`volatile`만으로 `count++` 동시성 버그를 못 막는 이유를 **가시성·원자성** 개념으로 설명하고, 올바른 대안 2가지를 제시해보세요."
  - "인기 상품 한정 수량(경합 매우 높음) vs 일반 상품(경합 낮음)에서 각각 **낙관적/비관적/원자적 UPDATE** 중 무엇을 택할지, 그 근거를 처리량·재시도 관점에서 비교해보세요."
  - "서버를 2대로 스케일아웃했더니 `synchronized`로 막던 재고 차감이 다시 Oversell이 났습니다. 왜 그런지 설명하고, 분산 환경에서의 해결책 2가지를 Trade-off와 함께 제시해보세요."
---
## 1. 스레드 · 스레드풀

JVM에서 요청 1건은 보통 스레드 1개가 처리한다(Servlet의 thread-per-request 모델). 스레드는 비싸므로 **스레드풀(Thread Pool)**로 재사용한다.

```mermaid
flowchart LR
    Q["요청 큐\n(Queue)"]
    subgraph Pool["Thread Pool (core=10, max=50)"]
      T1[Thread-1]
      T2[Thread-2]
      T3[Thread-N]
    end
    DB[("DB Conn Pool\nHikariCP")]
    Q --> T1 & T2 & T3
    T1 & T2 & T3 --> DB
    style Pool fill:#fef3c7,stroke:#f59e0b
    style DB fill:#dbeafe,stroke:#3b82f6
```

*스레드풀 ↔ 커넥션풀은 함께 사이징해야 함. 스레드 200개가 커넥션 10개를 두고 경쟁하면 대기 폭증*

> **⚠️ 실무 함정 — 풀 사이징 불균형**
>
> 스레드 200개가 동시에 DB 연결을 요구하고 연결 10개가 모두 사용 중이면 나머지는 대기할 수 있다. 하지만 스레드 수 차이가 언제나 대기자 수는 아니다. HikariCP의 코어·디스크 기반 경험식은 시작점이며 SSD·쿼리 비용·DB CPU·서비스 복제본 수에 따라 부하 시험으로 조정한다. 스레드풀과 커넥션풀, 다운스트림 타임아웃을 **한 세트로** 설계해야 함.

## 2. Race Condition — 경쟁 상태

`Race Condition(경쟁 상태)`은 둘 이상의 스레드가 공유 자원에 접근할 때, **실행 순서(interleaving)**에 따라 결과가 달라지는 버그다. 대표는 `read-modify-write`가 원자적이지 않을 때.

```mermaid
sequenceDiagram
    participant T1 as Thread-1
    participant M as 공유 변수 stock=1
    participant T2 as Thread-2
    T1->>M: read stock (=1)
    T2->>M: read stock (=1)
    Note over T1,T2: 둘 다 1을 읽음 (lost update 시작)
    T1->>M: write stock = 0
    T2->>M: write stock = 0
    Note over M: 재고는 0인데 두 주문이 성공 → Oversell 발생
```

*Lost Update — 두 스레드가 같은 값을 읽고 각자 덮어쓰면 한 번의 갱신이 사라짐*

```kotlin
// 동시성 버그가 있는 코드 — 절대 이렇게 하지 말 것
fun decreaseStock(productId: Long) {
    val product = repository.findById(productId)   // read
    product.stock = product.stock - 1               // modify
    repository.save(product)                         // write
    // 두 스레드가 동시에 read 하면 둘 다 같은 stock 으로 -1 → lost update
}
```

## 3. JMM · 메모리 가시성

`JMM(Java Memory Model, 자바 메모리 모델)`은 "한 스레드의 쓰기가 다른 스레드에 언제 보이는가"를 정의한다. 각 스레드는 변수를 **CPU 캐시/레지스터에 복사**해서 쓰기 때문에, 동기화 없이는 다른 스레드의 변경이 영원히 안 보일 수 있다(가시성 문제).

```java
// volatile 없으면 worker가 stop 변경을 영영 못 볼 수 있음 (무한루프)
private volatile boolean stop = false;   // 가시성 보장

void worker() { while (!stop) { doWork(); } }   // 다른 스레드
void shutdown() { stop = true; }              // 메인 스레드
```

*`volatile`은 **가시성**과 **순서(happens-before)**를 제공하고 단일 읽기·쓰기는 원자적이지만 **읽기-증가-쓰기 전체의 원자성**은 보장하지 않음 — `count++` 에는 부족*

| 도구 | 가시성 | 원자성 | 용도 |
| --- | --- | --- | --- |
| `volatile` | ✅ | 단일 읽기·쓰기만, 복합 연산은 ❌ | 플래그·상태 신호 |
| `AtomicLong` / CAS | ✅ | ✅ | 카운터·증감 (lock-free) |
| `synchronized` / Lock | ✅ | ✅ (구간) | 복합 연산 보호 |

> **💡 happens-before**
>
> 같은 모니터의 unlock → 후속 lock, 같은 `volatile` 변수의 write → 후속 read 사이에 **happens-before 관계** 가 성립해, 그 이전의 모든 쓰기가 보이도록 보장된다. 동시성 코드의 정합성은 이 관계를 만족시키느냐로 판단.

## 4. 락 — 비관적 락 vs 낙관적 락

| 관점 | Pessimistic Lock (비관적 락) | Optimistic Lock (낙관적 락) |
| --- | --- | --- |
| 가정 | 충돌이 자주 난다 | 충돌이 드물다 |
| 구현 | `SELECT ... FOR UPDATE` (DB 행 잠금) | `@Version` 컬럼 비교 후 UPDATE |
| 충돌 시 | 대기 (블로킹) | 실패 → 재시도 (`OptimisticLockException`) |
| 장점 | 읽고 판단하는 동안 경쟁 변경 제어 | 사전 읽기 잠금 없이 버전으로 충돌 검출 |
| 단점 | 락 경합·데드락·처리량 저하 | 경합 심하면 재시도 폭증 |
| 적합 | 인기 상품 한정 수량 (경합 심함) | 일반 상품 재고 (경합 낮음) |

```mermaid
sequenceDiagram
    participant T1 as Tx-1
    participant DB as DB (stock=1, version=5)
    participant T2 as Tx-2
    Note over T1,T2: 낙관적 락 — version 비교
    T1->>DB: SELECT stock, version (=1, v5)
    T2->>DB: SELECT stock, version (=1, v5)
    T1->>DB: UPDATE ... SET stock=0, version=6 WHERE version=5
    DB-->>T1: 1 row updated ✅
    T2->>DB: UPDATE ... SET stock=0, version=6 WHERE version=5
    DB-->>T2: 0 row updated ❌ (version 이미 6)
    Note over T2: OptimisticLockException → 재시도
```

*낙관적 락 — version이 안 맞으면 0 row 갱신 → 예외 → 애플리케이션이 재시도*

> **🎯 면접 포인트 — synchronized로는 왜 안 되나**
>
> "재고 차감을 `synchronized` 로 막으면 되지 않나요?" → **서버가 2대 이상이면 JVM 락은 무력** 하다(프로세스 경계를 못 넘음). 분산 환경에선 **DB 제약·조건부 갱신·잠금 또는 키별 직렬화**로 모든 인스턴스가 같은 불변식을 지키게 한다. Redis 분산락은 Lease 만료 후 늦은 쓰기까지 막는지 별도 검증해야 한다. 단일 인스턴스 가정을 깨는 후속 질문이 반드시 온다. 🔥(Deep-dive)

## 5. Async · Non-blocking · 코루틴

블로킹 I/O는 스레드를 점유한 채 대기한다. 다운스트림 호출이 느리면 스레드풀이 고갈된다. 해법은 **Non-blocking I/O** 또는 **경량 동시성**이다.

- **CompletableFuture** — 완료 결과를 조합하는 API다. 블로킹 작업을 별도 풀로 옮겨도 그 작업의 Worker는 점유되며, API 자체가 I/O를 Non-blocking으로 바꾸지는 않는다.
- **WebFlux / Reactor** — 이벤트 루프 기반 Non-blocking, 적은 스레드로 높은 동시성. 단 학습·디버깅 비용 큼
- **Kotlin Coroutine** — `suspend` 함수로 동기 코드처럼 작성, 구조적 동시성. 블로킹 호출은 사용하는 Dispatcher와 동시성 한도를 확인해야 한다
- **Java 21 Virtual Thread** — 블로킹 코드 그대로 두고 경량 스레드로 확장(Project Loom)

```kotlin
// Kotlin Coroutine — 구조적 동시성. 두 호출을 병렬로
suspend fun getOrderDetail(id: Long): OrderDetail = coroutineScope {
    val order   = async { orderClient.fetch(id) }      // 병렬 시작
    val payment = async { paymentClient.fetch(id) }
    OrderDetail(order.await(), payment.await())          // 둘 다 완료 대기
    // scope 안에서 하나라도 실패하면 나머지도 자동 취소 (구조적 동시성)
}
```

> **⚠️ 실무 함정 — suspend에서 블로킹**
>
> 코루틴 `suspend` 함수 안에서 JDBC·RestTemplate 같은 블로킹 호출을 그대로 부르면, 한정된 디스패처 스레드를 막아 전체 처리량이 붕괴한다. 블로킹이 불가피하면 `withContext(Dispatchers.IO)` 로 격리해야 한다.

## 6. ⭐ 재고 차감 동시성 — 실전 4가지 해법

> **WMS / OMS 핵심 문제** — 동시에 1만 명이 한정 수량 상품을 주문할 때, *Oversell(초과판매)* 없이 정확히 차감하기

### 해법 1 — DB 원자적 조건부 UPDATE (1순위 추천)

```kotlin
// JPA Repository 예시: 호출 서비스의 트랜잭션 안에서 실행한다.
@Modifying
@Query("""
    UPDATE product
    SET stock = stock - :qty
    WHERE id = :id AND :qty > 0 AND stock >= :qty
""", nativeQuery = true)
fun decreaseStock(id: Long, qty: Int): Int   // 영향받은 행 수 반환

// 호출부 — 0이면 재고 부족
val updated = repository.decreaseStock(id, qty)
if (updated == 0) throw InsufficientStockException(id)
```

*양수 수량과 충분한 재고를 같은 문장에서 검사한다. 영향 행 수와 커밋 결과를 확인하고, 같은 주문 재시도의 중복 차감은 별도 고유 예약 키로 막는다. UPDATE도 트랜잭션 종료까지 잠금을 보유할 수 있다.*

### 해법 2 — 낙관적 락 (@Version)

```kotlin
@Entity
class Product(
    @Id val id: Long,
    var stock: Int,
    @Version var version: Long = 0   // JPA가 UPDATE 시 자동 비교
)

@Retryable(value = [OptimisticLockException::class], maxAttempts = 3,
           backoff = Backoff(delay = 50, multiplier = 2.0))   // 재시도 + backoff
@Transactional
fun decrease(id: Long, qty: Int) {
    require(qty > 0)
    val p = repository.findById(id).orElseThrow()
    if (p.stock < qty) throw InsufficientStockException(id)
    p.stock -= qty   // 커밋 시 version 안 맞으면 예외 → 재시도
}
```

*버전 충돌 재시도는 새 트랜잭션에서 다시 읽어야 한다. Retry가 트랜잭션 전체를 감싸는지 프록시 순서와 예외 변환을 검증한다. 버전 기반 UPDATE도 DB 잠금을 사용하며, 품절 같은 업무 실패는 재시도하지 않는다.*

### 해법 3 — 비관적 락 (SELECT … FOR UPDATE)

```kotlin
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT p FROM Product p WHERE p.id = :id")
fun findByIdForUpdate(id: Long): Product
// 락 타임아웃 필수 — 안 걸면 데드락/대기 폭주로 스레드풀 고갈
```

### 해법 4 — Redis를 쓰기 전에 입장 제한을 검토한다

단순 `DECRBY → 음수이면 INCRBY`는 검사·보상 사이 장애에 취약하다. Lua로 수량 검사와 감소를 묶어도 Redis 반영과 외부 큐 발행은 같은 트랜잭션이 아니다. 응답 유실 후 재실행할 예약 ID, 복제 장애 후 기록 소실, 미반영 DB 대사를 설계해야 한다.

```text
first: measure DB hot-row wait and admit a bounded request rate
if Redis reservation is required:
    atomically check request identity and available quantity
    retain reservation result and durable delivery intent
    retry delivery, not an untracked decrement
    reconcile uncertain state before confirming the order
```

> **실무 함정** — 위 코드는 설계 의사코드이며 Redis와 Kafka의 원자 커밋을 뜻하지 않는다. 그 보장 경계를 구현할 수 없다면 Redis는 입장 제한에 사용하고 최종 예약은 DB에서 확정한다.

```mermaid
flowchart TD
    Q{"경합 수준?"}
    Q -->|"낮음"| OPT["낙관적 락\n@Version + 재시도"]
    Q -->|"보통~높음\n단일 SKU"| ATOM["원자적 조건부\nUPDATE (1순위)"]
    Q -->|"복합 연산\n다중 행"| PESS["비관적 락\nFOR UPDATE"]
    Q -->|"플래시세일\n초당 수만"| REDIS["입장 제한 우선\nRedis는 내구성·멱등성 검증 후"]
    style ATOM fill:#dcfce7,stroke:#22c55e
    style REDIS fill:#fee2e2,stroke:#ef4444
```

*경합 수준에 따른 선택 트리 — 면접에서는 "상황에 따라 다르다"를 이 트리로 구체화*

> **🎯 면접 포인트 — 정답은 하나가 아니다**
>
> "재고 차감 어떻게 하시겠어요?"의 만점 답: **(1) 단일 수량 조건 → 조건부 UPDATE, (2) 읽은 값에 의존하는 복합 조건 → 잠금·격리 경계 검토, (3) 유입 과다 → 입장 제한·큐와 측정 후 Redis 예약의 실패 모델 검토** . 그리고 "예약(Reserve)·만료(TTL)·확정(Commit) 3단계로 Oversell을 막는다"까지 연결하면 도메인 깊이가 드러난다. 🔥(Deep-dive)

> **검수 기준 — 2026-09-12**: JVM 변수의 원자성과 DB 트랜잭션의 원자성은 다른 경계다. 예약 만료는 상태 조건부 전이와 수량 복원을 함께 커밋하고, JVM 밖의 다른 Writer도 같은 규칙에 참여해야 한다.

## 참고

- [Java 25 JLS 17: Threads and Locks](https://docs.oracle.com/javase/specs/jls/se25/html/jls-17.html)
- [HikariCP: About Pool Sizing](https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing)
- [Redis Lua](https://redis.io/docs/latest/develop/programmability/eval-intro/), [복제](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
