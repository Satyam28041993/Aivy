/**
 * What Aivy says out loud, and what she heard — the parts that are pure text
 * and would go wrong quietly.
 */

import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/params", () => ({ defineSecret: () => ({ value: () => "" }) }));
vi.mock("firebase-admin/firestore", () => ({ getFirestore: vi.fn() }));
vi.mock("google-auth-library", () => ({ GoogleAuth: class { getAccessToken = async () => "t"; } }));

const { speakableText, voiceFor, cleanTranscript, pcmToWav, MAX_SPOKEN_CHARS } = await import("./aivyVoice");

describe("speaking", () => {
  it("reads bold as plain words, says rupees, and does not spell out links", () => {
    const t = speakableText("**Travel saved** — 42.4 km = ₹169.6.\nhttps://docs.google.com/spreadsheets/d/abc");
    expect(t).toContain("Travel saved");
    expect(t).not.toContain("**");
    expect(t).toContain("169.6 rupees");
    expect(t).not.toContain("docs.google");
    expect(t).toContain("link on screen");
  });

  it("drops emoji and list bullets", () => {
    expect(speakableText("🗑️ Deleted\n- one\n- two")).toBe("Deleted. one. two");
  });

  it("cuts a long reply at a sentence and points at the screen", () => {
    const long = "This is a sentence. ".repeat(200);
    const t = speakableText(long);
    expect(t.length).toBeLessThan(MAX_SPOKEN_CHARS + 40);
    expect(t.endsWith("The rest is on screen.")).toBe(true);
  });

  it("uses an Indian English voice, Hindi only for Devanagari", () => {
    expect(voiceFor("Here's the visit for Bajaj").languageCode).toBe("en-IN");
    expect(voiceFor("नमस्ते").languageCode).toBe("hi-IN");
  });
});

describe("hearing", () => {
  it("keeps one clean line", () => {
    expect(cleanTranscript('  "visit record karo\n Bajaj Auto"  ')).toBe("visit record karo Bajaj Auto");
  });

  it("wraps Gemini's raw PCM in a playable WAV header", () => {
    const wav = pcmToWav(Buffer.alloc(48000), 24000);
    expect(wav.subarray(0, 4).toString()).toBe("RIFF");
    expect(wav.readUInt32LE(24)).toBe(24000);
    expect(wav.length).toBe(48044);
  });
});
