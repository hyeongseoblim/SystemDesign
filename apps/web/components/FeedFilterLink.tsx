"use client";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import type { ComponentProps } from "react";

/** 카테고리·모드·난이도를 바꿔도 검색어와 학습 상태는 유지한다. */
export default function FeedFilterLink({ href, ...props }: Omit<ComponentProps<typeof Link>, "href"> & { href: string }) {
  const current = useSearchParams();
  const params = new URLSearchParams(href.split("?")[1]);
  for (const key of ["q", "study", "random"]) {
    const value = current.get(key);
    if (value) params.set(key, value);
  }
  return <Link {...props} href={params.size ? `/?${params}` : "/"} />;
}
