import {
  getFeed,
  AREA_LABELS,
  MODE_LABELS,
  DIFFICULTY_LABELS,
  TopicArea,
  LearningMode,
  DifficultyLevel,
} from "@/lib/api";
import FeedFilterLink from "@/components/FeedFilterLink";
import CardFeed from "@/components/CardFeed";
import ActiveTabScroller from "@/components/ActiveTabScroller";
import Link from "next/link";
import FilterSheet from "@/components/FilterSheet";

const AREAS = Object.keys(AREA_LABELS) as TopicArea[];
const MODES = Object.keys(MODE_LABELS) as LearningMode[];
// 현재 큐레이션 카드가 존재하는 난이도만 노출한다. API 자체는 1~5를 모두 지원한다.
const DIFFICULTIES = [3, 4, 5] as DifficultyLevel[];

function feedHref(area?: TopicArea, mode?: LearningMode, difficulty?: DifficultyLevel) {
  const q = new URLSearchParams({ view: "explore" });
  if (area) q.set("area", area);
  if (mode) q.set("mode", mode);
  if (difficulty) q.set("difficulty", String(difficulty));
  const s = q.toString();
  return s ? `/?${s}` : "/";
}

export default async function Home({
  searchParams,
}: {
  searchParams: Promise<{ area?: string; mode?: string; difficulty?: string; view?: string; study?: string; q?: string }>;
}) {
  const { area, mode, difficulty, view, study, q } = await searchParams;
  const activeView = view === "review" ? "review" : view === "explore" || area || mode || difficulty || study || q ? "explore" : "home";
  const activeArea = AREAS.includes(area as TopicArea)
    ? (area as TopicArea)
    : undefined;
  const activeMode = MODES.includes(mode as LearningMode)
    ? (mode as LearningMode)
    : undefined;
  const parsedDifficulty = Number(difficulty);
  const activeDifficulty = DIFFICULTIES.includes(parsedDifficulty as DifficultyLevel)
    ? (parsedDifficulty as DifficultyLevel)
    : undefined;

  let initial;
  let error: string | null = null;
  try {
    initial = await getFeed({
      area: activeArea,
      mode: activeMode,
      difficulty: activeDifficulty,
      limit: 20,
    });
  } catch (e) {
    error = e instanceof Error ? e.message : "불러오기 실패";
    initial = { items: [], nextCursor: null };
  }

  return (
    <>
      <header className="topbar home-topbar">
        <div className="brand">
          <Link href="/" className="brand-home" aria-label="STUDY WITH JOB 홈">
            <span className="brand-mark" aria-hidden="true">S</span>
            <span className="brand-copy">
              <h1>STUDY WITH JOB</h1>
              <p>커리어를 만드는 기술 학습</p>
            </span>
          </Link>
          <Link href="/interview" className="brand-action">
            <span aria-hidden="true">●</span>
            AI 면접
          </Link>
        </div>
        {activeView === "explore" && <FilterSheet>
        <div className="filter-panel" aria-label="학습 카드 필터">
          <div className="filter-group">
            <div className="filter-heading">
              <span>카테고리</span>
            </div>
            <nav className="tabs" aria-label="카테고리 필터">
              <FeedFilterLink
                className={`tab t-all ${!activeArea ? "active" : ""}`}
                href={feedHref(undefined, activeMode, activeDifficulty)}
                aria-current={!activeArea ? "page" : undefined}
              >
                전체
              </FeedFilterLink>
              {AREAS.map((a) => (
                <FeedFilterLink
                  key={a}
                  className={`tab a-${a} ${activeArea === a ? "active" : ""}`}
                  href={feedHref(a, activeMode, activeDifficulty)}
                  aria-current={activeArea === a ? "page" : undefined}
                >
                  {AREA_LABELS[a]}
                </FeedFilterLink>
              ))}
            </nav>
          </div>
          <div className="filter-group mode-filter">
            <div className="filter-heading">
              <span>학습 모드</span>
            </div>
            <nav className="tabs sub" aria-label="학습 모드 필터">
              <FeedFilterLink
                className={`tab ${!activeMode ? "active" : ""}`}
                href={feedHref(activeArea, undefined, activeDifficulty)}
                aria-current={!activeMode ? "page" : undefined}
              >
                모든 모드
              </FeedFilterLink>
              {MODES.map((m) => (
                <FeedFilterLink
                  key={m}
                  className={`tab ${activeMode === m ? "active" : ""}`}
                  href={feedHref(activeArea, m, activeDifficulty)}
                  aria-current={activeMode === m ? "page" : undefined}
                >
                  {MODE_LABELS[m]}
                </FeedFilterLink>
              ))}
            </nav>
          </div>
          <div className="filter-group difficulty-filter">
            <div className="filter-heading">
              <span>난이도</span>
            </div>
            <nav className="tabs sub" aria-label="난이도 필터">
              <FeedFilterLink
                className={`tab ${!activeDifficulty ? "active" : ""}`}
                href={feedHref(activeArea, activeMode, undefined)}
                aria-current={!activeDifficulty ? "page" : undefined}
              >
                전체 난이도
              </FeedFilterLink>
              {DIFFICULTIES.map((level) => (
                <FeedFilterLink
                  key={level}
                  className={`tab ${activeDifficulty === level ? "active" : ""}`}
                  href={feedHref(activeArea, activeMode, level)}
                  aria-current={activeDifficulty === level ? "page" : undefined}
                >
                  {DIFFICULTY_LABELS[level]}
                </FeedFilterLink>
              ))}
            </nav>
          </div>
        </div>
        <ActiveTabScroller
          filterKey={`${activeArea ?? "ALL"}:${activeMode ?? "ALL"}:${activeDifficulty ?? "ALL"}`}
        />
        </FilterSheet>}
      </header>

      {error ? (
        <p className="empty">
          <span className="glyph">📡</span>
          카드를 불러오지 못했어요.
          <br />
          잠시 후 다시 시도해 주세요.
          <a className="loadmore" href={activeView === "explore" ? feedHref(activeArea, activeMode, activeDifficulty) : activeView === "review" ? "/?view=review" : "/"}>다시 시도</a>
        </p>
      ) : (
        <CardFeed
          key={`${activeView}:${activeArea ?? "ALL"}:${activeMode ?? "ALL"}:${activeDifficulty ?? "ALL"}`}
          view={activeView}
          initial={initial}
          area={activeArea}
          mode={activeMode}
          difficulty={activeDifficulty}
        />
      )}
    </>
  );
}
