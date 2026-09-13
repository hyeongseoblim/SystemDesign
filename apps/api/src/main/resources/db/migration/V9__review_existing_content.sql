-- 2026-09-13: 기존 카드 32개의 검수 본문을 반영한다.
-- MANUAL 본문만 변경하며 카드·질문 ID와 학습 기록 연결은 유지한다.
-- 신규 DB는 이후 ContentSeeder가 같은 본문을 적재한다.

UPDATE cards
SET content_md = $review_1$## 1. 스레드 · 스레드풀

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
- [Redis Lua](https://redis.io/docs/latest/develop/programmability/eval-intro/), [복제](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)$review_1$
WHERE slug = 'backend-02-concurrency' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_2$## 1. 먼저 보장 범위를 정한다

이 카드는 **Spring Framework 6.2의 기본 Proxy(프록시) 모드, JDBC 기반 로컬 트랜잭션, MySQL 8.4 InnoDB, PostgreSQL 17**을 기준으로 한다. 기본값은 연결 설정으로 바뀔 수 있다. 아래 주문·결제 흐름은 학습용 설계다.

ACID는 Atomicity(원자성), Consistency(일관성), Isolation(격리성), Durability(지속성)다. 원자성은 참여한 DB 변경에 적용되며 HTTP 결제까지 되돌리지 않는다. 일관성은 업무 불변식을 올바른 제약과 로직으로 표현해야 얻는다. 지속성도 로그 동기화·복제·저장 장치와 장애 범위의 전제가 있다. Undo Log(실행 취소 로그)만을 모든 DB의 원자성 구현으로 단정하지 않는다.

예를 들어 `qty >= 0` 제약은 음수 재고를 막지만 같은 주문을 두 번 차감하는 것은 막지 못한다. 주문별 고유 예약 키와 조건부 재고 변경을 같은 트랜잭션으로 묶어야 한다.

## 2. 격리수준 이름보다 읽기와 쓰기를 구분한다

| 구분 | MySQL InnoDB | PostgreSQL |
|---|---|---|
| 기본 격리수준 | REPEATABLE READ | READ COMMITTED |
| READ COMMITTED 일반 SELECT | 문장별 새 스냅샷 | 문장별 새 스냅샷 |
| REPEATABLE READ 일반 SELECT | 첫 일관 읽기의 스냅샷을 재사용 | 첫 비제어 문장의 스냅샷을 재사용 |
| REPEATABLE READ 잠금 읽기·갱신 | 최신 상태를 다루므로 일반 읽기와 섞으면 관측이 다를 수 있음 | 스냅샷 이후 변경된 행을 갱신하려 하면 직렬화 실패 가능 |
| SERIALIZABLE | 더 강한 잠금 규칙과 대기·교착 가능 | 직렬성 위반을 감지하고 일부 트랜잭션 중단 |

Dirty Read(미커밋 읽기)는 남이 아직 커밋하지 않은 값을 읽는 것이다. Non-repeatable Read(반복 불가 읽기)는 같은 행의 값이, Phantom Read(팬텀 읽기)는 같은 조건의 결과 집합이 다른 커밋으로 바뀌는 것이다. PostgreSQL의 READ UNCOMMITTED는 READ COMMITTED처럼 동작한다. 표준상 RR이 팬텀을 허용한다는 말과 특정 DB가 실제로 팬텀을 허용한다는 말은 다르다.

```mermaid
sequenceDiagram
    participant A as 세션 A
    participant DB as PostgreSQL RC
    participant B as 세션 B
    A->>DB: BEGIN; SELECT qty (10)
    B->>DB: UPDATE qty = 9; COMMIT
    A->>DB: SELECT qty (9)
    Note over A,DB: RC는 문장마다 새 스냅샷
    A->>DB: COMMIT
```

> **면접 포인트 — SERIALIZABLE도 안 된다는 답은 잘못이다**
>
> 필요한 읽기·조건 검사·쓰기를 모두 같은 직렬화 가능한 트랜잭션에 넣고 중단 시 전체를 재시도하면, 직렬 실행에서 보존되는 DB 불변식을 지킬 수 있다. 원격 결제나 트랜잭션 밖에서 읽은 값은 보장 밖이다. 단일 재고 행은 조건부 UPDATE가 더 단순할 수 있으며 두 방식의 처리량은 경합을 측정해 비교한다.

```sql
-- qty는 양수인 요청만 허용한다. :qty는 바인딩 매개변수 표기다.
UPDATE stock SET available = available - :qty
WHERE sku_id = :sku_id AND :qty > 0 AND available >= :qty;
-- 영향 행 수 1: 차감 성공, 0: 수량 오류/재고 부족/행 없음 구분
-- 중복 주문 방지는 같은 트랜잭션의 UNIQUE 예약 키로 별도 처리한다.
```

## 3. 전파는 물리적 트랜잭션과 예외 경로를 함께 본다

Propagation(전파)은 이미 진행 중인 트랜잭션과 새 메서드 경계를 연결하는 규칙이다.

| 속성 | 기존 트랜잭션이 있을 때 | 실패 경계 |
|---|---|---|
| REQUIRED | 동일한 물리적 트랜잭션에 참여 | 내부 rollback-only가 전체 커밋을 막을 수 있음 |
| REQUIRES_NEW | 외부 자원을 유지한 채 독립 트랜잭션 시작 | 독립 롤백이지만 예외가 외부로 전파되면 외부도 롤백 가능 |
| NESTED | 지원되는 JDBC 관리자의 Savepoint(저장점) 사용 | 내부 부분 롤백 가능, 외부 롤백이면 모두 취소 |
| SUPPORTS | 있으면 참여, 없으면 비트랜잭션 | 단독 호출의 원자성을 기대하면 안 됨 |
| MANDATORY | 기존 트랜잭션 필수 | 없으면 예외 |

내부 REQUIRED 메서드에서 롤백 대상으로 판정된 예외를 외부가 잡아도 rollback-only 표시가 사라지지 않는다. 외부 커밋에서 `UnexpectedRollbackException`이 날 수 있다. 반면 REQUIRES_NEW 감사 기록은 주문이 롤백돼도 남을 수 있지만, 감사 실패 예외를 그대로 던지면 주문도 실패할 수 있다. 감사 실패를 허용할지는 업무 정책으로 결정한다.

외부가 미커밋 주문 행을 잠근 상태에서 내부 감사 트랜잭션이 그 행을 변경하거나 참조 무결성 확인을 기다리면 서로 진행할 수 없다. 독립 커밋이 필요한 시도 기록은 미커밋 주문에 의존하지 않는 요청 식별자로 설계한다.

가상의 동시 요청 20개가 각각 외부 연결 1개를 보유한 채 내부 연결을 기다리고 풀 크기도 20이면 추가 연결이 없다. 풀을 무조건 키우기보다 독립 트랜잭션 수·중첩 깊이·DB 수용량을 함께 조절한다.

## 4. 자기 호출·롤백·readOnly의 함정

기본 프록시 모드에서 같은 객체의 `outer()`가 `inner()`를 직접 부르면 inner의 트랜잭션 조언을 거치지 않는다. outer에 이미 트랜잭션이 있으면 그 경계는 유지되지만 inner의 REQUIRES_NEW는 적용되지 않는다.

해법은 별도 빈의 메서드를 프록시를 통해 호출하거나 `TransactionTemplate`으로 필요한 경계를 명시하는 것이다. 아래는 후자다. 이 템플릿의 기본 REQUIRED는 기존 트랜잭션이 있으면 참여한다.

```kotlin
@Service
class StockService(
    transactionManager: PlatformTransactionManager,
    private val jdbc: JdbcTemplate,
) {
    private val tx = TransactionTemplate(transactionManager)

    fun decrement(skuId: Long, qty: Int) {
        require(qty > 0)
        tx.executeWithoutResult {
            val changed = jdbc.update(
                "UPDATE stock SET available = available - ? " +
                    "WHERE sku_id = ? AND available >= ?",
                qty, skuId, qty,
            )
            check(changed == 1) { "Insufficient stock or unknown SKU" }
        }
    }
}
```

이 코드는 한 번의 차감 경계만 보여준다. 중복 주문 검사는 포함하지 않는다. 클래스 프록시를 쓰는 Kotlin 애너테이션 방식에서는 `kotlin-spring` 플러그인 등 프록시 가능한 클래스 구성도 확인한다.

- 기본 롤백 규칙은 RuntimeException과 Error다. Checked Exception(검사 예외)은 별도 규칙 없이는 자동 롤백 대상이 아니다. Kotlin이 검사 예외 선언을 강제하지 않는 것과 Spring의 판단은 별개다. 프로젝트의 전역 롤백 설정도 확인한다.
- `readOnly=true`는 최적화를 위한 힌트다. 모든 쓰기 차단·더티 체킹 제거·읽기 복제본 라우팅을 자동 보장하지 않는다. 적용 효과는 관리자·드라이버·ORM·라우팅 구성에 달린다.
- 일반적인 스레드 기반 트랜잭션은 새 비동기 스레드로 전파되지 않는다. 비동기 작업이 프록시를 거쳐 자체 트랜잭션을 시작할 수는 있다. 예약 실행도 호출자 트랜잭션의 연장으로 생각하지 않는다.

## 5. 외부 결제는 명령 저장과 결과 확정으로 나눈다

DB 트랜잭션 안의 원격 호출에는 두 문제가 있다. 지연 중 연결과 이미 획득한 잠금을 오래 점유하고, 원격 성공 뒤 DB 롤백 또는 응답 유실로 결과가 어긋난다. 단순히 호출을 커밋 뒤로 옮기면 커밋 직후 프로세스 종료 시 요청이 사라질 수 있다.

```mermaid
sequenceDiagram
    participant API as 주문 API
    participant DB as 주문 DB
    participant W as 실행 작업자
    participant PG as 결제 제공자
    API->>DB: Tx A: PENDING 주문과 결제 명령 Outbox 저장
    DB-->>API: COMMIT
    W->>DB: 미완료 명령 읽기
    W->>PG: 고정 멱등 키로 결제 요청
    PG-->>W: 성공 또는 응답 불명
    W->>DB: Tx B: 성공 기록 또는 UNKNOWN 기록
    Note over W,PG: UNKNOWN은 조회와 대사로 확정
```

Transactional Outbox(트랜잭션 아웃박스)는 같은 DB의 주문과 실행 의도를 원자적으로 남긴다. 작업자 재시작·중복 실행을 전제로 같은 결제 멱등 키를 사용하고 결과 불명은 실패로 단정하지 않는다. 제공자의 멱등성·조회 기능이 없다면 안전한 자동 재시도의 범위가 제한된다. 발행 성공 직후 작업자가 죽으면 재발행할 수 있으므로 소비자도 중복을 처리해야 한다.

| 기법 | 해결하는 경계 | 남는 과제 |
|---|---|---|
| 2PC, Two-Phase Commit(2단계 커밋) | 참여 자원의 원자적 커밋 결정 | 격리성은 별도 문제; 준비 상태 대기·복구·지원 자원 제약 |
| Saga(사가) | 여러 로컬 트랜잭션의 진행과 업무 보상 | 중간 상태 노출·보상 실패·재시도·수동 대사 |
| Outbox | DB 변경과 발행 의도 기록 | 반복 전달·운영 복구·외부 효과 멱등성 |

2PC가 전역 직렬성을 자동 보장하거나 모든 구현의 코디네이터가 단일 장애점인 것은 아니다. Saga도 가용성을 무조건 높이는 정답이 아니다. 환불은 과거 결제 기록을 지우는 롤백이 아니라 실패할 수도 있는 새 업무다. `CANCEL_REQUESTED`에서 취소 결과를 확인한 뒤 `CANCELED`로 전이해야 한다.

## 6. 검증할 실패 시나리오

일반 SELECT 두 번 사이에 다른 세션이 커밋하는 경우, 같은 행을 두 세션이 갱신하는 경우, 내부 REQUIRED가 rollback-only를 표시한 경우를 각각 재현한다. 외부 결제 성공 후 응답 유실과 Outbox 처리 완료 표시 전 종료도 주입한다. 확인할 것은 예외 발생 자체가 아니라 최종 재고·주문 상태·외부 결제 횟수·미완료 명령 복구다.

## 참고 자료

- [PostgreSQL 17 격리수준](https://www.postgresql.org/docs/17/transaction-iso.html)
- [MySQL 8.4 일관 읽기](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [Spring 6.2 트랜잭션 전파](https://docs.spring.io/spring-framework/reference/6.2/data-access/transaction/declarative/tx-propagation.html)
- [Spring 6.2 애너테이션과 프록시](https://docs.spring.io/spring-framework/reference/6.2/data-access/transaction/declarative/annotations.html)
- [Spring 6.2 Transactional API](https://docs.spring.io/spring-framework/docs/6.2.x/javadoc-api/org/springframework/transaction/annotation/Transactional.html)
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html), [Saga](https://microservices.io/patterns/data/saga.html)$review_2$
WHERE slug = 'backend-03-transaction' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_3$## 1. Timeout — 모든 복원력의 출발점

Timeout이 없으면 다른 모든 패턴이 의미 없다. 응답 없는 호출이 스레드를 무한 점유하면 **스레드풀 고갈 → 캐스케이딩 장애(Cascading Failure)**로 번진다.

> **⚠️ 실무 함정 — 기본 타임아웃 무한대**
>
> 기본 타임아웃은 HTTP 클라이언트·RequestFactory·버전에 따라 다르므로 명시적으로 확인한다. 연결·풀 획득·응답·전체 요청 Deadline(마감 시간)을 구분하고 재시도·대기를 포함해 남은 예산 안에서 실행한다. 클라이언트 타임아웃은 상대의 작업 취소나 롤백을 보장하지 않는다.

```kotlin
// WebClient — connect/response 타임아웃 명시
val client = WebClient.builder()
    .clientConnector(ReactorClientHttpConnector(
        HttpClient.create()
            .responseTimeout(Duration.ofSeconds(2))          // 응답 읽기 간격 제한; 전체 요청 Deadline과는 다름
            .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 500) // 연결 타임아웃
    )).build()
```

## 2. Retry · Backoff · Jitter

일시적(transient) 장애는 재시도로 회복된다. 단 **(1) 멱등 연산만, (2) 지수 백오프 + 지터, (3) 최대 횟수** 세 조건을 지켜야 한다.

```mermaid
flowchart TD
    Call["외부 호출"] --> R{"성공?"}
    R -->|"예"| Done["완료"]
    R -->|"아니오"| C{"재시도 가능한 에러?\n(5xx/timeout/429)"}
    C -->|"아니오 (검증 실패 등)"| Fail["즉시 실패\n재시도 무의미"]
    C -->|"예"| M{"최대 횟수 초과?"}
    M -->|"예"| Fail2["포기 → Fallback"]
    M -->|"아니오"| W["대기:\nbase × 2^n + random jitter"]
    W --> Call
    style Done fill:#dcfce7,stroke:#22c55e
    style Fail fill:#fee2e2,stroke:#ef4444
```

*HTTP 상태 계열만으로 결정하지 않는다. 예를 들어 429는 Retry-After와 예산을 고려하고, 5xx도 비멱등 외부 효과의 결과가 불명확하면 무조건 재호출하지 않는다.*

#### 왜 Jitter(지터)가 필요한가

장애 후 모든 클라이언트가 *정확히 같은 간격*으로 재시도하면 **Thundering Herd(동시 재시도 폭주)**가 발생해 막 회복한 서버를 다시 죽인다. 각 클라이언트의 대기 시간에 랜덤성을 더해 분산시킨다.

```kotlin
// Resilience4j — 지수 백오프 + 지터 + 재시도 대상 한정
val config = RetryConfig.custom<Any>()
    .maxAttempts(3)
    .intervalFunction(IntervalFunction.ofExponentialRandomBackoff(
        Duration.ofMillis(100),  // initial
        2.0,                     // multiplier
        0.5))                    // jitter factor (±50%)
    .retryExceptions(IOException::class.java, TimeoutException::class.java)
    .ignoreExceptions(BadRequestException::class.java)  // 재시도 불가한 검증 오류 예시
    .build()
```

> **⚠️ 실무 함정 — 다층 재시도 곱셈**
>
> 클라이언트 3회 × 게이트웨이 3회 × 서비스 3회 = **최대 27배 트래픽** . 재시도는 **한 레이어에서만** 하거나, 안쪽 레이어는 재시도하지 않도록 설계해야 한다. 멱등성 계약이 없는 POST를 재시도하면 중복 생성 가능 — 그래서 멱등성(5절)이 필수.

## 3. Circuit Breaker — 회로 차단기

다운스트림이 계속 실패하는데 재시도를 반복하면 자원만 낭비한다. `Circuit Breaker(회로 차단기)`는 실패율이 임계치를 넘으면 **회로를 열어 즉시 실패(Fail-fast)**시키고, 일정 시간 후 시험 호출로 회복을 탐지한다.

```mermaid
stateDiagram-v2
    [*] --> CLOSED
    CLOSED --> OPEN : 실패율 > 임계치 (예: 50%)
    OPEN --> HALF_OPEN : wait duration 경과
    HALF_OPEN --> CLOSED : 시험 호출 성공
    HALF_OPEN --> OPEN : 시험 호출 실패
    note right of CLOSED : 정상 — 호출 통과
    note right of OPEN : 차단 — 즉시 실패/Fallback다운스트림에 부하 안 줌
    note right of HALF_OPEN : 회복 탐색 — 제한된 호출만 허용
```

*Circuit Breaker 상태 머신 — OPEN 상태에서 다운스트림을 쉬게 해 회복을 돕는다*

```text
try payment attempt within deadline
if circuit is open:
    if a durable payment command already exists:
        return pending with its stable operation ID
    else:
        return retryable failure
if outcome is unknown:
    persist UNKNOWN and reconcile with the payment provider
```

`deferred` 응답만 반환하고 큐에 기록하지 않으면 나중에 실행할 작업이 없다. Fallback(대체 처리)은 실제 저장된 작업·상태와 연결되어야 하며, 예외가 모두 회로 열림을 뜻하지도 않는다.

Resilience4j Spring 기본 조합은 `Retry(CircuitBreaker(...))` 형태다. 이 경우 CircuitBreaker는 각 재시도 호출을 관측할 수 있다. 순서·Fallback 위치·설정에 따라 관측되는 실패가 달라지므로 실제 버전에서 검증한다. “재시도 전체 실패가 무조건 1회로 집계된다”고 외우지 않는다.

## 4. Bulkhead — 격벽 격리

배의 격벽처럼, 한 다운스트림 호출이 **전체 스레드풀을 독점**하지 못하게 자원을 칸막이로 나눈다. 느린 결제 API가 주문 조회 스레드까지 잡아먹는 사태를 막는다.

```mermaid
flowchart LR
    In["요청"] --> B1["격벽 A\n결제용 풀 (10)"]
    In --> B2["격벽 B\n조회용 풀 (20)"]
    In --> B3["격벽 C\n알림용 풀 (5)"]
    B1 --> Pay["결제 API (느림)"]
    B2 --> Query["조회 (빠름)"]
    style B1 fill:#fee2e2,stroke:#ef4444
    style B2 fill:#dcfce7,stroke:#22c55e
```

*Bulkhead — 결제용 풀이 고갈돼도 조회용 풀은 멀쩡 → 장애 격리*

| 패턴 | 막는 문제 | 핵심 파라미터 |
| --- | --- | --- |
| Timeout | 무한 대기 | connect / read timeout |
| Retry | 일시적 실패 | maxAttempts, backoff, jitter |
| Circuit Breaker | 지속 실패에 자원 낭비 | failureRate, waitDuration |
| Bulkhead | 한 호출의 자원 독점 | maxConcurrentCalls |
| Rate Limiter | 과부하·다운스트림 보호 | limitForPeriod |

## 5. Idempotency-Key와 외부 결제 상태를 분리한다

Idempotency-Key(멱등성 키)는 **하나의 논리 요청**의 재시도에서 유지한다. 클라이언트가 만들거나 서버가 사전에 발급한 작업 ID를 사용할 수 있다. 매 HTTP 시도마다 새 키를 발급하는 것이 문제다. 키 범위에는 사용자·가맹점과 작업 종류도 포함한다.

동일 키와 다른 본문은 계약에 따른 오류로 거부한다. 해시는 금액·통화·주문·사용자 등 의미 있는 필드를 정규화해 계산한다. 단순 객체 `hashCode()`를 영속 요청 지문으로 사용하지 않는다.

```mermaid
sequenceDiagram
    participant C as Client
    participant A as Payment API
    participant D as DB
    participant W as Worker
    participant P as Payment Provider
    C->>A: stable key + request
    A->>D: short Tx: claim key and save payment command
    D-->>A: commit operation ID
    A-->>C: pending or stored result
    W->>D: read pending command
    W->>P: charge with stable provider key
    alt result known
        P-->>W: result
        W->>D: short Tx: save outcome
    else timeout
        W->>D: save UNKNOWN, schedule reconciliation
    end
```

```text
short DB transaction:
    insert (actor, operation, key, request_hash, status=PENDING)
        ON CONFLICT DO NOTHING
    if existing:
        verify same request_hash
        return stored result or current operation status
    save durable payment command with stable provider idempotency key
commit

worker outside DB transaction:
    call provider with the SAME provider key
    persist known outcome in a new short transaction
    on uncertain timeout, query/reconcile instead of marking definite failure
```

DB UNIQUE는 동시 요청의 선점을 제어할 뿐 원격 결제를 롤백하지 않는다. 로컬 `@Transactional` 안에서 PG를 호출한 뒤 DB 커밋에 실패하면, 키 기록은 없어져도 실제 청구는 남을 수 있다. 위와 같이 의도를 먼저 내구성 있게 저장하고 불명확한 결과를 복구한다.

| 상태 | 같은 키 재요청 | 운영 책임 |
|---|---|---|
| PENDING / PROCESSING | 진행 중 작업 ID 반환 또는 계약상 충돌 응답 | 오래된 작업 재확인 |
| SUCCEEDED | 저장된 결과 반환 | 결과 일관성 유지 |
| FAILED | 확정된 실패 반환·새 시도 정책 적용 | 실패 원인 분류 |
| UNKNOWN | 성공·실패 단정 금지 | 상대 조회·같은 키 재시도 가능 여부 확인 |

TTL은 공급자의 중복 제거 기간, 클라이언트 재시도 기간, 업무 기록 보존과 맞춰 정한다. Stripe의 키 보존 정책을 모든 결제사에 적용하거나 “24시간 후엔 무조건 삭제”로 구현하지 않는다. 오래된 키를 삭제한 뒤 같은 결제를 새로 실행하지 않도록 결제 의도 ID 등 장기 업무 키도 검토한다.

> **면접 포인트** — 유일 키·본문 비교뿐 아니라 **선점 후 프로세스 종료**, **PG 성공 후 DB 결과 저장 실패**, **키 보존 기간 경과**를 차례로 설명해야 한다.

## 6. Kafka 소비와 DB 커밋을 연결한다

이벤트 중복 판별을 `existsById → 업무 처리 → 처리 기록 저장`으로 분리하면 동시 소비자가 함께 통과할 수 있다. 아래는 독립된 빈의 짧은 DB 트랜잭션으로 처리하는 예시다. Repository의 `tryInsert`는 고유 키를 가진 `INSERT ... ON CONFLICT DO NOTHING`의 영향 행 수를 반환한다고 가정한다.

```kotlin
// Listener와 별도 Spring Bean. 아래 반환 전에 DB 커밋이 완료된다.
@Transactional
fun applyOnce(event: TrackingEvent) {
    val inserted = inboxRepo.tryInsert("tracking", event.eventId)
    if (inserted == 0) return
    shipmentRepo.applyVersionedTracking(event) // 업무 버전·상태 전이 검사
    // 실패하면 Inbox도 롤백한다.
}

// Listener: 수동 ACK 모드로 구성하고, 동기 처리를 가정한다.
fun onEvent(event: TrackingEvent, ack: Acknowledgment) {
    trackingTxService.applyOnce(event)
    ack.acknowledge()
}
```

Kafka 클라이언트의 자동 Offset 커밋과 Spring Kafka 컨테이너의 AckMode(확인 모드)는 구분한다. `enable.auto.commit=false`만으로 DB와 소비 위치가 원자적이 되는 것은 아니다. DB 커밋 뒤 ACK 전에 종료되는 경우는 재전달과 Inbox로 흡수한다. 병렬 처리는 앞선 미완료 Offset을 넘어 커밋하지 않도록 구성해야 한다.

> **실무 함정** — 모든 5xx 재시도, PROCESSING 키 영구 방치, 저장 없는 Fallback, DB 커밋 전 ACK는 서로 다른 실패다. 재시도 횟수 하나를 늘려서 해결하지 않는다.

## 참고

- [Stripe: Idempotent requests](https://docs.stripe.com/api/idempotent_requests)
- [Resilience4j: Spring Boot integration](https://resilience4j.readme.io/docs/getting-started-3)
- [Spring Kafka: Message Listener Containers](https://docs.spring.io/spring-kafka/reference/kafka/receiving-messages/message-listener-container.html)
- [Spring: Programmatic Transaction Management](https://docs.spring.io/spring-framework/reference/data-access/transaction/programmatic.html)

> **검수 기준 — 2026-09-12**: 요청 타임아웃과 결과 불명, 영속 작업 없는 Fallback, DB 선점과 외부 결제의 보장 경계, ACK 시점을 검수했다. 코드 조각은 버전·Repository 계약을 맞춰 구현해야 하는 학습 예제다.$review_3$
WHERE slug = 'backend-04-resilience-idempotency' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_4$> **검수 기준 — 2026-09-12**
>
> 가상의 포인트·주문 서비스 코드 리뷰다. PostgreSQL 17, Spring의 프록시 기반 트랜잭션을 가정한다. 아래 결함 코드와 수정 의사코드는 구분해서 읽는다. 특정 기업의 실제 코드는 아니다.

## 면접 진행 — 30분, 네 가지 실패 경계

첫 5분은 요구사항을 확인한다. 같은 리뷰의 포인트는 한 번만 지급하고, 다른 리뷰는 각각 지급해야 한다. 결제는 응답이 사라져도 중복 청구하지 않아야 하며, 주문과 외부 결제의 상태 불일치는 복구 가능해야 한다.

```mermaid
flowchart LR
    R1[중복 업무 키] --> R2[잔액 동시 갱신]
    R2 --> R3[재시도와 외부 결제]
    R3 --> R4[주문·예약·Outbox]
```

라운드별로 결함 → 구체적 실행 순서 → 최소 수정 → 수정 뒤 남는 장애를 말한다. 특정 기술을 골랐다는 이유만으로 정답·오답을 판정하지 않는다.

## R1 — 같은 리뷰가 동시에 두 번 적립된다

```kotlin
// 결함 코드: exists 검사와 INSERT 사이가 보호되지 않는다.
@Transactional
fun earnReviewPoint(userId: Long, reviewId: Long) {
    if (pointHistoryRepo.existsByUserIdAndReviewId(userId, reviewId)) return
    val user = userRepo.findById(userId).orElseThrow()
    user.point += 500
    pointHistoryRepo.save(PointHistory(userId, reviewId, 500))
}
```

두 요청이 모두 “기록 없음”을 읽으면 두 적립 이력이 저장될 수 있다. 잔액은 실행 순서에 따라 500만 늘어 이력 합계와 어긋나거나 1,000이 늘어 중복 적립될 수 있다. **중복 업무 처리**와 **갱신 유실**을 하나의 현상으로 섞지 않는다.

수정에는 `(user_id, review_id)` 고유 제약과 원자적 잔액 증가를 함께 쓴다. 아래 예시는 Repository가 영향 행 수를 반환한다고 가정한다.

```kotlin
@Transactional
fun earnReviewPoint(userId: Long, reviewId: Long) {
    // INSERT ... ON CONFLICT (user_id, review_id) DO NOTHING
    val inserted = pointHistoryRepo.insertIfAbsent(userId, reviewId, 500)
    if (inserted == 0) return
    // UPDATE users SET point = point + :amount WHERE id = :id
    val updated = userRepo.addPoint(userId, 500)
    check(updated == 1) // 계정 변경 실패면 이력도 롤백
}
```

> **실무 함정** — JPA `save()` 직후 UNIQUE 예외를 catch하고 같은 트랜잭션을 계속 쓰는 방식은 안전한 기본 예제가 아니다. INSERT가 Flush(변경 전송)·커밋까지 지연될 수 있고, 예외 이후 트랜잭션이 롤백 전용일 수 있다. 충돌을 정상적인 영향 행 결과로 다루거나, 실패한 트랜잭션 밖에서 중복을 판정한다.

**후속 질문:** 같은 리뷰인데 적립 금액이 다른 재요청은? 고정 500 정책이면 서버가 계산한다. 금액이 입력이라면 기존 기록과 비교해 불일치를 거절해야 한다.

## R2 — 서로 다른 리뷰인데 포인트가 하나 사라진다

리뷰 ID가 다르면 두 INSERT 모두 정상이다. 하지만 두 요청이 잔액 1,000을 읽고 1,500으로 덮어쓰면 한 적립이 사라진다. READ COMMITTED(커밋된 데이터 읽기)에서 상수 덮어쓰기는 이런 실행이 가능하다.

```mermaid
sequenceDiagram
    participant A as Review 11
    participant D as users point=1000
    participant B as Review 12
    A->>D: read 1000
    B->>D: read 1000
    A->>D: set 1500 and commit
    B->>D: set 1500 and commit
    Note over D: 두 이력 합계와 잔액 불일치
```

`UPDATE users SET point = point + 500`은 현재 행을 기준으로 증가시켜 이 경합을 제어한다. 이력 INSERT와 같은 트랜잭션에서 실행해야 이력만 남거나 잔액만 증가하지 않는다. UPDATE도 잠금을 사용하고 트랜잭션이 길면 대기가 길어진다.

`@Transactional`은 선언된 트랜잭션 경계를 제공할 뿐, 모든 애플리케이션 조건 검사를 자동으로 직렬화하지 않는다. 반대로 “트랜잭션은 어떤 락도 쓰지 않는다”는 뜻도 아니다. PostgreSQL REPEATABLE READ는 같은 행의 동시 갱신에서 중단될 수 있고, SERIALIZABLE은 여러 행에 걸친 규칙을 지키는 선택지가 될 수 있다. DBMS·규칙·재시도 비용으로 비교한다.

**후속 질문:** 서버가 두 대면? 같은 JVM 모니터를 공유하지 않으므로 각 서버의 `synchronized`는 서로를 막지 못한다. DB 제약·갱신 규칙은 두 서버뿐 아니라 배치·운영 도구에도 적용되어야 한다.

## R3 — 타임아웃 뒤 재시도했더니 이중 결제다

```kotlin
// 결함 코드: 원격 결제 결과와 로컬 기록이 함께 롤백되지 않는다.
@Transactional
fun pay(req: PayRequest): PayResponse {
    val result = pgClient.charge(req.amount)
    paymentRepo.save(Payment(req.orderId, result.txId))
    return PayResponse(result.txId)
}
```

PG(Payment Gateway, 결제 대행 시스템)가 승인했는데 응답이 유실되면 서버에는 실패처럼 보인다. 타임아웃은 **결과 불명**이지 확정 실패가 아니다. 그대로 새 요청을 만들면 다른 결제가 수행될 수 있다.

Idempotency-Key(멱등성 키)는 논리 결제 의도별로 유지한다. 클라이언트 생성 키나 서버가 미리 발급해 저장한 결제 의도 ID 모두 가능하다. 생성 위치보다 모든 재시도에서 동일한 의도에 동일한 키를 쓰는 것이 중요하다.

```text
short DB transaction:
    claim unique (merchant, operation, idempotency_key)
    compare normalized request fingerprint on duplicate
    persist payment intent and delivery command
commit

worker:
    call PG using persisted provider key, outside DB transaction
    save confirmed result in another short DB transaction
    if uncertain: retain UNKNOWN and reconcile with provider
```

| 실패 지점 | 필요한 복구 |
|---|---|
| 선점 후 Worker 실행 전 종료 | 저장된 대기 명령 재개 |
| PG 성공 후 로컬 결과 저장 실패 | 같은 PG 키·상태 조회로 결과 확인 |
| 같은 키에 다른 금액·통화 | 의미 있는 요청 필드 비교 후 거절 |
| 오래된 PROCESSING | 작업 진행·PG 결과 대사, 무조건 새 결제 금지 |
| 키 보존 기간 경과 | 장기 결제 의도 키와 공급자 재시도 계약 검토 |

**후속 질문:** PG가 멱등 키·상태 조회를 모두 제공하지 않는다면? 결과 불명 상태를 자동으로 재청구해서 해결할 수 없다. 수동 대사나 다른 결제 연동 방식이 필요하다는 한계를 명시한다.

## R4 — 주문·재고·결제를 어디서 나눈다

다음 초기 코드는 외부 호출 동안 DB 연결과 잠금을 붙잡고, PG 승인 뒤 DB 롤백 또는 커밋 전 이벤트 발행의 불일치를 만든다.

```kotlin
// 결함 코드
@Transactional
fun placeOrder(cmd: OrderCommand): Order {
    stockRepo.decrease(cmd.productId, cmd.qty)
    val pay = pgClient.charge(cmd.amount)
    val order = orderRepo.save(Order(cmd, pay.txId))
    kafkaTemplate.send("order-created", order)
    return order
}
```

가상 설계에서는 예약을 먼저 하고 결제를 비동기로 확정한다. 결제 승인·매입 정책이 다르면 순서와 보상도 달라질 수 있다.

```text
transaction A:
    claim order request with UNIQUE business key
    reserve inventory with positive-quantity conditional updates
    require all items succeeded
    save order PAYMENT_PENDING + payment command in Outbox
commit A

worker outside transaction:
    execute/reconcile payment with stable provider key

transaction B:
    claim outcome event once
    transition reservation/order only from allowed previous state
    save confirmation or compensation command to Outbox
commit B
```

```mermaid
sequenceDiagram
    participant A as Order API
    participant D as DB
    participant W as Worker
    participant P as PG
    A->>D: reserve + pending order + outbox in one Tx
    D-->>A: commit
    W->>D: load committed command
    W->>P: payment with stable key
    P-->>W: known result
    W->>D: apply outcome + next outbox in one Tx
    Note over W,D: 응답 유실·재전달은 멱등 키와 상태 조회로 복구
```

Outbox(발행 대기 기록)는 **로컬 업무 변경과 전달 의도**를 함께 커밋한다. PG 청구를 같은 트랜잭션으로 묶거나, 릴레이 중복을 제거하거나, 보상 정책을 자동 생성하지 않는다. 예약 만료가 결제 성공보다 먼저 확정됐다면 재예약·환불 중 업무 정책에 맞는 경로로 대사한다.

> **실무 함정** — 같은 객체 내부에서 `saveOrderTx()`를 호출하면 기본 Spring 프록시 기반 `@Transactional`이 적용되지 않을 수 있다. 별도 트랜잭션 빈 또는 `TransactionTemplate`으로 경계를 명시한다. “호출을 메서드로 나눴다”만으로 해결되지 않는다.

## 검증 시나리오와 평가 기준

가정: 초당 100건이 평균 2초씩 DB 연결을 붙잡으면 평균 약 200개의 연결 점유 수요가 생긴다. 풀을 늘리기 전에 외부 대기를 트랜잭션 밖으로 옮기고 DB 처리 시간·대기열·재시도 증폭을 측정한다. 평균 계산은 p99나 최대 동시성 보장이 아니다.

| 시나리오 | 확인할 결과 |
|---|---|
| 동일 리뷰 동시 100회 | 이력 1개·잔액 500 증가 |
| 다른 리뷰 100개 동시 요청 | 이력 100개·잔액 50,000 증가 |
| 이력 저장 뒤 강제 실패 | 이력과 잔액 모두 미반영 |
| PG 승인 뒤 로컬 종료 | 새 청구 없이 결과 대사 |
| Outbox 발행 후 표시 전 종료 | 재전달되어도 업무 효과 중복 없음 |
| 예약 만료와 승인 동시 처리 | 허용된 상태 전이 하나만 성공·늦은 결과 보상 |

좋은 답변은 기술 이름보다 이 결과를 어떻게 보장하는지 설명한다. SERIALIZABLE·분산락을 사용했다는 이유만으로 감점하지 않고, 더 단순한 제약과 비교한 근거·충돌 비용·실패 복구를 평가한다.

## 참고

- [PostgreSQL 17 Transaction Isolation](https://www.postgresql.org/docs/17/transaction-iso.html), [INSERT](https://www.postgresql.org/docs/17/sql-insert.html)
- [Spring Programmatic Transactions](https://docs.spring.io/spring-framework/reference/data-access/transaction/programmatic.html)
- [Stripe Idempotent Requests](https://docs.stripe.com/api/idempotent_requests)
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)$review_4$
WHERE slug = 'backend-07-interview-concurrency' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_5$## 1. 두 아키텍처의 본질

**Monolith(모놀리스)**는 하나의 배포 단위 안에 모든 도메인이 들어있는 구조다. 그중 **Modular Monolith(모듈러 모놀리스)**는 내부를 모듈 경계로 엄격히 나눈, "잘 정돈된 단일 배포물"이다. **MSA(Microservices Architecture, 마이크로서비스 아키텍처)**는 도메인별로 *독립 배포·독립 DB·독립 프로세스*로 쪼갠 구조다.

```mermaid
flowchart TB
    subgraph MM["Modular Monolith — 단일 배포물"]
      direction LR
      O1["Ordering\n모듈"]
      P1["Payment\n모듈"]
      I1["Inventory\n모듈"]
      O1 -. "in-process 호출\n(컴파일 타임 경계)" .- P1
      P1 -. "in-process 호출" .- I1
    end
    DB1[("단일 DB\n스키마 분리")]
    MM --> DB1

    subgraph MSA["MSA — 독립 배포물 N개"]
      direction LR
      O2["Ordering\nService"]
      P2["Payment\nService"]
      I2["Inventory\nService"]
      O2 -->|"network\n(REST/이벤트)"| P2
      P2 -->|"network"| I2
    end
    O2 --> DBO[("Order DB")]
    P2 --> DBP[("Payment DB")]
    I2 --> DBI[("Inventory DB")]

    style MM fill:#dbeafe,stroke:#3b82f6
    style MSA fill:#ede9fe,stroke:#8b5cf6
    style O1 fill:#fff,stroke:#3b82f6
    style P1 fill:#fff,stroke:#3b82f6
    style I1 fill:#fff,stroke:#3b82f6
```

*핵심 차이는 "모듈 경계"가 아니라 **배포 단위와 데이터 소유권**이다. Modular Monolith도 경계는 있다.*

> **💡 핵심 통찰**
>
> Modular Monolith와 MSA는 **모듈성(modularity)** 이라는 같은 목표를 공유한다. 차이는 모듈을 *프로세스 경계와 네트워크로 분리하느냐* 다. 좋은 MSA는 좋은 Modular Monolith에서 출발한다 — 경계가 엉망인 모놀리스를 쪼개면 `Distributed Monolith(분산 모놀리스)` 가 된다.

## 2. 정면 비교

| 관점 | Modular Monolith | MSA |
| --- | --- | --- |
| 초기 개발 속도 | **빠름** — 단일 코드베이스, 로컬 호출 | 느림 — 인프라·계약·관측성 선투자 |
| 배포 독립성 | 없음 (전체 재배포) | **있음** (서비스별 배포) |
| 데이터 정합성 | **쉬움** — 단일 DB 트랜잭션 | 어려움 — Saga/Outbox 등 분산 정합성 필요 |
| 장애 격리 | 부분적 (한 모듈 OOM → 전체 다운) | **좋음** (설계 시 — Bulkhead·Circuit Breaker) |
| 지연(Latency) | **낮음** — in-process 호출 ns 단위 | 높음 — 네트워크 hop마다 ms 누적 |
| 운영 복잡도 | 낮음 (1개 배포·1개 DB) | **높음** — 관측성·서비스 디스커버리·배포 N배 |
| 기술 스택 다양성 | 제한적 (단일 런타임) | **높음** (서비스별 언어/DB 선택) |
| 적합 팀 규모 | 소~중 (1~3팀) | 중~대 (Conway 정렬 다수 팀) |

> **🎯 면접 포인트**
>
> "MSA로 가시겠어요?"에 무조건 "네"는 감점. **"팀 규모·도메인 성숙도·운영 역량을 보고, 대부분은 Modular Monolith로 시작해 경계가 안정된 뒤 쪼갠다"** 가 시니어 답변. 지연과 운영 인력의 증가율에는 보편적인 배수가 없다. 가상의 직렬 원격 호출 세 개가 각각 5ms씩 걸리면 해당 요청에는 15ms가 추가되지만, 이 계산을 시스템 p99에 그대로 더할 수는 없다. 실제 판단은 같은 부하에서 종단 p95·p99, 장애 전파, 배포 빈도, 온콜 업무 시간을 측정해 내린다. 🔥(Deep-dive)

## 3. Conway의 법칙 (Conway's Law)

**"시스템 구조는 그것을 만든 조직의 커뮤니케이션 구조를 복제한다."** 4개 팀이 만들면 자연히 4덩어리 시스템이 나온다. 따라서 *원하는 아키텍처를 먼저 정하고, 거기에 맞춰 팀을 정렬*하는 **Inverse Conway Maneuver(역 콘웨이 전략)**가 실무 전략이다.

```mermaid
flowchart LR
    subgraph ORG["조직 구조"]
      TA["주문팀"]
      TB["결제팀"]
      TC["재고/풀필먼트팀"]
    end
    subgraph SYS["시스템 구조 (복제됨)"]
      SA["Ordering\nService"]
      SB["Payment\nService"]
      SC["Inventory\nService"]
    end
    TA ==> SA
    TB ==> SB
    TC ==> SC

    style ORG fill:#dbeafe,stroke:#3b82f6
    style SYS fill:#dcfce7,stroke:#22c55e
```

*팀 경계 = 서비스 경계. Team Topologies의 **Stream-aligned team(스트림 정렬 팀)**이 한 Bounded Context를 소유하는 것이 이상적.*

> **⚠️ 실무 함정**
>
> 조직은 모놀리식 한 팀인데 시스템만 10개 서비스로 쪼개면 → 모든 변경이 팀 내 여러 서비스를 동시에 건드려 배포 독립성이 사라진다. **팀이 안 쪼개졌으면 서비스도 쪼개지 마라.**

## 4. 서비스 분리 기준

"기능이 크니까"가 아니라 다음 축으로 자른다.

| 분리 기준 | 설명 | 물류 예시 |
| --- | --- | --- |
| **비즈니스 capability** | 독립적 가치를 내는 능력 단위 | 주문수집 / 결제 / 재고할당 / 배차 / 운송추적 |
| **변경의 축** | 함께 변하는 것은 함께 둔다 (응집) | 쿠폰·프로모션 로직은 주문과 함께 자주 변경 |
| **데이터 소유권(SSOT)** | 한 데이터의 단일 진실 원천이 한 서비스 | 재고 수량은 Inventory만 쓴다 — 남이 직접 못 씀 |
| **팀 구조** | 한 팀이 한 서비스를 온전히 소유 | 라스트마일팀이 배송추적 서비스 전담 |
| **통신 빈도** | 채터링(Chattering) 많으면 경계 의심 | 주문↔재고가 초당 수십 번 호출 → 합칠 신호 |
| **확장 특성** | 부하 패턴이 다르면 분리해 독립 확장 | 운송추적(읽기 폭주) vs 정산(배치) |

> **💡 응집도·결합도 한 줄 판단**
>
> 한 변경 요청(Change request)이 **여러 서비스를 동시에** 수정해야 한다면 경계가 틀린 것. 이상적으로는 "주문 화면에 필드 추가" → 주문 서비스 하나만 배포하면 끝나야 한다.

## 5. 분산 시스템의 진짜 비용

MSA는 공짜가 아니다. 로컬 메서드 호출을 네트워크로 바꾸는 순간 다음이 전부 "내 문제"가 된다.

```mermaid
flowchart TB
    A["로컬 메서드 호출\n(Modular Monolith)"] -->|"프로세스 분리"| B["네트워크 호출\n(MSA)"]
    B --> C1["부분 실패\nPartial failure"]
    B --> C2["지연 누적\nLatency tax"]
    B --> C3["분산 정합성\nSaga / Outbox"]
    B --> C4["관측성\nDistributed Tracing"]
    B --> C5["버전·계약\nAPI Contract 진화"]
    B --> C6["네트워크 보안\nmTLS / 인증"]

    style A fill:#dcfce7,stroke:#22c55e
    style B fill:#fee2e2,stroke:#ef4444
```

*"8 Fallacies of Distributed Computing"의 현대판 — 네트워크는 신뢰할 수 없고 공짜가 아니다.*

### 정량 근거 — 동기 HTTP 체인의 지연·가용성 붕괴

- **지연 누적**: 한 hop이 P99 20ms라면, 5개 서비스 직렬 체인은 P99가 단순 합이 아니라 꼬리 지연 곱셈으로 **100ms 이상**으로 악화.
- **가용성 곱셈**: 각 서비스 가용성 99.9%여도 5개 직렬 의존이면 0.999⁵ ≈ **99.5%** — 연 43시간 장애로 급락.
- → 대응: 동기 체인을 줄이고 `비동기 이벤트`·`Circuit Breaker(서킷 브레이커)`·`Bulkhead(격벽)`·`Timeout/Retry + Idempotency(멱등성)`로 격리.

> **🎯 면접 포인트 (단골)**
>
> "서비스 A가 다운되면 어떻게 되나요?" → **연쇄 장애(Cascading failure)** 시나리오를 그리고, Timeout·Circuit Breaker·Fallback·격벽으로 전파를 끊는 설계를 답해야 한다. "그냥 재시도하면 된다"는 오히려 **Retry storm(재시도 폭주)** 으로 장애를 키운다. 🔥(Deep-dive)

## 6. 최악의 결과 — Distributed Monolith

네트워크로 쪼갰는데 결합도는 그대로인 상태. 모놀리스의 단점(강결합)과 MSA의 단점(네트워크·운영 복잡도)을 *동시에* 가진다.

| 증상 | 왜 분산 모놀리스인가 |
| --- | --- |
| **DB 공유** | 여러 서비스가 같은 테이블을 직접 읽고 씀 → 스키마 변경이 전 서비스 동시 배포를 강제 |
| **동기 호출 체인** | A→B→C→D 직렬 호출 → 하나만 죽어도 전부 실패 |
| **강한 시간 결합** | B가 살아있어야 A가 응답 가능 (Temporal coupling) |
| **공유 라이브러리 강제** | 공통 도메인 모델 jar를 모두 의존 → 버전 올리면 동시 재배포 |
| **함께 배포** | "A를 배포하려면 B도 같이 배포"가 일상이면 이미 실패 |

> **⚠️ 실무 함정 — DB 공유**
>
> MSA 전환 1순위 안티패턴. "일단 서비스만 나누고 DB는 같이 쓰자"는 즉시 분산 모놀리스로 직행한다. **데이터 소유권 분리가 진짜 분리** 다. 남의 데이터는 API/이벤트로만 접근.

## 7. 마이그레이션 전략 — Strangler Fig

빅뱅 재작성은 거의 실패한다. **Strangler Fig Pattern(교살자 무화과 패턴)**으로 기존 모놀리스를 감싼 프록시 뒤에서 기능을 한 조각씩 새 서비스로 떼어낸다.

```mermaid
sequenceDiagram
    participant C as Client
    participant G as API Gateway / Proxy
    participant M as 기존 Monolith
    participant S as 신규 Inventory Service

    Note over G: 1단계 — 모든 요청 모놀리스로
    C->>G: GET /inventory
    G->>M: 라우팅
    M-->>C: 응답

    Note over G,S: 2단계 — Inventory만 신규로 라우팅 전환
    C->>G: GET /inventory
    G->>S: 라우팅 (떼어낸 기능)
    S-->>C: 응답
    C->>G: POST /order
    G->>M: 아직 모놀리스
    M-->>C: 응답

    Note over M: 3단계 — 모든 기능 이전 후 모놀리스 폐기
```

*Strangler Fig — 프록시 뒤에서 점진 전환. 롤백이 라우팅 스위치 한 번이라 리스크가 작다.*

### 전환 순서 — 무엇부터 떼는가

1. **경계가 가장 뚜렷하고 결합이 약한 모듈**부터 (예: 알림, 검색, 정산 배치).
2. **독립 확장 요구가 큰 모듈** (운송추적 읽기 폭주 등).
3. 데이터 분리: 먼저 읽기 복제 → 이중 쓰기(Dual-write) 회피 위해 `Outbox(아웃박스)` 도입 → SSOT 이전 → 옛 컬럼 제거. 🔥(Deep-dive)
4. 핵심 트랜잭션(주문-결제-재고)은 **가장 마지막**에 — 분산 정합성 비용이 가장 크다.

> **💡 Trade-off 정리**
>
> "지금 쪼개야 하나?"의 판단: ① 팀이 서로 배포를 막고 있다 ② 모듈별 확장 특성이 명확히 다르다 ③ 경계가 코드에서 이미 안정적이다 — 셋 다 ✓면 분리. 하나라도 모호하면 **Modular Monolith로 더 버티는 게 정답** . 조기 MSA는 재앙이다.

## 8. 실제 사례

| 회사 | 선택 | 맥락 |
| --- | --- | --- |
| **우아한형제들(배민)** | 모놀리스 → MSA 점진 전환 | 주문 폭증으로 결제·주문·정산 분리. 이벤트 기반 + Outbox로 정합성 확보, 가게/메뉴/주문 도메인 단위로 분해 |
| **토스** | 도메인별 MSA | 금융 규제·장애 격리가 중요 → 송금/결제/인증 강하게 분리, 각 서비스 독립 SLA |
| **쿠팡** | 대규모 MSA | 주문·풀필먼트·물류(WMS/TMS) 도메인 다수 팀 → Conway 정렬된 서비스망 |
| **Amazon** | Two-Pizza Team + 서비스 | 팀 크기를 먼저 제한해 서비스 경계 유도 (Inverse Conway) |
| **Shopify / Stripe** | 의도적 Modular Monolith 유지 | 핵심 도메인은 모놀리스로 두되 모듈 경계를 엄격히 강제 (조기 분리 거부) |

> **🎯 면접 포인트**
>
> "쿠팡/배민은 MSA니까 우리도"는 함정. 그 회사들은 **수십~수백 팀** 규모에서 운영 역량(관측성·플랫폼팀·SRE)을 갖췄기에 가능. Shopify가 대규모인데도 모놀리스를 유지하는 이유를 설명할 수 있으면 시니어 신호다.

```text
분리 결정 기록(ADR)
- 독립 배포가 필요한 팀/변경 주기인가?
- 데이터 소유권과 트랜잭션 경계를 자를 수 있는가?
- 네트워크 실패·관측성·온콜 비용을 감당할 수 있는가?
```

> **부분 검수 — 2026-09-12**: 근거 없는 성능·인력 배수를 제거했다. 나머지 기업 사례는 별도 출처 대조 대상이다.$review_5$
WHERE slug = 'backend-architecture-01-msa-vs-monolith' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_6$## 1. 왜 이벤트 기반인가 — 문제 → 해결

**문제**: 주문 완료 후 재고차감·포인트적립·알림발송·정산을 동기 호출하면, 한 호출만 느려도/죽어도 주문 전체가 실패한다(시간 결합 Temporal coupling). 새 후속 작업이 생길 때마다 주문 코드를 고쳐야 한다.

**해결**: 주문은 `OrderPlaced` 이벤트만 발행하고 떠난다. 관심 있는 컨슈머가 알아서 구독한다. **발행자는 소비자를 모른다** → 느슨한 결합과 확장성.

```mermaid
flowchart LR
    subgraph SYNC["동기 호출 — 강결합"]
      O1["Order"] --> Inv1["Inventory"]
      O1 --> Pt1["Point"]
      O1 --> Noti1["Notify"]
    end
    subgraph EVT["이벤트 기반 — 느슨한 결합"]
      O2["Order"] -->|"OrderPlaced"| B[("Event Broker\nKafka")]
      B --> Inv2["Inventory"]
      B --> Pt2["Point"]
      B --> Noti2["Notify"]
      B -.->|"신규 컨슈머\n주문코드 수정 0"| Fraud["Fraud 분석"]
    end

    style SYNC fill:#fee2e2,stroke:#ef4444
    style EVT fill:#dcfce7,stroke:#22c55e
    style B fill:#ede9fe,stroke:#8b5cf6
```

*동기(좌)는 컨슈머 추가마다 발행자 수정. 이벤트(우)는 발행자 변경 없이 컨슈머만 늘린다.*

> **💡 Trade-off**
>
> 이벤트 기반은 결합도↓·확장성↑·장애 격리↑를 주지만, 대가로 **최종 일관성(Eventual Consistency)** , 흐름 추적 난이도↑, 디버깅 복잡도↑를 받는다. 강한 일관성이 필수인 곳(잔액 차감 즉시 반영 등)은 동기가 낫다.

## 2. Event vs Command vs Query — 명확히 구분

|  | Command(명령) | Event(이벤트) | Query(조회) |
| --- | --- | --- | --- |
| 의미 | "~을 해라" | "~이 일어났다"(사실) | "~을 알려달라" |
| 시제 | 명령형 | **과거형** | 질문형 |
| 수신자 | 1명 (특정) | 0~N명 (모름) | 1명 |
| 거부 가능 | 가능 (검증 후 실패) | 불가 (이미 발생함) | 해당 없음 |
| 예시 | `ReserveInventory` | `InventoryReserved` | `GetOrderStatus` |

> **⚠️ 실무 함정 — Event와 Command 혼용**
>
> 이벤트 이름을 `ReserveInventory` (명령형)로 지으면 발행자가 컨슈머의 행동을 지시하는 셈 → 결합이 다시 강해진다. 이벤트는 **과거의 사실** ( `OrderPlaced` )만 알리고, 무엇을 할지는 컨슈머가 결정해야 한다.

## 3. Domain Event vs Integration Event

둘 다 "과거의 사실"이지만 **범위와 계약(Contract)**이 다르다. 이 구분을 못 하면 내부 모델이 외부로 새어 강결합이 된다.

|  | Domain Event (도메인 이벤트) | Integration Event (통합 이벤트) |
| --- | --- | --- |
| 범위 | 한 Bounded Context **내부** | 컨텍스트/서비스 **경계 간** |
| 전달 | in-process (메모리 디스패처) | 메시지 브로커 (Kafka/SQS) |
| 스키마 | 내부용, 자유롭게 변경 | **공개 계약** — 하위호환 필수 |
| 내용 | 풍부한 도메인 객체 가능 | 최소·안정 필드 (ID 중심) |
| 예시 | Order Aggregate가 발행한 `OrderPlaced` | 외부로 나가는 `order.placed.v1` |

```mermaid
flowchart LR
    subgraph BC["Ordering 컨텍스트"]
      AGG["Order Aggregate"] -->|"Domain Event\n(in-process)"| H["이벤트 핸들러"]
      H -->|"번역 + 안정 스키마"| OUT["Integration Event\norder.placed.v1"]
    end
    OUT -->|"브로커"| K[("Kafka")]
    K --> INV["Inventory 서비스"]
    K --> SHIP["Shipping 서비스"]

    style BC fill:#dbeafe,stroke:#3b82f6
    style AGG fill:#fff,stroke:#3b82f6
    style OUT fill:#dcfce7,stroke:#22c55e
    style K fill:#ede9fe,stroke:#8b5cf6
```

*도메인 이벤트는 내부에서, 통합 이벤트는 안정된 공개 스키마로 번역해 밖으로. 내부 모델을 외부에 그대로 노출하지 마라.*

> **🎯 면접 포인트 — 스키마 진화**
>
> 통합 이벤트는 **하위 호환(Backward compatibility)** 이 생명. 필드 추가는 OK, 삭제·의미 변경은 금지. `Schema Registry(Avro/Protobuf)` 와 버전 태깅( `v1` )으로 관리. `Consumer-Driven Contracts(Pact)` 로 컨슈머가 깨지지 않게 검증. 🔥(Deep-dive)

## 4. 이벤트 흐름 설계 — 물류 주문 파이프라인

주문이 들어오면 이벤트가 컨텍스트를 타고 흐른다. 각 컨슈머는 자기 일을 하고 다음 이벤트를 발행한다.

```mermaid
sequenceDiagram
    participant O as Ordering
    participant K as Kafka
    participant I as Inventory
    participant F as Fulfillment
    participant S as Shipping
    participant N as Notification

    O->>K: OrderPlaced
    K->>I: OrderPlaced 구독
    I->>I: 재고 예약(Reserve)
    I->>K: InventoryReserved
    K->>F: InventoryReserved 구독
    F->>F: 피킹/패킹
    F->>K: PackagePrepared
    K->>S: PackagePrepared 구독
    S->>S: 운송장 발행
    S->>K: ShipmentDispatched
    K->>N: 각 이벤트 구독
    N->>N: 고객 알림 발송
```

*물류 주문 이벤트 파이프라인 — 각 컨텍스트가 사실을 발행하고 다음이 반응한다(Choreography).*

### 이벤트 설계 체크리스트

- **이벤트는 자기완결적**: 컨슈머가 매번 발행자에게 되묻지(콜백) 않아도 되게 필요한 ID·핵심 필드 포함.
- **too fat / too thin 균형**: 전체 객체를 다 넣으면 결합·페이로드 비대, 너무 적으면 컨슈머가 추가 조회 폭주. 보통 ID + 핵심 필드.
- **순서 보장 범위**: Kafka는 파티션 내 순서만 보장 → 같은 `orderId`는 같은 파티션 키로.

## 5. Choreography vs Orchestration

여러 단계의 흐름을 누가 제어하는가의 문제. **Choreography(코레오그래피)**는 각자 이벤트를 듣고 자율적으로 반응, **Orchestration(오케스트레이션)**은 중앙 조정자가 단계를 지시한다.

```mermaid
flowchart TB
    subgraph CHOREO["Choreography — 분산 자율"]
      direction LR
      A1["Order"] -->|"이벤트"| A2["Inventory"]
      A2 -->|"이벤트"| A3["Shipping"]
    end
    subgraph ORCH["Orchestration — 중앙 조정"]
      direction LR
      ORCa(["Orchestrator"])
      ORCa -->|"명령"| B1["Order"]
      ORCa -->|"명령"| B2["Inventory"]
      ORCa -->|"명령"| B3["Shipping"]
      B1 -.->|"응답"| ORCa
      B2 -.->|"응답"| ORCa
      B3 -.->|"응답"| ORCa
    end

    style CHOREO fill:#dcfce7,stroke:#22c55e
    style ORCH fill:#dbeafe,stroke:#3b82f6
    style ORCa fill:#fff,stroke:#3b82f6
```

*Choreography는 결합도 낮지만 흐름이 코드에 흩어진다. Orchestration은 흐름이 한곳에 보이지만 조정자가 핵심 지점.*

| 관점 | Choreography | Orchestration |
| --- | --- | --- |
| 결합도 | **낮음** (서로 모름) | 중간 (조정자가 다 앎) |
| 흐름 가시성 | 낮음 (전체 추적 어려움) | **높음** (한곳에 정의) |
| 단일 지점 | 없음 | 조정자 (장애·병목 가능) |
| 적합 상황 | 단계 적고 자율적, 느슨한 흐름 | 단계 많고 복잡, 보상·롤백 필요 |
| 디버깅 | 어려움 (분산 추적 필수) | 쉬움 (상태 머신 추적) |

> **💡 선택 기준**
>
> 단계가 **2~3개로 단순** 하면 Choreography. **4단계 이상 + 실패 보상이 복잡** (주문-결제-재고-배송 + 각 단계 롤백)하면 Orchestration이 흐름 가시성에서 유리. 이게 다음 장(04 Saga)의 두 변형으로 직결된다.

## 6. 전달 보장과 함정

| 전달 의미론 | 의미 | 현실 |
| --- | --- | --- |
| At-most-once | 최대 1번 (유실 가능) | 중요 이벤트에 부적합 |
| At-least-once | 최소 1번 (중복 가능) | **표준** — 중복은 멱등성으로 흡수 |
| Exactly-once processing | 정의된 경계 안에서 한 번 실행한 결과 | 트랜잭션·중복 제거·소비 위치를 함께 관리하며 외부 효과는 별도 설계 |

> **⚠️ 실무 함정 — DB 커밋 후 이벤트 발행**
>
> "주문 저장 → 그 다음 줄에서 Kafka 발행"은 위험하다. 저장 후 발행 직전에 프로세스가 죽으면 **이벤트 유실** (Dual-write 문제). 반대로 발행 후 커밋 실패면 **유령 이벤트** . 해결은 `Transactional Outbox(트랜잭셔널 아웃박스)` — DB 트랜잭션과 이벤트 적재를 원자화. 06장에서 깊게 다룬다. 🔥(Deep-dive)

> **🎯 면접 포인트**
>
> "이벤트가 중복으로 오면?" → 컨슈머를 **멱등(Idempotent)** 하게 설계. 운송장 `TrackingEvent` 가 여러 경로로 중복 수신되어도 같은 `eventId` 를 이미 처리했으면 무시(Inbox 패턴). At-least-once + 멱등 컨슈머 = Effectively once.

## 7. 실제 사례

| 회사 | 이벤트 활용 |
| --- | --- |
| **우아한형제들(배민)** | 주문 도메인을 Kafka 이벤트로 결제·정산·배달대행에 전파. 주문 발생 시 다수 컨슈머가 비동기 반응 |
| **쿠팡** | 풀필먼트·물류 상태 변화를 이벤트 스트림으로 — 수천만 건/일 TrackingEvent fan-out에 Kafka + CDC |
| **토스** | 금융 이벤트를 비동기로 처리하되 핵심 트랜잭션은 동기 강일관성 유지 (혼합 전략) |
| **Netflix** | 대규모 이벤트 파이프라인 + 스트림 처리로 추천·시청 로그 처리 |
| **Uber** | 배차·결제·위치 업데이트를 이벤트 기반으로, Orchestration(Cadence/Temporal) 활용 |

> **💡 물류 맥락**
>
> 운송장 상태 변화( `PickedUp` → `InTransit` → `Delivered` )는 이벤트 기반의 교과서. 기사 앱 오프라인 동기화·중복 스캔 때문에 **멱등 + 순서 키(orderId 파티셔닝)** 가 필수다.

```json
{
  "eventId": "01J...",
  "aggregateId": "waybill-42",
  "aggregateVersion": 17,
  "type": "Delivered",
  "occurredAt": "2026-08-20T09:00:00Z"
}
```

> **부분 검수 — 2026-09-12**: 전달 횟수와 관측 가능한 처리 결과를 구분했다. [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/)의 트랜잭션 보장을 “분산 환경이므로 모두 불가능”으로 부정하지 않는다. 기업별 도입 사례는 후속 출처 검수 대상이다.$review_6$
WHERE slug = 'backend-architecture-03-event-driven' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_7$## 1. Saga가 책임지는 범위

Saga(사가)는 여러 로컬 트랜잭션을 연결하고 실패 시 업무 보상을 수행하는 패턴이다. 각 로컬 커밋은 보이므로 전체 작업이 하나의 ACID 트랜잭션처럼 원자적으로 관측되는 것은 아니다. 보상이 격리성을 복원하지도 않는다. 아래 주문 흐름은 특정 기업의 구현이 아닌 학습용 설계다.

모놀리스라도 외부 결제 HTTP 호출은 로컬 DB 롤백에 참여하지 않는다. 반대로 DB가 여러 개라는 이유만으로 분산 원자적 커밋이 불가능한 것도 아니다. 자원과 프로토콜의 지원 범위를 확인해야 한다.

| 관점 | 2PC, Two-Phase Commit(2단계 커밋) | Saga |
|---|---|---|
| 원자성 | 참여 자원의 커밋 결정을 조정 | 단계별 커밋과 의미적 보상 |
| 격리성 | 2PC 자체가 전역 직렬성을 보장하지 않음 | 중간 상태와 경쟁 작업을 업무 모델로 통제 |
| 장애·가용성 | 준비 후 결정 확인 불가 시 대기 가능; 복구 구현에 따라 다름 | 독립 처리 가능하지만 의존 서비스 장애 시 진행·보상도 멈출 수 있음 |
| 처리량·확장 | 참여자 지연과 잠금 보유 부담 | 짧은 로컬 거래 대신 메시지·상태 저장·대사 비용 |
| 외부 자원 | 참여 프로토콜 지원 필요 | 외부 멱등성·조회·보상 계약 필요 |

“2PC=CP, Saga=AP”로 CAP 분류를 붙이지 않는다. 서로 다른 문제의 보장을 섞는 표현이다. 지원 자원 사이 강한 원자적 커밋이 필요하면 2PC를 검토하고, 장시간 물류 과정과 외부 서비스를 조정하며 중간 상태를 허용하면 Saga가 후보가 된다.

## 2. 주문 상태와 자원 예약을 먼저 설계한다

학습용 요구는 주문별 중복 결제 방지, 재고 음수 방지, 집하 후 단순 재고 복원 금지다. 재고 예약을 결제보다 먼저 하면 재고 부족 뒤 환불을 줄일 수 있지만 결제 대기 중 재고를 점유한다. 순서는 업무 비용으로 선택한다.

```mermaid
stateDiagram-v2
    [*] --> RESERVING
    RESERVING --> AUTHORIZING: 예약 성공
    RESERVING --> REJECTED: 재고 부족 확정
    AUTHORIZING --> READY: 결제 승인 확정
    AUTHORIZING --> PAYMENT_UNKNOWN: 응답 유실
    PAYMENT_UNKNOWN --> READY: 대사로 승인 확인
    PAYMENT_UNKNOWN --> COMPENSATING: 미승인 확정
    AUTHORIZING --> COMPENSATING: 승인 실패 확정
    READY --> HANDED_OVER: 집하 확정
    READY --> COMPENSATING: 취소 승인
    COMPENSATING --> CANCELED: 필요한 보상 모두 확인
    COMPENSATING --> NEEDS_REVIEW: 자동 처리 한도 초과
    HANDED_OVER --> RETURN_REQUESTED: 출고 후 취소 요청
```

READY에서 집하와 취소가 경쟁하면 양쪽이 동시에 성공하지 않도록 같은 권위 있는 상태의 조건부 전이로 조정한다. 창고 작업자·운송사의 물리적 집하 사실이 시스템보다 늦게 도착할 수 있으므로 출고 승인과 실물 스캔의 운영 절차도 필요하다.

> **면접 포인트 — 예약은 격리성의 대안 설계 중 하나다**
>
> 예약 상태, 주문 버전, 허용 전이, 가용 재고 계산으로 다른 작업이 중간 상태를 잘못 소비하지 않게 한다. 결제 중인 예약의 만료와 늦은 결제 성공이 경쟁하면 무조건 재고를 해제하지 말고 결제 대사·취소 또는 재예약 정책으로 분기한다.

## 3. Pivot은 단순히 마지막 API 호출이 아니다

Pivot Transaction(전환점 거래)은 보상 가능한 구간에서 앞으로 완료해야 하는 구간으로 넘어가는 업무 경계다. 이후 단계를 재시도로 완료할 수 있다는 전제가 중요하며, 외부의 영구적 거절까지 “반드시 성공”한다고 가정하지 않는다. 예외 경로가 있다면 별도 해결 절차가 필요하다.

| 단계 | 취소·보상의 의미 | 주의 |
|---|---|---|
| 재고 예약 | 해당 예약을 해제 | 조건부 상태 전이와 수량 복원을 같은 거래로 처리 |
| Authorization(결제 승인·한도 확보) | 승인 취소 | Capture(매입·청구 확정)와 다르며 만료 조건 확인 |
| Capture | 환불이라는 새로운 거래 | 수수료·처리 시간·부분 환불·실패 가능 |
| 운송장 발행 | 제공자 계약에 따른 라벨 취소 | 실물 집하와 동일한 확정점이 아님 |
| 실물 집하 | 회수·반품 절차 | 원위치에 즉시 판매 가능 재고를 더하면 안 됨 |

운송장 발행을 항상 비가역이라고 부르거나 모든 비가역 작업을 맨 끝에 옮기면 해결된다고 말하지 않는다. 발행 취소 가능성, 집하 시점, 환불 정책은 외부 계약과 업무 정의에 달린다. 고객에게 보낸 알림도 지울 수 없으므로 중간 상태에 맞는 문구가 필요하다.

## 4. 조정 방식 선택

Choreography(이벤트 안무 방식)는 서비스들이 이벤트에 반응하며 흐름을 이어간다. Orchestration(중앙 조정 방식)은 조정자가 상태와 명령을 관리한다. 단계 수 4개를 기계적인 선택 기준으로 삼지 않는다.

| 기준 | Choreography | Orchestration |
|---|---|---|
| 변경 | 이벤트 계약과 구독자 영향 분석 | 조정 흐름과 각 서비스 명령 계약 변경 |
| 관측 | 분산된 실행을 Saga ID로 연결 | 중앙 진행 상태를 기준으로 추적 |
| 복구 | 각 서비스의 진행 의도와 중복 처리 필요 | 조정 상태·명령의 영속성과 다중 작업자 경쟁 제어 필요 |
| 비용 | 순환 이벤트·암묵적 순서 위험 | 조정 계층의 운영·버전 변경 비용 |

중앙 조정자는 복제된 영속 저장소와 여러 작업자로 구현할 수 있으므로 항상 단일 프로세스 장애점은 아니다. 반대로 중앙화 자체가 보상 로직의 정확성을 보장하지 않는다.

## 5. 결제 승인 직후 조정자가 죽으면

`결제 호출 → 성공 응답 → 상태 저장` 사이에는 장애 간격이 있다. 상태만 저장해도 다음 단계부터 정확히 재개할 수 있다는 주장은 이 간격을 놓친다. 호출 전에 안정적인 명령 식별자와 실행 의도를 저장한다.

```mermaid
sequenceDiagram
    participant O as 조정자
    participant DB as Saga DB
    participant W as 실행 작업자
    participant P as 결제 제공자
    O->>DB: 상태 버전 전이와 결제 명령 Outbox를 같은 거래로 커밋
    W->>P: order-42-auth-v1 멱등 키로 요청
    P->>P: 승인 성공
    Note over W,P: 응답 저장 전 작업자 종료 가능
    W->>DB: 재시작 후 미완료 명령 확인
    W->>P: 같은 키로 재요청 또는 결과 조회
    P-->>W: 기존 승인 결과
    W->>DB: 결과와 다음 명령을 같은 거래로 기록
```

멱등 키는 네트워크 시도마다 바꾸지 않는다. 명령의 업무 개정판과 함께 고정하고 요청 본문 해시로 같은 키·다른 내용 충돌을 거절한다. 결제 제공자의 보존 기간을 넘긴 재요청은 원래 결과를 보장하지 않을 수 있다. 멱등 재요청·조회가 지원되지 않으면 불명 결과를 자동 실패로 처리하지 않고 대사로 넘긴다.

아래 PostgreSQL 예시는 결과 수신 뒤 **상태 전이와 다음 명령 저장**을 하나의 트랜잭션으로 묶는 핵심만 보인다. `:...`는 바인딩 표기이며 상태 행은 Saga별 하나, Outbox 명령 ID는 UNIQUE라고 가정한다.

```sql
BEGIN;
WITH advanced AS (
  UPDATE saga_state
  SET state = 'READY', version = version + 1
  WHERE saga_id = :saga_id AND state = 'AUTHORIZING'
    AND version = :expected_version
  RETURNING saga_id, version
)
INSERT INTO outbox(command_id, saga_id, command_type)
SELECT :next_command_id, saga_id, 'PREPARE_SHIPMENT'
FROM advanced;
-- 영향 행 수 0이면 이미 처리/다른 전이/버전 충돌을 조회해 분기한다.
-- UNIQUE 충돌 등 오류가 나면 전체 롤백한다.
COMMIT;
```

이 SQL에 PAYMENT_UNKNOWN 분기나 외부 호출 멱등성까지 포함된 것은 아니다. 결과 메시지 식별자, 현재 명령 ID, 공급자 결과의 진위를 검증한 뒤 허용 전이를 선택해야 한다. 상태를 바꾼 뒤 다음 명령을 별도로 발행하면 다시 이중 쓰기 간격이 생긴다.

## 6. 보상 실패는 해결할 업무 부채로 남긴다

보상은 원래 데이터 전체를 과거 값으로 덮어쓰지 않는다. 다른 주문의 정상 변경을 지우지 않도록 원래 예약·결제 거래를 참조해 필요한 효과만 상쇄한다. 순서는 보통 의존성을 역으로 따르지만 독립 보상은 병렬 실행하거나 위험한 자원부터 해제할 수 있다.

재시도 가능한 오류는 횟수·총 기한·무작위 지연을 두고 반복한다. 비재시도 오류나 기한 초과는 `NEEDS_REVIEW`에 사유, 외부 거래 ID, 담당자, 다음 확인 시각을 영속화한다. DLQ(Dead Letter Queue, 자동 처리가 중단된 메시지 보관 큐)와 알림은 탐지 수단이며 해결 완료가 아니다. 알림 전 프로세스가 죽어도 다시 발견할 주기적 스캔이 필요하다.

가상의 주문 유입 100건/초, 전체 처리 평균 3초라면 안정 상태 진행 중 주문은 약 300개다. 외부 장애로 평균 60초가 되면 약 6,000개다. 단순한 Little의 법칙 예시이며 실제 재시도 폭주·긴 꼬리·유입 제어에 따라 달라진다. 오래된 미완료 주문 수, 보상 체류 시간, 외부 결과 불명 수를 핵심 운영 지표로 둔다.

## 참고 자료

- [Saga 패턴과 격리성 대응](https://microservices.io/patterns/data/saga.html)
- [Pivot과 Saga 구성](https://learn.microsoft.com/en-us/azure/architecture/patterns/saga)
- [보상의 순서와 실패 처리](https://learn.microsoft.com/en-us/azure/architecture/patterns/compensating-transaction)
- [원자적 커밋과 복구 논문](https://lamport.azurewebsites.net/video/consensus-on-transaction-commit.pdf)
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)
- [Stripe 멱등 요청](https://docs.stripe.com/api/idempotent_requests), [승인과 Capture 분리](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method)$review_7$
WHERE slug = 'backend-architecture-04-saga' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_8$## 1. Dual-write 문제 (이중 쓰기)

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

> **부분 검수 — 2026-09-12**: 기존 두 번째 질문의 “유실 0”은 내구성과 재시도가 작동한다는 조건을 생략한 표현이다. 답변에서는 이 전제를 먼저 지적한다. 질문·답변 연결은 유지했다. 참고: [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html), [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/).$review_8$
WHERE slug = 'backend-architecture-06-outbox-idempotency' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_9$## 1. 40분 면접의 판단 기준

학습용 주문·결제·재고·배송 서비스는 각각 DB를 갖고 외부 결제와 운송사를 호출한다. 첫 답변에서는 허용 중간 상태, 취소 마감, 결제 결과 불명 처리, 자동 복구 기한을 확인한다. 이 카드는 특정 기업의 내부 설계를 주장하지 않는다.

| 라운드 | 시간 예시 | 평가할 판단 |
|---|---:|---|
| R1 선택 | 8분 | 원자적 커밋·격리성과 업무 보상의 차이 |
| R2 보상 실패 | 10분 | 반복해도 안전한 자원 전이와 미해결 업무 관리 |
| R3 결제·이벤트 간격 | 12분 | 외부 효과, 로컬 기록, 메시지 전달의 세 경계 |
| R4 집하 후 취소 | 10분 | 물리 재고와 소프트웨어 상태의 대응 |

> **면접 포인트 — 질문의 전제도 검증한다**
>
> 기존 확인 질문의 “불일치로 고착되지 않음을 증명”은 무조건적 복구 보장을 요구하는 것으로 받아들이지 않는다. 영구적인 외부 장애나 응답 없는 운영자를 전제로는 최종 해결을 보장할 수 없다. 안전성, 탐지, 복구 가능 조건을 구분하는 답을 평가한다.

## 2. R1 — “2PC로 묶으면 되지 않나요?”

**답변 예시:** “2PC(Two-Phase Commit, 2단계 커밋)는 참여 자원의 커밋 결정을 조정하지만 전역 격리성을 자동으로 만들지는 않습니다. 이번 외부 결제·운송사 API가 그 프로토콜에 참여하는지 먼저 확인합니다. 장시간 처리의 중간 상태를 허용한다면 Saga(사가)와 예약 상태를 고려하겠습니다. 모든 자원이 원자적 커밋을 지원하고 중간 노출을 허용할 수 없다면 다른 선택이 가능합니다.”

**후속 압박:** “그럼 Saga가 더 빠르다는 근거는요?”

짧은 로컬 거래로 잠금 보유를 줄일 수 있지만 단계별 메시지·영속 기록·재시도가 추가된다. 무조건적인 처리량 우위를 주장하지 않는다. 가상 유입 100건/초에 평균 체류 5초라면 진행 중 약 500건이고, 50초면 약 5,000건이다. 완료 지연·미완료 수·DB 경합·외부 제한을 같은 부하에서 비교한다.

**오답:** “2PC는 CP, Saga는 AP”, “서비스가 4개면 무조건 중앙 조정”, “보상이 격리성을 메운다.” CAP의 의미와 커밋 프로토콜을 섞거나 중간 상태 경쟁을 생략하는 답이다.

## 3. R2 — “보상도 실패하면 무한 루프 아닌가요?”

**60초 답변 예시:** “보상은 별도의 업무이므로 실패할 수 있습니다. 원래 예약이나 결제 ID를 기준으로 중복 효과를 막고, 일시 장애는 총 기한과 횟수를 제한해 재시도합니다. 초과하면 원인·외부 거래·담당자·다음 확인 시각을 NEEDS_REVIEW로 영속화합니다. DLQ와 알림만으로 복구됐다고 계산하지 않고, 미해결 상태를 주기적으로 재검색해 대사·운영 처리를 이어갑니다. 외부 서비스 복구와 실제 운영 조치라는 전제 아래 해결을 추적하며, 영구 장애에서도 반드시 완료된다고 약속하지 않습니다.”

```mermaid
stateDiagram-v2
    [*] --> COMPENSATING
    COMPENSATING --> RETRY_WAIT: 일시 장애
    RETRY_WAIT --> COMPENSATING: 다음 실행 시각 도달
    COMPENSATING --> RESOLVED: 보상 결과 확인
    COMPENSATING --> NEEDS_REVIEW: 기한 초과 또는 영구 거절
    NEEDS_REVIEW --> COMPENSATING: 승인된 재실행
    NEEDS_REVIEW --> RESOLVED: 대사와 업무 조치 완료 확인
```

**후속 압박:** “재고 해제에 성공했는데 응답 전에 죽었습니다. 다시 +1 하면요?”

그 방식은 중복 복원이다. 예약 상태 전이가 성공한 경우에만 같은 트랜잭션에서 수량을 복원한다. 아래 PostgreSQL 예시는 단일 SKU 예약이며 `reservation.id`와 `stock.sku_id`는 기본 키, 예약 수량은 양수, SKU는 유효한 외래 키라고 가정한다.

```sql
BEGIN;
WITH released AS (
  UPDATE reservation SET state = 'RELEASED'
  WHERE id = :reservation_id AND state = 'RESERVED'
  RETURNING sku_id, qty
)
UPDATE stock s SET available = s.available + r.qty
FROM released r WHERE s.sku_id = r.sku_id;
-- 영향 행 수 1이면 이번 해제 성공.
-- 0이면 예약을 조회해 이미 RELEASED인지, CONFIRMED인지, 없는지 구분한다.
COMMIT;
```

서로 다른 두 작업자가 호출해도 예약의 `RESERVED → RELEASED`는 한 번만 성공해야 한다. 결제 확정도 같은 예약 상태에서 `CONFIRMED`로 경쟁한다면 어느 전이가 이겼는지에 따라 후속 정책이 달라진다. 모든 0행 결과를 성공으로 숨기면 안 된다.

**추가 압박:** “DB에 NEEDS_REVIEW를 쓴 직후 알림 전에 죽으면요?”

미해결 레코드의 주기적 스캔 또는 같은 거래의 알림 Outbox(발행 의도 테이블)가 필요하다. 알림 수신과 담당자 확인도 해결 완료와 별도다.

## 4. R3 — “고객 돈은 빠졌는데 재고 이벤트가 없습니다”

문제를 세 구간으로 나눈다.

| 장애 위치 | 남을 수 있는 상태 | 대응 |
|---|---|---|
| 외부 Capture 성공 후 로컬 기록 전 | 외부만 결제됨 | 호출 전 명령 저장, 고정 멱등 키, 외부 결과 조회·대사 |
| 로컬 결과 기록 후 이벤트 발행 전 | DB만 성공, 후속 미진행 | 결과와 Outbox를 같은 DB 거래에 기록 |
| 발행 후 처리 완료 표시 전 | 재발행·재소비 | Inbox(수신 중복 기록)와 업무 키, 상태 전이로 반복 효과 방지 |

**답변 예시:** “Outbox는 로컬 결과와 발행 의도의 원자성을 보장합니다. 외부 결제 성공이 아직 로컬에 기록되지 않은 간격은 Outbox 하나로 해결하지 못합니다. 고정된 실행 명령을 먼저 저장하고 결과가 불명하면 조회·대사를 합니다. 이벤트가 남아도 릴레이·보관·복구가 제대로 동작해야 전달이 진행됩니다. 중복 실행도 예상합니다.”

```mermaid
sequenceDiagram
    participant S as Saga 실행자
    participant DB as 로컬 DB
    participant P as 결제 제공자
    participant I as 재고 서비스
    S->>DB: 명령 ID와 요청 해시 저장
    S->>P: 고정 멱등 키로 Capture
    P->>P: 성공
    Note over S,P: 여기서 종료하면 결과 불명
    S->>P: 재시작 후 조회 또는 동일 키 재요청
    P-->>S: 기존 거래 결과
    S->>DB: 결과와 다음 단계 Outbox 원자 기록
    S->>I: 반복 전달 가능한 재고 명령
    I->>I: 업무 키와 예약 상태로 중복 방지
```

**후속 압박:** “5분 멈췄으면 자동 환불하면 되죠?”

시간 초과는 실패 확정이 아니다. 재고 예약·출고가 이미 성공했지만 결과만 늦을 수 있다. 현재 외부 거래와 예약·출고 상태를 대조하고 권위 있는 취소 전이로 더 이상의 집하를 차단한 뒤 환불 여부를 결정한다. 무조건 환불과 늦은 출고가 동시에 진행되면 돈도 물건도 잃는다.

대사에는 주문 ID, 결제 제공자 거래 ID, 명령 ID, 예약 ID, 운송장 개정판을 연결한다. 중복·누락·상태 불일치의 종류를 기록하고, 늦게 온 이벤트를 다시 재생할 때 이미 수행한 환불·알림을 반복하지 않는다.

## 5. R4 — “이미 트럭에 실렸는데 취소하면?”

**답변 예시:** “Pivot Transaction(전환점 거래)을 집하 승인·실물 인계 절차와 연결합니다. 운송장 생성 자체가 항상 비가역인 것은 아닙니다. 집하 후에는 DB의 예약 해제처럼 원창고 판매 가능 수량을 증가시키지 않습니다. 취소 요청을 반품·배송 중지·회수라는 별도 흐름으로 처리하고, 입고와 검수 결과에 따라 판매 가능·격리·폐기로 분류합니다. 환불 시점은 재고 복원 시점과 별도의 정책입니다.”

| 관측 | 처리 방향 | 검증할 조건 |
|---|---|---|
| 집하 전 취소가 권위 있는 상태 전이에서 승리 | 예약 해제·승인 취소 등 | 창고 집하 권한도 취소됐는지 |
| 집하 완료 뒤 취소 | Reverse Logistics(역물류) 생성 | 이동 중·반품 중 재고로 추적 |
| 취소 뒤 늦은 집하 스캔 | 물리 사실 대사와 예외 처리 | 단순히 늦었다고 사실을 버리지 않기 |
| 반품 입고 | 검수 뒤 재분류 | 중복 입고 이벤트가 수량을 중복 증가시키지 않기 |

**후속 압박:** “Pivot 뒤는 재시도로 반드시 성공해야 한다면서 영구 실패는요?”

재시도 가능한 후속 단계라는 설계 전제를 설명하되, 현실의 분실·영구 거절은 별도 예외 업무로 해결한다. 패턴의 이상적 전제를 현실에 무조건 적용하지 않는다.

## 6. 평가와 실패 주입

시니어 답변은 패턴 이름의 개수보다 **불변식과 장애 간격을 연결하는지**로 평가한다. 보상 완료, 운영 개입 대기, 외부 결과 불명을 구분하고 담당자 알림을 정합성 회복으로 계산하지 않는다.

검증할 시나리오는 재고 해제 중복 호출, 결제 성공 뒤 로컬 저장 전 종료, Outbox 발행 뒤 완료 표시 전 종료, 취소와 집하 경쟁, 반품 입고 중복이다. 기대 결과는 각각 수량 1회 복원, 중복 청구 없는 결과 회수, 중복 후속 효과 방지, 물리 상태에 맞는 취소 분기, 검수 수량 1회 반영이다. 이 카드의 모든 외부 장애를 실제 제공자에 주입한 것은 아니며, 구현 시 계약 테스트와 상태 전이 테스트로 확인한다.

## 참고 자료

- [Saga와 격리성](https://microservices.io/patterns/data/saga.html)
- [보상 실패·순서](https://learn.microsoft.com/en-us/azure/architecture/patterns/compensating-transaction)
- [Pivot과 단계 분류](https://learn.microsoft.com/en-us/azure/architecture/patterns/saga)
- [Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)
- [Stripe 멱등 요청](https://docs.stripe.com/api/idempotent_requests)$review_9$
WHERE slug = 'backend-architecture-07-interview-saga' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_10$> **검수 기준 — 2026-09-12**
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
- [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/) — 소비 위치와 외부 시스템 처리 경계.$review_10$
WHERE slug = 'backend-architecture-11-idempotent-consumer-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_11$## 1. 격리수준은 제품·문장·트랜잭션 경계로 설명한다

기준은 **MySQL 8.4 InnoDB와 PostgreSQL 17**이다. Dirty Read(미커밋 읽기), Non-repeatable Read(반복 불가 읽기), Phantom Read(팬텀 읽기)는 각각 남의 미커밋 값, 같은 행의 값 변화, 같은 조건의 결과 집합 변화를 뜻한다. 팬텀이 없다는 사실만으로 모든 실행이 직렬화 가능하다고 결론 내리지 않는다.

| 격리수준 | 표준의 최소 허용 범위 | 제품에서 확인할 점 |
|---|---|---|
| READ UNCOMMITTED | 세 이상현상 허용 | PostgreSQL은 RC처럼 동작 |
| READ COMMITTED, RC | 미커밋 읽기 방지 | 두 DB의 일반 읽기는 문장별 스냅샷 |
| REPEATABLE READ, RR | 미커밋·반복 불가 읽기 방지, 팬텀 허용 가능 | 두 DB의 일반 스냅샷 읽기는 팬텀을 방지; 쓰기 의미는 다름 |
| SERIALIZABLE | 직렬 실행과 동등한 결과 | 대기·교착·직렬화 실패의 처리까지 설계 |

MySQL 기본은 RR, PostgreSQL 기본은 RC이지만 세션 설정을 직접 확인한다. PostgreSQL RR도 서로 다른 행을 바꾸는 Write Skew(쓰기 편향)를 허용할 수 있다. SERIALIZABLE에서 올바른 업무 판단을 같은 트랜잭션에 넣고 실패한 전체 작업을 재시도하면 이런 비직렬 실행을 배제할 수 있다.

```sql
SELECT @@transaction_isolation; -- MySQL
SHOW transaction_isolation;    -- PostgreSQL
```

## 2. InnoDB RR: 스냅샷 읽기와 잠금 읽기는 다르다

일반 SELECT는 MVCC(Multi-Version Concurrency Control, 다중 버전 동시성 제어)의 스냅샷을 사용한다. RR에서 첫 일관 읽기가 기준을 만들고 이후 재사용한다. 다른 세션의 INSERT를 막아서 같은 결과를 얻는 것이 아니다. 자기 트랜잭션의 변경은 보일 수 있으므로 단순히 모든 읽기가 과거 DB 전체의 사진이라는 설명도 부족하다.

`SELECT ... FOR UPDATE`는 현재 잠글 수 있는 상태를 읽는다. 범위 검색은 실행계획에 따라 레코드와 갭을 잠가 해당 범위의 INSERT를 대기시킬 수 있다. 같은 트랜잭션에서 일반 읽기와 잠금 읽기를 섞으면 서로 다른 상태를 관측할 수 있다.

```mermaid
sequenceDiagram
    participant A as 세션 A InnoDB RR
    participant DB as orders
    participant B as 세션 B
    A->>DB: 일반 SELECT로 PENDING 목록 읽기
    B->>DB: 새 PENDING 주문 INSERT 후 COMMIT
    A->>DB: 같은 일반 SELECT
    DB-->>A: 기존 스냅샷의 목록
    A->>DB: 같은 조건 FOR UPDATE
    DB-->>A: 새 커밋을 포함한 잠금 읽기
```

PostgreSQL RR의 잠금 읽기는 InnoDB의 최신 읽기와 같지 않다. 스냅샷 이후 바뀐 행을 잠그거나 갱신하려 하면 직렬화 실패가 날 수 있다. PostgreSQL SERIALIZABLE의 SSI(Serializable Snapshot Isolation, 직렬화 가능 스냅샷 격리)는 읽기·쓰기 의존성을 감시하지만 기존 쓰기 락을 없애지 않는다.

> **면접 포인트**
>
> “InnoDB RR은 팬텀을 막는다” 다음에 읽기 종류를 붙인다. 일반 SELECT의 스냅샷 유지와 범위 잠금의 INSERT 차단은 다른 메커니즘이다. `FOR UPDATE`를 트랜잭션 밖에서 실행해 문장 직후 잠금이 풀리면 뒤따르는 업무를 보호하지 못한다.

## 3. 공유·배타·갭 잠금의 범위

Shared Lock(S, 공유 잠금)끼리는 호환되며 Exclusive Lock(X, 배타 잠금)은 같은 레코드의 다른 S/X와 충돌한다. 이는 단순화한 레코드 잠금 표다. PostgreSQL은 `FOR KEY SHARE` 등 추가 행 잠금 모드를 제공하므로 모든 잠금을 이 두 가지로 환원하지 않는다.

| InnoDB 잠금 | 대상과 효과 | 주의점 |
|---|---|---|
| Record Lock | 인덱스 레코드 | 기존 행의 고유 키 동등 검색은 갭 없이 처리 가능 |
| Gap Lock(갭 잠금) | 레코드 사이 삽입 위치 | 갭 잠금끼리는 공존할 수 있으나 INSERT는 대기 가능 |
| Next-key Lock(넥스트키 잠금) | 레코드와 그 앞의 갭 | RR 범위 검색에서 잠금 범위가 논리 조건보다 넓을 수 있음 |
| Intention Lock(의도 잠금) | 테이블 수준의 하위 잠금 의도 | IX 획득 자체가 테이블 전체의 배타 잠금은 아님 |
| Metadata Lock(메타데이터 잠금) | 테이블 정의 접근 | 일반 DML도 획득하므로 오래 열린 트랜잭션이 DDL을 막을 수 있음 |

```sql
-- MySQL 8.4, 독립 실습 DB에서 준비
CREATE TABLE orders (
  id BIGINT PRIMARY KEY,
  status VARCHAR(20) NOT NULL,
  KEY ix_orders_status (status)
) ENGINE=InnoDB;
INSERT INTO orders VALUES (10, 'PENDING'), (20, 'SHIPPED');

-- 세션 A
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT * FROM orders WHERE status='PENDING' FOR UPDATE;
-- A를 열린 상태로 둔다.

-- 세션 B: 별도 연결에서 실행
START TRANSACTION;
INSERT INTO orders VALUES (15, 'PENDING');
-- A가 잠근 범위에 삽입하려 하므로 대기한다.
-- 세션 A에서 COMMIT한 뒤 B도 COMMIT한다.
```

정확한 경계는 실제 인덱스·데이터·실행계획과 `performance_schema.data_locks`, `data_lock_waits`로 확인한다. 인덱스가 없으면 전체 스캔으로 잠금과 삽입 차단 범위가 크게 넓어질 수 있다. 이를 “DB가 테이블 X 락으로 승격했다”와 혼동하지 않는다. RC에서는 비일치 행 잠금 해제와 일반 검색의 갭 잠금 축소가 있지만 외래 키·중복 키 검사 등 예외가 있다.

일반 SELECT도 항상 모든 잠금과 무관하지는 않다. InnoDB SERIALIZABLE의 조건별 잠금 읽기 전환, 두 DB의 스키마 관련 잠금과 DDL 대기를 별도로 본다.

## 4. 여러 SKU 차감: 순서를 명시하고 실패는 전체 롤백한다

Deadlock(교착 상태)은 잠금을 보유한 세션들이 서로를 순환 대기하는 상태다. A→B와 B→A 순서의 주문 차감이 대표적이다. 아래는 양수 수량 검증과 중복 SKU 수량 합산을 완료한 주문이 A 2개, B 1개를 차감하는 예다. `sku_id`는 기본 키이며 모든 차감 경로가 같은 정렬 순서를 따른다.

```sql
BEGIN;
-- 애플리케이션이 정렬한 SKU마다 한 문장씩 호출한다.
UPDATE stock SET qty = qty - 2 WHERE sku_id = 'A' AND qty >= 2;
-- 영향 행 수가 0이면 즉시 ROLLBACK 후 재고 부족 처리
UPDATE stock SET qty = qty - 1 WHERE sku_id = 'B' AND qty >= 1;
-- 영향 행 수가 0이면 A 차감도 포함해 ROLLBACK
COMMIT;
```

영향 행 수 검사는 애플리케이션 책임이며 위 주석이 SQL 분기를 실행하는 것은 아니다. 조건부 UPDATE도 내부적으로 쓰기 잠금을 사용한다. `ORDER BY`가 있는 단일 범위 SELECT의 결과 순서만으로 모든 실행계획의 실제 잠금 획득 순서를 보장한다고 설명하지 않는다. 명시적인 키 순차 접근도 외래 키·보조 인덱스·다른 코드 경로에서 생기는 모든 교착을 없애지는 않는다.

```mermaid
sequenceDiagram
    participant T1 as 주문 1
    participant A as SKU A
    participant B as SKU B
    participant T2 as 주문 2
    T1->>A: UPDATE 잠금 획득
    T2->>A: UPDATE 대기
    T1->>B: UPDATE 잠금 획득
    T1->>T1: COMMIT
    A-->>T2: 잠금 획득 후 조건 재평가
    T2->>B: UPDATE
    T2->>T2: COMMIT
```

## 5. 교착과 시간 초과는 복구 단위가 다르다

InnoDB의 기본 교착 감지가 활성화돼 있으면 희생 트랜잭션을 롤백하며 보통 오류 1213을 받는다. 감지를 끈 구성은 시간 초과에 의존할 수 있다. 잠금 대기 시간 초과 1205는 기본적으로 문장만 롤백할 수 있으므로 1213과 같은 상태라고 단정하지 않는다. 애플리케이션은 실패한 주문의 전체 트랜잭션을 명시적으로 롤백한 뒤 새 경계에서 다시 시작한다.

PostgreSQL의 교착 `40P01`, 직렬화 실패 `40001`도 새 트랜잭션에서 읽기·판단부터 재시도한다. 재시도 횟수와 총 기한을 제한하고 무작위 지연을 둔다. 가상의 최대 3회 정책은 무한 재시도를 막기 위한 예시이며 서비스 지연 예산에 맞춰 정한다. 재고 부족 같은 정상 업무 거절은 교착 재시도와 분리한다.

> **실무 함정 — 성공 여부가 불명확한 커밋**
>
> DB 연결이 커밋 응답 전에 끊기면 “롤백됐겠지” 하고 무조건 다시 차감하지 않는다. 주문별 고유 예약 키로 결과를 조회하고 중복 처리를 막는다. 외부 HTTP 호출은 재시도할 DB 트랜잭션 안에 넣지 않는다.

진단은 InnoDB의 `SHOW ENGINE INNODB STATUS`와 잠금 대기 표, PostgreSQL의 `pg_locks`·`pg_stat_activity`에서 시작한다. 대기 시간뿐 아니라 실패한 전체 거래 수, 재시도 후 성공률, 최종 재고 음수·중복 예약 여부를 측정한다.

## 참고 자료

- [MySQL 8.4 일관 읽기](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL 8.4 잠금 종류](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)
- [MySQL 8.4 문장별 잠금](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html)
- [MySQL 8.4 교착 처리](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)
- [MySQL 8.4 오류 처리](https://dev.mysql.com/doc/refman/8.4/en/innodb-error-handling.html)
- [PostgreSQL 17 격리수준](https://www.postgresql.org/docs/17/transaction-iso.html), [명시적 잠금](https://www.postgresql.org/docs/17/explicit-locking.html)$review_11$
WHERE slug = 'database-02-lock-isolation' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_12$## 1. 버전의 저장 위치와 가시성은 다른 문제다

기준은 **MySQL 8.4 InnoDB와 PostgreSQL 17**이다. MVCC(Multi-Version Concurrency Control, 다중 버전 동시성 제어)는 과거 행 버전에서 자기 읽기에 보이는 값을 선택한다. 일반 스냅샷 읽기와 쓰기의 경합을 줄이지만 쓰기 잠금·잠금 읽기·DDL(데이터 정의 언어) 대기까지 없애지는 않는다.

InnoDB의 `DB_TRX_ID`는 행을 마지막으로 변경한 트랜잭션, `DB_ROLL_PTR`은 Undo Log(실행 취소 로그)를 통해 이전 상태를 재구성할 때 사용하는 정보다. 단순히 “내 트랜잭션 ID보다 작으면 보인다”로 판단할 수 없다. 먼저 시작했어도 아직 커밋하지 않은 트랜잭션이 있기 때문이다. Read View(읽기 뷰)는 경계와 당시 활성 트랜잭션 정보를 이용해 가시성을 판정한다.

| InnoDB 일반 일관 읽기 | 읽기 뷰 생성 | 결과 |
|---|---|---|
| REPEATABLE READ, RR | 보통 첫 일관 읽기 때 만들고 재사용 | 뒤에 커밋된 다른 거래를 반복 SELECT에 반영하지 않음 |
| READ COMMITTED, RC | 일관 읽기마다 새로 생성 | 두 SELECT 사이 다른 커밋이 반영될 수 있음 |
| 명시적 스냅샷 시작 | 지원 격리수준에서 WITH CONSISTENT SNAPSHOT 사용 | 일반 BEGIN과 생성 시점이 다를 수 있음 |

이 비교는 일반 SELECT 기준이다. 격리수준 전체가 읽기 뷰 생성 시점 하나만으로 구현되는 것은 아니며 범위 잠금·갱신 규칙도 다르다. 자기 트랜잭션의 변경은 이후 읽기에 보일 수 있다.

```mermaid
sequenceDiagram
    participant R as 읽기 세션 RR
    participant DB as InnoDB
    participant W as 쓰기 세션
    R->>DB: START TRANSACTION
    W->>DB: qty를 9로 변경 후 COMMIT
    R->>DB: 첫 일반 SELECT
    DB-->>R: 9, 이 시점에 읽기 뷰 생성
    W->>DB: qty를 8로 변경 후 COMMIT
    R->>DB: 두 번째 일반 SELECT
    DB-->>R: Undo로 재구성한 9
```

> **면접 포인트**
>
> RR의 기준을 무조건 BEGIN 시점이라 말하지 않는다. 첫 일관 읽기 전에 커밋된 값은 보일 수 있다. RC에서는 두 번째 읽기 뷰에 새 커밋이 포함돼 8을 읽을 수 있다.

## 2. Undo와 PostgreSQL 행 버전의 수명

InnoDB의 Update Undo는 롤백과 과거 읽기에 사용한다. 커밋된 과거 정보를 어떤 읽기 뷰도 필요로 하지 않으면 Purge(과거 버전 정리)가 회수할 수 있다. Insert Undo와 Update Undo의 수명이 같지는 않다. 보조 인덱스 키가 바뀌면 기존 항목이 삭제 표시되고 새 항목이 생길 수 있으므로 “보조 인덱스는 항상 버전당 하나뿐”도 틀리다.

PostgreSQL UPDATE는 Heap(테이블 행 저장 영역)에 새 튜플 버전을 만든다. 옛 버전은 기존 스냅샷에 여전히 필요할 수 있어서 변경 직후 곧바로 회수 가능한 Dead Tuple(죽은 튜플)이라고 부르면 부정확하다. 가시성 판단에는 생성·삭제 트랜잭션 정보와 커밋 상태, 스냅샷 등이 관여한다.

| 항목 | InnoDB | PostgreSQL |
|---|---|---|
| 과거 상태 | 주로 Undo에서 재구성 | Heap의 기존 튜플 버전 |
| 회수 지연 원인 | 필요한 읽기 뷰, Purge 처리 지연 등 | 오래된 스냅샷·복제 관련 보존 경계·정리 처리량 등 |
| 정리 | Purge | VACUUM·Autovacuum·페이지 Pruning(불필요 버전 정리) |
| 증상 | Undo 증가·긴 버전 탐색 | Heap/인덱스 팽창·불필요한 페이지 접근 |

History List Length는 Undo 바이트 수나 현재 불필요한 행 개수와 동일한 지표가 아니다. 증가 추세, 오래된 거래, Undo 공간, Purge 진행을 함께 본다. 장기 집계를 청크로 끊으면 보존 시간을 줄일 수 있지만 청크 사이 데이터가 변하므로 일관된 전체 집계가 필요한지 먼저 결정한다.

## 3. WAL은 데이터 파일 쓰기를 없애지 않는다

WAL(Write-Ahead Logging, 선행 기록)은 데이터 페이지를 영구 저장하기 전에 그 변경을 복구할 로그부터 영구 저장하는 원칙이다. 동기 커밋에서는 필요한 로그의 저장 완료를 기다리므로 변경된 모든 데이터 페이지를 커밋마다 즉시 쓰지 않아도 된다. 비동기 커밋과 저장 장치의 보장 범위는 별도다.

```mermaid
flowchart LR
    T[트랜잭션 변경] --> L[로그 버퍼와 WAL 또는 Redo]
    T --> P[메모리의 변경된 데이터 페이지]
    L --> F[로그 영구 저장]
    F --> C[동기 커밋 응답]
    F --> D[해당 로그 이후 데이터 페이지 저장 가능]
    P --> D
    D --> K[Checkpoint 진행과 복구 시작 범위 축소]
```

로그는 순차 기록과 Group Commit(여러 거래의 동기화 묶음)에 유리하다. 데이터 페이지의 랜덤 쓰기는 남아 있으며 백그라운드 쓰기와 Checkpoint(복구 기준점) 처리에서 분산된다. 페이지가 오직 Checkpoint 때만 저장되는 것도 아니다. 로그량·스토리지 지연·체크포인트 압력에 따라 병목이 달라진다.

| innodb_flush_log_at_trx_commit | 커밋 때 하는 일 | 장애 의미 |
|---|---|---|
| 1 | 로그를 기록하고 디스크 동기화 | 저장 계층이 보장을 지킨다는 전제로 내구성 강화; Group Commit 가능 |
| 2 | 로그 파일에 쓰지만 커밋마다 디스크 동기화는 하지 않음 | OS·전원 장애로 아직 동기화 안 된 커밋 유실 가능 |

값 2의 주기적 Flush(동기화)는 정확히 1초 이내 손실만 보장하는 계약이 아니다. 설정과 스케줄링에 영향을 받는다. 값 1도 원격 복제본에 반영됐음을 뜻하지 않으며, Binary Log(복제용 이진 로그)를 사용하는 복구·복제 구성은 `sync_binlog` 등도 같이 확인한다. 결제·재고는 허용 가능한 커밋 유실량을 정하고 설정을 선택한다.

## 4. 운송장 UPDATE 지연을 어떻게 진단할까

“초당 수천 번 UPDATE”만으로 VACUUM이 원인이라고 단정하지 않는다. 실행계획 변화, 잠금 대기, 저장 장치 지연, 인덱스 증가, 오래된 스냅샷을 먼저 분리한다. 다음은 PostgreSQL의 읽기 전용 진단 예다.

```sql
SELECT relname, n_live_tup, n_dead_tup,
       n_tup_upd, n_tup_hot_upd, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'shipment_status';

SELECT pid, state, xact_start, backend_xmin, wait_event_type, wait_event
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY xact_start NULLS LAST;

SELECT relname, age(relfrozenxid) AS xid_age
FROM pg_class
WHERE oid = 'shipment_status'::regclass;
```

튜플 수 통계는 추정치이며 누적 HOT 비율은 최근 장애 구간의 비율과 다르다. 같은 간격의 차분으로 비교한다. `backend_xmin`을 붙잡는 세션, Prepared Transaction(준비된 거래), 복제 슬롯의 `xmin`/`catalog_xmin`과 복제 피드백도 확인한다. WAL 보존만 늘어나는 문제와 Heap 정리가 막히는 문제는 구분한다.

## 5. VACUUM·HOT·fillfactor의 적용 조건

HOT(Heap-Only Tuple, 인덱스 항목 추가를 피하는 행 갱신)은 기존 행 페이지에 공간이 있고, 일반 인덱스가 참조하는 컬럼을 갱신하지 않을 때 가능하다. PostgreSQL 17의 BRIN 같은 요약 인덱스에는 별도 예외가 있다. `status`에 B-tree 인덱스가 있는데 status를 매번 바꾸면 fillfactor만 낮춰 해결되지 않는다.

가상의 1,000만 행 테이블에서 기본 예시 임계식 `50 + 0.2 × 행 수`는 약 200만 변경 튜플이다. scale factor를 0.02로 낮춘 예시는 약 20만이다. 이는 VACUUM 시작 후보를 찾는 단순 계산이며 완료 시간을 보장하지 않는다. 실제 통계·워커·I/O(입출력) 예산과 긴 스냅샷 해소를 함께 본다.

```sql
-- 운영 적용 전 쓰기 부하와 공간 증가를 측정할 학습용 설정 예
ALTER TABLE shipment_status SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_threshold = 50,
  fillfactor = 80
);
-- 기존에 꽉 찬 모든 페이지가 이 명령만으로 다시 배치되지는 않는다.
-- VACUUM은 명시적 트랜잭션 블록 밖에서 실행한다.
VACUUM (ANALYZE) shipment_status;
```

일반 VACUUM은 주로 재사용 공간을 만들고 보통 파일 크기 전체를 OS에 반환하지 않는다. VACUUM FULL은 테이블을 재작성하고 강한 잠금과 추가 공간이 필요하다. 통계 갱신은 ANALYZE의 역할이고, VACUUM의 가시성 맵 정리는 Index-Only Scan(인덱스만 이용하는 조회)에도 영향을 준다.

XID(Transaction ID, 트랜잭션 식별자)의 순환 비교 한계 때문에 오래된 행을 Freeze(과거 거래 ID 처리)해야 한다. 갱신이 거의 없는 테이블도 대상이다. 단순히 “32비트 값이 모두 소진될 때 한 번 청소”가 아니며, 오래된 XID·Multixact 연령과 정리 진행을 지속 감시한다.

## 참고 자료

- [MySQL 8.4 다중 버전 구조](https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html)
- [MySQL 8.4 일관 읽기](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL 8.4 로그 동기화 설정](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_flush_log_at_trx_commit)
- [PostgreSQL 17 WAL](https://www.postgresql.org/docs/17/wal-intro.html)
- [PostgreSQL 17 VACUUM 운영](https://www.postgresql.org/docs/17/routine-vacuuming.html)
- [PostgreSQL 17 HOT](https://www.postgresql.org/docs/17/storage-hot.html)$review_12$
WHERE slug = 'database-03-mvcc-internals' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_13$## 1. CAP 정리와 PACELC 확장

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
- [Cassandra Dynamo architecture](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html)$review_13$
WHERE slug = 'database-05-rdbms-vs-nosql' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_14$> **검수 기준 — 2026-09-12**
>
> PostgreSQL 17의 조건부 갱신과 Redis의 원자 실행·복제 경계를 구분한다. 티켓·창고 예제와 수치는 가상 설계이며 특정 기업의 실제 구현을 뜻하지 않는다.

## 1. 수량과 예약 불변식을 함께 지킨다

SKU(Stock Keeping Unit, 재고 관리 단위) A가 한 개 남았다. 요청 두 개가 각각 1을 읽고 0으로 덮어쓰면 DB에는 음수가 없지만 두 주문이 성공할 수 있다. **재고 음수 방지**와 **같은 주문의 중복 예약 방지**는 다른 조건이다.

```mermaid
sequenceDiagram
    participant A as 주문 A
    participant D as stock qty=1
    participant B as 주문 B
    A->>D: SELECT qty=1
    B->>D: SELECT qty=1
    A->>D: UPDATE qty=0
    B->>D: UPDATE qty=0
    Note over D: 수량은 0이나 두 주문이 성공할 수 있음
```

가상 모델에서는 `available = on_hand - reserved`다. 예약은 가용 수량을 점유하고, 출고는 실물 수량을 줄이며 예약 점유를 해제한다. 예약이 영원히 남으면 실제 재고가 있어도 판매하지 못하는 과소판매가 생긴다. TTL(Time To Live, 유효 기간)은 만료 판단 기준이며 자동으로 DB 보상을 실행해주지 않는다.

## 2. 조건부 UPDATE를 기본 후보로 둔다

아래에서 `qty`는 가용 수량이고 `sku`는 고유 키다. 요청 수량은 양의 정수로 검증하고 모든 차감 경로가 같은 규칙을 지킨다고 가정한다.

```sql
UPDATE stock
SET qty = qty - :requested_qty
WHERE sku = :sku
  AND :requested_qty > 0
  AND qty >= :requested_qty;
-- 영향 행 1개: 차감됨. 0개: 품절·SKU 없음·잘못된 요청 중 하나.
-- 주문 성공 응답은 관련 예약 기록까지 커밋된 다음 반환한다.
```

재고 1개에 서로 다른 주문 100개가 한 개씩 요청하면, 같은 행의 조건 검사와 변경이 직렬화되어 한 요청만 차감할 수 있다. UPDATE는 내부적으로 잠금을 사용한다. 락이 없어서 빠른 것이 아니라 `SELECT FOR UPDATE → 앱 판단 → UPDATE`의 왕복을 줄일 수 있는 것이다.

잠금은 일반적으로 트랜잭션 종료까지 유지된다. 뒤에 느린 HTTP 호출을 붙이면 한 문장 차감이라도 짧은 잠금이 아니다. DB 타임아웃·데드락·직렬화 실패는 여전히 가능하므로 업무 실패와 재시도 가능한 오류를 구분한다.

## 3. 비관적·낙관적 잠금과 비교한다

| 방식 | 적합한 조건 | 지불할 비용 |
|---|---|---|
| 조건부 UPDATE | 한 행의 단순 수량 조건 | Hot Row 경합·영향 행 검사 |
| SELECT FOR UPDATE | 읽은 값을 바탕으로 여러 규칙 판단 | 트랜잭션 동안 대기·왕복·데드락 |
| 버전 비교 UPDATE | 충돌 드문 복합 수정 | 충돌 후 재조회·재계산 |
| 키별 순차 처리 | 같은 SKU의 많은 요청을 조절 | 큐 대기·재배정·중복 방지 |

낙관적 갱신도 UPDATE 시 DB 잠금을 쓴다. “미리 잠그지 않는다”가 “락 대기가 없다”는 뜻은 아니다.

```sql
UPDATE stock
SET qty = qty - :requested_qty, version = version + 1
WHERE sku = :sku
  AND version = :read_version
  AND :requested_qty > 0
  AND qty >= :requested_qty;
```

영향 행이 0개면 품절인지 버전 충돌인지 확인한다. 충돌 재시도는 새 트랜잭션에서 재조회하고 전체 시간·시도 횟수를 제한한다. 단일 SKU 한 건 처리가 평균 2ms 동안 직렬 자원을 점유한다고 가정하면 단순 상한은 약 500건/초다. 실제로는 로그·인덱스·대기·다른 트랜잭션의 영향을 측정해야 한다. 접속자 50만 명 자체는 초당 DB 요청 수가 아니다.

## 4. 여러 SKU와 중복 예약은 하나의 커밋으로

같은 DB 안의 여러 SKU라면 한 트랜잭션으로 전부 성공하거나 전부 롤백할 수 있다. 같은 SKU가 주문에 반복되면 수량을 합치고 SKU 순서로 처리한다. 재시도마다 새로운 예약 ID를 만들지 않는다.

```text
begin transaction
claim reservation_id with UNIQUE constraint
if existing:
    verify same customer and normalized item quantities
    return existing reservation state without another decrement
for each aggregated item sorted by sku:
    conditional decrement of available quantity
    if affected rows != 1: rollback the whole transaction
save reservation items, status=RESERVED, expires_at
commit
```

다른 테이블·인덱스 잠금까지 모두 같은 순서라는 보장은 없으므로 정렬만으로 모든 데드락을 제거했다고 말하지 않는다. 여러 DB로 나뉘면 이 로컬 원자성이 사라진다. 부분 예약을 해제하는 보상과 중간 상태를 설계하거나, 함께 예약해야 할 재고의 데이터 경계를 바꾼다.

## 5. 만료와 결제 완료가 동시에 오면

예약 행은 `RESERVED → CONFIRMED` 또는 `RESERVED → EXPIRED` 중 한 번만 전이한다. 결제 완료가 늦게 도착했는데 예약을 이미 해제했다면 자동으로 다시 CONFIRMED로 바꾸지 않는다. 재예약 가능 여부를 확인하거나 결제 취소·환불 흐름으로 보낸다.

```mermaid
stateDiagram-v2
    [*] --> RESERVED
    RESERVED --> CONFIRMED: 유효한 결제 확인
    RESERVED --> EXPIRED: 만료 작업이 전이 선점
    EXPIRED --> RECONCILING: 늦은 결제 확인
    RECONCILING --> REFUND_PENDING: 재예약 불가
    CONFIRMED --> SHIPPED: 출고
```

```sql
-- 만료 처리 트랜잭션의 첫 단계. 예약 품목은 생성 후 불변이라고 가정한다.
BEGIN;
UPDATE reservations
SET status = 'EXPIRED'
WHERE id = :reservation_id
  AND status = 'RESERVED'
  AND expires_at <= CURRENT_TIMESTAMP
RETURNING id;
-- 반환된 행이 있을 때만 품목별 가용 수량 복원.
-- 위 상태 변경과 모든 수량 복원을 같은 트랜잭션으로 커밋.
COMMIT;
```

확정 처리도 `status='RESERVED'` 조건을 검사해 동일 예약 행에서 경쟁한다. 만료 처리 재실행은 이미 EXPIRED이므로 수량을 다시 더하지 않는다. 복원 중 DB 실패면 상태 전이도 롤백되어 다음 시도에서 복구할 수 있다.

Redis 만료 알림은 내구성 있는 업무 큐가 아니며 구독이 끊기면 놓칠 수 있다. DB의 `status, expires_at` 인덱스를 이용한 주기 스캔·재시도·대사로 누락된 만료도 수렴시킨다.

## 6. Redis 선차감은 별도의 실패 모델을 만든다

아래 Lua는 **한 키의 재고 검사와 감소만** 원자화하는 학습용 예제다. 실행 전 키 자료형이 문자열이고 수량 범위가 애플리케이션의 안전한 정수 범위 안이라고 가정한다. 요청 멱등성과 이벤트 내구성은 포함하지 않는다.

```lua
local requested = tonumber(ARGV[1])
if requested == nil or requested <= 0 or requested % 1 ~= 0 then
  return redis.error_reply('invalid quantity')
end
local available = tonumber(redis.call('GET', KEYS[1]))
if available == nil or available < requested then
  return -1
end
return redis.call('DECRBY', KEYS[1], requested)
```

단순 `DECRBY → 음수이면 INCRBY` 두 요청은 그 사이 종료되면 복원이 빠진다. Lua도 실행 중 다른 요청이 끼지 않는 보장과 장애 후 데이터 내구성이 별개다. **Redis 차감 성공 → Kafka 발행 전 종료**는 또 다른 Dual Write(이중 쓰기) 문제다. AOF(Append Only File, 추가 기록 파일)를 켜는 것만으로 해결되지 않는다.

| 위험 | 필요한 설계 |
|---|---|
| 응답 유실 후 같은 요청 재시도 | 예약 ID별 결과 보존·조회 |
| 복제 전 장애로 차감 기록 소실 | 내구성 기준·승격 시 검증·판매 일시 중지 정책 |
| 차감 후 이벤트 발행 실패 | 예약 기록과 전달 대기 기록을 같은 경계에서 남기고 재전달 |
| 비동기 DB 반영 지연 | 예약과 DB의 대사·오래된 미반영 감시 |
| 최종 수량 불확실 | 과판매 허용 대신 확정 지연 또는 DB 최종 검증 |

Redis는 비동기 복제로 인해 승격 시 확인받은 쓰기가 사라질 수 있다. WAIT 같은 복제 확인도 모든 장애에서 강한 일관성을 보장하지 않는다. Lua로 여러 키를 다루는 경우 Cluster의 슬롯 제약과 실행 오류·복구까지 검토한다. 이 책임을 감당하기 어렵다면 DB를 최종 진실원으로 두고 대기열·입장 제한을 먼저 적용한다.

> **면접 포인트** — “티켓팅이면 Redis”가 정답은 아니다. 유입률·허용 대기·과판매 비용·DB 측정 결과를 제시하고, 선택한 방식에서 중복·만료·장애 후 재개를 어떻게 처리하는지 설명한다.

## 참고

- [PostgreSQL 17 Transaction Isolation](https://www.postgresql.org/docs/17/transaction-iso.html)
- [Redis Lua 실행](https://redis.io/docs/latest/develop/programmability/eval-intro/)
- [Redis 복제 보장](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [Redis 만료 알림](https://redis.io/docs/latest/develop/pubsub/keyspace-notifications/)$review_14$
WHERE slug = 'database-07-inventory-concurrency' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_15$## 이 라운드에 대하여

백엔드 시니어 면접의 **DB 라운드는 보통 20~30분**, 하나의 실제 장애 스토리를 따라간다. "느린 쿼리 하나"에서 출발해 인덱스 → 실행계획 → 락 → 격리수준 → 고경쟁 설계까지 **꼬리를 물고 압박**한다. 면접관이 보는 건 단편 지식이 아니라 **정량적 근거로 원인을 좁히는 사고 과정**과 **MySQL/PostgreSQL 차이를 아는 실무 감각**이다.

이 카드는 개념 설명이 아니라 **실전 문답 대본**이다. 개념 복습은 `database-01`(인덱스·EXPLAIN), `database-02`(락·격리수준), `database-07`(재고 동시성)을 보라. 여기서는 그 지식을 **면접관의 압박에 어떻게 꺼내 쓰는가**에 집중한다.

```mermaid
flowchart LR
    R0["R0 워밍업\n느린 쿼리 관측"] --> R1["R1 인덱스 설계\n복합 인덱스 순서"]
    R1 --> R2["R2 탔는데도 느리다\n커버링·filesort·통계"]
    R2 --> R3["R3 갱신 유실\nRR인데 왜? 데드락"]
    R3 --> R4["R4 재고 핫스팟\n락 대기 폭증 완화"]
    R4 --> FB["평가\n주니어·미들·시니어"]
    style R2 fill:#fef3c7,stroke:#d97706
    style R3 fill:#fee2e2,stroke:#dc2626
    style R4 fill:#ede9fe,stroke:#8b5cf6
```

*면접 문답의 진행 경로 — 한 장애 스토리가 4라운드로 심화된다*

> **🎯 면접 포인트 — "모른다"보다 "어떻게 확인하겠다"**
>
> DB 라운드의 모든 질문은 사실 **"측정 없이 단정하지 마라"** 를 시험한다. "인덱스 추가하겠습니다"가 아니라 "EXPLAIN의 `Extra`와 `rows` vs `actual`을 먼저 보고, `SHOW STATUS LIKE 'Handler_read%'`로 실제 읽은 행을 확인한 뒤 판단하겠습니다"가 시니어의 답이다.

## R1 — "이 쿼리가 느립니다. 인덱스를 어떻게 잡겠습니까?"

**면접관 제시:**

```sql
-- 셀러 대시보드: 특정 샵의 최근 주문을 상태별로 조회, 최신순 20건
SELECT order_id, buyer_id, total_amount, created_at
FROM orders
WHERE shop_id = 4210 AND status = 'PAID'
ORDER BY created_at DESC
LIMIT 20;
-- 현재 orders는 1,200만 행, 인덱스는 PK(order_id)뿐. 800ms.
```

**모범 답변 포인트:**

- 먼저 조건을 분해한다: `shop_id`(등치, 고선택도), `status`(등치, 저선택도 6종), `created_at`(정렬 + 잠재적 범위).
- **복합 인덱스 `(shop_id, status, created_at)`** 를 제안. 순서 근거를 명확히:
  - **등치 조건을 앞, 정렬 컬럼을 뒤** — Leftmost Prefix(선두 컬럼 원칙). `shop_id`, `status`가 등치로 트리 진입점을 좁히고, 마지막 `created_at`이 이미 정렬돼 있어 `ORDER BY ... DESC LIMIT 20`이 **filesort 없이 인덱스 뒤에서 20개만** 읽고 끝난다.
  - `status`를 `created_at`보다 앞에 두는 이유: `status`가 등치라 트리에서 하나의 연속 구간으로 좁혀지고, 그 구간 안에서 `created_at`이 정렬 유지된다. 순서를 `(shop_id, created_at, status)`로 하면 `status` 필터가 정렬 구간을 쪼개 filesort가 붙거나 인덱스 뒤쪽 컬럼을 못 쓴다.

```sql
CREATE INDEX idx_shop_status_created
  ON orders (shop_id, status, created_at);

-- 기대 EXPLAIN (MySQL)
+----+--------+-------+----------------------------+---------+------+-------------+
| id | table  | type  | key                        | key_len | rows | Extra       |
+----+--------+-------+----------------------------+---------+------+-------------+
|  1 | orders | ref   | idx_shop_status_created    | 156     |   20 | Using where |  <- filesort 없음
+----+--------+-------+----------------------------+---------+------+-------------+
```

> **⚠️ 실무 함정 — 정렬 방향과 인덱스**
>
> `ORDER BY created_at DESC`인데 인덱스가 오름차순이어도 InnoDB는 **Backward index scan(역방향 스캔)** 으로 대응한다. 단 MySQL 8.0 미만에서 복합 인덱스의 컬럼별 정렬 방향이 엇갈리면(`a ASC, b DESC`) 인덱스로 못 풀고 filesort가 붙는다. 이때는 8.0의 **Descending Index** (`created_at DESC`로 인덱스 생성)가 답이다. 면접에서 버전을 확인하고 답하면 가점.

**흔한 오답:**

- "`shop_id`, `status`, `created_at`에 각각 인덱스를 만들겠다" → 단일 인덱스 3개로는 이 쿼리를 못 푼다. 옵티마이저가 하나만 골라 나머지는 필터로 떨어지고(`filtered` 낮음), MySQL의 index_merge는 정렬을 만족 못 해 filesort가 붙는다.
- "`status`가 저선택도니 인덱스에서 빼겠다" → 등치 조건이라 트리 진입을 좁히는 데 기여하고, 무엇보다 뒤의 `created_at` 정렬을 살리려면 필요하다. 저선택도라 **단독 인덱스**가 무의미한 것이지, 복합의 앞자리에서는 유용하다.

## R2 — "인덱스를 탔는데도 느립니다"

**면접관 압박:**

> "말한 대로 인덱스를 걸었더니 `type=range`로 인덱스는 타요. 그런데 여전히 200ms. `EXPLAIN`의 `rows`는 500인데 실측하면 8만 행을 읽습니다. `Extra`에는 `Using filesort`가 보이고요. 무엇을 의심하고 어떻게 좁히겠습니까?"

**모범 답변 포인트 — 3가지를 분리해 진단:**

**(1) filesort — 정렬이 인덱스로 안 풀림.** `Using filesort`는 인덱스 정렬 순서와 `ORDER BY`가 안 맞을 때 붙는다. 여기선 아마 쿼리에 `created_at` 범위(`created_at > ?`)가 끼어들어 `status`와 `created_at` 사이 순서가 깨졌거나, 정렬 컬럼이 인덱스 밖 컬럼이다. 인덱스 순서를 쿼리 형태에 맞춰 재조정한다.

**(2) 커버링 실패 — Bookmark Lookup 폭증.** `SELECT`에 `buyer_id, total_amount`가 있어 인덱스만으론 못 풀고 **PK로 클러스터드 인덱스를 8만 번 재방문**(랜덤 I/O)한다. 이게 `rows=500`인데 실측 8만의 정체일 수 있다 — 정렬 후 LIMIT 전에 넓은 구간을 스캔+룩업. **커버링 인덱스**로 필요한 컬럼을 인덱스에 포함시키면 테이블 접근이 사라진다.

```sql
-- 커버링: SELECT 컬럼을 인덱스에 얹는다 (MySQL은 뒤에 그냥 나열, PG는 INCLUDE)
CREATE INDEX idx_cover
  ON orders (shop_id, status, created_at, buyer_id, total_amount);
-- PostgreSQL: CREATE INDEX ... ON orders (shop_id,status,created_at)
--             INCLUDE (buyer_id, total_amount);  -- 키가 아닌 payload로만

-- 기대: Extra: Using index (커버링 성공, 랜덤 I/O 0)
```

**(3) 통계 오차 — `rows` vs `actual` 괴리.** `rows=500`(추정) vs 실측 8만이면 옵티마이저 통계가 낡았다. PostgreSQL이면 `EXPLAIN (ANALYZE, BUFFERS)`로 `estimated` vs `actual rows`를 직접 대조하고 `ANALYZE orders`; MySQL이면 `ANALYZE TABLE orders` 또는 히스토그램(`ANALYZE TABLE ... UPDATE HISTOGRAM ON status`)을 갱신한다.

```sql
-- 실제로 몇 행을 읽었나: 옵티마이저 추정 말고 엔진 카운터로 확인
FLUSH STATUS;
SELECT ... ;  -- 문제 쿼리 실행
SHOW STATUS LIKE 'Handler_read%';
-- Handler_read_next 가 크면 인덱스 구간을 넓게 훑은 것 (LIMIT 전 8만 스캔 등)
```

```mermaid
sequenceDiagram
    participant App as 애플리케이션
    participant Sec as 보조 인덱스
    participant Clu as 클러스터드(테이블)
    Note over App,Clu: 커버링 실패 — 8만 번 Bookmark Lookup
    loop 정렬 구간 8만 행
        App->>Sec: 인덱스 구간 스캔
        Sec-->>App: PK 반환
        App->>Clu: PK로 행 재방문 (랜덤 I/O)
        Clu-->>App: buyer_id, total_amount
    end
    Note over App,Sec: 커버링 성공 — 인덱스만으로 종료 (테이블 접근 0회)
```

*rows=500 추정과 실측 8만의 괴리 — 커버링 실패로 인한 대량 룩업이 흔한 원인*

> **💡 팁 — `rows`는 "추정", 진짜는 `actual`/Handler 카운터**
>
> `EXPLAIN`의 `rows`는 옵티마이저 추정치라 믿지 마라. PostgreSQL은 `EXPLAIN ANALYZE`의 `actual rows ... loops=N`을 곱해 실제 처리량을 보고, `Buffers: shared hit/read`로 캐시 히트/디스크 I/O를 구분한다. MySQL은 `EXPLAIN ANALYZE`(8.0.18+) 또는 `Handler_read_*` 카운터로 실측한다. 이 구분을 아는 것만으로 미들과 시니어가 갈린다.

> **⚠️ 실무 함정 — 커버링 인덱스에 컬럼을 다 넣지 마라**
>
> 커버링이 좋다고 `SELECT *`용으로 컬럼을 다 얹으면 인덱스가 테이블만큼 커져 **쓰기마다 인덱스 갱신 비용·버퍼풀 오염**이 생긴다. PostgreSQL의 `INCLUDE`는 키가 아닌 payload라 트리 정렬 부담이 없어 이럴 때 유리하다. 커버링은 **핫 쿼리에만 선택적으로**, 그리고 payload 컬럼은 좁게.

## R3 — "REPEATABLE READ인데 왜 갱신 유실이 납니까?"

**면접관 제시 (포인트 적립 로직):**

```sql
-- 세션 격리수준: REPEATABLE READ (MySQL InnoDB 기본)
BEGIN;
SELECT balance FROM account WHERE id = 100;   -- 1000 읽음 (스냅샷 읽기, 락 없음)
-- 애플리케이션: new = 1000 + 500
UPDATE account SET balance = 1500 WHERE id = 100;
COMMIT;
-- 두 트랜잭션이 동시에 이 흐름을 돌면 한쪽 +500이 사라진다 (최종 1500, 기대 2000)
```

**모범 답변 포인트:**

- **왜 RR이 못 막나:** 일반 `SELECT`는 **MVCC 스냅샷 읽기(consistent read)** 라 **락을 걸지 않는다.** RR이 보장하는 건 "한 트랜잭션 안에서 같은 SELECT는 같은 값" — 즉 **읽기 재현성**이지, 다른 트랜잭션의 쓰기를 막는 게 아니다. 두 트랜잭션이 각자 1000을 읽고 각자 계산해 덮어쓰면 하나가 유실된다. 이 설명은 **MySQL InnoDB의 일반 스냅샷 SELECT 후 상수로 덮어쓰는 시나리오**에 한정한다. PostgreSQL REPEATABLE READ에서는 스냅샷 이후 다른 트랜잭션이 변경한 같은 행을 갱신하려 할 때 직렬화 실패로 중단될 수 있다. SERIALIZABLE과 적절한 재시도도 검토할 수 있으므로 “격리수준으로는 막을 수 없다”고 일반화하지 않는다.
- **해법 1 — 원자적 UPDATE:** 애플리케이션에서 계산하지 말고 DB가 원자적으로:

```sql
UPDATE account SET balance = balance + 500 WHERE id = 100;  -- 읽기-계산-쓰기를 한 문장으로
```

- **해법 2 — 잠금 읽기:** 굳이 값을 읽어 판단해야 하면 `SELECT ... FOR UPDATE`로 X 락을 잡아 직렬화. 이때 두 번째 트랜잭션은 첫 커밋까지 대기하다 **최신 값 1500을 읽고** 2000으로 만든다.
- **해법 3 — 낙관적 락:** `WHERE ... AND version = ?` + affected rows 검사 후 재시도. 충돌이 드물 때.

**이어지는 압박 — 데드락:**

> "그래서 `SELECT ... FOR UPDATE`로 바꿨더니 이번엔 여러 계좌를 동시에 다루는 정산 배치에서 `ERROR 1213 Deadlock`이 자주 터집니다. 왜죠?"

**모범 답변:**

- 두 트랜잭션이 **여러 행을 엇갈린 순서로 잠그면** 순환 대기 → 데드락. T1이 A→B, T2가 B→A 순으로 잠그는 전형.
- **예방: 잠금 순서 일관성.** 항상 같은 순서(예: `id` 오름차순)로 잠근다.

```sql
-- 여러 계좌를 항상 id 오름차순으로 잠근다 → 순환 대기 원천 차단
SELECT * FROM account WHERE id IN (100, 205) ORDER BY id FOR UPDATE;
```

```mermaid
sequenceDiagram
    participant T1 as 정산 배치1
    participant A as 계좌 A(id=100)
    participant B as 계좌 B(id=205)
    participant T2 as 정산 배치2
    T1->>A: "FOR UPDATE A (X 락)"
    T2->>B: "FOR UPDATE B (X 락)"
    T1->>B: "FOR UPDATE B 요청 → 대기"
    T2->>A: "FOR UPDATE A 요청 → 대기"
    Note over T1,T2: "순환 대기 = Deadlock → InnoDB가 victim 롤백(1213)"
```

*락 획득 순서가 엇갈리면 데드락 — 항상 동일 순서로 잠가 예방*

> **🎯 면접 포인트 — RR의 팬텀·갱신유실은 MySQL/PostgreSQL이 다르다**
>
> **MySQL InnoDB RR**: 잠금 읽기(`FOR UPDATE`)는 **Next-key Lock(넥스트키 락)** 으로 갭까지 잠가 팬텀도 막는다. 그런데 이 갭락이 오히려 **데드락의 단골 원인**이다. **PostgreSQL RR**: 스냅샷 격리(Snapshot Isolation)라 갱신 유실을 **직접 감지** — 두 트랜잭션이 같은 행을 UPDATE하면 나중 커밋 쪽이 `ERROR: could not serialize access due to concurrent update`로 abort된다(first-updater-wins). 즉 PG RR은 락 대기 대신 **재시도**를 강제한다. SERIALIZABLE에서는 PG가 **SSI(Serializable Snapshot Isolation)** 로 직렬성 위반을 감지해 abort한다. "RR이면 다 같다"고 답하면 감점.

> **⚠️ 실무 함정 — 인덱스 없는 `FOR UPDATE`는 테이블을 통째로 잠근다**
>
> `SELECT ... WHERE non_indexed_col = ? FOR UPDATE`는 풀스캔하며 **스캔한 모든 레코드에 락**을 건다 → 사실상 테이블 락으로 동시성이 0이 된다. 잠금 읽기의 WHERE는 반드시 인덱스(가급적 PK/Unique)로 좁혀야 한다. MySQL RR에서는 여기에 **갭락**까지 더해져 무관한 INSERT도 막힌다.

## R4 — "재고 차감 UPDATE로 Oversell은 막았는데, 락 대기가 폭증합니다"

**면접관 제시:**

```sql
-- Oversell은 이 한 문장으로 막았다 (database-07의 원자적 조건부 UPDATE)
UPDATE stock SET qty = qty - 1 WHERE sku = 'HOT-SKU' AND qty >= 1;
-- 그런데 인기 SKU 하나에 초당 3만 요청 → 같은 행에 X 락이 직렬화되며
-- innodb_lock_wait_timeout(50s) 초과 에러, p99가 2초로 폭등.
```

이건 정합성 문제가 아니라 **단일 행 핫스팟(hot row)** 문제다. `qty>=1`이 Oversell을 막는 건 맞지만, 같은 행에 대한 X 락은 **한 번에 하나씩만** 통과하므로 초당 처리량이 행 하나의 락 순환 속도에 묶인다.

**모범 답변 — SQL을 거의 안 바꾸고 완화하는 3가지:**

**(1) 재고 분할(Stock Bucketing / sharded counter).** 한 SKU의 재고를 N개 행으로 쪼개 락 경합을 1/N로 분산.

```sql
-- 재고를 10개 버킷으로: 요청마다 랜덤/해시 버킷 하나만 잠근다
UPDATE stock_bucket
SET qty = qty - 1
WHERE sku = 'HOT-SKU' AND bucket = ? AND qty >= 1;   -- bucket = rand()%10
-- 총재고 = SUM(qty). 버킷이 비면 다른 버킷 재시도(재고 쏠림 보정 필요)
```

트레이드오프: 락 경합을 N배로 낮추지만 **총재고 조회가 집계**가 되고, 특정 버킷만 소진되는 **불균형**을 재분배 로직으로 보정해야 한다. 잔여가 적을 때(마지막 몇 개) 정확도가 떨어진다.

**(2) Redis 원자 선차감 + 비동기 DB 반영.** 초고 TPS 선착순의 정석. `DECR`/Lua로 Redis에서 선차감하고 DB는 큐(Kafka)로 비동기 반영.

```
-- Lua: GET → 검사 → DECRBY 를 단일 원자 실행 (database-07 참고)
local q = tonumber(redis.call('GET', KEYS[1]))
if q == nil or q < tonumber(ARGV[1]) then return -1 end
return redis.call('DECRBY', KEYS[1], ARGV[1])
```

트레이드오프: 처리량은 수십만 TPS로 뛰지만 **Redis가 진실원**이 되어 장애 시 차감분 유실 위험(AOF/RDB 영속성 필수), 캐시-DB 최종 일관성, 보상 처리 복잡도. **선착순/티켓팅에만**.

**(3) 애플리케이션 직렬화 — 단일 파티션 큐.** 해당 SKU의 차감 요청을 **하나의 워커/파티션으로 순서화**(Kafka partition key=sku)해 DB 경합 자체를 없앤다. 락 대신 큐가 순서를 보장.

트레이드오프: DB 락 경합은 사라지지만 **처리 지연(큐 대기)** 이 생기고, 워커 장애 시 해당 SKU가 멈춘다. 처리량은 워커 하나의 속도에 묶인다.

**보조 튜닝(즉효):** `innodb_lock_wait_timeout`을 50s → **2~3s**로 낮춰 **빠른 실패 + 재시도**로 전환. 50초 대기는 커넥션 풀을 고갈시켜 장애를 전파시킨다.

```mermaid
flowchart TD
    A["단일 행 핫스팟\n초당 3만, 락 직렬화"] --> B{"TPS 규모 / 정합성 요구"}
    B -->|"수천 TPS, 강정합"| C["재고 버킷 분할\n락 경합 1/N\n(집계·불균형 보정)"]
    B -->|"수십만 TPS, 선착순"| D["Redis 선차감\n+ 큐로 DB 반영\n(영속성·보상)"]
    B -->|"순서 보장 우선"| E["파티션 큐 직렬화\nsku별 단일 워커\n(지연·SPOF)"]
    A -.->|"즉효"| F["lock_wait_timeout\n50s→2~3s + 재시도"]
    style C fill:#dcfce7,stroke:#16a34a
    style D fill:#ede9fe,stroke:#8b5cf6
    style E fill:#dbeafe,stroke:#3b82f6
    style F fill:#fef3c7,stroke:#d97706
```

*핫스팟 완화 의사결정 — TPS 규모와 정합성 요구가 방식을 가른다*

> **🎯 면접 포인트 — "정확성"과 "처리량"을 분리해 답하라**
>
> R4의 함정은 "Oversell을 어떻게 막나"로 되돌아가는 것이다. Oversell은 이미 `qty>=1`로 해결됐다. 면접관이 묻는 건 **정확한데도 느린** 핫스팟의 **처리량 문제**다. "정합성은 유지한 채 락 경합만 분산한다"는 프레임으로, 위 3가지를 **경합 강도·정합성 타협 여부·운영 복잡도**로 비교하면 시니어 답변이다.

## 좋은 답변 vs 나쁜 답변

| 질문 상황 | 나쁜 답변 (감점) | 좋은 답변 (가점) |
| --- | --- | --- |
| R1 인덱스 순서 | "필요한 컬럼에 다 인덱스 걸겠다" | "등치→정렬 순서로 복합 인덱스, filesort 제거를 EXPLAIN `Extra`로 검증" |
| R2 탔는데 느림 | "인덱스 하나 더 추가" | "커버링 실패/filesort/통계 오차를 `actual rows`·`Handler_read`·`Buffers`로 분리 진단" |
| R2 rows vs actual | "rows가 500이니 빠를 것" | "`rows`는 추정치, `EXPLAIN ANALYZE`의 actual·loops로 실측하고 `ANALYZE`로 통계 갱신" |
| R3 갱신 유실 | "격리수준을 SERIALIZABLE로 올린다" | "read-modify-write 경쟁이라 격리론 못 막음. 원자 UPDATE/`FOR UPDATE`/버전으로 해결" |
| R3 데드락 | "재시도만 하면 된다" | "잠금 순서 일관성(id 정렬)으로 예방 + 짧은 트랜잭션 + 재시도, MySQL 갭락 원인 인지" |
| R3 DBMS 차이 | "RR이면 다 똑같다" | "MySQL은 넥스트키 락, PG는 SI라 concurrent update abort — first-updater-wins" |
| R4 핫스팟 | "Oversell 막으면 됨" (질문 회피) | "정합성은 유지, 락 경합만 버킷/Redis/큐로 분산. timeout 낮춰 빠른 실패" |

> **💡 팁 — 항상 "측정 → 가설 → 검증"의 3박자로 말하라**
>
> "느리면 EXPLAIN을 보고(측정), 커버링 실패가 의심되니(가설), `Extra`에 `Using index`가 뜨는지 커버링 인덱스로 검증하겠다(검증)." 이 구조로 말하면 어떤 압박에도 흔들리지 않는다. 숫자(`rows`, 락 대기 시간, TPS)를 근거로 붙이면 확실히 가점.

## 평가 루브릭

| 항목 | 주니어 | 미들 | 시니어 |
| --- | --- | --- | --- |
| 인덱스 설계 | 단일 인덱스 나열 | 복합 인덱스 순서 이해 | 정렬·범위·커버링까지 EXPLAIN 근거로 설계 |
| 실행계획 | `type`만 봄 | `key`/`rows`/`Extra` 해석 | `rows` vs `actual`, Handler/Buffers로 실측 진단 |
| 격리수준 | 4단계 암기 | 이상현상 매핑 | MySQL/PG 차이(넥스트키 vs SSI) + 갱신유실 한계 |
| 락·데드락 | "락 걸면 됨" | `FOR UPDATE` 사용 | 순서 일관성 예방 + 갭락 원인 + 타임아웃 튜닝 |
| 고경쟁 설계 | 원자 UPDATE 안다 | 비관/낙관/원자 비교 | 핫스팟 분산(버킷/Redis/큐)을 트레이드오프로 선택 |
| 태도 | 단정적 답변 | 트레이드오프 언급 | 측정 우선·정량 근거·케이스 분기 |

> **🎯 면접 포인트 — 한 문장으로 마무리하는 습관**
>
> 각 라운드 끝에 "즉 이 케이스는 ___ 조건이라 ___를 택하고, ___이면 ___로 갑니다"처럼 **조건부 결론**으로 닫아라. 면접관은 "정답 하나"가 아니라 "상황에 따라 다르게 판단할 수 있는가"를 본다. `database-07`의 재고 방식 5분법, `database-02`의 격리수준 DBMS 매트릭스를 조건부 결론의 재료로 쓰면 좋다.

## 이해도 확인 Q&A

아래 질문에 직접 답변을 작성하세요. 실제 면접이라 생각하고 소리 내어 답한 뒤, 자동 저장된 답을 코치에게 보내 피드백을 받으세요.

> **부분 검수 — 2026-09-12**: R3의 DBMS별 차이를 보강했다. [PostgreSQL 17 트랜잭션 격리](https://www.postgresql.org/docs/17/transaction-iso.html)를 기준으로 같은 행 충돌과 서로 다른 행의 Write Skew를 구분한다.$review_15$
WHERE slug = 'database-08-interview-index-lock' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_16$## 1. 배치 기준과 실행 제어를 구분한다

기준은 **Kubernetes 1.34, Linux의 일반 컨테이너별 자원 설정**이다. Pod 수준 자원, CPU Manager의 전용 CPU, MemoryQoS 등은 설정과 기능 상태를 별도로 확인한다. 아래 수치는 학습용이다.

Request(요청량)는 Scheduler(배치기)가 노드의 Allocatable(파드에 배정 가능한 자원)과 비교하는 값이다. 실제 사용량이 지금 낮다는 이유로 요청량 합계를 넘는 Pod를 배치하지 않는다. 실제 배치는 CPU·메모리 외에도 위치 제약·스토리지·확장 자원에 영향을 받는다.

Limit(제한량)은 실행 중 상한이다. CPU 요청 500m는 CPU 시간 0.5개에 해당하며 특정 코어 절반을 독점한다는 뜻이 아니다. 요청량은 CPU 경합 시 상대 가중치에도 영향을 주고, 여유가 있으면 요청보다 더 사용할 수 있다. CPU Limit이 있으면 그 상한이 추가된다.

```mermaid
flowchart LR
    S[컨테이너 자원 명세] --> A[Admission 기본값과 정책]
    A --> R[실제 Request]
    R --> P[노드 Allocatable과 배치 판단]
    R --> W[CPU 경합 시 가중치]
    A --> L[실제 Limit]
    L --> C[CPU 실행시간 제한]
    L --> M[메모리 상한과 OOM]
```

| 설정 | 역할 | 실패 신호 |
|---|---|---|
| CPU Request | 배치·경합 가중치·사용률 기반 HPA의 분모 | Pending, CPU 경합, 예상과 다른 확장 |
| CPU Limit | CPU 시간 상한 | Throttling(실행 제한)과 지연 증가 |
| Memory Request | 배치와 메모리 압박 시 축출 판단 요소 | 과밀 배치·노드 압박 |
| Memory Limit | 커널의 메모리 상한 | OOM 종료 가능 |

Limit만 지정하고 Request를 생략하면 Admission(입장 처리) 기본값이 없는 경우 해당 Limit이 Request로 복사될 수 있다. 원본 YAML만 보지 말고 실제 생성된 Pod와 LimitRange 정책을 확인한다.

## 2. CPU 제한과 메모리 종료는 다르게 관측한다

CPU는 실행 시간을 지연시킬 수 있어 상한을 넘는 수요를 Throttling으로 제어한다. 노드 전체 CPU가 남아 있어도 컨테이너의 제한 시간 예산을 소진하면 지연될 수 있다. CPU Limit을 없애는 정책은 순간 부하에 유리할 수 있지만 이웃 작업과의 경합·조직 정책을 검토해야 한다.

메모리는 이미 사용한 페이지를 CPU 시간처럼 단순히 나중으로 미룰 수 없다. 회수가 충분하지 않아 제한을 만족하지 못하면 커널이 프로세스를 종료할 수 있다. Memory Limit은 순간 초과를 항상 사전에 차단하는 예약 장치가 아니며, `OOMKilled`와 노드 압박에 따른 Eviction(축출)은 서로 다른 경로다.

```yaml
# 지연 민감 API의 학습용 예. CPU Limit 부재는 모든 업무의 권장값이 아니다.
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    memory: "768Mi"
```

이 예는 일반 컨테이너별 QoS(Quality of Service, 서비스 품질 등급) 규칙에서 Burstable이다. CPU와 메모리의 Request/Limit이 모든 해당 컨테이너에서 설정되고 서로 같아야 Guaranteed 조건을 만족한다. 둘 다 전혀 없는 경우는 BestEffort다. 보조 컨테이너 설정도 확인한다.

> **실무 함정 — Guaranteed는 종료 면제권이 아니다**
>
> 메모리 상한 초과나 충분히 심한 노드 압박에서 종료될 수 있다. 일반적인 노드 압박 축출은 요청 초과 여부·Pod 우선순위·요청 대비 사용량 등을 고려하므로 등급 이름 하나로 정확한 순서를 단정하지 않는다.

## 3. 평균 Request가 노드를 과밀하게 만드는 예

가상 노드의 메모리 Allocatable이 8Gi이고 각 Pod가 512Mi를 요청하면 메모리 요청 합계만으로는 16개다. 이는 CPU·다른 파드·오버헤드를 제외한 상한 계산이다. 각 Pod가 동시에 768Mi 가까이 쓰면 총 12Gi 수요가 생긴다. 스케줄러는 Request 초과 사용까지 모두 미리 확보하지 않는다.

JVM(Java Virtual Machine, 자바 가상 머신) Heap을 768Mi 상한과 같게 두면 스레드 스택·직접 버퍼·메타데이터·네이티브 메모리의 여유가 사라진다. 메모리 기반 emptyDir와 페이지 캐시 등 자원 계정도 확인하고, 단일 RSS 지표만 컨테이너 전체 비용으로 동일시하지 않는다.

평균만이 아니라 시작 구간, 캐시 준비, GC(Garbage Collection, 가비지 수집), 동시 요청, 재시도 폭주를 포함해 측정한다. 높은 분위수도 관측하지 않은 최악 상황을 보장하지 않는다. Request를 높이면 과밀 위험을 줄일 수 있지만 배치 가능한 수와 비용이 달라진다.

## 4. HPA의 분모가 Request다

HPA(Horizontal Pod Autoscaler, 수평 파드 자동 확장)의 CPU 사용률 기반 지표는 요청량 대비 사용량을 이용한다. 가상의 Pod 4개가 각각 300m를 사용하고 Request가 500m면 사용률 60%다. 목표 60%에서는 단순 계산상 4개다. 같은 실제 사용량에 Request만 250m로 낮추면 120%가 되어 단순 계산은 8개다.

```text
단순화한 사용률 기반 계산:
desired = ceil(current_replicas × current_utilization / target_utilization)
4 × (120 / 60) = 8
```

실제 HPA에는 허용 오차·준비되지 않은 Pod·누락 지표·안정화 구간·증감 정책이 있다. 필요한 Request가 없으면 사용률을 정의하지 못하는 경우도 있다. 자원 요청 권고를 적용할 때 수평 확장 목표와 함께 검토한다. 절대값이나 외부 큐 지표를 쓰는 HPA는 이 분모 설명과 구분한다.

HPA가 복제 수를 늘려도 노드 여유가 없으면 Pending이 된다. 노드 확장 시간, 이미지 다운로드, 시작 피크, 한 노드 장애 때 재배치와 롤링 배포의 추가 Pod 공간까지 용량 계획에 포함한다.

## 5. 진단 순서와 변경 검증

```bash
kubectl describe pod <pod-name>
kubectl get pod <pod-name> -o yaml
kubectl describe node <node-name>
kubectl describe hpa <hpa-name>
kubectl top pod <pod-name> --containers
```

이 명령은 관측의 시작이다. `top`은 순간 요약이며 과거 피크·Throttling·재시작 직전 메모리를 충분히 보여주지 않는다. 실제 Pod의 기본값, 종료 이유와 이전 로그, 노드 압박 이벤트, CPU 제한 시간 지표, 메모리 시계열, HPA 조건을 연결한다.

| 증상 | 먼저 분리할 원인 | 변경 검증 |
|---|---|---|
| Pending | 요청량·위치 제약·가용 노드 | 장애/배포 중에도 배치 가능한가 |
| 지연 상승 | CPU 제한·경합·외부 대기 | 같은 부하에서 꼬리 지연과 제한 시간 |
| OOMKilled | 상한·누수·시작 피크·네이티브 사용 | 재시작 반복과 메모리 여유 |
| Evicted | 노드 압박·요청 초과·우선순위 | 이웃 Pod와 노드 전체 수요 |

> **면접 포인트**
>
> “Limit을 두 배로 올린다”보다 어떤 자원 계층에서 실패했는지 먼저 설명한다. 요청량·상한·복제 수·노드 여유를 함께 바꾸면 원인 추적이 어려우므로 가설별 변경과 동일 부하 검증을 남긴다. 이 카드의 설정은 실제 클러스터에서 부하 검증된 값이 아니다.

## 참고 자료

- [Kubernetes 1.34 자원 관리](https://v1-34.docs.kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes 1.34 Pod QoS](https://v1-34.docs.kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
- [Kubernetes 1.34 노드 압박 축출](https://v1-34.docs.kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Kubernetes 1.34 HPA](https://v1-34.docs.kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)$review_16$
WHERE slug = 'infra-12-kubernetes-resource-management' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_17$## 1. 재고가 있는 것과 오늘 보낼 수 있는 것은 다르다

ATP(Available-to-Promise, 약속 가능 공급)는 선택한 시점까지 다른 수요에 배정되지 않은 공급을 본다. CTP(Capable-to-Promise, 추가 공급의 이행 가능성)는 자재·생산 자원 등으로 아직 없는 공급을 만들 수 있는지도 고려한다. 제품마다 용어와 계산 범위가 다르다. Oracle Global Order Promising 25C는 기존 공급과 추가 제조·구매·이동 공급 탐색을 구분한다.

이 카드의 물류 설계는 **공급 가능량에 창고 작업·운송 제약을 추가한 배송 약속 계산**이다. 모든 제품이 창고 피킹 용량 검사를 CTP라고 부르는 것은 아니다. 기존 질문의 ATP/CTP 비교도 이 적용 범위를 먼저 설명한다.

```text
학습용 누적 공급 계산:
미약속 공급(t) = 판매 가능한 현재고
              + t까지 사용 가능한 확정 공급
              - 같은 공급에 대한 기존 할당·예약
              - 보호할 안전재고
```

현재고가 이미 예약을 뺀 “가용 재고”라면 예약을 다시 빼면 안 된다. 품질 격리·불량·반품 검수 대기는 판매 가능한 현재고에서 제외하고, 입고 예정 시각과 검수 후 사용 가능한 시각도 구분한다. 시간 버킷별 공급을 누적 계산할 때 같은 입고를 중복 사용하지 않는다.

가상의 SKU 재고가 100개이고 남은 피킹 작업이 20건이라고 해서 이행 가능량이 20개인 것은 아니다. 주문당 수량과 작업 난이도를 같은 단위로 바꿔야 한다. 예를 들어 잔여 작업 600초, 주문 한 건의 작업 30초, 주문당 해당 SKU 2개라는 단순 가정이면 최대 20건·40개다. 패킹·도크가 더 작은 한도를 가지면 그 제약을 따른다.

| 입력 | 단위·시점 | 실패 사례 |
|---|---|---|
| 재고·확정 공급 | SKU·단위·노드·사용 가능 시각 | 입고 예정품을 검수 전에 판매 |
| 작업 | 표준 작업초·작업대·구간 | 주문 건수와 상품 개수를 직접 비교 |
| 운송 | 노선·출발편·중량/부피·집하 마감 | 출고는 했지만 간선편을 놓침 |
| 정책 | 분할 허용·합배송·서비스 수준 | 한 상품 지연이 전체 주문을 지연 |

## 2. 시간대와 캘린더를 따라 후보를 만든다

Cut-off(접수 마감)는 창고의 시간대와 기준 사건을 포함한다. 접수 시각인지 결제 승인 시각인지 정하고, 경계가 `< 14:00`인지 `<= 14:00`인지도 명시한다. 해외 노드라면 일광 절약 시간의 중복·없는 현지 시각도 다룬다.

```mermaid
flowchart LR
    O[주문 품목과 목적지] --> S[노드별 공급 가능 시각]
    S --> W[피킹과 패킹 가능 구간]
    W --> D[도크와 집하 마감]
    D --> T[노선별 출발 캘린더]
    T --> A[도착 권역 배송 구간]
    A --> Q[비용과 분할 정책으로 후보 선택]
```

금요일 14시 집하가 마감이고 토요일 집하가 없다면 14시 이후 준비된 상품은 다음 집하 가능일로 이동한다. 도착일은 그 이후 운송·배송 캘린더로 계산한다. 이 예시는 특정 운송사 일정이 아니다. 단순 `주문일 + 1일`이나 각 구간의 평균만 더하는 방식은 마감·휴일·변동성을 놓친다.

## 3. Promise Token은 예약 증명인가, 재조회 표식인가

Promise Token(배송 약속 토큰)은 이 설계의 애플리케이션 계약이다. 단순 서명된 조회 결과는 용량을 확보하지 않는다. 강하게 유지할 약속이면 실제 Hold(임시 예약) 참조와 함께 발급해야 한다.

```json
{
  "tokenId": "promise-42-v1",
  "orderDraftId": "draft-42",
  "requestHash": "hash-of-lines-address-service",
  "planVersion": 3,
  "policyVersion": 7,
  "calendarVersion": "cal-18",
  "holds": ["inventory-hold-42", "packing-hold-42"],
  "deliveryWindowStart": "2026-09-15T00:00:00Z",
  "deliveryWindowEnd": "2026-09-15T12:00:00Z",
  "expiresAt": "2026-09-13T05:03:00Z"
}
```

실제 계획에는 품목·수량·단위·출고 노드·분할·운송 서비스가 포함된다. 토큰은 서버 저장 레코드의 불투명 ID이거나 무결성을 검증할 수 있는 표현을 사용하고 주문 주체와 요청 내용을 바인딩한다. 전역 재고 버전이 바뀌었다는 이유만으로 무관한 고객의 약속까지 모두 무효화하지 않는다.

| 확인 단계 | 조건 | 실패 정책 |
|---|---|---|
| 토큰 수신 | 주문 주체·요청 해시·만료·상태 | 다른 주문 사용·변조·재사용 차단 |
| 예약 확정 | 각 Hold가 아직 유효하고 현재 명령이 소유 | 일부만 성공하면 미확정 상태에서 복구·해제 |
| 결제 결과 | 성공·실패 확정·불명 구분 | 불명은 대사; 만료를 결제 실패로 간주하지 않음 |
| 약속 확정 | 예약·지급 정책 충족 | 변경 시 고객에게 날짜와 선택지를 제시 |

재고와 용량이 같은 DB면 조건부 전이를 한 거래로 묶을 수 있다. 서로 다른 서비스의 버전을 읽는 것만으로 원자적 재검증이 되지는 않는다. 예약 Saga(단계별 거래와 보상)나 한정 용량의 사전 할당 등을 설계하고 모든 필수 Hold가 확보되기 전 확정 약속으로 표시하지 않는다.

TTL(Time to Live, 유효 기간)은 결제 소요 시간과 용량 점유 비용으로 결정한다. 만료와 결제 성공이 경쟁하면 예약의 권위 있는 상태 전이를 기준으로 대사하고, 더 늦은 날짜를 자동 확정하지 않는다. 결제 전 승인·예약 순서와 부분 실패 시 취소 경로까지 필요하다.

## 4. 분할과 합배송의 비교

가상의 주문 X·Y에서 A는 X만 오늘, B는 Y만 내일 가능하다고 하자. 두 소포를 보내면 X를 먼저 받을 수 있지만 비용과 배송 횟수가 늘어난다. A→B 이동 후 한 소포로 보내면 이동 시간·검수·작업 용량까지 더해야 하므로 단순히 `max(각 상품 도착일)`이 아니다.

| 선택 | 비용 | 약속과 고객 경험 |
|---|---|---|
| 부분 출고 | 소포별 운송·포장비 증가 가능 | 먼저 오는 품목과 나머지 구간을 각각 고지 |
| 한 노드 공급 대기 | 추가 보유·지연 비용 | 한 번에 수령하지만 가장 늦은 품목에 영향 |
| 노드 간 이동 후 합배송 | 내부 이동·입고 작업 비용 | 합배송 절감보다 이동 지연이 클 수 있음 |

고객의 묶음 필수 조건을 먼저 적용하고, 가능한 후보끼리 비용과 시간 약속 위반 위험을 비교한다. 이미 일부를 발송한 주문의 나머지 계획만 바꾸되 이전 약속 이력을 덮어쓰지 않는다.

> **면접 포인트 — 정확도 분모도 설계한다**
>
> 최초 약속 대비 정시율과 변경된 약속 대비 정시율을 따로 본다. 취소·미완료·부분 배송의 포함 규칙을 정해야 늦은 주문을 재약속해서 지표만 좋아지는 일을 막는다. 권역·노드·마감 직전·운송사별 약속 변경률과 Hold 만료율도 확인한다.

## 참고 자료

- [Oracle 25C 공급·CTP·분할 약속의 범위](https://docs.oracle.com/en/cloud/saas/supply-chain-and-manufacturing/25c/fascp/overview-of-global-order-promising.html)
- [Saga의 로컬 거래와 보상](https://microservices.io/patterns/data/saga.html)

수량·토큰·TTL·분할 사례는 위 제품의 필드나 정책을 재현한 것이 아닌 학습용 설계다.$review_17$
WHERE slug = 'logistics-10-order-promise' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_18$## 1. 원장은 수량과 원인을 함께 보존한다

Inventory Ledger(재고 원장)는 입고·예약·이동·출고·조정의 근거를 변경 이력으로 남긴다. 이 카드의 Double Entry(이중기입)는 **수량 이동에 대한 학습용 모델**이며 재무 회계 원장의 차변·대변 규칙을 그대로 주장하지 않는다.

동일 SKU·소유자·기준 단위의 이동은 출발 계정 음수와 도착 계정 양수로 기록한다. 합계 0만으로 정확성이 충분하지 않다. 잘못된 창고로 옮겨도 합계는 0이고, 중복 거래도 각각 균형을 이룰 수 있다. 유효한 계정·양수 이동량·중복 업무 키·재고 하한을 별도로 검사한다.

| 계정·수량 | 의미 | 주의 |
|---|---|---|
| AVAILABLE | 판매·예약 가능한 보유량 | 격리·예약분을 다시 포함하지 않음 |
| RESERVED | 주문에 점유된 보유량 | 예약 해제·확정의 경쟁 제어 |
| IN_TRANSIT | 창고 간 운송 중 | A에서도 B에서도 판매 가능으로 중복 계산 금지 |
| QUARANTINE | 검수·불량 판단 대기 | 실물은 있지만 판매 불가 |
| EXTERNAL / LOSS | 입출고·손실의 상대 계정 | 내부 On-hand 합계에 포함하지 않음 |

On-hand(현장 보유량)의 포함 계정과 소유권을 명시한다. AVAILABLE과 RESERVED 사이 이동은 물리 총량을 바꾸지 않는다. 고객 출고는 내부 보유량을 줄이지만 외부 상대 계정을 포함한 전체 기입은 균형을 유지할 수 있다.

## 2. A에서 B로 10개는 출고와 입고 두 사건이다

```mermaid
flowchart LR
    A[A 창고 AVAILABLE] -->|이동 출고 10| T[이동 중 IN_TRANSIT]
    T -->|실물 입고 10 확인| B[B 창고 검수 대기]
    B -->|검수 통과| V[B 창고 AVAILABLE]
```

출발 때 A -10/B +10을 바로 기록하면 아직 도착하지 않은 상품을 B에서 판매할 수 있다. 각 사건은 같은 Journal ID(원장 거래 ID)의 두 기입으로 원자 처리하되, 실제 출고와 실제 입고는 서로 다른 업무 거래로 기록한다. 일부 8개만 도착하면 8개 입고와 남은 2개의 이동 중·분실 조사를 분리한다.

다음 PostgreSQL 스키마는 단일 SKU의 두 계정 이동을 **한 행**에 저장해 한쪽 기입만 저장되는 구조를 피하는 예다. 여러 차변·대변을 지원하는 범용 원장은 별도 게시 검증이 필요하다.

```sql
CREATE TABLE inventory_transfer (
  transaction_id UUID PRIMARY KEY,
  business_key TEXT NOT NULL UNIQUE,
  sku_id TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  uom TEXT NOT NULL,
  from_account TEXT NOT NULL,
  to_account TEXT NOT NULL,
  quantity NUMERIC(18,3) NOT NULL CHECK (quantity > 0),
  occurred_at TIMESTAMPTZ NOT NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  reason TEXT NOT NULL,
  reverses_transaction_id UUID REFERENCES inventory_transfer(transaction_id),
  CHECK (from_account <> to_account)
);
CREATE VIEW inventory_entry AS
SELECT transaction_id, business_key, sku_id, owner_id, uom,
       from_account AS account, -quantity AS quantity_delta
FROM inventory_transfer
UNION ALL
SELECT transaction_id, business_key, sku_id, owner_id, uom,
       to_account AS account, quantity AS quantity_delta
FROM inventory_transfer;
```

하나의 업무 키를 각 Entry에 UNIQUE로 부여하면 두 번째 기입이 충돌한다. 업무 키는 위와 같이 거래 헤더에 두거나 Entry는 `(transaction_id, line_no)`로 구분한다. 같은 업무 키·다른 수량 요청은 성공한 중복으로 숨기지 말고 기존 요청과 비교해 거절한다.

이 최소 스키마는 음수 재고 방지·계정 유효성·쓰기 권한까지 구현하지 않는다. 실제 게시 경로는 계정 참조와 기준 단위를 검증하고, 잔액 조건부 갱신·원장 기록·Outbox를 같은 거래로 묶는다. 애플리케이션 역할의 직접 UPDATE/DELETE를 제한하고, 잘못된 게시도 감사 대상이다. 일반 CHECK 제약으로 다른 여러 행의 합계를 검증할 수 있다고 가정하지 않는다.

## 3. Snapshot 기준점은 단순 MAX ID가 아니다

Snapshot(잔액 스냅샷)은 `(sku, owner, location, bucket, uom)`별 잔액과 처리 기준점을 함께 저장한다. 정렬 가능한 UUID나 시각만으로 전체 커밋 순서를 만들 수 없다.

```text
T1: sequence 101을 할당받고 아직 미커밋
T2: sequence 102를 할당받고 먼저 COMMIT
Snapshot: 현재 보이는 행을 합산하고 watermark=102 저장
T1: 뒤늦게 COMMIT
증분 조회 WHERE sequence > 102: 101을 영원히 놓침
```

PostgreSQL Sequence(번호 생성기)는 롤백 때 번호를 되돌리지 않으며, 번호 할당 순서와 커밋 순서는 다를 수 있다. `occurred_at`도 늦게 수신된 실물 사건 때문에 기준점으로 안전하지 않다.

| 방법 | 안전한 처리 경계 | 비용·주의 |
|---|---|---|
| 게시 시 동기 잔액 갱신 | 원장과 잔액을 같은 DB 거래로 변경 | 인기 SKU의 잔액 행 경합 |
| 파티션별 순차 소비 | 로그의 확정된 소비 위치와 잔액을 같은 거래로 저장 | 파티션별 기준점 벡터, 재처리 중복 방지 |
| 일관 스냅샷+변경 캡처 | 스냅샷과 연결된 변경 로그 위치에서 이어받기 | 초기화·로그 보존·도구별 경계 확인 |

파티션별 순서도 관련 기입이 어떻게 게시됐는지 검토한다. 하나의 이동을 두 독립 파티션에 나눠 반영하면 잠시 한쪽만 보일 수 있다. 조회에 요구되는 원자성 범위를 정하고 거래 단위 투영이나 조정된 스냅샷으로 처리한다.

## 4. 실물 대사는 과거 사건과 관측 시점을 맞춘다

Reconciliation(대사)은 원장 합계·잔액·운영 투영·실사 결과를 같은 범위와 기준 시점으로 비교하는 과정이다. 실사 동안 이동이 계속되면 실사 시작/종료 사이 입출고를 반영하거나 해당 구간을 통제한다. 시스템 100개와 실물 98개라는 숫자만으로 곧바로 -2 조정을 게시하지 않는다.

1. 단위·포장 환산, 위치, 소유자, 로트, 미처리 스캔과 중복을 확인한다.
2. 실사 ID, 관측 시간, 담당자, 장비, 증빙과 차이 원인을 저장한다.
3. 승인된 조정 거래를 기존 거래 참조와 함께 게시한다. 원래 기입을 덮어쓰지 않는다.
4. 다시 대사해 차이가 해소됐는지 확인하고 이미 발행된 보고서의 개정 이력을 남긴다.

정정은 잘못된 A→B 거래를 B→A로 상쇄하고 올바른 이동을 새로 게시할 수 있다. 다만 이미 B 재고를 소비했다면 단순 역기입이 현재 가용량 제약과 충돌할 수 있다. 감사 정정과 실물·가용량 복구의 허용 절차를 구분한다. 과거에 발생한 사건을 오늘 기록하면 업무 발생 시각과 기록 시각을 모두 남긴다.

> **면접 포인트 — 원장이 곧 실물의 진실은 아니다**
>
> 원장은 “무엇을 기록했는지”를 검증 가능하게 한다. 누락 스캔·잘못된 식별·분실은 실사와 대사로 찾아야 한다. 균형 합계, 중복 업무, 음수 잔액, 오래된 이동 중 재고를 서로 다른 지표로 본다.

## 참고 자료

- [PostgreSQL 17 Sequence의 트랜잭션 특성](https://www.postgresql.org/docs/17/functions-sequence.html)
- [PostgreSQL 17 CHECK·UNIQUE 제약의 범위](https://www.postgresql.org/docs/17/ddl-constraints.html)
- [GS1 추적성: 식별과 이동 관계 기록](https://www.gs1.org/standards/gs1-global-traceability-standard/current-standard)

계정·이중기입·게시·Snapshot 선택지는 이 카드의 학습용 설계이며 GS1 표준 원장 스키마가 아니다.$review_18$
WHERE slug = 'logistics-11-inventory-ledger' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_19$## 1. 식별 값과 표현 수단을 분리한다

SKU(Stock Keeping Unit, 내부 재고 관리 단위)는 회사가 품목을 관리하는 식별자다. Barcode(바코드)는 식별 값과 속성을 기계가 읽도록 표현하는 수단이며, 바코드 그림 자체가 상품의 영구 식별자는 아니다. GTIN(Global Trade Item Number, 국제 거래 품목 번호)은 GS1의 거래 품목 식별 키다.

| 구분 | 식별 범위 | 설계할 키 |
|---|---|---|
| SKU | 내부 판매·재고 품목 | 조직/테넌트 + 내부 ID |
| GTIN | 거래 품목·포장 수준 | 문자열로 보존한 표준 식별 값 |
| Lot/Batch(로트·배치) | 생산·처리 묶음 | 품목·발급 범위를 포함한 로트 키 |
| Serial(시리얼) | 개별 개체 | 표준 범위의 GTIN + 시리얼 등 |
| SSCC(Serial Shipping Container Code, 물류 단위 식별 코드) | 운송·보관을 위한 박스·팔레트·소포 | 물류 단위 키와 포함 관계 |

로트 문자열이나 시리얼 문자열만을 세계적으로 고유한 값으로 가정하지 않는다. 하나의 팔레트는 서로 다른 SKU·로트를 포함할 수 있으며, SSCC가 상품 GTIN을 대체하는 것도 아니다. Lot은 모든 Serial의 필수 부모라는 단일 계층보다 개체의 속성과 물류 포함 관계를 구분하는 편이 정확하다.

```mermaid
flowchart LR
    S[내부 SKU] --> M[거래 품목과 포장 매핑]
    M --> G[GTIN]
    G --> I[개체: GTIN과 Serial]
    I --> L[Lot 속성]
    I --> C[현재 포함된 박스]
    C --> P[상위 팔레트 SSCC]
```

## 2. 한 번 스캔이 한 개를 뜻하지 않는다

학습용 예로 내부 SKU가 낱개 재고를 관리하지만 스캔 코드는 낱개·6입 상자·공급사 라벨로 여러 개일 수 있다. 상자를 스캔하면 기준 단위로 6개를 반영해야 한다. 거래 품목의 포장 수준과 환산을 무시하면 재고가 6배 차이 난다.

```text
barcode_mapping:
  issuer_namespace, identifier_type, identifier_value
  internal_sku_id, packaging_level, base_uom, units_per_scan
  valid_from, valid_to, mapping_revision, recorded_at

raw_scan:
  event_id, raw_payload, symbology, occurred_at, received_at
  resolved_identifier, mapping_revision, resolved_quantity
```

같은 코드가 중복 유효 기간에 서로 다른 SKU로 해석되지 않게 한다. 묶음 상품이 여러 SKU의 구성품이라면 단일 `units_per_scan`이 아닌 구성 명세와 개정판이 필요하다. 환산은 정수 개수뿐 아니라 중량·길이 단위의 정밀도도 다룬다.

표준 코드 재사용을 임의로 허용하는 정책을 만들지 않는다. 내부·공급사 코드의 변경이나 잘못된 매핑 정정은 발급 범위·표준 규칙에 맞추고, 과거 스캔에는 당시 적용한 매핑 개정판을 남긴다. 잘못된 매핑을 고쳤다고 과거 재고를 자동 재계산하면 중복 입고가 생길 수 있어 정정·대사가 필요하다.

## 3. GS1 데이터는 고정 길이 숫자 한 덩어리가 아니다

AI(Application Identifier, 응용 식별자)는 GS1 바코드 속성의 의미와 형식을 나타내는 접두어다. 대표적으로 01은 GTIN, 10은 배치/로트, 21은 시리얼, 00은 SSCC다. 이는 AI 인공지능이라는 뜻과 다르다.

```text
사람이 읽는 예시 표기:
(01)09506000134352(10)LOT-A(21)SER-0007

의미:
GTIN = 09506000134352
lot = LOT-A
serial = SER-0007
```

괄호는 사람이 읽는 표기이며 스캐너가 보내는 원문에 그대로 들어온다고 가정하지 않는다. 가변 길이 필드의 구분자와 심볼 종류를 지원하는 파서를 사용한다. 식별 값은 숫자 자료형 변환으로 선행 0을 잃지 않게 문자열로 저장한다. Check Digit(검사 숫자)은 입력 오류 검출을 도울 뿐 진품임을 증명하지 않는다.

원문 파싱, 표준 형식 검증, 내부 매핑, 현재 허용 업무 검증을 분리한다. 형식이 맞는 개체라도 이미 출고됐거나 다른 입고 문서에 등록됐다면 재입고 허용 정책을 따로 확인한다. 알 수 없는 코드를 임의의 기본 SKU로 처리하지 말고 예외 작업대로 보낸다.

## 4. 로트와 시리얼은 회수 범위와 작업 비용의 선택이다

가상의 로트 1,000개 중 문제가 있는 개체가 10개라고 하자. 로트만 추적하면 해당 로트와 연결된 출고 전체를 조사할 수 있다. 시리얼을 모든 필수 단계에서 기록했다면 특정 개체의 경로를 좁힐 수 있지만, 누락·잘못된 집계 관계가 있으면 정밀도가 떨어진다. 시리얼 추적 자체가 “항상 10개만 회수”를 보장하지 않는다.

| 선택 | 운영 부담 | 얻는 정보와 한계 |
|---|---|---|
| 로트 | 묶음 스캔·수량 확인 중심 | 묶음 단위 출처·출고 연결; 개별 위치는 불명확할 수 있음 |
| 시리얼 | 개별 식별·중복·누락 처리 | 개체별 이력; 잘못된 부모 관계와 누락 이동은 대사 필요 |
| 물류 단위 집계 | 포장 시 포함 목록 검증 | 이후 상위 단위 스캔으로 추적 가능하나 개봉·재포장 시 갱신 필수 |

선택은 제품 위험·회수 요구·거래처 계약과 스캔 비용에 따라 정한다. 일반 카드에서 특정 산업의 법적 추적 의무를 임의로 단정하지 않는다.

## 5. 합포장과 분할은 포함 관계의 사건이다

박스 B1의 개체 S1을 B2로 옮길 때 B1의 현재 목록만 덮어쓰면 과거 “어느 박스에 실렸나”를 잃는다. 분리와 추가 사건에 event ID, 발생·기록 시각, 작업자, 장소, 부모·자식, 정정 참조를 남긴다. GS1 EPCIS의 Aggregation(집계) 개념과 연결할 수 있으나 아래는 자체 모델 예다.

```text
09:00 ADD    parent=B1 child=S1
10:00 DELETE parent=B1 child=S1
10:00 ADD    parent=B2 child=S1
11:00 ADD    parent=P1 child=B2
```

같은 시각의 두 관계도 업무 거래 ID와 순서로 연결한다. 현재 포함 관계는 순환할 수 없고 하나의 개체가 동시에 두 물리 박스에 들어갈 수 없다는 제약을 둔다. 중복 스캔은 event ID뿐 아니라 작업 명령과 개체 상태도 검증한다. 수량 단위 비시리얼 상품은 포장 전후 수량 보존과 혼합 로트의 명세를 확인한다.

> **면접 포인트**
>
> 지연 수신·정정 때 발생 시각과 기록 시각을 구분한다. 원문·해석 개정판·포함 관계 이력을 보존해야 과거에 알았던 내용과 나중에 정정한 사실을 각각 재구성할 수 있다. 단순 `barcode → SKU` 테이블 하나로는 충분하지 않다.

## 참고 자료

- [GS1 응용 식별자](https://ref.gs1.org/ai/)
- [GS1 추적성 표준](https://www.gs1.org/standards/gs1-global-traceability-standard/current-standard)
- [GS1 SSCC](https://www.gs1.org/standards/id-keys/sscc)
- [GS1 EPCIS 2.0.1](https://ref.gs1.org/standards/epcis/2.0.1/)$review_19$
WHERE slug = 'logistics-12-sku-barcode-serial' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_20$## 1. 원본과 현재 상태를 분리한다

단말은 안정적인 Event ID, 장치 시각, 수집 시각, 작업자와 위치를 보낸다. 원본 이벤트는 추가만 하고 현재 배송 상태는 규칙에 따라 다시 만들 수 있는 투영으로 관리한다.

```mermaid
flowchart LR
    D[스캐너·오프라인 큐] --> I[멱등 수집]
    I --> E[(불변 이벤트 로그)]
    E --> P[상태 투영]
    C[정정 이벤트] --> E
    P --> A[예외 알림]
```

| 이상 | 판별 단서 | 처리 |
|---|---|---|
| 중복 | 동일 Event ID | 한 번만 반영 |
| 역전 | 업무 단계·장치/수집 시각 | 보류 후 재정렬 |
| 누락 | 허용 상태 전이 위반 | 보정 작업 생성 |
| 오스캔 | 관리자 승인 | 취소·대체 이벤트 추가 |

```json
{"eventId":"device-7:8841","shipmentId":"S1","type":"LOADED","deviceAt":"...","ingestedAt":"..."}
```

> **운영 원칙** — 장치 시각만 신뢰하지 않는다. 시간대 오류와 시계 보정이 있으므로 업무 순서, 시설 이동 가능 시간, 수집 시각을 함께 사용한다.

## 2. 시각 세 개와 순번의 범위

다음은 가상 설계이며 특정 물류사의 운영 규칙이 아니다. `occurred_at`은 현장 발생 시각, `received_at`은 수집 시각, `recorded_at`은 서버가 내구성 있게 저장한 시각이다. 단말 시각은 오차가 있을 수 있고 오프라인 큐는 늦게 전송된다. 같은 시각 필드로 세 의미를 대신하지 않는다.

단말 순번은 `device_id + boot_id + sequence`처럼 재시작 후 재사용을 방지한다. 이는 **그 단말 내부의 순서**이지 화물 전체의 전역 순서가 아니다. 단말 두 대가 스캔한 사건은 시설 이동·업무 단계·신뢰할 수 있는 업무 버전과 함께 판단한다. 모든 입력을 단말 Timestamp로 정렬하면 완료 상태가 과거 집하로 되돌아갈 수 있다.

| 수신 사례 | 원본 이력 | 현재 상태 판단 |
|---|---|---|
| 같은 Event ID·같은 내용 | 중복 전달 기록 가능 | 효과 반복 안 함 |
| 같은 Event ID·다른 내용 | 충돌 증거 보존 | 자동 덮어쓰기 금지 |
| 완료 뒤 늦은 집하 | 늦은 원본 추가 | 완료를 과거 단계로 되돌리지 않음 |
| 완료 오스캔 정정 | 승인된 정정 추가 | 참조한 원본과 규칙을 재평가 |
| 불가능한 시설 이동 | 원본 보존·의심 표시 | 예외 큐와 현장 확인 |

## 3. 정정은 새 증거를 추가한다

아래 JSON은 앱 자체 이벤트 모델이며 GS1 EPCIS 표준 페이로드를 그대로 구현한 예제가 아니다. 잘못된 원본 ID, 정정 사유, 승인 주체, 대체 사건을 연결한다.

```json
{
  "eventId": "correction-42",
  "shipmentId": "S1",
  "type": "SCAN_CORRECTED",
  "correctsEventId": "device-7:boot-3:8841",
  "reason": "WRONG_SHIPMENT",
  "approvedBy": "operator-18",
  "replacementEventId": "device-7:boot-3:8848",
  "ruleVersion": 3
}
```

원본 UPDATE로 내용을 없애면 과거 고객 알림·정산·운영 판단의 근거가 사라진다. 정정도 누가 어떤 권한으로 했는지 남기고 동일 정정의 재전달을 중복 적용하지 않는다. 승인되지 않은 외부 입력이 과거 사건을 취소할 수 없게 한다.

## 4. Shadow 투영을 검증하고 교체한다

1. 화물·시간 범위와 원본 로그의 체크포인트를 고정한다. 투영 규칙 버전도 함께 기록한다.
2. 같은 원본과 정정을 새 투영에 재생한다. 알림·정산·외부 호출 소비자는 재생에서 분리한다.
3. 현재 상태뿐 아니라 참조 Event ID, 적용·보류 수, 버전 공백을 비교한다.
4. 체크포인트 이후 유입을 따라잡는다. 기존 투영과 같은 기준점인지 확인한 뒤 읽기 대상 버전을 원자적으로 교체한다.
5. 이전 투영을 보존해 되돌릴 수 있게 하고 차이를 원본 삭제로 맞추지 않는다.

가정: 대상 120만 건, 측정 재생 속도 2,000건/초면 초기 재생은 약 10분이다. 그동안 초당 200건이 추가되면 12만 건이 더 쌓인다. 따라잡기 단계에는 새 유입을 뺀 순처리율과 여유 시간을 반영한다. 처리 이벤트 수만 같아도 결과는 다를 수 있으므로 상태 차이를 검증한다.

> **검수 기준 — 2026-09-12**: 원본 보존·정정·재생 절차를 가상 구현으로 구체화했다. [GS1 EPCIS 2.0.1](https://ref.gs1.org/standards/epcis/2.0.1/)의 발생 시각·기록 시각·오류 선언 개념을 참고하되 실제 표준 연동은 스키마 적합성을 별도로 검증한다.


## 5. 재처리 안전성

투영은 Event ID와 버전을 기록해 멱등하게 갱신한다. 규칙 변경 시 특정 화물 범위만 Shadow 투영으로 재생하고 결과 차이를 확인한 뒤 교체한다.

> **면접 포인트** — 이상 이벤트를 억지로 정상 순서에 끼워 넣기보다 원본 보존, 예외 큐, 승인, 재투영의 감사 가능한 흐름을 설계한다.$review_20$
WHERE slug = 'logistics-13-scan-event-correction-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_21$## 1. 내부 계약을 안정시킨다

주문 시스템은 운송사별 필드와 상태를 직접 알지 않는다. Gateway가 주소, 서비스 등급, 라벨, 취소, 추적을 공통 명령으로 받고 Adapter가 외부 계약으로 변환한다.

```mermaid
flowchart LR
    O[출고 시스템] --> G[Carrier Gateway]
    G --> A1[Carrier A Adapter]
    G --> A2[Carrier B Adapter]
    A1 --> W[Webhook 수집]
    A2 --> W
    W --> T[공통 추적 상태]
```

| 경계 | 핵심 장치 | 목적 |
|---|---|---|
| 라벨 요청 | 내부 멱등 키·외부 참조 | 중복 송장 방지 |
| 상태 변환 | 원본+공통 상태 동시 저장 | 정보 손실 추적 |
| Webhook | 서명·중복 제거·Inbox | 위조·재전송 대응 |
| 정산 | 청구서와 예상 운임 대사 | 과금 오류 탐지 |

```text
internal_status = map(carrier, carrier_status)
store carrier_payload, mapping_version, occurred_at, received_at
```

> **실무 함정** — Timeout 직후 새 요청 번호로 재시도하면 송장이 둘 생길 수 있다. 동일 참조로 조회하거나 결과 미상 상태를 운영 큐로 보낸다.

## 2. 요청 계약과 결과 불명 상태

가상 모델에서 출고 명령마다 `shipment_id + label_revision`을 내부 업무 키로 둔다. 같은 라벨 재시도는 같은 키, 주소 변경으로 새 라벨을 만드는 것은 새 revision(개정 번호)이다. 주소·박스·서비스 등급의 정규화된 요청 지문을 저장해 같은 키에 다른 내용을 보내지 못하게 한다.

```text
POST /label-requests
  shipment_id, revision, address, parcel, service_level

GET /label-requests/{operation_id}
  status: PENDING | SUCCEEDED | FAILED | UNKNOWN
  carrier_reference, tracking_number, label_reference
```

내부 DB에는 명령과 발행 대기 기록을 함께 저장한다. Worker가 운송사를 호출하고 결과를 별도 트랜잭션으로 저장한다. 운송사가 멱등 키를 지원하면 안정된 같은 키를 전달한다. 지원하지 않으면 가맹점 참조로 조회 가능한지 확인한다. 두 기능 모두 없고 결과가 불명확하면 자동 재발급을 멈추고 대사 대상으로 보낸다.

| 상황 | 재시도 판단 |
|---|---|
| 연결 전 확정 실패 | 계약·예산 안에서 재시도 |
| 요청 후 응답 Timeout | 접수 여부 불명, 같은 참조 조회·대사 |
| 성공 후 로컬 저장 실패 | 외부 참조로 기존 라벨 회수 |
| 같은 키의 주소 변경 | 기존 요청과 충돌, 명시적 개정 필요 |
| 대체 운송사 전환 | 기존 접수·취소 가능성 확인 후 새 명령 |

## 3. 상태 축약과 Webhook 저장

운송사의 `DELIVERY_ATTEMPTED`, `ADDRESS_ISSUE`, `HELD_AT_DEPOT`를 모두 내부 `EXCEPTION`으로 묶으면 고객 안내에 필요한 이유가 사라진다. 공통 단계와 원본 코드·사유·발생 시각·수신 시각·매핑 버전을 함께 보존한다. 모르는 코드는 임의로 배송 중에 넣지 않고 UNKNOWN_MAPPING으로 격리한다.

Webhook(외부 이벤트 통지)의 서명 검증은 공급자 규격에 따라 수행하고, 필요한 원본 바이트를 파싱 전에 검증한다. 검증된 이벤트를 Inbox에 내구성 있게 저장한 후 성공 응답을 보낸다. 저장 전에 성공 응답하면 이후 장애에서 이벤트가 사라질 수 있다. 무거운 상태 계산은 비동기로 수행한다.

## 4. Polling과 대사를 함께 운영한다

진행 중 운송장과 결과 불명 요청에 조회 예산을 우선 배정한다. 공급자의 호출 제한·페이지 크기·재시도 대기·조회 이력 보존을 확인한다. 오래된 완료 건은 낮은 빈도로 확인하되 정정 가능 기간에는 재조회 대상으로 유지한다.

가정: 진행 중 10만 건을 5분마다 개별 조회하면 약 333요청/초가 필요하다. 허용량이 50요청/초라면 단순 Polling(주기 조회)은 불가능하다. 배치 조회 지원, 우선순위별 주기, Webhook과 변화 시점 조회를 조합한다. 배치당 100건이면 산술상 약 3.3요청/초지만 실제 공급자가 그 API와 크기를 지원할 때만 유효하다.

정산 대사는 “요청한 라벨 수”가 아니라 실제 발급·취소·집하·청구 식별자를 연결한다. 누락 Webhook을 Polling으로 채웠다고 실제 물건의 위치까지 증명되는 것은 아니다. 현장 스캔·운송사 사건·금액 차이의 증거를 보존한다.

> **검수 기준 — 2026-09-12**: 운송사와 수치는 가상이다. [Stripe Webhook 문서](https://docs.stripe.com/webhooks)의 서명·중복·순서·재전송 사례를 외부 API 설계 참고로 사용하며, 운송사가 같은 계약을 제공한다고 가정하지 않는다. [멱등 요청 계약](https://docs.stripe.com/api/idempotent_requests) 역시 실제 운송사별 지원을 확인해야 한다.


## 5. 격리와 전환

운송사별 Rate Limit, Circuit Breaker, 자격 증명과 지표를 분리한다. 장애 시 서비스 가능 지역과 마감 시간까지 고려해 대체 운송사를 고르며 이미 발급한 라벨의 취소 가능성을 확인한다.

> **면접 포인트** — Adapter 패턴에서 멈추지 말고 결과 미상, 상태 대사, 계약 버전, 운임 정산까지 수명주기를 닫는다.$review_21$
WHERE slug = 'logistics-14-carrier-gateway-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_22$## 1. 요구와 보장 범위를 고정한다

특정 기업의 내부 구현이 아닌 **학습용 익일·당일 배송망**이다. 재고·출고·간선·허브·라스트마일을 종단 약속으로 연결한다. SLO(Service Level Objective, 서비스 수준 목표)는 최초 확정 배송 구간 안의 도착률로 정의하고, 취소·미완료·부분 배송의 분모 규칙을 명시한다. 빠른 배송을 구매 화면에 표시한 것과 실제 예약이 확정된 것을 구분한다.

가상의 요구는 권역별 당일 배송, 품목별 분할 허용 여부, 결제 중 짧은 임시 예약, 최초 약속 변경 이력 보존이다. 실물 집하 후 취소는 역물류로 처리한다. 허용 중간 상태와 수동 운영 절차도 기능 요구다.

## 2. 같은 단위로 용량을 계산한다

가상 센터의 마감까지 남은 시간이 30분이고 주문당 평균 2개 품목이라고 하자. 아래 값은 대기 주문을 아직 차감하지 않은, 같은 잔여 구간의 작업량이다.

| 구간 | 측정된 잔여 처리량 | 주문 환산 |
|---|---|---:|
| 피킹 | 품목 1,200개 | 평균 2개 가정 시 600건 |
| 패킹 | 소포 500개 | 주문당 소포 1개면 500건 |
| 간선 | 남은 적재 구간 | 이 주문 구성에서 450건 상당 |
| 라스트마일 | 잔여 서비스 시간·동선 | 이 목적지 구성에서 400건 상당 |

단순 비교에서는 최대 400건이지만 실제로 모든 주문이 서로 다른 SKU·중량·부피·목적지를 가진다. “Stop(방문 지점) 400개=주문 400건”도 같은 주소 묶음과 서비스 시간에 따라 달라진다. 각 제약에 주문의 수요량을 별도로 배분하고 이미 예약된 작업을 차감한다. 평균 2개라는 가정은 품목 구성이 바뀌면 다시 계산한다.

주문이 900건 유입되면 500건을 기존 약속에 억지로 넣지 않는다. 대체 센터·더 늦은 배송 구간·주문 제한을 후보로 제시한다. 센터 추가가 해결책이 되려면 해당 센터의 재고와 운송편까지 실제로 가능해야 한다.

## 3. 경로상의 선후 관계로 날짜를 계산한다

```mermaid
flowchart LR
    API[Checkout] --> P[약속 계산과 후보 노드]
    P --> I[재고 예약]
    P --> C[작업·운송 용량 예약]
    I --> O[주문 계획과 상태]
    C --> O
    O --> W[창고 작업]
    W --> L[간선과 허브]
    L --> R[배송 경로]
    R --> E[도착 증빙]
    E --> M[약속 정확도와 대사]
```

`max(재고 준비, 피킹 완료, 간선 도착, 배송 ETA)`만으로 시간을 계산하면 앞 단계 지연이 출발편을 놓치는 효과를 숨긴다. 각 단계의 완료를 다음 단계의 입력으로 전달해야 한다.

```text
ready = max(공급 사용 가능 시각, 주문 처리 가능 시각)
packed = earliest_feasible_pick_pack_finish(ready, remaining_capacity)
departure = next_departure_after_loading(packed, dock_calendar)
hub_ready = unload_and_sort(arrive(departure), hub_capacity)
delivery_window = feasible_route_window(hub_ready, destination, route_capacity)
```

가상으로 패킹이 13:50에 끝나고 적재 15분, 간선 출발 14:00이면 그 편을 탈 수 없다. 패킹 완료 시각만 14:00보다 빠르다고 수락하면 안 된다. 창고 현지 시간대·마감 포함 여부·공휴일을 캘린더에 넣는다. 구간별 p95를 더해 종단 p95라고 부를 수도 없다. 같은 날 날씨·혼잡으로 지연이 상관될 수 있으므로 실제 종단 분포와 실패 시나리오를 평가한다.

## 4. API와 상태 모델

```text
POST /promise-quotes
  draft_id, lines[sku, qty, uom], destination, split_policy
  -> quote_id, plan_revision, delivery_windows, expires_at

POST /orders
  request_id, quote_id, draft_hash
  -> order_id, status

plan_leg:
  plan_id, revision, leg_no, resource_id, time_bucket,
  demand_vector, hold_id, hold_state
```

`request_id`는 중복 주문을 막고 같은 키·다른 요청은 거절한다. 조회 견적만으로 재고를 확보한 것은 아니다. 확정에는 각 자원 Hold(임시 예약)를 확인한다. 분리된 서비스는 한 번의 DB 거래로 묶을 수 없으므로 예약 Saga(단계별 거래와 보상), 자원 사전 할당 등 일관성 전략을 명시한다.

부분 예약 성공은 `RESERVING`으로 유지하고 기한 안에 완성하거나 해제한다. 결제 결과가 불명확한 동안 TTL(Time to Live, 유효 기간) 만료를 실패로 간주하지 않는다. 결제 조회·대사와 예약의 조건부 전이를 연결한다. 상태 변경과 다음 명령은 Outbox(발행 의도 저장)로 연결하고 소비자는 중복을 처리한다.

## 5. 마감 직전 배분과 장애 대응

먼저 온 주문·유료 서비스·상품 특성 등 우선순위를 업무 정책으로 정한다. 이미 확정한 약속을 보호하면서 신규 수락을 제한한다. 가까운 센터만 선택하면 그 센터의 도크·패킹 병목을 악화시킬 수 있다. 가능 후보를 제약으로 거른 뒤 비용·지연 위험을 비교하고 재계획 횟수를 제한한다.

| 장애 | 즉시 보호 | 복구·고객 처리 |
|---|---|---|
| 패킹 설비 중단 | 해당 시간 구간 신규 수락 축소 | 대체 라인·센터의 실제 여유 확인 |
| 재고 차이 | 영향 SKU·위치 예약 제한 | 대체 재고, 실사, 약속 변경 선택지 |
| 간선 취소 | 해당 편에 의존한 계획 식별 | 다음 편·대체편 재예약과 도착 재계산 |
| 운송 응답 지연 | 기존 명령 ID 유지·상태 불명 | 조회·대사 후 확정, 중복 라벨/배차 방지 |
| 현장 통신 단절 | 승인된 작업 범위로 운영 | 단말 작업 ID·순번 동기화와 예외 대사 |

영향 권역만 제한하려면 주문 계획이 어떤 자원·편·버전에 의존하는지 역조회할 수 있어야 한다. 전체 빠른 배송을 끄는 것보다 세분화된 제어는 유용하지만, 의존성이 불명확한 상태에서 부분 영향만 있다고 낙관하지 않는다.

## 6. 비용과 품질의 검증

빠른 배송률만 목표로 두면 작은 소포 분할, 낮은 차량 적재율, 긴급 보충과 초과 작업이 늘 수 있다. 주문당 전체 비용·오배송·파손·재배송·작업 부하·원래 약속 준수율을 함께 본다. 작업 안전·온도·적재 한계는 비용 점수로 상쇄할 수 없는 제약이다.

> **면접 포인트**
>
> 수요 재생 실험에서 평시뿐 아니라 마감 직전 폭증·간선 한 편 취소·재고 부족을 넣는다. 수락률만 보지 말고 수락한 약속의 실제 이행 가능성과 거절·재약속 고객 경험을 확인한다. 이 카드의 수치는 학습용이며 운영 처리량 측정 결과가 아니다.

## 참고 자료

- [Oracle 공급과 배송 약속](https://docs.oracle.com/en/cloud/saas/supply-chain-and-manufacturing/25c/fascp/overview-of-global-order-promising.html)
- [OR-Tools 시간창 경로 제약](https://developers.google.com/optimization/routing/vrptw)
- [OR-Tools 차량 용량 제약](https://developers.google.com/optimization/routing/cvrp)$review_22$
WHERE slug = 'logistics-15-rocket-delivery-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_23$## 1. 빠른 후보와 정교한 점수를 분리한다

실제 기업 구현을 단정하지 않고 실시간 배차 문제를 모델링한다. 위치 Cell로 가까운 후보를 빠르게 줄인 뒤 도착 예상, 적재 여유, 약속 위반 위험, 이동 방향을 점수화한다.

```mermaid
flowchart LR
    O[새 주문] --> G[공간 후보 검색]
    R[라이더 위치 Stream] --> G
    G --> S[제약·점수 계산]
    S --> L[짧은 제안 Lease]
    L -->|거절·만료| S
    L -->|수락| A[Assignment]
```

| 단계 | 지연 목표 | 정확성 요구 |
|---|---|---|
| 후보 검색 | 매우 짧음 | 일부 여유 있는 Recall |
| ETA·점수 | 짧음 | 최신 도로·준비 시간 반영 |
| 제안 | 제한 시간 | 한 주문의 단일 확정 |
| 재배차 | 이벤트 기반 | 취소 비용·공정성 고려 |

```text
score = pickup_eta + delivery_lateness_penalty + detour_cost + fairness_penalty
assignment succeeds only if order_version and rider_capacity still match
```

> **실무 함정** — 위치 업데이트마다 전역 최적화를 다시 하면 계산과 배차 흔들림이 커진다. 의미 있는 이벤트와 재최적화 최소 간격을 둔다.

## 2. 공간 후보의 누락과 과다를 분리한다

작은 Cell(공간 격자)은 한 셀의 후보 수를 줄이지만 반경 검색에 여러 이웃 셀을 조회해야 한다. 큰 셀은 조회 셀 수가 줄어도 거리와 무관한 후보를 많이 가져온다. 셀 경계 양쪽의 가까운 기사를 놓치지 않도록 겹치는 셀을 모두 찾고 실제 거리·도로 ETA(Estimated Time of Arrival, 도착 예상 시간)로 다시 거른다.

가정: 한 주문마다 500명 전원에게 경로 계산을 요청하면 주문 100건/초에서 초당 5만 번 계산한다. 공간·상태 필터로 30명으로 줄이면 초당 3,000번이다. 이 계산은 병목 후보를 찾는 예시이며 셀 크기의 정답은 아니다. 후보 Recall(실제 가능한 후보를 포함하는 비율), 오래된 위치 비율, 계산 시간으로 선택한다.

위치 업데이트는 기사별 순번·수집 시각을 함께 저장한다. 단절로 오래된 위치라면 “가까움”을 확정 근거로 사용하지 않는다. 후보 탐색의 최신성보다 최종 배차 확정의 정합성을 더 엄격하게 유지한다.

## 3. 제안 점유와 최종 확정은 별개다

아래는 기사당 하나의 활성 제안만 허용하는 가상 정책이다. 실제 묶음 배달에서는 기사 전체가 아니라 남은 용량의 슬롯을 예약할 수도 있다. 주문의 버전만 검사하면 같은 기사에게 다른 주문 두 개가 동시에 제안될 수 있다.

```text
short transaction:
    lock order and rider rows in consistent order
    verify order is unassigned and expected order version matches
    verify rider has capacity and no active offer under this policy
    reserve offer for BOTH order and rider, with token and expires_at
    persist notification command
commit

on acceptance:
    transactionally verify token, state, expiry and both reservations
    consume reserved capacity and confirm assignment exactly once
```

```mermaid
stateDiagram-v2
    [*] --> OFFERED
    OFFERED --> ACCEPTED: 유효 Token과 양쪽 점유 확인
    OFFERED --> EXPIRED: 만료 전이 선점
    OFFERED --> REJECTED: 거절
    EXPIRED --> [*]
    REJECTED --> [*]
    ACCEPTED --> PICKED_UP: 인수 완료
```

만료 처리와 수락은 같은 상태 조건으로 경쟁한다. 이미 EXPIRED인 제안의 늦은 수락은 새 제안을 훼손하지 못하도록 Token을 확인한다. 기사에게 보내는 알림은 트랜잭션 밖에서 전달하지만, 알림 명령은 함께 저장해 커밋 후 종료에도 재시도한다. 여러 DB에 주문·기사 상태가 나뉘면 위 트랜잭션을 가정할 수 없으므로 예약 프로토콜이나 데이터 소유 경계를 다시 설계해야 한다.

## 4. 불가능한 해를 점수로 숨기지 않는다

적재 한도, 인수 전 배달 금지, 근무 가능 시간 같은 Hard Constraint(필수 제약)를 먼저 적용한다. 그 다음 추가 이동, 지각 위험, 음식 보관 시간과 기회 편차를 Soft Cost(조정 가능한 비용)로 비교한다. 시간과 거리와 금액을 단위 변환 없이 더하지 않는다.

```text
cost_in_seconds = extra_travel_seconds
                + 3 * predicted_late_seconds
                + 2 * extra_food_holding_seconds
                + fairness_penalty_seconds
```

가상 후보 A가 `(60, 0, 20, 10)`이면 비용은 110초, B가 `(20, 40, 10, 0)`이면 160초다. 이동만 보면 B지만 지각 비용까지 보면 A가 선택된다. 가중치는 예시이며 사용자 약속·품질·기사 기회 분포를 실제 데이터로 평가해 정한다.

차량 경로 문제의 시간 창과 미배정 벌점은 구현 가능한 출발점이지만, 모든 주문을 무조건 배정하는 것이 정답은 아니다. 허용 제약을 만족하는 해가 없으면 미배정·지연 안내·운영 개입으로 드러낸다. 재최적화는 이득이 작은 변경으로 기사의 경로가 계속 흔들리지 않도록 최소 개선폭·주기·인수 이후 변경 제한을 둔다.

> **검수 기준 — 2026-09-12**: 배차 정책·수치는 가상이다. [OR-Tools 시간 창](https://developers.google.com/optimization/routing/vrptw)과 [미방문 벌점](https://developers.google.com/optimization/routing/penalties)을 참고해 제약·목적 함수를 구분했다. 동시 제안의 DB 모델은 이 카드의 자체 설계 예제다.


## 5. 실패 처리와 지표

제안은 만료되는 Lease로 만들고 확정은 주문·라이더 버전 조건부 갱신으로 처리한다. 배차 시간뿐 아니라 약속 위반, 취소, 공차 거리, 라이더별 기회 편차를 함께 본다.

> **면접 포인트** — 지리 검색, 최적화 알고리즘, 동시성 제어, 사람에게 미치는 품질 지표를 한 흐름으로 연결한다.$review_23$
WHERE slug = 'logistics-16-realtime-dispatch-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_24$## 1. 면접 조건: 평균 속도보다 흐름을 설명한다

가상의 풀필먼트 센터에서 주문이 피킹·패킹·분류·출고를 거친다. WIP(Work in Process, 공정 안의 미완료 작업)와 완료 처리량을 주문·품목·소포 중 어떤 단위로 측정하는지 먼저 합의한다. 입고·적치는 출고의 공급 경로이지만 모든 주문이 주문 접수 이후 새 입고를 거치는 직렬 공정은 아니다.

```mermaid
flowchart LR
    R[입고와 적치] --> B[보관 재고]
    B --> F[피킹 구역 보충]
    F --> P[피킹]
    O[주문 릴리스] --> P
    P --> K[패킹]
    K --> S[분류와 출고]
    P --> E[부족·파손 예외]
    E --> V[재고와 예약 재검증]
    V --> P
```

| 라운드 | 제시 상황 | 답변에 포함할 것 |
|---|---|---|
| R1 병목 | 주문 증가, 출고 처리량 정체 | 단위·구간별 유입/완료·대기·재작업 |
| R2 Wave | 피킹 생산성 개선, 배송 지연 증가 | 묶음 대기와 하류 순간 부하 |
| R3 예외 | 실물 부족, 자동 작업 재시도 | 중복 제어·소유자·재합류 조건 |

## 2. R1 — “인력을 어디에 더 넣겠습니까?”

**질문:** 주문은 시간당 1,200건이다. 피킹은 시간당 3,000품목, 패킹은 900소포, 출고는 1,100소포를 처리한다. 어느 곳이 병목인가?

**답변 예시:** “주문당 평균 2품목·1소포라는 가정이면 피킹은 1,500주문/시간, 패킹은 900주문/시간입니다. 같은 시간대의 실제 처리율이라면 패킹을 우선 의심하겠습니다. 유입 1,200에 완료 900이 지속되면 미완료 주문이 시간당 약 300건 증가합니다. 다만 가동 중 속도와 교대 전체의 실효 속도를 섞지 않고, 상품 구성·재작업·설비 대기도 확인하겠습니다.”

900이 작업 중 생산성인지 휴식·중단을 포함한 실효 생산성인지 구분한다. 이미 실효치라면 Availability(가동률)를 다시 곱해 이중 차감하지 않는다. 주문 분할이 늘어 소포/주문 비율이 바뀌면 패킹 환산도 바뀐다.

```text
같은 범위와 단위의 근사:
WIP 변화/시간 = 유입률 - 완료율
안정 상태 평균 WIP = 평균 처리량 × 평균 체류 시간
예: 900건/시간 × 20/60시간 = 평균 300건
```

Little의 법칙을 계속 큐가 증가하는 과부하 구간에 대입해 고정 대기 시간을 예측하지 않는다. 위 300건은 안정 상태의 평균 예시이며 p95나 최대 지연이 아니다.

**후속 압박:** “패킹 앞에 물건이 없는데 패킹 완료율이 낮으면요?”

낮은 완료율만으로 패킹 능력이 부족하다고 볼 수 없다. 공급이 없는 Starvation(작업 공급 부족), 하류가 막힌 Blocking(진행 차단), 설비 장애·인력 부족·라벨 재작업을 분리한다. 피킹의 작업 완료와 실물 인계 완료가 다른지도 확인한다.

| 신호 | 가설 | 확인 |
|---|---|---|
| 패킹 앞 WIP와 대기 상승 | 패킹 병목 | 작업 중 속도·중단·상품 구성 |
| 피킹 작업은 많지만 완료 부족 | 보충·동선·결품 | 위치별 부족·보충 대기 |
| 패킹 완료 후 체류 상승 | 분류·출고 제한 | 편별 출차 마감·도크 점유 |
| 재작업 증가 | 품질 결함 | 라벨·상품·수량 오류 원인 |

## 3. R2 — “피킹은 빨라졌는데 주문이 왜 늦죠?”

Wave(작업 파동)는 묶어서 이동·설비 효율을 높이지만 묶음이 찰 때까지의 대기와 하류에 한꺼번에 도착하는 부하가 생긴다. 피킹 완료 시간만 최적화하면 마감이 가까운 주문도 큰 묶음의 마지막 작업을 기다릴 수 있다.

**답변 예시:** “30분마다 Wave를 여는 단순 정책에서 균등하게 도착하는 주문은 릴리스만 평균 약 15분 기다릴 수 있습니다. 이는 균등 유입 가정이고 프로모션 폭증에는 달라집니다. 피킹 시간 3분을 줄였어도 추가 대기 10분이면 종단 시간은 악화됩니다. 작은 Wave·마감 임박 주문의 별도 릴리스·하류 WIP 상한을 비교하겠습니다.”

보충이 끝나야 수행 가능한 할당을 먼저 풀어 현장에 일을 쌓지 않는다. Oracle WMS의 보충 연계 Wave처럼 실제 제품에서도 피킹과 보충 의존성을 관리하지만, 여기의 임계값과 릴리스 정책은 자체 설계 예다.

**후속 압박:** “그러면 한 주문씩 바로 내리면 되죠?”

작은 묶음은 대기를 줄일 수 있지만 이동·설비 전환·소포 분류 비용이 커질 수 있다. 주문 유형별로 크기와 최대 대기 시간을 함께 제한하고, 시간 내 출고 비율·오류·총 작업 시간을 동일 주문 구성에서 비교한다.

## 4. R3 — “장부 3개인데 위치에는 1개뿐입니다”

Short Pick(피킹 수량 부족)은 재고 2개를 즉시 삭제하거나 같은 작업을 무한 재시도할 문제가 아니다. 실제 1개를 피킹했는지, 다른 토트에 있는지, 보충 중인지, 단위 환산이 틀렸는지부터 확인한다.

```text
NORMAL -> SHORT_REVIEW
SHORT_REVIEW -> REASSIGNED -> PICKING
SHORT_REVIEW -> WAIT_REPLENISHMENT -> PICKING
SHORT_REVIEW -> CUSTOMER_DECISION -> PARTIAL_OR_CANCEL

예외 레코드:
exception_id, order_line_id, task_id, task_version, reservation_id,
expected_qty, confirmed_picked_qty, observed_qty, uom,
location_id, reason, owner, next_check_at, evidence_ref
```

이미 피킹한 1개는 실물 토트와 주문 할당에 유지하고 부족분 2개의 대체 예약만 처리한다. 예외에서 돌아올 때 기존 예약·주문 취소 여부·기존 작업 버전을 재검증한다. 이전 단말의 늦은 성공이 오면 새 작업 완료로 중복 반영하지 않게 명령 ID와 허용 상태를 검사한다.

**답변 예시:** “부족분에 대한 예외를 담당자와 확인 기한이 있는 큐에 격리하겠습니다. 정상 주문을 보호하면서 대체 위치 예약·보충·고객의 부분 출고 선택을 진행합니다. 복구 후에는 미완료 수량과 유효 예약만으로 새 작업을 만들고, 이미 완료된 피킹을 다시 시키지 않습니다. 원장 조정은 실사·승인으로 별도 게시합니다.”

> **면접 포인트 — 예외 큐는 완료 상태가 아니다**
>
> 예외 이관으로 정상 흐름의 리드타임만 좋아 보일 수 있다. 전체 주문 체류 시간·오래된 미해결 예외·재합류 실패·재발률을 함께 측정한다. 담당자 부재·단말 오프라인·중복 스캔도 검증 시나리오에 포함한다.

## 참고 자료

- [Oracle 26A 보충과 피킹 Wave](https://docs.oracle.com/en/cloud/saas/warehouse-management/26a/owmol/workflow-of-replenishment-with-picking-wave.html)
- [Oracle 26A 보충 개념](https://docs.oracle.com/en/cloud/saas/warehouse-management/26a/owmol/overview-of-replenishment.html)
- [Oracle 25D Pick Cart와 부족 처리](https://docs.oracle.com/en/cloud/saas/warehouse-management/25d/owmol/pick-cart.html)

운영 수치와 예외 상태 모델은 학습용이다. 실제 인력·생산성을 주장하는 기업 사례가 아니다.$review_24$
WHERE slug = 'logistics-17-fulfillment-operations-interview' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_25$## 1. 슬롯 배치는 제약을 만족하는 총 작업 비용 문제다

Slotting(슬로팅)은 상품을 어떤 피킹 위치에 얼마나 배치할지 정하는 작업이다. ABC 분석의 기준은 출고 수량, 주문 빈도, 피킹 방문 횟수, 매출 등으로 달라지므로 “A급=매출 상위”를 동선 최적화에 그대로 쓰지 않는다. 이 카드에서는 **피킹 방문 수**를 출발점으로 삼는다.

가상의 A급 상품을 모두 출고구 옆 한 통로에 모으면 거리는 짧아져도 동시 작업자가 몰린다. 대기·카트 교행·보충 장비 간섭을 포함한 피킹 시간은 오히려 늘 수 있다. 주문당 낱개 수량보다 방문 횟수가 동선과 더 직접 연결되는 경우도 있다.

| 입력 | 제약 또는 비용 | 확인할 것 |
|---|---|---|
| 상품 크기·중량 | 슬롯 용적·하중·장비 | 낱개와 포장 단위 환산 |
| 보관 조건 | 온도·혼재 금지·취급 | 비용 점수로 위반을 허용하지 않기 |
| 작업 접근 | 높이·동선·통로 점유 | 현장 안전 규칙과 작업 방법 |
| 피킹 빈도 | 이동·탐색·집기 시간 | 행사·요일·품절 때문에 관측이 왜곡되는지 |
| 보충 | reserve→pick face 이동 | 보충 단위·빈도·피킹 방해 |

Pick Face(전방 피킹 위치)를 작게 잡으면 가까운 곳에 더 많은 SKU를 놓을 수 있지만 보충 횟수가 증가한다. 보충은 Reserve Storage(예비 보관 위치)에서 피킹 위치로 옮기는 별도 작업이며 무료가 아니다.

## 2. 상품 친화도는 실제 함께 피킹하는 단위에서 계산한다

Affinity(친화도)는 함께 주문되는 상품의 관계다. 가상 1,000주문에서 A는 200주문, B는 100주문, 둘 다 포함된 주문은 60개라면 공동 출현 비율은 0.06, 독립 가정 대비 Lift(상대 동시 출현)는 `0.06 / (0.2 × 0.1) = 3`이다. 방향별 조건부 확률은 `P(B|A)=0.3`, `P(A|B)=0.6`으로 다르다.

```mermaid
flowchart LR
    O[주문·실제 피킹 이력] --> F[방문 빈도와 친화도]
    F --> C[후보 슬롯 배치]
    H[공간·취급·구역 제약] --> C
    C --> S[동선·혼잡·보충 시뮬레이션]
    S --> R[재배치 비용과 기간별 순이익]
    R --> P[소구역 파일럿]
    P --> M[실측과 재평가]
```

Lift가 높아도 공동 주문이 2건뿐이면 효과 추정이 불안정하다. 최소 관측량과 최근 기간·행사 여부를 함께 본다. 같은 주문이어도 온도대가 달라 다른 작업자가 피킹한다면 가까이 놓는 후보가 유효하지 않을 수 있다. Batch Picking(묶음 피킹)에서는 한 주문 기준 친화도보다 실제 배치 구성과 경로의 방문 절감 효과를 다시 평가한다.

인접 배치가 왕복을 줄이는지, 이미 지나가는 동선이라 차이가 없는지, 인기 조합이 한 통로를 과부하시키는지 확인한다. 단순히 모든 고친화 상품 쌍의 거리를 최소화하면 슬롯 용량과 혼잡을 놓친다.

## 3. 이득과 비용은 같은 단위·평가 기간으로 비교한다

```text
기간 순이득(작업초)
= 기간 피킹 작업초 절감
- 기간 추가 보충 작업초
- 기간 추가 혼잡·재작업초
- 1회 재배치 작업초
```

거리(m)에서 비용(원)을 직접 빼지 않는다. 이동 거리 절감은 실제 통행 속도·탐색·대기를 반영한 시간으로 환산하거나 모두 금액으로 환산한다. 피킹 시간 실측에 이미 혼잡이 포함돼 있다면 혼잡 페널티를 또 빼지 않는다.

가상의 하루 2,000회 피킹에서 회당 4초를 절감하면 8,000초다. 추가 보충 10회×180초=1,800초, 별도로 모델링한 혼잡 1,200초라면 하루 순절감은 5,000초다. 재배치가 20,000초면 손익분기점은 4일이고 10일 평가의 순이득은 30,000초다. 수요가 3일 뒤 끝나는 행사라면 이 가정에서는 손해다.

| 후보 | 장점 | 비교해야 할 비용 |
|---|---|---|
| A급 집중 | 짧은 평균 이동 | 피크 통로 혼잡·잦은 보충 |
| 구역 분산 | 동시 작업 분산 | 일부 이동 증가·다중 위치 관리 |
| 큰 피킹 면적 | 보충 빈도 감소 | 슬롯 점유로 다른 상품 동선 증가 |
| 친화 상품 인접 | 공동 방문 절감 가능 | 주문 구성 변화·제약 충돌 |

## 4. 재배치도 재고 이동 거래다

추천 배치를 바로 현재 위치 마스터에 덮어쓰면 현장 실물과 시스템이 어긋난다. 새 위치 용량과 상품 조건을 확인하고, 진행 중 피킹·보충 작업과 충돌하지 않는 시간에 이동 명령을 만든다. 출발 스캔·이동 중·도착 확인을 남기고 중복 완료가 수량을 두 번 옮기지 않게 한다.

```text
slotting_plan: plan_id, revision, horizon, assumptions, approved_by
move_task: task_id, plan_id, sku, lot, uom, qty,
           source_location, target_location, status, task_version
state: PLANNED -> CLAIMED -> IN_TRANSIT -> RECEIVED
```

일부만 이동됐으면 남은 작업과 두 위치의 실제 가용량을 유지한다. 오래된 단말 작업은 버전·상태로 거절하고 실물은 대사한다. 변경을 되돌리는 경우도 이전 마스터를 복원하는 것이 아니라 새 이동 작업이다.

## 5. 파일럿과 재계산

같은 주문 구성·물량·인력 조건을 맞춰 주문당 피킹 시간, 보충 작업초, 통로 대기, 오류와 이동 미완료를 비교한다. 전후 비교만으로 행사 종료나 작업자 숙련 효과를 슬로팅 성과로 계산하지 않는다. 비슷한 구역을 비교하거나 기간을 교차해 보되 공용 통로의 상호 간섭을 고려한다.

효과가 작은 배치는 유지하고 충분한 예상 순이득·최소 유지 기간이 있는 경우에만 바꾸는 정책이 가능하다. 너무 긴 유지 기간은 수요 변화에 늦게 대응하므로 예외 조건을 둔다.

> **면접 포인트**
>
> 최단 거리보다 “제약을 지키며 평가 기간 동안 총 작업을 얼마나 줄이는가”로 답한다. 안전·상품 보관 규칙은 최적화 점수에 흡수하지 않고 먼저 검사한다. 예측 순이득과 실제 피킹·보충·이동 비용을 별도로 기록해 다음 추천을 개선한다.

## 참고 자료

- [Microsoft Dynamics 365 슬롯 계획과 보충 작업](https://learn.microsoft.com/en-us/dynamics365/supply-chain/warehousing/warehouse-slotting)
- [Oracle 26A 보충 개념](https://docs.oracle.com/en/cloud/saas/warehouse-management/26a/owmol/overview-of-replenishment.html)

친화도 계산·기간 순이득·이동 상태 모델은 학습용 설계이며 특정 제품의 최적화 알고리즘을 재현하지 않는다.$review_25$
WHERE slug = 'logistics-18-slotting-optimization' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_26$## 1. 업무 단위별 질서를 만든다

전역 순서는 불필요하고 비싸다. Shipment, Inventory Item, Order처럼 상태 전이가 직렬화되어야 하는 키를 정하고 같은 키를 같은 Partition으로 보낸다. Producer Sequence와 Event ID로 재전송을 판별한다.

```mermaid
flowchart LR
    S[Scanner·OMS·Carrier] --> I[수집·스키마 검증]
    I --> P[업무 키 Partition]
    P --> L[(불변 Event Log)]
    L --> V[상태 투영]
    L --> R[원장·대사]
    R -->|차이| X[재처리·정정]
```

| 압박 질문 | 답변의 핵심 | 위험한 답변 |
|---|---|---|
| 중복이면 | Inbox·업무 멱등 키 | Broker가 제거한다 |
| 순서가 바뀌면 | 전이 검증·보류·Version | Timestamp 정렬만 한다 |
| 소비가 실패하면 | Retry Budget·격리·재처리 | 무한 재시도 |
| 투영이 틀리면 | 원본 재생·대사 | 수동 UPDATE |

```text
partition_key = business_entity_id
if a single authority assigns per-entity business versions:
    apply only when event.version == projection.version + 1
else:
    validate transition and reconcile gaps; device sequences are not global versions
```

> **면접 전략** — 전달 보장 이름보다 중복·누락·역순 예시 하나를 끝까지 추적해 어느 저장소가 진실의 원본인지 밝힌다.

## 2. 라운드 1 — Partition Key만 같으면 순서가 맞나

면접 상황: 같은 화물이 창고 스캐너, 기사 앱, 운송사 Webhook에서 갱신된다. 상태 투영의 키는 `shipment_id`로 시작한다. 재고 원장은 `warehouse_id + sku`, 주문 화면은 `order_id`처럼 다른 업무 경계를 가질 수 있다. 하나의 키가 모든 불변식을 직렬화해주지는 않는다.

같은 화물의 로그는 한 파티션 안에서 순서가 있지만, 여러 Producer(생산자)가 보내는 사건의 **업무 발생 순서**와 같다는 보장은 없다. `device_sequence=18`과 다른 단말의 `device_sequence=9`는 크기만 비교할 수 없다. Event ID는 중복 판단, 단말 순번은 단말별 누락, 서버의 업무 버전은 상태 적용 순서에 사용한다.

> **압박 질문** — `event.version == projection.version + 1`의 버전을 누가 발급하나요? 답변에 단일 업무 Writer나 조정 주체가 없다면 여러 단말이 독립 발급한 숫자를 전역 버전처럼 취급한 것이다.

## 3. 라운드 2 — 완료 뒤 집하가 도착했다

가상 입력을 순서대로 설명한다.

| 도착 순서 | 사건 | 해야 할 판단 |
|---|---|---|
| 1 | 배송 완료 E30 | 증거·전이 조건 확인 후 완료 반영 |
| 2 | 오프라인 집하 E10 | 원본에 추가하되 현재 상태를 집하로 되돌리지 않음 |
| 3 | E30 재전달 | 같은 내용이면 효과 반복 안 함 |
| 4 | E30과 같은 ID, 다른 화물 | 충돌 격리·원본 증거 보존 |
| 5 | 승인된 완료 취소 정정 C1 | 원본 참조·정정 권한 확인 후 재투영 |

“가장 큰 Timestamp만 유지”하면 시계 오차·정정·예외 흐름을 잃는다. “완료보다 낮은 상태는 전부 버린다”도 원본 감사와 실제 오스캔 정정을 불가능하게 한다. 원본 저장과 현재 상태 판단을 분리해야 한다.

## 4. 라운드 3 — 원장과 조회가 어긋났다

먼저 진실의 원본과 비교 시점을 정한다. 생산자가 아직 보내지 않은 원본 누락, Broker 유입 후 미처리, 업무 규칙 오류, 조회 캐시 지연을 구분한다. 서로 다른 체크포인트의 값을 비교하면 정상 지연도 장애처럼 보인다.

```text
choose entity scope and stable source checkpoint
compare raw events, corrections, projection version and rule version
replay into shadow projection WITHOUT external notifications
compare missing IDs, duplicates, state differences and unresolved gaps
catch up to the cutover checkpoint
switch read version atomically; retain rollback target
```

재생 도중 새 이벤트가 들어오는 상황까지 설명한다. 오류를 발견했다고 운영 DB의 현재 상태만 UPDATE하면 다음 재생에서 다시 잘못될 수 있다. 원본이 잘못됐으면 승인된 정정, 투영 규칙이 잘못됐으면 버전 수정과 재생으로 해결한다.

가정: 지연 이벤트 90만 건, 유입 1,000건/초, 성공 처리 2,500건/초이면 순처리 1,500건/초로 약 10분에 따라잡는다. 재시도와 느린 키 때문에 실제 성공 처리율이 낮아질 수 있다. 성공 처리율이 유입 이하라면 기다리는 것만으로 해소되지 않는다.

## 5. 답변 평가와 장애 주입

| 확인 항목 | 기대 답변 |
|---|---|
| 수집 저장 직후 종료 | 내구성 있는 이벤트 재개, 중복 무해 |
| DB 반영 후 Offset 커밋 전 종료 | Inbox·업무 변경 원자 커밋으로 반복 효과 차단 |
| 키 하나의 독약 메시지 | 재시도 예산·키별 격리·순서 공백 정책 |
| 재생 중 알림 소비 | 외부 효과 분리, 원래 고객 알림 반복 방지 |
| 규칙 버전 변경 | 비교 기준·되돌릴 투영 버전 보존 |

> **검수 기준 — 2026-09-12**: 입력·수치·운영 절차는 가상 면접 문제다. [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/)의 소비 위치·처리 보장과 [GS1 EPCIS 2.0.1](https://ref.gs1.org/standards/epcis/2.0.1/)의 이벤트·정정 개념을 참고한다.


## 6. 현장 단절을 포함한다

오프라인 단말은 안정적인 로컬 ID와 큐를 사용하고 복구 후 Batch 전송한다. 지연 허용 시간을 넘은 이벤트는 자동 적용보다 예외 큐와 대사로 보낸다.

> **면접 포인트** — 파이프라인 처리량뿐 아니라 실제 배송 상태의 정확성과 감사 가능성을 함께 설계한다.$review_26$
WHERE slug = 'logistics-19-event-pipeline-interview' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_27$> **검수 기준 — 2026-09-12**
>
> CAP 원 논문, Raft 확장 논문, Transaction Commit 논문을 기준으로 보장 조건을 구분한다. 재고·배송 사례와 지연 수치는 가상 설계다. 제품을 고정된 CP/AP로 분류하거나 복제본 개수만으로 최신 읽기를 단정하지 않는다.

## 1. CAP는 분할 중의 선택이다

CAP(Consistency, Availability, Partition Tolerance: 일관성·가용성·분할 내성)는 네트워크가 분할될 수 있는 모델에서 선형화 가능한 읽기·쓰기와 모든 정상 노드의 요청 완료를 함께 보장할 수 없다는 결과다.

- C는 Linearizability(선형화 가능성)다. 연산이 호출과 응답 사이 한 순간에 실행된 것처럼 설명되고, 실제 시간의 선후 관계를 지킨다. 모든 복제본이 매 순간 같은 메모리 값을 가진다는 뜻은 아니다.
- A는 실패하지 않은 노드가 받은 요청이 결국 연산을 완료하는 조건이다. 읽기·쓰기마다 오류만 보내는 방식으로 충족하지 못하며, 실무의 “월 성공률 99.9%”와도 다르다.
- P는 노드 집합 사이 메시지가 전달되지 않는 실행을 허용한다. 그런 실행을 가정한 질문에서 “P를 안 고른다”는 답은 해결이 아니라 실패 모델을 바꾸는 것이다.

```mermaid
flowchart TD
    P[네트워크 분할 발생] --> C[선형화 가능성 유지]
    P --> A[각 정상 노드에서 요청 완료]
    C --> W[일부 요청 대기·거절 가능]
    A --> S[최신 완료 쓰기와 다른 읽기 가능]
```

가상의 창고 예약은 과판매를 피하기 위해 필요한 조정 노드에 도달하지 못하면 확정을 보류할 수 있다. 배송 위치 화면은 마지막 수신 시각을 표시하며 일부 지연을 허용할 수 있다. 같은 서비스에도 서로 다른 계약이 있다. 단, 재고 보장은 강한 읽기 하나가 아니라 조건 검사·갱신의 원자성과 중복 예약 방지를 함께 요구한다.

## 2. PACELC와 실제 요청 계약

PACELC는 분할 시(P) 가용성(A)과 일관성(C), 평상시(E) 지연(L)과 일관성(C)의 절충을 생각하는 틀이다. “DynamoDB는 항상 AP”처럼 제품명 하나로 결론내리지 않는다. 일관된 읽기 지원 범위, 읽기 대상, 쓰기 확인, 복제·리더 전환 구성을 확인한다.

| 요구 | 필요한 확인 | 비용·남는 문제 |
|---|---|---|
| 완료된 쓰기 이후 최신 읽기 | 선형화 가능한 읽기 경로 | 리더 유효성·상태 적용 대기 |
| 내가 쓴 결과 재조회 | 세션이 본 버전 이상의 읽기 | 복제본 이동·장애 전환 |
| 읽기 역행 방지 | 읽은 버전 하한 유지 | 고정 복제본 장애 후 라우팅 |
| 최종 수렴 | 변경 전달·충돌 해결·복구 | 수렴 시간·중간 불일치 |

Read-your-writes(자기 쓰기 읽기)를 위해 잠시 리더로 보낼 수 있지만, 리더가 바뀌거나 확인받은 쓰기가 유실될 수 있는 복제 모델이면 추가 검증이 필요하다. 단순 Sticky Routing(고정 라우팅)을 영구 보장으로 설명하지 않는다.

## 3. Quorum 교집합의 조건

고정된 N개 복제본에서 쓰기 확인 집합 W와 읽기 응답 집합 R을 고른다고 하자. `W + R > N`이면 두 집합에 최소 한 노드가 겹친다. 이것은 집합의 성질이며, 반환할 최신 버전 판정이나 동시 쓰기 해결까지 자동으로 제공하지 않는다.

```text
N = 5
write set = {1, 2, 3}
read set  = {3, 4, 5}
intersection = {3}

W = 1, R = 1:
write set = {1}, read set = {5}
intersection may be empty
```

쓰기 이후 읽기라면, 겹친 노드가 확인한 값을 내구성 있게 보존하고 읽기에 제공해야 한다. 읽기 측도 버전·동시 충돌·미완료 쓰기를 올바르게 판단해야 한다. 임시 대체 노드에 쓰는 Sloppy Quorum(느슨한 정족수), 멤버십 변경, 복구로 값이 되돌아가는 경우는 이 단순 계산의 전제를 다시 확인해야 한다.

| N=5 | W=3, R=3 | W=1, R=1 |
|---|---|---|
| 집합 교차 | 같은 구성에서 보장 | 보장 안 됨 |
| 응답 수 | 각 연산에 3개 필요 | 각 연산에 1개 필요 |
| 분할 | 3개에 도달하지 못하는 쪽은 해당 연산 불가 | 각 쪽이 독립 응답할 수 있으나 불일치 가능 |
| 지연 | 필요한 응답을 기다림 | 더 적은 응답으로 완료 가능 |
| 동시 쓰기 | 별도 버전·충돌 규칙 필요 | 별도 버전·충돌 규칙 필요 |

가상 응답 지연이 1, 2, 4, 8, 20ms이고 다섯 노드에 동시에 요청한다면 세 번째 응답까지 기다리는 데 4ms, 첫 응답만이면 1ms다. 이것은 네트워크 응답만의 예제이며 디스크·조정·클라이언트 구간이 더해진다.

> **실무 함정** — W=R=1이라고 자동으로 최종 수렴하는 것도 아니다. Anti-entropy(복제본 대사)와 충돌 해결 같은 복구 경로가 있어야 수렴을 기대할 수 있다.

## 4. Raft는 과반수 외에도 규칙이 있다

Raft는 복제 로그의 순서를 합의한다. Term(임기)이 더 높은 메시지를 보면 이전 리더가 물러나지만, 단절된 이전 리더가 새 임기를 아직 모를 수 있다. 서로 자신이 리더라고 생각하는 순간 자체를 없애는 것이 아니라 올바른 커밋·읽기 규칙으로 잘못된 결과가 성공하지 않게 한다.

```mermaid
sequenceDiagram
    participant C as Client
    participant L as Leader term 4
    participant F as Follower
    participant X as Slow Follower
    C->>L: write request
    L->>L: persist entry of current term
    L->>F: AppendEntries
    L->>X: AppendEntries
    F-->>L: persisted
    Note over L,F: Leader 포함 3개 중 2개
    L->>L: advance commit and apply
    L-->>C: result
```

리더는 **현재 임기의 엔트리**가 과반수에 복제됐다는 조건으로 커밋 인덱스를 전진시킨다. 이전 임기 엔트리를 단순히 세어 “지금 과반수에 있으니 커밋”하면 안 된다. 현재 임기 엔트리가 커밋되면 그 앞 로그도 함께 확정될 수 있다. 선거는 후보 로그가 충분히 최신인지 검사하고 임기·투표·로그의 필요한 상태를 영속화한다.

선형화 가능한 읽기는 리더라고 믿는 노드의 로컬 값을 바로 반환하는 것과 다르다. 리더 권한을 과반과 확인하거나 안전한 Lease 조건을 사용하고, 필요한 커밋 인덱스까지 상태 머신이 적용됐는지 확인해야 한다.

3노드의 과반은 2, 5노드는 3이다. 투표 노드 4개는 3개와 마찬가지로 1개 실패만 허용하지만 복제·운영 비용은 더 든다. 다만 실제 배치는 장애 도메인·구성 변경·비투표 복제본까지 포함해 판단한다.

## 5. 2PC는 언제 기다리는가

2PC(Two-Phase Commit, 2단계 커밋)는 참가자들이 준비 상태를 기록한 뒤 코디네이터의 공통 결정을 따르게 한다. 참가자가 YES를 보낸 뒤 결정이 불명확하면 임의로 롤백할 수 없으므로 복구까지 자원을 유지하며 기다릴 수 있다.

```mermaid
sequenceDiagram
    participant C as Coordinator
    participant A as DB A
    participant B as DB B
    C->>A: prepare
    C->>B: prepare
    A-->>C: yes, prepared
    B-->>C: yes, prepared
    Note over C: 결정 전 장애 가능
    Note over A,B: 결정 확인 전 자의적 완료 금지
```

코디네이터를 영속 로그·복제로 복구하는 구현도 있으므로 “2PC면 항상 단일 프로세스가 영구 SPOF”라고 단정하지 않는다. 원자 커밋과 트랜잭션 격리도 다른 성질이다. 모든 참가자가 프로토콜에 참여하는지, 준비 동안 잠금·연결을 얼마나 유지하는지 확인한다. 일반 PG HTTP API는 DB의 prepare/commit 참가자가 아니다.

## 6. Saga가 추가하는 책임

Saga(사가)는 업무를 여러 로컬 커밋으로 나누고 실패한 경로를 보상한다. 보상은 DB 롤백처럼 과거를 없애는 일이 아니라 환불·예약 해제 같은 **새 업무 동작**이다. 이미 배송한 물건은 상태 값만 되돌려 회수되지 않는다.

| 가상 주문 단계 | 실패 처리 | 주의점 |
|---|---|---|
| 예약 생성 | 만료·취소로 수량 해제 | 한 번만 복원 |
| 결제 요청 | 확정 실패 시 예약 해제 | 타임아웃은 결과 불명 |
| 결제 성공 후 출고 실패 | 재시도 또는 환불 | 고객에게 중간 상태 안내 |
| 보상 자체 실패 | 지속 재시도·대사·운영 개입 | 종료 상태를 거짓으로 기록하지 않음 |

Outbox와 소비자 멱등성으로 전달·재시도를 연결하되 진행 상태·기한·보상 결과를 영속화한다. 중간 예약을 다른 주문이 볼 수 있으므로 격리 정책도 설계한다. 2PC를 못 쓰는 외부 시스템, 긴 업무 시간, 서비스 자율성이 Saga를 선택할 근거이고, 단순한 한 DB의 원자 변경까지 Saga로 쪼갤 필요는 없다.

> **면접 포인트** — 기존 질문의 “2PC 대신 Saga”도 결론을 미리 정하지 말고 검토한다. 필요한 불변식, 참가자 지원, 준비 시간, 중간 상태 허용과 보상 가능성으로 선택을 설명한다.

## 참고

- [Gilbert·Lynch CAP 원 논문](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf)
- [Raft 확장 논문](https://raft.github.io/raft.pdf)
- [Gray·Lamport: Consensus on Transaction Commit](https://lamport.azurewebsites.net/video/consensus-on-transaction-commit.pdf)
- [Saga 패턴](https://microservices.io/patterns/data/saga.html)
- [Cassandra의 복제·일관성](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html)$review_27$
WHERE slug = 'system-design-07-consistency-consensus' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_28$## 1. 복제는 순서와 확인 규칙이다

복제본을 세 대 둔다고 일관성이 자동으로 생기지 않는다. 누가 쓰기 순서를 정하고, 어느 복제본까지 반영됐을 때 성공으로 응답하며, 읽기가 어떤 버전을 반환할지 프로토콜로 정해야 한다.

```mermaid
flowchart LR
    subgraph LeaderBased["리더 기반"]
        C1[Client] --> L[Leader]
        L --> F1[Follower 1]
        L --> F2[Follower 2]
        L --> C1
    end
    subgraph Chain["Chain Replication"]
        C2[Write Client] --> H[Head]
        H --> M[Middle]
        M --> T[Tail]
        T --> C2
        R[Read Client] --> T
    end
```

| 방식 | 쓰기 순서 | 기본 읽기 위치 | 강점 | 주요 위험 |
|---|---|---|---|---|
| 리더 기반 | 리더 로그 순서 | 리더 또는 복제본 | 일반적이고 운영 경험 풍부 | 리더 병목·복제 지연 읽기 |
| Chain Replication | Head→…→Tail | Tail | 파이프라인 처리와 강한 읽기 규칙 | Tail 읽기 병목·체인 재구성 |
| CRAQ | 체인 전파 | 모든 노드 가능 | 읽기 확장성과 강한 일관성 조합 | Dirty 읽기의 Tail 확인 비용 |

## 2. CRAQ의 Clean과 Dirty

CRAQ(Chain Replication with Apportioned Queries, 조회를 분담하는 체인 복제)는 각 노드가 객체 버전을 저장한다. Tail까지 확정된 버전은 Clean, 아직 체인을 통과 중인 최신 버전은 Dirty다. 노드가 Clean 객체를 읽으면 즉시 응답하고, Dirty라면 Tail에 현재 확정 버전을 물어 그 버전을 반환한다.

```text
write(v2): Head -> Middle(v2=dirty) -> Tail(v2=commit)
ack(v2):   Tail -> ... -> Head, 각 노드는 v2를 clean 처리
read:      clean이면 로컬 응답, dirty이면 Tail의 확정 버전 확인
```

> **실무 함정** — 정상 경로 QPS만 비교하면 안 된다. 노드 제거 중 미완료 쓰기를 어느 이웃이 이어받는지, 새 노드가 Snapshot과 변경분을 어떻게 따라잡는지 정의되지 않으면 장애 순간에 중복 적용이나 유실이 생긴다.

## 3. 버전별 읽기 결과를 따라가 본다

가상의 객체 `shipment/7`에 버전 1이 확정되어 있다. Middle(중간 노드)은 버전 2를 받았지만 Tail(체인 끝 노드)에는 아직 도착하지 않았다. Middle이 최신 로컬 값 2를 바로 주면 아직 확정되지 않은 쓰기를 읽게 된다. Tail에 확정 버전을 물어 1을 받아 그 로컬 버전을 반환한다.

| Middle의 상태 | Tail의 확정 버전 | 강한 읽기 결과 |
|---|---:|---|
| v1 Clean(확정), 이후 쓰기 없음 | 1 | 로컬 v1 |
| v1 보관, v2 Dirty(미확정) | 1 | 확인 후 v1 |
| v2 Dirty, 확인 응답만 지연 | 2 | 확인 후 v2 |
| v2 Dirty, Tail에 연결 불가 | 확인 불가 | 타임아웃·실패 또는 명시적 약한 읽기 계약 |

Dirty 여부는 그 객체의 더 최신 미확정 쓰기를 인지했는지와 연결된다. 과거 Clean 버전이 하나 있다는 이유로 Tail 확인을 생략하지 않는다. 메타데이터 질의가 필요하므로 쓰기가 잦으면 읽기의 추가 왕복과 Tail 집중이 늘어난다.

## 4. 지연과 처리량을 나눠 계산한다

가정: 데이터 노드 사이 편도 전파가 각각 2ms이고 체인이 세 노드다. Head(시작 노드)에서 Tail까지 전파만 4ms이며 디스크·클라이언트 왕복·확인 전파는 별도다. 파이프라인은 여러 요청을 겹쳐 처리할 수 있지만 첫 요청이 체인을 통과하는 지연 자체를 없애지는 않는다.

리더 기반 복제가 병렬로 두 복제본에 쓰기를 보낸다면 확인 조건에 따라 느린 노드 전부를 기다리지 않을 수 있다. 반면 체인에서는 경로의 느린 노드가 뒤 노드 전파에 영향을 준다. “세 복제본이라 같은 비용”으로 계산하지 않는다.

## 5. 재구성 중에도 같은 규칙을 지킨다

| 사건 | 복구 중 확인할 것 |
|---|---|
| Head 종료 | 미확인 요청을 클라이언트가 재시도할 ID·새 Head의 로그 |
| Middle 종료 | 앞 노드가 아직 뒤에 전달하지 못한 갱신의 재전송 |
| Tail 종료 | 새 Tail의 버전·확정 상태와 기존 미완료 요청 |
| 새 노드 추가 | 기존 데이터 복사 중 발생한 변경까지 따라잡은 시점 |
| 네트워크 분할 | 단일 멤버십 결정·이전 구성의 쓰기 차단 |

Membership(구성원 목록)을 관리하는 주체와 장애 감지 오판도 실패 모델에 포함한다. 서로 다른 노드가 임의로 “옆 노드를 제거했다”고 결정하면 체인이 둘로 갈라질 수 있다. 재구성 권한·세대 번호·재전송 규칙을 원 프로토콜과 함께 구현해야 한다.

## 6. 선택 기준

- 쓰기 순서와 범용 운영 도구가 필요하면 리더 기반 제품을 검토한다. 여러 객체의 트랜잭션 기능은 복제 토폴로지가 아니라 제품의 별도 동시성 제어·커밋 기능으로 확인한다.
- 읽기는 Tail로 충분하고 대량 객체 쓰기를 파이프라인화하려면 Chain Replication을 검토한다.
- 읽기 비중이 높고 여러 복제본에서 강한 읽기를 제공해야 한다면 CRAQ의 추가 메타데이터와 확인 비용을 비교한다.

> **면접 포인트** — “복제 3개” 대신 쓰기 성공 시점, 읽기 위치, RPO(Recovery Point Objective, 복구 시점 목표), 장애 감지 오판 시 동작을 순서대로 설명해야 한다.

## 참고

- [Chain Replication 논문](https://www.cs.cornell.edu/fbs/publications/ChainReplicOSDI.html)
- [CRAQ 원 논문](https://www.usenix.org/legacy/event/usenix09/tech/full_papers/terrace/terrace.pdf)

> **검수 기준 — 2026-09-12**: 원 논문의 객체 단위 강한 읽기를 설명한다. 여러 객체의 원자 트랜잭션을 보장한다는 뜻은 아니다. 숫자는 가상 지연 계산이며 특정 제품 성능이 아니다.$review_28$
WHERE slug = 'system-design-17-replication-protocols' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_29$## 1. 벽시계는 정확한 전역 순서가 아니다

NTP(Network Time Protocol, 네트워크 시간 동기화 프로토콜) 보정, VM(Virtual Machine, 가상 머신) 정지, 하드웨어 편차 때문에 서로 다른 노드의 `now()`는 어긋나거나 뒤로 갈 수 있다. 따라서 단순 Timestamp 비교는 인과관계를 잃을 수 있다. 분산 시계 설계는 필요한 보장이 “인과 순서”인지 “실제 시간과 일치하는 트랜잭션 순서”인지 먼저 구분한다.

```mermaid
sequenceDiagram
    participant A as Node A
    participant B as Node B
    A->>A: event e1, HLC=(100,0)
    A->>B: message with (100,0)
    B->>B: physical=98, receive max=100
    B->>B: event e2, HLC=(100,1)
    Note over A,B: e1 → e2 인과 순서 보존
```

| 방식 | 표현 | 제공하는 핵심 | 비용·제약 |
|---|---|---|---|
| 물리 시계 | 단일 Timestamp | 사람이 이해하기 쉬운 시간 | Skew·역행·동률 |
| Lamport Clock | 논리 Counter | 인과관계가 있으면 순서 증가 | 실제 시간과 거리 표현 불가 |
| HLC | 물리값+논리 Counter | 물리 시간 근접성과 인과 순서 | 완전한 동시성 판별은 아님 |
| TrueTime 계열 | `[earliest, latest]` 구간 | 제한된 시간 불확실성 노출 | 시계 인프라와 대기 비용 |

## 2. HLC 갱신 규칙

HLC(Hybrid Logical Clock, 하이브리드 논리 시계)는 로컬 물리 시간, 현재 HLC, 수신 HLC의 최대 물리값을 선택하고 동률일 때 논리 카운터를 증가시킨다. 물리 시계가 뒤로 가도 HLC가 감소하지 않게 만든다.

다음 구현은 수신 전 로컬 값을 보존하고 네 경우를 나눈다. 단일 노드 내 동시 호출은 직렬화한다고 가정한다. 수치 범위·재시작 시 저장·원격 시계 검증은 별도 운영 책임이다.

```python
def local_event(local, wall):
    old_time, old_counter = local
    new_time = max(wall, old_time)
    counter = old_counter + 1 if new_time == old_time else 0
    return new_time, counter


def receive_event(local, remote, wall):
    lt, lc = local
    rt, rc = remote
    new_time = max(wall, lt, rt)
    if new_time == lt == rt:
        counter = max(lc, rc) + 1
    elif new_time == lt:
        counter = lc + 1
    elif new_time == rt:
        counter = rc + 1
    else:
        counter = 0
    return new_time, counter
```

| 로컬 HLC | 수신 HLC | 물리 시각 | 수신 후 HLC |
|---|---|---:|---|
| (100, 2) | (100, 5) | 99 | (100, 6) |
| (105, 4) | (100, 8) | 99 | (105, 5) |
| (100, 2) | (105, 8) | 99 | (105, 9) |
| (100, 2) | (105, 8) | 110 | (110, 0) |

카운터는 항상 두 카운터의 최댓값에 1을 더하는 것이 아니다. 실제 물리 시간이 둘보다 앞서면 0으로 시작한다. 이 예제에서 순서는 `(물리값, 논리값)`의 사전식 비교다. 인과관계가 있으면 값이 증가하지만, 값이 작다고 두 사건이 인과관계라는 역명제는 성립하지 않는다.

## 3. LWW가 버리는 정보를 확인한다

가상 예제: 창고 A의 시계가 5초 빠르고 B는 정상이다. A가 수량 10을 기록한 뒤 B에서 더 늦게 수량 9를 입력해도, 물리 Timestamp만 비교하는 LWW(Last Write Wins, 마지막 쓰기 우선)는 A를 남길 수 있다. 이것은 “실제로 나중 쓰기”가 아니라 “Timestamp가 큰 쓰기”를 선택한 결과다.

HLC를 도입해도 서로 통신하지 않은 동시 차감을 합산하거나 초과판매를 막아주지는 않는다. 재고는 조건부 상태 전이나 충돌 없는 연산 모델이 필요하다. 동시 업데이트의 의미를 보존해야 한다면 단순 덮어쓰기 대신 버전 벡터·명시적 병합·직렬화 중 요구에 맞는 모델을 선택한다.

## 4. TrueTime과 Commit Wait

TrueTime은 현재 시각을 점이 아니라 불확실성 구간으로 제공한다. 트랜잭션 Commit Timestamp 이후가 실제로 지났다고 확신할 때까지 기다리는 Commit Wait를 통해, 먼저 완료된 트랜잭션이 나중 트랜잭션보다 앞선 순서로 관찰되게 한다.

가정: 선택한 커밋 Timestamp가 104ms이고, 현재 TrueTime 구간이 `[100, 106]ms`다. 시스템은 구간의 하한이 104ms를 **넘었다고 확인**하기 전에는 Commit Wait(커밋 대기)를 끝낼 수 없다. 고정 4ms를 자면 충분하다는 뜻이 아니라 시계 API의 하한으로 판단한다. 불확실성·시간 동기화 상태와 다른 커밋 작업의 중첩에 따라 실제 지연은 달라진다.

Spanner의 외부 일관성은 TrueTime 하나가 아니라 트랜잭션 타임스탬프 배정·동시성 제어·복제·Commit Wait가 결합된 성질이다. 선행 트랜잭션이 완료된 뒤 시작한 트랜잭션의 순서와 실제 시간을 맞춘다.

> **실무 함정** — HLC Timestamp가 있다고 충돌이 사라지는 것은 아니다. 동시에 발생한 업데이트의 병합 정책, Tie-breaker, 보존할 인과 메타데이터를 별도로 정해야 한다.

## 5. 선택 기준

- 이벤트 정렬과 버전 비교에 물리 시간 근접성이 필요하면 HLC를 검토한다.
- 진짜 동시성을 구분해야 하면 Vector Clock 같은 더 큰 메타데이터가 필요할 수 있다.
- 외부 일관성이 필요하면 제한된 시계 불확실성과 합의·Commit Wait가 결합된 시스템 비용을 받아들여야 한다.

> **면접 포인트** — “시계를 동기화한다”는 답보다 허용 Skew, 시간 역행, 인과관계, 동률 처리와 사용자에게 필요한 일관성 수준을 분리해 설명한다.

## 참고

- [Cloud Spanner: TrueTime and external consistency](https://docs.cloud.google.com/spanner/docs/true-time-external-consistency)

- [HLC 원 논문: Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases](https://cse.buffalo.edu/tech-reports/2014-04.pdf)

> **검수 기준 — 2026-09-12**: HLC 수신의 네 분기, 시계 역행, LWW 손실과 Commit Wait의 조건을 검수했다. 숫자는 동작 설명용이며 구현별 지연 보장이 아니다.$review_29$
WHERE slug = 'system-design-18-distributed-clocks' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_30$> **검수 기준 — 2026-09-12**
>
> 아래 창고 집계 작업은 가상 설계다. Lease(임대 기간)는 자원 회수를, Fencing Token(이전 소유자의 쓰기를 차단하는 순번)은 저장소에서 오래된 쓰기 거부를 담당한다. 둘은 같은 보장이 아니다.

## 1. 보호할 불변식을 먼저 쓴다

창고별 재고 집계를 두 Worker(작업 프로세스)가 동시에 덮어쓰는 상황을 생각하자. 목표는 “락을 한 명만 보유한다”가 아니라 **새 소유자의 결과를 받아들인 저장소가 이전 소유자의 결과로 되돌아가지 않는다**다. 잠깐 중복 실행되어도 결과가 같은 캐시 재계산과, 중복 출고처럼 되돌릴 수 없는 작업은 요구가 다르다.

다음 실패를 가정한다. 프로세스가 임의 시간 멈출 수 있고, 요청과 응답이 지연·유실될 수 있으며, 락 서비스 일부 노드가 중단될 수 있다. 소유자의 시계나 정상 실행 시간만으로 안전성을 증명하지 않는다.

```mermaid
sequenceDiagram
    participant A as Worker A
    participant L as Lock Service
    participant R as Resource
    participant B as Worker B
    A->>L: acquire warehouse-7
    L-->>A: token=41, lease
    Note over A: 긴 정지, lease 만료
    B->>L: acquire warehouse-7
    L-->>B: token=42
    B->>R: write(result B, token=42)
    R-->>B: persist result and fence
    A->>R: late write(result A, token=41)
    R-->>A: reject stale fence
```

## 2. 끝단에서 원자적으로 검사한다

락 서비스는 같은 자원에 대해 새 소유자가 더 큰 Token을 받게 해야 한다. Token을 임의 UUID로 만들면 이전·이후를 비교할 수 없다. 발급 상태가 장애 복구 때 뒤로 돌아가거나, 두 리더가 같은 순번을 발급하지 않도록 합의와 영속성 조건을 정한다.

아래는 **소유권당 한 번의 집계 결과만 저장하는** PostgreSQL 예시다. `warehouse_summary` 행이 미리 존재하고 `last_fence`가 초기화되어 있다고 가정한다. 매개변수는 애플리케이션 바인딩 값이다.

```sql
UPDATE warehouse_summary
SET result_json = :result,
    last_fence = :fence
WHERE warehouse_id = :warehouse_id
  AND last_fence < :fence
RETURNING warehouse_id, last_fence;
```

영향받은 행이 0개면 성공으로 처리하지 않는다. 이미 반영된 동일 요청인지, 더 최신 소유자가 반영했는지, 보호할 행이 없는지를 확인한다. `last_fence` 검사와 본문 쓰기를 별도 요청으로 분리하면 검사 직후 다른 소유자가 끼어들 수 있다.

같은 Lease 동안 여러 변경을 허용하려면 `<`만으로는 부족하다. 소유권 Token 비교와 별개로 작업 ID 또는 소유권 내부 순번을 저장해야 한다. `incoming >= last_fence`는 동일 Token의 중복·순서 역전을 막아주지 않는다.

> **실무 함정** — 저장소가 Token 42를 아직 받지 않았다면 41을 수락할 수도 있다. Fencing은 벽시계 기준 만료 즉시 차단이 아니라, **저장소가 관측한 더 높은 세대 이후의 오래된 쓰기 차단**이다. 만료 후 모든 쓰기를 금지해야 한다면 권한 확인과 변경을 같은 직렬화 경계에 넣어야 한다.

## 3. 만료·재시도·복구 계약

가정: 작업 p99가 4초이고 Lease를 10초로 설정했다. 12초 정지 후 재개하는 경우는 여전히 가능하다. Lease를 길게 하면 오탐 만료는 줄어도 실제 장애 시 회수가 늦어진다. 갱신 실패 후 새 작업을 시작하지 않되, 이미 날아간 요청은 취소할 수 없다고 보고 저장소 검증을 유지한다.

| 장애 지점 | 판단 | 복구 |
|---|---|---|
| 획득 응답 유실 | 소유권 불명 | 요청 ID로 확인하거나 안전하게 포기 |
| 갱신 응답 유실 | 유효 기간 불명 | 새 작업 중단, 자원에서 Fence 확인 |
| 쓰기 성공 후 응답 유실 | 결과 불명 | 저장된 작업 ID·결과 조회 |
| 락 서비스 과반 중단 | 새 소유권 발급 불가 가능 | 재시도 예산·업무 지연 허용 판단 |
| 외부 API가 Token 미지원 | 오래된 호출 차단 불가 | 상대의 멱등 키·상태 확인 또는 설계 변경 |

측정할 것은 획득 지연, 갱신 실패율, 만료 후 재개 횟수, Fence 거부 수, 보호 자원별 대기 시간이다. 락 재획득에 성공했다고 이전 작업을 무조건 재실행하지 않는다.

## 4. 락이 필요 없는 설계와 비교한다

| 선택 | 좋은 적용 조건 | 남는 책임 |
|---|---|---|
| 조건부 UPDATE·고유 제약 | 재고 한 행·업무 키 중복 방지 | 영향 행 수 확인, 트랜잭션 범위 |
| 버전 기반 낙관적 갱신 | 충돌이 드문 편집 | 충돌 후 새 값으로 재계산 |
| 키별 단일 Writer | 운송장 단위 순차 반영 | 재배정 시 이전 Writer 차단·중복 처리 |
| Lease + Fencing | 여러 프로세스의 자원 소유권 | 발급 순번·자원 검증·복구 계약 |

> **면접 포인트** — 중복 출고를 막으려면 출고 명령의 업무 키와 상태 전이를 보호해야 한다. 분산 락을 추가하는 것만으로 운송사 API의 중복 효과가 사라지지 않는다.

## 참고

- [Martin Kleppmann: How to do distributed locking](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html) — 정지한 소유자와 Fencing의 적용 경계.
- [PostgreSQL 17: Transaction Isolation](https://www.postgresql.org/docs/17/transaction-iso.html) — 조건부 갱신의 동시성 동작.$review_30$
WHERE slug = 'system-design-21-distributed-lock-design' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_31$> **검수 기준 — 2026-09-12**
>
> PostgreSQL 17을 기준으로 설명한다. Snapshot Isolation(스냅샷 격리)과 다른 DBMS의 REPEATABLE READ를 동일시하지 않는다. 아래 당직 예제는 동시성 재현용 가상 업무다.

## 1. 행 충돌이 없어도 업무 규칙은 깨진다

업무 불변식은 “같은 팀에 당직자가 최소 한 명 남는다”다. A와 B가 모두 당직 중이고, 두 트랜잭션이 각각 두 명을 읽은 뒤 자기 행만 해제하면 어떻게 될까?

```mermaid
sequenceDiagram
    participant A as Tx A
    participant B as Tx B
    participant D as PostgreSQL
    A->>D: read count = 2
    B->>D: read count = 2
    A->>D: set A off
    B->>D: set B off
    A->>D: commit
    B->>D: commit
    Note over D: Repeatable Read에서는 둘 다 성공 가능
```

이것이 Write Skew(쓰기 편향)다. 같은 행을 덮어쓰는 Lost Update(갱신 유실)와 구별한다. PostgreSQL REPEATABLE READ는 반복 조회 결과가 바뀌는 Phantom Read(팬텀 읽기)는 막지만, 이처럼 서로 다른 행을 변경해 생기는 직렬화 이상은 허용할 수 있다.

## 2. 두 세션으로 실패를 재현한다

연습 DB에 초기 데이터를 만든다.

```sql
CREATE TABLE duty_roster (
    team_id integer NOT NULL,
    doctor_id integer PRIMARY KEY,
    on_call boolean NOT NULL
);
INSERT INTO duty_roster VALUES (7, 1, true), (7, 2, true);
```

다음 순서로 두 연결을 번갈아 실행한다. `doctor_id`와 `team_id`를 실제 업무에서는 매개변수로 전달한다.

| 순서 | 세션 A | 세션 B |
|---|---|---|
| 1 | BEGIN ISOLATION LEVEL REPEATABLE READ | BEGIN ISOLATION LEVEL REPEATABLE READ |
| 2 | 팀 7의 당직 COUNT 조회 → 2 | 팀 7의 당직 COUNT 조회 → 2 |
| 3 | 2 > 1일 때 doctor 1 해제 | 2 > 1일 때 doctor 2 해제 |
| 4 | COMMIT | COMMIT |

```sql
-- 세션 A: 위 순서에 맞춰 문장별 실행. 세션 B는 doctor_id = 2.
SELECT count(*) FROM duty_roster WHERE team_id = 7 AND on_call;
-- 애플리케이션은 조회 결과가 1보다 클 때만 아래 UPDATE를 실행한다.
UPDATE duty_roster SET on_call = false
WHERE team_id = 7 AND doctor_id = 1 AND on_call;
```

초기 상태로 되돌리고 두 BEGIN을 SERIALIZABLE로 바꿔 같은 순서를 실행한다. 둘 다 같은 초기 상태를 읽고 쓰려고 하면 하나가 직렬화 실패로 중단될 수 있다. 재시도는 새 트랜잭션으로 COUNT부터 다시 시작하므로, 한 명만 남았음을 읽으면 해제를 거절한다.

> **실무 함정** — `SELECT count(*)` 결과를 무시하고 무조건 UPDATE하는 코드는 SERIALIZABLE에서도 잘못됐다. 격리는 올바른 직렬 프로그램의 동시 실행을 보호하며, 빠진 업무 조건을 만들어주지 않는다.

## 3. Predicate Lock과 SSI의 역할

SSI(Serializable Snapshot Isolation, 직렬화 가능한 스냅샷 격리)는 읽기·쓰기 의존성을 추적해 직렬 실행과 양립하지 않을 위험이 있는 실행을 중단한다. PostgreSQL의 Predicate Lock(조건 읽기 추적 잠금)은 읽은 조건에 영향을 줄 쓰기를 감지하는 용도이며, InnoDB Gap Lock처럼 삽입을 대기시키는 잠금과 다르다. 모든 읽기·쓰기 충돌을 곧바로 중단시키는 것도 아니다.

| PostgreSQL 17 수준 | 조회 기준 | 이 예제의 책임 |
|---|---|---|
| READ COMMITTED | 문장마다 새 스냅샷 | 별도 직렬화 경계가 필요 |
| REPEATABLE READ | 트랜잭션의 첫 일반 문장 시점 스냅샷 | Write Skew에 취약 |
| SERIALIZABLE | 스냅샷 + 의존성 감시 | 직렬화 실패 전체 재시도 |

당직자 행만 잠그는 방식은 새 당직자 추가·팀 이동처럼 집합을 바꾸는 모든 경로를 함께 검토해야 한다. 대안은 팀별 가드 행을 두고 **READ COMMITTED에서 모든 변경 경로가 먼저 그 행을 `FOR UPDATE`로 잠근 뒤 다음 문장으로 당직 집합을 조회**하는 것이다. 팀 단위 경합이 늘고 우회 경로가 생기면 규칙이 깨진다는 비용이 있다.

## 4. 재시도는 트랜잭션 밖에서 통제한다

```text
for attempt in 1..max_attempts:
    try:
        begin a NEW serializable transaction
        read current duty count
        if count <= 1: reject business request
        otherwise update my duty and commit
        return result
    catch SQLSTATE 40001:
        rollback
        if retry budget exhausted: return retryable failure
        wait bounded backoff with jitter
```

`40001`은 PostgreSQL 직렬화 실패 코드다. 실패한 UPDATE만 다시 실행하지 않는다. 입력을 결정한 조회·계산까지 새 스냅샷에서 반복해야 한다. 외부 알림은 로컬 트랜잭션의 Outbox(발행 대기함)에 기록하고 커밋 이후 전달해 재시도 중의 중복 부작용을 분리한다.

가정: 요청 100건 중 10건이 첫 시도에서 실패하고 재시도는 모두 성공하면 DB 실행은 110회다. 실제로 재시도끼리 재충돌하면 이보다 늘어난다. 최대 시도 수, 총 시간 예산, 팀별 중단율, 대기 시간과 사용자에게 보이는 실패율을 함께 측정한다.

> **면접 포인트** — 물류센터에서 “가용 작업자 최소 한 명” 같은 집합 규칙도 같은 문제다. 단일 재고 행의 조건부 감소와 여러 행에 걸친 불변식을 구분하고, 규칙을 지키는 코드·격리 수준·재시도까지 연결한다.

## 참고

- [PostgreSQL 17: Transaction Isolation](https://www.postgresql.org/docs/17/transaction-iso.html) — REPEATABLE READ와 SERIALIZABLE의 차이 및 전체 재시도.$review_31$
WHERE slug = 'system-design-25-transaction-isolation' AND source = 'MANUAL';

UPDATE cards
SET content_md = $review_32$> **검수 기준 — 2026-09-12**
>
> Kafka 4.1의 일반 Consumer Group(소비자 그룹), RabbitMQ 4.1의 Queue·Stream, Amazon SQS의 Standard·FIFO를 구분한다. 용량 수치는 제품 한도가 아닌 가상 부하 시험의 가정이다.

## 1. 같은 배송 이벤트에도 소비 목적이 다르다

배송 스캔 이벤트를 감사팀은 7일 뒤 다시 읽고, 고객 알림은 한 번 성공하면 끝내고, 운영팀은 지역과 오류 유형별로 나누려 한다. 제품부터 고르면 이 세 요구가 섞인다.

Event Log(이벤트 로그)는 보존 기간 안에서 소비 위치를 옮겨 다시 읽는 모델이다. Work Queue(작업 큐)는 Worker에 미완료 작업을 배분하는 모델이다. 재생 가능하다는 것은 영구 보관이나 외부 부작용의 안전한 재실행을 뜻하지 않는다.

```mermaid
flowchart TD
    E[배송 스캔 이벤트] --> L[보존 가능한 이벤트 로그]
    L --> A[감사 소비자: 재생]
    L --> P[조회 모델 소비자: 갱신]
    L --> N[알림 명령 생성]
    N --> Q[작업 큐]
    Q --> W[멱등 알림 Worker]
```

## 2. 제품명이 아니라 기능 범위를 비교한다

| 선택 | 보존·재생 | 순서 범위 | 주의점 |
|---|---|---|---|
| Kafka 일반 Consumer Group | 보존된 로그와 Offset(소비 위치) | 파티션 내 로그 순서 | 업무 처리의 완료 순서는 소비자 책임 |
| RabbitMQ Queue | ACK(처리 확인) 이후 일반적으로 제거 | 큐·소비 설정에 의존 | 재전달·병렬 소비가 처리 순서를 바꿀 수 있음 |
| RabbitMQ Stream | 보존 정책 안에서 재생 | 스트림 내 순서 | 일반 큐와 다른 보존·소비 모델 |
| SQS Standard | 작업 처리·삭제 중심 | 최선 노력 순서 | 중복 전달과 역전 허용 |
| SQS FIFO | 작업 처리·삭제 중심 | Message Group ID별 | 같은 그룹의 긴 작업이 뒤를 막음 |

RabbitMQ 전체를 “재생 불가”로 묶거나 SQS 전체를 “순서 보장”으로 묶지 않는다. RabbitMQ Exchange(교환기)의 라우팅이 필요하면 큐 유형과 Binding(연결 규칙)을 별도로 선택한다. SQS의 Visibility Timeout(메시지 비노출 시간)은 처리 중 재노출을 지연시키며, 업무 성공을 보장하는 타이머가 아니다.

## 3. 용량 추정의 단위를 맞춘다

가정: 피크 유입 6,000건/초, 재시도 배수 1.2, 같은 페이로드와 내구성 설정으로 측정한 파티션당 지속 처리 900건/초다. 일반 Consumer Group에서 목표 병렬 소비자 수는 12개다.

```text
attempt_rate = 6000 * 1.2 = 7200 attempts/s
partitions_for_rate = ceil(7200 / 900) = 8
initial_partitions = max(8, 12) = 12

backlog = 3_600_000 messages
new_arrival_rate = 6000 messages/s
successful_service_rate = 9000 messages/s
recovery_time = backlog / (successful_service_rate - new_arrival_rate)
              = 1200 s = 20 min
```

처리율과 파티션 개수를 바로 비교하면 단위가 맞지 않는다. 파티션당 처리율은 평균 메시지 크기, 복제, 압축, DB 쓰기 지연까지 포함해 측정한다. 위 복구 계산은 성공 처리율이 유입보다 크고 재시도 비용이 이미 처리율에 반영된 경우다. 실제 피크 분포와 여유 용량을 반영해 부하 시험으로 보정한다.

운송장 하나에 이벤트가 몰리는 Hot Key(특정 키 집중)가 있으면 파티션을 늘려도 그 키의 병목은 그대로다. 키를 쪼개면 순서를 합치는 책임이 생기므로 먼저 업무 순서의 최소 단위를 정한다.

## 4. 전달 순서와 업무 순서를 구분한다

`shipment_id`로 같은 파티션·그룹에 넣어도 생산자 둘이 12번 이벤트를 11번보다 먼저 보내면 업무 순서가 자동 복원되지 않는다. 이벤트에 업무 버전을 넣고 소비자가 마지막 적용 버전과 비교한다. 버전 공백을 기다릴지, 원장을 조회할지, 오래된 이벤트를 무시해도 되는지 업무 계약을 정한다.

실패 메시지를 DLQ(Dead Letter Queue, 처리 실패 격리 큐)로 보내고 뒤의 메시지를 계속 적용하면 순서 요구를 깨뜨릴 수 있다. 결제·출고 상태처럼 의존성이 있으면 해당 키를 멈추거나 상태를 재구성한 뒤 재개한다. 독립 알림이라면 실패 작업만 격리할 수 있다.

> **실무 함정** — Kafka 트랜잭션의 exactly-once 보장 범위와 외부 DB·HTTP 부작용은 다르다. SQS FIFO도 소비자의 외부 결제를 원자적으로 커밋해주지 않는다. 커밋 후 확인 응답이 유실되는 경우를 반드시 설계한다.

## 5. 교체 가능한 경계를 정한다

애플리케이션에는 업무 이벤트 스키마, 키, 버전, 재시도 가능 오류를 명시한다. 어댑터가 ACK·Offset·재생 API를 다루되 중요한 기능까지 감추지는 않는다. “send와 receive만 공통화”하면 재생·라우팅·순서를 다시 구현하는 비용이 생긴다.

면접에서는 “감사 로그는 보존·다중 재생, 알림은 독립 작업 처리”처럼 요구와 선택을 연결한다. 두 제품을 동시에 운영하는 비용이 크다면 하나로 시작하되, 필요한 기능과 현재 허용하는 제약을 문서화한다.

> **운영 점검** — 가장 오래된 미처리 메시지의 나이, 성공 처리율, 재전달률, 키별 정체, 보존 만료까지 남은 시간을 본다. 메시지 개수만으로 사용자 지연을 판단하지 않는다.

## 참고

- [Kafka 4.1 Design](https://kafka.apache.org/41/design/design/) — 소비 위치와 전달·처리 보장 범위.
- [RabbitMQ 4.1 Queues](https://www.rabbitmq.com/docs/4.1/queues), [Streams](https://www.rabbitmq.com/docs/4.1/streams) — 큐와 로그형 스트림의 차이.
- [SQS Standard](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues.html), [FIFO delivery logic](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-understanding-logic.html) — 전달 중복과 메시지 그룹 순서.$review_32$
WHERE slug = 'system-design-26-message-queue-selection' AND source = 'MANUAL';

