import type { CardSummary } from "./api";

export type Mastery = "review" | "hint" | "confident";
export type StudyFilter = "all" | "new" | "reading" | "complete" | "review";
export interface StudyRecord { read?: string; done?: string; mastery?: Mastery }
export const masteryKey = (id: string) => `jobStudy::mastery::${id}`;
export const STUDY_LABELS: Record<StudyFilter, string> = {
  all: "전체", new: "미학습", reading: "학습 중", complete: "완료", review: "복습 필요",
};
export const MASTERY_LABELS: Record<Mastery, string> = {
  review: "다시 공부할래요", hint: "힌트가 있으면 설명 가능", confident: "혼자 설명 가능",
};
export function readStorage(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
export function writeStorage(key: string, value: string | null): boolean {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
    window.dispatchEvent(new Event("study-change"));
    return true;
  } catch { return false; }
}
export function readStudy(id: string): StudyRecord {
  const mastery = readStorage(masteryKey(id));
  return {
    read: readStorage(`jobStudy::read::${id}`) ?? undefined,
    done: readStorage(`jobStudy::done::${id}`) ?? undefined,
    mastery: mastery === "review" || mastery === "hint" || mastery === "confident" ? mastery : undefined,
  };
}
export function needsReview(record: StudyRecord): boolean {
  return record.mastery === "review" || record.mastery === "hint";
}
export function matchesStudy(record: StudyRecord, filter: StudyFilter): boolean {
  if (filter === "review") return needsReview(record);
  if (filter === "complete") return !!record.done;
  if (filter === "reading") return !!record.read && !record.done;
  if (filter === "new") return !record.read && !record.done && !record.mastery;
  return true;
}
export function matchesSearch(card: CardSummary, query: string): boolean {
  const haystack = [card.title, card.summary ?? "", ...card.tags].join(" ").normalize("NFKC").toLocaleLowerCase();
  return query.normalize("NFKC").trim().toLocaleLowerCase().split(/\s+/).every((term) => haystack.includes(term));
}
/** 같은 시드와 카드 ID는 목록 재진입 시에도 같은 순서를 만든다. */
export function shuffleRank(id: string, seed: number): number {
  let hash = seed | 0;
  for (const ch of id) hash = Math.imul(hash ^ ch.charCodeAt(0), 16777619);
  return hash >>> 0;
}
