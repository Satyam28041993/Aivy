import { describe, expect, it } from "vitest";
import { parseWhatsAppWebhookBody } from "../parser";
import { detectCoexistenceParseWarnings } from "../coexistence/parseWarnings";
import { processCoexistenceWebhookEvents } from "../coexistence/processor";
import type { CoexistenceStore, CoexistenceUpsertResult } from "../coexistence/types";

class InMemoryCoexistenceStore implements CoexistenceStore {
  history = new Map<string, Record<string, unknown>>();
  smbSync = new Map<string, Record<string, unknown>>();
  echoes = new Map<string, Record<string, unknown>>();
  diagnostics: Record<string, unknown> = {};

  private upsert(
    map: Map<string, Record<string, unknown>>,
    eventType: CoexistenceUpsertResult["eventType"],
    recordId: string,
    payload: Record<string, unknown>,
  ): CoexistenceUpsertResult {
    const nowMs = Date.now();
    if (map.has(recordId)) {
      const existing = map.get(recordId)!;
      map.set(recordId, {
        ...existing,
        lastSeenAtMs: nowMs,
        deliveryCount: Number(existing.deliveryCount ?? 1) + 1,
        processingStatus: "duplicate_ignored",
      });
      return { recordId, eventType, created: false, duplicate: true };
    }
    map.set(recordId, {
      ...payload,
      id: recordId,
      idempotencyKey: recordId,
      eventType,
      createdAtMs: nowMs,
      lastSeenAtMs: nowMs,
      deliveryCount: 1,
      processingStatus: "stored",
    });
    return { recordId, eventType, created: true, duplicate: false };
  }

  upsertHistoryRecord(recordId, payload) {
    return Promise.resolve(
      this.upsert(this.history, "history", recordId, payload),
    );
  }

  upsertSmbSyncRecord(recordId, payload) {
    return Promise.resolve(
      this.upsert(this.smbSync, "smb_app_state_sync", recordId, payload),
    );
  }

  upsertEchoRecord(recordId, payload) {
    return Promise.resolve(
      this.upsert(this.echoes, "smb_message_echoes", recordId, payload),
    );
  }

  updateDiagnostics(patch) {
    this.diagnostics = { ...this.diagnostics, ...patch };
    return Promise.resolve();
  }
}

const echoPayload = {
  entry: [
    {
      id: "WABA_TEST",
      changes: [
        {
          field: "smb_message_echoes",
          value: {
            metadata: { phone_number_id: "PHONE_1" },
            message_echoes: [
              {
                from: "15550783881",
                to: "16505551234",
                id: "wamid.echo.integration.1",
                timestamp: "1700255121",
                type: "text",
                text: { body: "Echo integration" },
              },
            ],
          },
        },
      ],
    },
  ],
};

describe("processCoexistenceWebhookEvents integration", () => {
  it("stores coexistence records separately without touching legacy collections", async () => {
    const store = new InMemoryCoexistenceStore();
    const parsed = parseWhatsAppWebhookBody(echoPayload);
    const summary = await processCoexistenceWebhookEvents(
      { parsed, rawBody: echoPayload, parseErrors: [] },
      store,
    );

    expect(summary.echoRecordsCreated).toBe(1);
    expect(summary.echoDuplicatesSkipped).toBe(0);
    expect(store.echoes.size).toBe(1);
    expect(store.history.size).toBe(0);
    expect(store.smbSync.size).toBe(0);
    expect(store.diagnostics.lastMessageEcho).toBeTruthy();
  });

  it("ignores duplicate deliveries (idempotent)", async () => {
    const store = new InMemoryCoexistenceStore();
    const parsed = parseWhatsAppWebhookBody(echoPayload);

    const first = await processCoexistenceWebhookEvents(
      { parsed, rawBody: echoPayload, parseErrors: [] },
      store,
    );
    const second = await processCoexistenceWebhookEvents(
      { parsed, rawBody: echoPayload, parseErrors: [] },
      store,
    );

    expect(first.echoRecordsCreated).toBe(1);
    expect(second.echoRecordsCreated).toBe(0);
    expect(second.echoDuplicatesSkipped).toBe(1);
    expect(store.echoes.size).toBe(1);
    expect(store.echoes.values().next().value?.deliveryCount).toBe(2);
  });

  it("handles out-of-order deliveries as distinct records", async () => {
    const store = new InMemoryCoexistenceStore();
    const payloadA = {
      entry: [
        {
          id: "WABA_TEST",
          changes: [
            {
              field: "history",
              value: {
                metadata: { phone_number_id: "PHONE_1" },
                history: [
                  {
                    metadata: { phase: 0, chunk_order: 2, progress: 40 },
                    threads: [],
                  },
                ],
              },
            },
          ],
        },
      ],
    };
    const payloadB = {
      entry: [
        {
          id: "WABA_TEST",
          changes: [
            {
              field: "history",
              value: {
                metadata: { phone_number_id: "PHONE_1" },
                history: [
                  {
                    metadata: { phase: 0, chunk_order: 1, progress: 20 },
                    threads: [],
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    await processCoexistenceWebhookEvents(
      {
        parsed: parseWhatsAppWebhookBody(payloadA),
        rawBody: payloadA,
        parseErrors: [],
      },
      store,
    );
    await processCoexistenceWebhookEvents(
      {
        parsed: parseWhatsAppWebhookBody(payloadB),
        rawBody: payloadB,
        parseErrors: [],
      },
      store,
    );

    expect(store.history.size).toBe(2);
  });

  it("returns skipped_empty for empty payloads", async () => {
    const store = new InMemoryCoexistenceStore();
    const parsed = parseWhatsAppWebhookBody({});
    const summary = await processCoexistenceWebhookEvents(
      { parsed, rawBody: {}, parseErrors: [] },
      store,
    );

    expect(summary.processingStatus).toBe("skipped_empty");
    expect(store.history.size).toBe(0);
    expect(store.smbSync.size).toBe(0);
    expect(store.echoes.size).toBe(0);
  });

  it("records parse warnings for malformed coexistence payloads", async () => {
    const store = new InMemoryCoexistenceStore();
    const malformed = {
      entry: [
        {
          changes: [
            {
              field: "smb_message_echoes",
              value: {
                message_echoes: [{ id: "", from: "", to: "" }],
              },
            },
          ],
        },
      ],
    };
    const parsed = parseWhatsAppWebhookBody(malformed);
    const warnings = detectCoexistenceParseWarnings(malformed, parsed);
    const summary = await processCoexistenceWebhookEvents(
      { parsed, rawBody: malformed, parseErrors: warnings },
      store,
    );

    expect(warnings.length).toBeGreaterThan(0);
    expect(summary.processingStatus).toBe("parse_error");
    expect(summary.parseErrors.length).toBeGreaterThan(0);
    expect(store.diagnostics.lastParseErrors).toBeTruthy();
  });

  it("is retry-safe when the same payload is processed multiple times", async () => {
    const store = new InMemoryCoexistenceStore();
    const parsed = parseWhatsAppWebhookBody(echoPayload);

    for (let i = 0; i < 3; i++) {
      await processCoexistenceWebhookEvents(
        { parsed, rawBody: echoPayload, parseErrors: [] },
        store,
      );
    }

    expect(store.echoes.size).toBe(1);
    expect(store.echoes.values().next().value?.deliveryCount).toBe(3);
  });
});
