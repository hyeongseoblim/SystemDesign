// 백엔드 API 클라이언트 + 타입 (apps/api DTO와 1:1 매칭)

export type TopicArea =
  | "SYSTEM_DESIGN"
  | "LOGISTICS"
  | "BACKEND_DEV"
  | "BACKEND_ARCHITECTURE"
  | "DATABASE"
  | "INFRA"
  | "CS"
  | "AI";

export type LearningMode = "CONCEPT" | "DESIGN" | "INTERVIEW" | "REVIEW";
export type DifficultyLevel = 1 | 2 | 3 | 4 | 5;

export interface CardSummary {
  id: string;
  area: TopicArea;
  mode: LearningMode;
  title: string;
  slug: string;
  summary: string | null;
  coach: string | null;
  difficulty: number;
  tags: string[];
  publishedAt: string | null;
}

export interface QuestionItem {
  id: string;
  question: string;
  displayOrder: number;
}

export interface CardDetail extends CardSummary {
  contentMd: string;
  status: string;
  qualityScore: number | null;
  source: string;
  questions: QuestionItem[];
  createdAt: string;
}

export interface FeedResponse {
  items: CardSummary[];
  nextCursor: string | null;
}

export const API_BASE =
  process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8080";

export const AREA_LABELS: Record<TopicArea, string> = {
  SYSTEM_DESIGN: "시스템 디자인",
  LOGISTICS: "물류",
  BACKEND_DEV: "백엔드 개발",
  BACKEND_ARCHITECTURE: "아키텍처",
  DATABASE: "데이터베이스",
  INFRA: "인프라",
  CS: "CS 기초",
  AI: "AI · LLM",
};

export const MODE_LABELS: Record<LearningMode, string> = {
  CONCEPT: "개념",
  DESIGN: "설계",
  INTERVIEW: "면접",
  REVIEW: "리뷰",
};

/** 피드에서 각 학습 모드의 목적을 즉시 이해할 수 있도록 짧게 안내한다. */
export const MODE_GUIDES: Record<LearningMode, string> = {
  CONCEPT: "핵심 원리 이해",
  DESIGN: "설계 판단 연습",
  INTERVIEW: "말로 설명 연습",
  REVIEW: "기억 회상 · 복습",
};

export const DIFFICULTY_LABELS: Record<DifficultyLevel, string> = {
  1: "1 · 입문",
  2: "2 · 기초",
  3: "3 · 중급",
  4: "4 · 시니어",
  5: "5 · 스태프",
};

/** 읽음/완료 상태 — localStorage 키 (기기 로컬 학습 기록) */
export const readKey = (id: string) => `jobStudy::read::${id}`;
export const doneKey = (id: string) => `jobStudy::done::${id}`;

/** 요약 등 플레인 텍스트 자리에서 마크다운 문법 제거 */
export function stripMd(s: string): string {
  return s
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
}

export async function getFeed(params: {
  area?: TopicArea;
  mode?: LearningMode;
  difficulty?: DifficultyLevel;
  shuffleSeed?: number;
  cursor?: string | null;
  limit?: number;
}): Promise<FeedResponse> {
  const q = new URLSearchParams();
  if (params.area) q.set("area", params.area);
  if (params.mode) q.set("mode", params.mode);
  if (params.difficulty) q.set("difficulty", String(params.difficulty));
  if (params.shuffleSeed != null) q.set("shuffleSeed", String(params.shuffleSeed));
  if (params.cursor) q.set("cursor", params.cursor);
  q.set("limit", String(params.limit ?? 20));

  const res = await fetch(`${API_BASE}/api/v1/cards?${q.toString()}`, {
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`feed failed: ${res.status}`);
  return res.json();
}

export class CardFetchError extends Error {
  constructor(public status: number) { super(`card failed: ${status}`); }
}

export async function getCard(id: string): Promise<CardDetail> {
  const res = await fetch(`${API_BASE}/api/v1/cards/${id}`, {
    cache: "no-store",
  });
  if (!res.ok) throw new CardFetchError(res.status);
  return res.json();
}

// ── 면접 세션 ──

export type InterviewStatus = "ACTIVE" | "COMPLETED" | "ABANDONED";
export type TurnRole = "INTERVIEWER" | "CANDIDATE";

export interface InterviewTurn {
  id: string;
  role: TurnRole;
  content: string;
  turnOrder: number;
  createdAt: string;
}

export interface InterviewUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
}

export interface InterviewSummary {
  id: string;
  area: TopicArea;
  topic: string;
  difficulty: number;
  coach: string | null;
  status: InterviewStatus;
  turnCount: number;
  startedAt: string;
  endedAt: string | null;
}

export interface InterviewDetail {
  id: string;
  area: TopicArea;
  topic: string;
  difficulty: number;
  coach: string | null;
  status: InterviewStatus;
  cardId: string | null;
  turns: InterviewTurn[];
  feedbackMd: string | null;
  usage: InterviewUsage;
  startedAt: string;
  endedAt: string | null;
}

export const STATUS_LABELS: Record<InterviewStatus, string> = {
  ACTIVE: "진행 중",
  COMPLETED: "완료",
  ABANDONED: "중단",
};

/** 백엔드는 에러를 RFC 7807 ProblemDetail로 준다. detail 필드를 메시지로 승격. */
async function jsonOrThrow<T>(res: Response, fallback: string): Promise<T> {
  if (res.ok) return res.json();
  let detail = `${fallback} (${res.status})`;
  try {
    const body = await res.json();
    if (body?.detail) detail = body.detail;
  } catch {
    // ProblemDetail이 아니면 기본 메시지 유지
  }
  throw new Error(detail);
}

export async function listInterviews(limit = 20): Promise<InterviewSummary[]> {
  const res = await fetch(`${API_BASE}/api/v1/interviews?limit=${limit}`, {
    cache: "no-store",
  });
  return jsonOrThrow(res, "면접 목록을 불러오지 못했습니다");
}

export async function getInterview(id: string): Promise<InterviewDetail> {
  const res = await fetch(`${API_BASE}/api/v1/interviews/${id}`, {
    cache: "no-store",
  });
  return jsonOrThrow(res, "면접을 불러오지 못했습니다");
}

export async function startInterview(body: {
  area: TopicArea;
  topic: string;
  difficulty: number;
  cardId?: string;
}): Promise<InterviewDetail> {
  const res = await fetch(`${API_BASE}/api/v1/interviews`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return jsonOrThrow(res, "면접을 시작하지 못했습니다");
}

export async function sendAnswer(
  id: string,
  answer: string
): Promise<InterviewDetail> {
  const res = await fetch(`${API_BASE}/api/v1/interviews/${id}/answers`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ answer }),
  });
  return jsonOrThrow(res, "답변을 전송하지 못했습니다");
}

export async function finishInterview(id: string): Promise<InterviewDetail> {
  const res = await fetch(`${API_BASE}/api/v1/interviews/${id}/finish`, {
    method: "POST",
  });
  return jsonOrThrow(res, "피드백을 생성하지 못했습니다");
}
