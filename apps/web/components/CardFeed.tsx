"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { CardSummary, FeedResponse, TopicArea, LearningMode, DifficultyLevel, getFeed,
  AREA_LABELS, MODE_LABELS, MODE_GUIDES, DIFFICULTY_LABELS, stripMd } from "@/lib/api";
import { matchesSearch, matchesStudy, needsReview, readStudy, shuffleRank, STUDY_LABELS,
  StudyFilter, StudyRecord } from "@/lib/study";
import DifficultyDots from "@/components/DifficultyDots";

export default function CardFeed({ initial, area, mode, difficulty, view = "explore" }: {
  view?: "home" | "explore" | "review";
  initial: FeedResponse; area?: TopicArea; mode?: LearningMode; difficulty?: DifficultyLevel;
}) {
  const searchParams = useSearchParams();
  const searchString = searchParams.toString();
  const [items, setItems] = useState<CardSummary[]>(initial.items);
  const [records, setRecords] = useState<Record<string, StudyRecord>>({});
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<StudyFilter>("all");
  const [seed, setSeed] = useState<number | null>(null);
  const [visible, setVisible] = useState(20);
  const [ready, setReady] = useState(false);
  const [loading, setLoading] = useState(!!initial.nextCursor);
  const [error, setError] = useState(false);
  const [retry, setRetry] = useState(0);
  const cursor = useRef(initial.nextCursor);
  const restored = useRef(false);

  useEffect(() => {
    function restoreOptions() {
      const params = new URLSearchParams(searchString);
      setQuery(params.get("q") ?? "");
      const state = view === "review" ? "review" : params.get("study") ?? "all";
      setFilter(Object.hasOwn(STUDY_LABELS, state) ? state as StudyFilter : "all");
      const random = Number(params.get("random"));
      setSeed(Number.isSafeInteger(random) && random > 0 ? random : null);
      const count = Number(params.get("shown"));
      setVisible(Number.isSafeInteger(count) && count >= 20 ? Math.min(count, 10000) : 20);
      setReady(true);
    }
    restoreOptions();
  }, [searchString, view]);

  // 요약만 가져온다. 첫 페이지 밖의 카드도 검색·학습 상태 필터에 포함한다.
  useEffect(() => {
    let active = true;
    async function completeCatalog() {
      setError(false);
      setLoading(!!cursor.current);
      try {
        while (cursor.current && active) {
          const previous = cursor.current;
          const page = await getFeed({ area, mode, difficulty, cursor: previous, limit: 50 });
          if (!active) return;
          if (page.nextCursor === previous) throw new Error("Repeated feed cursor");
          setItems((current) => [...new Map([...current, ...page.items].map((card) => [card.id, card])).values()]);
          cursor.current = page.nextCursor;
        }
      } catch {
        if (active) setError(true);
      } finally {
        if (active) setLoading(false);
      }
    }
    void completeCatalog();
    return () => { active = false; };
  }, [area, mode, difficulty, retry]);

  useEffect(() => {
    function refresh() { setRecords(Object.fromEntries(items.map((card) => [card.id, readStudy(card.id)]))); }
    refresh();
    window.addEventListener("study-change", refresh);
    window.addEventListener("storage", refresh);
    window.addEventListener("pageshow", refresh);
    return () => {
      window.removeEventListener("study-change", refresh);
      window.removeEventListener("storage", refresh);
      window.removeEventListener("pageshow", refresh);
    };
  }, [items]);

  useEffect(() => {
    if (!ready || loading || error || restored.current) return;
    restored.current = true;
    let y: number | null = null;
    try {
      const saved = sessionStorage.getItem(`jobStudy::feed-position::${window.location.search}`);
      if (saved !== null) y = Number(saved);
    } catch { /* 저장소가 막혀도 탐색 가능 */ }
    const frame = requestAnimationFrame(() => {
      if (y !== null && Number.isFinite(y)) window.scrollTo({ top: y, behavior: "instant" });
    });
    return () => cancelAnimationFrame(frame);
  }, [ready, loading, error]);

  function updateOptions(next: { query?: string; filter?: StudyFilter; seed?: number | null; visible?: number }) {
    const q = next.query ?? query;
    const state = next.filter ?? filter;
    const random = next.seed === undefined ? seed : next.seed;
    const count = next.visible ?? 20;
    setQuery(q); setFilter(state); setSeed(random); setVisible(count);
    const params = new URLSearchParams(window.location.search);
    if (q) params.set("q", q); else params.delete("q");
    if (state !== "all") params.set("study", state); else params.delete("study");
    if (random !== null) params.set("random", String(random)); else params.delete("random");
    if (count > 20) params.set("shown", String(count)); else params.delete("shown");
    window.history.replaceState(null, "", params.size ? `/?${params}` : "/");
  }

  const filtered = useMemo(() => {
    const cards = items.filter((card) => matchesSearch(card, query) && matchesStudy(records[card.id] ?? {}, filter));
    return seed === null ? cards : [...cards].sort((a, b) => shuffleRank(a.id, seed) - shuffleRank(b.id, seed) || a.id.localeCompare(b.id));
  }, [items, query, records, filter, seed]);
  const completeCount = items.filter((card) => records[card.id]?.done).length;
  const reviewCount = items.filter((card) => needsReview(records[card.id] ?? {})).length;
  const reading = items.filter((card) => records[card.id]?.read && !records[card.id]?.done)
    .sort((a, b) => (records[b.id]?.read ?? "").localeCompare(records[a.id]?.read ?? ""))[0];
  const params = new URLSearchParams();
  if (view !== "home") params.set("view", view);
  if (area) params.set("area", area);
  if (mode) params.set("mode", mode);
  if (difficulty) params.set("difficulty", String(difficulty));
  if (query) params.set("q", query);
  if (filter !== "all") params.set("study", filter);
  if (seed !== null) params.set("random", String(seed));
  if (visible > 20) params.set("shown", String(visible));
  const listHref = params.size ? `/?${params}` : "/";
  function cardHref(id: string) { return `/cards/${id}?returnTo=${encodeURIComponent(listHref)}`; }
  function rememberPosition() {
    try { sessionStorage.setItem(`jobStudy::feed-position::${window.location.search}`, String(window.scrollY)); } catch { /* 선택적 복원 */ }
  }

  return (
    <>
      {view === "home" && <section className="home-welcome">
        <span className="eyebrow">조금씩, 꾸준히 쌓는 실력</span>
        <h2>오늘도 한 걸음<br />성장해 볼까요?</h2>
        <p>개념을 읽고, 내 언어로 설명하는 기술 학습.</p>
        <Link className="home-primary" href={reading ? cardHref(reading.id) : "/?view=explore"} onClick={rememberPosition}>
          {reading ? "이어서 공부하기" : "공부할 카드 찾기"}<span aria-hidden="true">↗</span>
        </Link>
        {ready && reading && <p className="resume-title">{reading.title}</p>}
        <div className="home-stats">
          <Link href="/?view=explore&study=complete"><strong>{ready ? `${completeCount}${loading || error ? "+" : ""}` : "—"}</strong><span>학습 완료</span></Link>
          <Link href="/?view=review"><strong>{ready ? `${reviewCount}${loading || error ? "+" : ""}` : "—"}</strong><span>복습할 카드</span></Link>
        </div>
      </section>}
      {view === "review" && <section className="screen-intro"><span className="eyebrow">내 것으로 만드는 시간</span><h2>한 번 더, 확실하게</h2><p>다시 공부하고 싶거나 힌트가 필요했던 카드를 모았어요.</p></section>}
      {view !== "home" && <section className="study-search" aria-label="카드 검색과 학습 상태">
        <label htmlFor="card-search">{view === "review" ? "복습 카드 검색" : "무엇을 공부할까요?"}</label>
        <input id="card-search" type="search" placeholder="제목·태그·요약 검색 (예: 인덱스, Kafka)"
          value={query} onChange={(e) => updateOptions({ query: e.target.value })} disabled={!ready} />
        {view === "explore" && <div className="study-filter-chips" role="group" aria-label="학습 상태">
          {(Object.keys(STUDY_LABELS) as StudyFilter[]).map((state) => (
            <button key={state} className={`chip ${filter === state ? "on" : ""}`} aria-pressed={filter === state}
              onClick={() => updateOptions({ filter: state })} disabled={!ready}>{STUDY_LABELS[state]}</button>
          ))}
        </div>}
        <p className="hint">학습 기록은 이 브라우저에 저장됩니다. 복습 필요에는 ‘힌트 필요’도 포함됩니다.</p>
      </section>}
      {view === "explore" && ready && (reading || reviewCount > 0) && (
        <div className="study-shortcuts">
          {reading && <Link href={cardHref(reading.id)} onClick={rememberPosition}>이어서 공부하기 → <strong>{reading.title}</strong></Link>}
          {reviewCount > 0 && <button onClick={() => updateOptions({ filter: "review", query: "" })}>복습할 카드 <strong>{reviewCount}개</strong></button>}
        </div>
      )}
      {view !== "home" && <><div className="feed-toolbar">
        <div className="feed-context">
          <span>학습 카드 · {seed === null ? "최신순" : "랜덤 순서"}</span>
          <strong>{area ? AREA_LABELS[area] : "전체 카테고리"} · {mode ? MODE_LABELS[mode] : "모든 모드"} · {difficulty ? DIFFICULTY_LABELS[difficulty] : "모든 난이도"}</strong>
        </div>
        <div className="feed-tools">
          <button className="chip" onClick={() => updateOptions({ seed: seed === null ? Math.floor(Math.random() * 2147483646) + 1 : null })} disabled={!ready}>
            {seed === null ? "랜덤으로 골라보기" : "최신순으로 보기"}
          </button>
          {(area || mode || difficulty || query || filter !== "all") && <Link href={view === "review" ? "/?view=review" : "/?view=explore"} className="reset-filter">전체 초기화</Link>}
        </div>
      </div>
      <div className="study-overview" aria-live="polite">
        <span>{loading || error ? `불러온 ${items.length}개 중` : `현재 카테고리·모드·난이도 ${items.length}개 중`} 검색 결과 <strong>{ready ? filtered.length : "…"}개</strong></span>
        <span>완료 <strong>{ready ? completeCount : "…"}개</strong></span>
      </div>
      </>}
      {view === "home" && <div className="home-section-title"><h2>새롭게 공부해 보세요</h2><Link href="/?view=explore">전체 보기 →</Link></div>}
      {loading && <p className="catalog-status" role="status">전체 목록을 확인하고 있어요. 검색 결과가 더 추가될 수 있습니다.</p>}
      {error && <div className="catalog-status" role="alert">일부 카드를 불러오지 못했어요. 현재 결과는 전체가 아닙니다. <button className="chip" onClick={() => setRetry((v) => v + 1)}>다시 시도</button></div>}
      {ready && filtered.length === 0 && !loading && (
        <div className="empty"><strong>{error ? "불러온 카드 중에는 일치하는 카드가 없어요." : (view === "review" ? "지금은 복습할 카드가 없어요." : "조건에 맞는 학습 카드가 없어요.")}</strong>
          <p>{view === "review" ? "학습 후 이해도를 기록하면 여기에 모아드려요." : "검색어나 학습 상태를 바꿔 보세요."}</p><button className="chip" onClick={() => updateOptions({ query: "", filter: view === "review" ? "review" : "all" })}>검색·학습 상태 초기화</button></div>
      )}
      {view === "review" && !ready && <p className="catalog-status" role="status">복습 기록을 확인하고 있어요.</p>}
      <div className="feed" aria-busy={loading || !ready}>
        {(ready ? filtered : view === "review" ? [] : items).slice(0, view === "home" ? 4 : visible).map((c) => {
          const record = records[c.id] ?? {};
          const isRead = !!record.read;
          const isDone = !!record.done;
          const review = needsReview(record);
          const studyState = isDone ? "complete" : isRead ? "reading" : "new";
          return (
            <Link key={c.id} href={cardHref(c.id)} onClick={rememberPosition} className={`card a-${c.area} state-${studyState}`}>
              <div className="meta">
                <span className="badge">{AREA_LABELS[c.area]}</span>
                <span className="badge mode">{MODE_LABELS[c.mode]}</span>
                <span className={`study-state ${review ? "review" : studyState}`}>{review ? "↺ 복습 필요" : isDone ? "✓ 완료" : isRead ? "● 학습 중" : "새 학습"}</span>
                <DifficultyDots level={c.difficulty} />
              </div>
              <h2>{c.title}</h2>
              {c.summary && stripMd(c.summary) !== c.title && <p className="summary">{stripMd(c.summary)}</p>}
              <p className="learning-cue"><span>학습 초점</span>{MODE_GUIDES[c.mode]}</p>
              {c.tags.length > 0 && <div className="tags">{c.tags.slice(0, 4).map((tag) => <span key={tag} className="tag">#{tag}</span>)}</div>}
              <div className="card-cta" aria-hidden="true"><span>{review || isDone ? "다시 복습하기" : isRead ? "이어서 학습하기" : "학습 시작하기"}</span><b>→</b></div>
            </Link>
          );
        })}
      </div>
      {view !== "home" && filtered.length > visible && <button className="loadmore" onClick={() => updateOptions({ visible: visible + 20 })}>20개 더 보기 · {Math.min(visible, filtered.length)}/{filtered.length}개 표시</button>}
    </>
  );
}
