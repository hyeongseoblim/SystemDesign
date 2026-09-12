import { getCard, CardFetchError, AREA_LABELS, MODE_LABELS, stripMd } from "@/lib/api";
import { headings } from "@/lib/reading";
import answerGuides from "@/content/answer-guides.json";
import CardBody from "@/components/CardBody";
import QuestionAnswers from "@/components/QuestionAnswers";
import DifficultyDots from "@/components/DifficultyDots";
import ReadingProgress from "@/components/ReadingProgress";
import LearnActions from "@/components/LearnActions";
import StartInterviewFromCard from "@/components/StartInterviewFromCard";
import Link from "next/link";
import { notFound } from "next/navigation";

export default async function CardPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ area?: string; mode?: string; difficulty?: string; returnTo?: string }>;
}) {
  const { id } = await params;
  const origin = await searchParams;

  let card;
  try {
    card = await getCard(id);
  } catch (error) {
    if (error instanceof CardFetchError && error.status === 404) notFound();
    throw error;
  }

  const published = card.publishedAt
    ? new Date(card.publishedAt).toLocaleDateString("ko-KR", {
        year: "numeric",
        month: "long",
        day: "numeric",
      })
    : null;
  const isAI = card.source === "AI_GENERATED";
  const backParams = new URLSearchParams();
  if (origin.area && Object.prototype.hasOwnProperty.call(AREA_LABELS, origin.area)) {
    backParams.set("area", origin.area);
  }
  if (origin.mode && Object.prototype.hasOwnProperty.call(MODE_LABELS, origin.mode)) {
    backParams.set("mode", origin.mode);
  }
  if (["1", "2", "3", "4", "5"].includes(origin.difficulty ?? "")) {
    backParams.set("difficulty", origin.difficulty!);
  }
  const backQuery = backParams.toString();
  const fallbackHref = backQuery ? `/?${backQuery}` : "/";
  const backHref = origin.returnTo === "/" || origin.returnTo?.startsWith("/?") ? origin.returnTo : fallbackHref;
  const outline = headings(card.contentMd);
  const guide = (answerGuides as Record<string, typeof answerGuides[keyof typeof answerGuides]>)[card.slug];
  const hasQuestions = card.questions.length > 0;
  const completionStep = hasQuestions ? 3 : 2;

  return (
    <article className={`detail a-${card.area}`}>
      <ReadingProgress cardId={card.id} />
      <nav className="reading-dock" aria-label="학습 바로가기">
        <Link href={backHref}>← 목록</Link>
        <a href={hasQuestions ? "#questions" : "#complete"}>{hasQuestions ? "질문 풀기" : "이해도 기록하기"} →</a>
      </nav>
      <Link href={backHref} className="back">
        ← 목록으로
      </Link>
      <header className="detail-hero">
        <div className="meta">
          <span className="badge">{AREA_LABELS[card.area]}</span>
          <span className="badge mode">{MODE_LABELS[card.mode] ?? card.mode}</span>
          <DifficultyDots level={card.difficulty} />
        </div>
        <h1>{card.title}</h1>
        {card.summary && stripMd(card.summary) !== card.title && (
          <p className="lede">{stripMd(card.summary)}</p>
        )}
        <div className="byline">
          {card.coach && <span className="coach">{card.coach}</span>}
          <span>{isAI ? "AI 생성" : "직접 큐레이션"}</span>
          {isAI && card.qualityScore != null && <span>품질 {card.qualityScore}점</span>}
          {published && <span>{published}</span>}
        </div>
      </header>

      <nav className="study-roadmap" aria-label="이 카드 학습 순서">
        <span className="roadmap-title">학습 순서</span>
        <ol className={hasQuestions ? undefined : "two-steps"}>
          <li><b>1</b><a href="#reading">핵심 내용 읽기</a></li>
          {hasQuestions && <li><b>2</b><a href="#questions">질문 {card.questions.length}개 답하기</a></li>}
          <li><b>{completionStep}</b><a href="#complete">이해도 기록하기</a></li>
        </ol>
      </nav>

      {outline.length > 0 && <details className="reading-outline">
        <summary>목차 · {outline.length}개 섹션</summary>
        <nav aria-label="본문 목차"><ol>{outline.map((item) => <li key={item.id}><a href={`#${item.id}`}>{item.title}</a></li>)}</ol></nav>
      </details>}
      <section id="reading" className="study-section">
        <div className="study-section-head">
          <span>STEP 1</span>
          <div>
            <h2>핵심 내용 이해하기</h2>
            <p>중요한 이유와 적용 맥락을 연결하며 읽어보세요.</p>
          </div>
        </div>
        <CardBody md={card.contentMd} />
      </section>
      <QuestionAnswers cardId={card.id} questions={card.questions} guide={guide} />
      <LearnActions cardId={card.id} step={completionStep} />
      <StartInterviewFromCard
        cardId={card.id}
        area={card.area}
        title={card.title}
        difficulty={card.difficulty}
        step={completionStep + 1}
      />
    </article>
  );
}
