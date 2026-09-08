export function sectionId(title: string): string {
  return `section-${title.trim().replace(/[*`]/g, "").replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "")}`;
}
export function headings(md: string): { title: string; id: string }[] {
  let fence = false;
  return md.split("\n").flatMap((line) => {
    if (/^\s*(```|~~~)/.test(line)) { fence = !fence; return []; }
    if (fence || !/^## /.test(line) || /이해도 확인/.test(line)) return [];
    const title = line.slice(3).replace(/[*`]/g, "").trim();
    return [{ title, id: sectionId(title) }];
  });
}
