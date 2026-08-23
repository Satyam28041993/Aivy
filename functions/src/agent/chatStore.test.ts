import { describe, expect, it } from "vitest";

import { titleFromText } from "./chatStore";

describe("titleFromText", () => {
  it("uses a short first line as-is", () => {
    expect(titleFromText("kal 11 baje meeting")).toBe("kal 11 baje meeting");
  });

  it("collapses whitespace", () => {
    expect(titleFromText("  kal   11  baje ")).toBe("kal 11 baje");
  });

  it("truncates a long line with an ellipsis", () => {
    const long = "rohan ko pachas hazaar ka quotation diya aur kal meeting bhi hai uske saath";
    const title = titleFromText(long);
    expect(title.length).toBe(40);
    expect(title.endsWith("…")).toBe(true);
  });

  it("falls back for empty input", () => {
    expect(titleFromText("")).toBe("Nayi baat");
    expect(titleFromText("   ")).toBe("Nayi baat");
  });
});
