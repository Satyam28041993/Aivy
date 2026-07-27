import { describe, expect, it } from "vitest";
import { parseWhatsAppWebhookBody } from "./parser";

describe("parseWhatsAppWebhookBody legacy payloads", () => {
  it("parses classic inbound messages webhook", () => {
    const body = {
      object: "whatsapp_business_account",
      entry: [
        {
          id: "WABA_LEGACY",
          changes: [
            {
              field: "messages",
              value: {
                messaging_product: "whatsapp",
                metadata: {
                  display_phone_number: "919876543210",
                  phone_number_id: "PHONE_LEGACY",
                },
                contacts: [
                  {
                    profile: { name: "Ravi" },
                    wa_id: "919811122233",
                  },
                ],
                messages: [
                  {
                    from: "919811122233",
                    id: "wamid.legacy.inbound.1",
                    timestamp: "1739230955",
                    type: "text",
                    text: { body: "Hello from user" },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.inboundMessages).toHaveLength(1);
    expect(parsed.inboundMessages[0]).toMatchObject({
      messageId: "wamid.legacy.inbound.1",
      from: "919811122233",
      conversationId: "919811122233",
      type: "text",
      textBody: "Hello from user",
      profileName: "Ravi",
    });
    expect(parsed.statusEvents).toHaveLength(0);
    expect(parsed.historyEvents).toHaveLength(0);
    expect(parsed.smbAppStateSyncEvents).toHaveLength(0);
    expect(parsed.messageEchoEvents).toHaveLength(0);
  });

  it("parses classic delivery status webhook", () => {
    const body = {
      entry: [
        {
          changes: [
            {
              field: "messages",
              value: {
                statuses: [
                  {
                    id: "wamid.legacy.status.1",
                    status: "delivered",
                    timestamp: "1739230999",
                    recipient_id: "919811122233",
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.statusEvents).toHaveLength(1);
    expect(parsed.statusEvents[0]).toMatchObject({
      messageId: "wamid.legacy.status.1",
      status: "delivered",
      recipient: "919811122233",
    });
    expect(parsed.inboundMessages).toHaveLength(0);
  });
});

describe("parseWhatsAppWebhookBody history", () => {
  it("parses approved history chunk with threads and messages", () => {
    const body = {
      object: "whatsapp_business_account",
      entry: [
        {
          id: "102290129340398",
          changes: [
            {
              field: "history",
              value: {
                messaging_product: "whatsapp",
                metadata: {
                  display_phone_number: "15550783881",
                  phone_number_id: "106540352242922",
                },
                history: [
                  {
                    metadata: {
                      phase: 0,
                      chunk_order: 1,
                      progress: 55,
                    },
                    threads: [
                      {
                        id: "16505551234",
                        messages: [
                          {
                            from: "15550783881",
                            id: "wamid.history.1",
                            timestamp: "1739230955",
                            type: "text",
                            text: { body: "Prior business message" },
                            history_context: { status: "READ" },
                          },
                          {
                            from: "16505551234",
                            id: "wamid.history.2",
                            timestamp: "1739230970",
                            type: "text",
                            text: { body: "Thanks!" },
                            history_context: { status: "READ" },
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.historyEvents).toHaveLength(1);
    const history = parsed.historyEvents[0];
    expect(history).toMatchObject({
      wabaId: "102290129340398",
      phoneNumberId: "106540352242922",
      displayPhoneNumber: "15550783881",
      field: "history",
    });
    expect(history.chunks).toHaveLength(1);
    expect(history.chunks[0]).toMatchObject({
      phase: 0,
      chunkOrder: 1,
      progress: 55,
    });
    expect(history.chunks[0].threads[0].threadId).toBe("16505551234");
    expect(history.chunks[0].threads[0].messages).toHaveLength(2);
    expect(history.chunks[0].threads[0].messages[0]).toMatchObject({
      messageId: "wamid.history.1",
      threadId: "16505551234",
      historyStatus: "READ",
      textBody: "Prior business message",
    });
    expect(parsed.inboundMessages).toHaveLength(0);
  });

  it("parses declined history sharing error chunk", () => {
    const body = {
      entry: [
        {
          id: "102290129340398",
          changes: [
            {
              field: "history",
              value: {
                metadata: {
                  display_phone_number: "15550783881",
                  phone_number_id: "106540352242922",
                },
                history: [
                  {
                    errors: [
                      {
                        code: 2593109,
                        title: "History sync is turned off",
                        message: "History sync is turned off",
                        error_data: {
                          details: "History sharing is turned off by the business",
                        },
                      },
                    ],
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.historyEvents).toHaveLength(1);
    expect(parsed.historyEvents[0].chunks[0].errors).toHaveLength(1);
    expect(parsed.historyEvents[0].chunks[0].errors[0]).toMatchObject({
      code: 2593109,
      details: "History sharing is turned off by the business",
    });
    expect(parsed.historyEvents[0].chunks[0].threads).toHaveLength(0);
  });

  it("parses history media supplemental messages without duplicating inbound messages", () => {
    const body = {
      entry: [
        {
          id: "102290129340398",
          changes: [
            {
              field: "history",
              value: {
                metadata: {
                  phone_number_id: "106540352242922",
                },
                messages: [
                  {
                    from: "16505551234",
                    id: "wamid.history.media.1",
                    timestamp: "1738796547",
                    type: "image",
                    image: {
                      caption: "Black Prince echeveria",
                      mime_type: "image/jpeg",
                      sha256: "abc123",
                      id: "24230790383178626",
                    },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.inboundMessages).toHaveLength(0);
    expect(parsed.historyEvents).toHaveLength(1);
    expect(parsed.historyEvents[0].supplementalMessages).toHaveLength(1);
    expect(parsed.historyEvents[0].supplementalMessages[0]).toMatchObject({
      messageId: "wamid.history.media.1",
      type: "image",
      textBody: null,
      media: {
        id: "24230790383178626",
        caption: "Black Prince echeveria",
      },
    });
  });
});

describe("parseWhatsAppWebhookBody smb_app_state_sync", () => {
  it("parses contact add sync event", () => {
    const body = {
      entry: [
        {
          id: "102290129340398",
          changes: [
            {
              field: "smb_app_state_sync",
              value: {
                metadata: {
                  display_phone_number: "15550783881",
                  phone_number_id: "106540352242922",
                },
                state_sync: [
                  {
                    type: "contact",
                    contact: {
                      full_name: "Pablo Morales",
                      first_name: "Pablo",
                      phone_number: "16505551234",
                    },
                    action: "add",
                    metadata: { timestamp: "1739321024" },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.smbAppStateSyncEvents).toHaveLength(1);
    expect(parsed.smbAppStateSyncEvents[0]).toMatchObject({
      wabaId: "102290129340398",
      field: "smb_app_state_sync",
    });
    expect(parsed.smbAppStateSyncEvents[0].contacts[0]).toMatchObject({
      action: "add",
      phoneNumber: "16505551234",
      fullName: "Pablo Morales",
      firstName: "Pablo",
      timestampSec: 1739321024,
    });
  });

  it("parses contact remove sync event", () => {
    const body = {
      entry: [
        {
          changes: [
            {
              field: "smb_app_state_sync",
              value: {
                state_sync: [
                  {
                    type: "contact",
                    contact: {
                      phone_number: "16505559999",
                    },
                    action: "remove",
                    metadata: { timestamp: "1739321099" },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.smbAppStateSyncEvents[0].contacts[0]).toMatchObject({
      action: "remove",
      phoneNumber: "16505559999",
      fullName: null,
      firstName: null,
    });
  });
});

describe("parseWhatsAppWebhookBody smb_message_echoes", () => {
  it("parses business app outbound echo message", () => {
    const body = {
      entry: [
        {
          id: "102290129340398",
          changes: [
            {
              field: "smb_message_echoes",
              value: {
                metadata: {
                  display_phone_number: "15550783881",
                  phone_number_id: "106540352242922",
                },
                message_echoes: [
                  {
                    from: "15550783881",
                    to: "16505551234",
                    id: "wamid.echo.1",
                    timestamp: "1700255121",
                    type: "text",
                    text: {
                      body: "Sent from WhatsApp Business app",
                    },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.messageEchoEvents).toHaveLength(1);
    expect(parsed.messageEchoEvents[0]).toMatchObject({
      wabaId: "102290129340398",
      field: "smb_message_echoes",
    });
    expect(parsed.messageEchoEvents[0].echoes[0]).toMatchObject({
      messageId: "wamid.echo.1",
      from: "15550783881",
      to: "16505551234",
      conversationId: "16505551234",
      type: "text",
      textBody: "Sent from WhatsApp Business app",
    });
    expect(parsed.inboundMessages).toHaveLength(0);
  });
});

describe("parseWhatsAppWebhookBody mixed migration payload", () => {
  it("parses legacy and coexistence sections in one webhook body", () => {
    const body = {
      entry: [
        {
          id: "WABA_MIXED",
          changes: [
            {
              field: "messages",
              value: {
                contacts: [{ profile: { name: "A" }, wa_id: "919900000001" }],
                messages: [
                  {
                    from: "919900000001",
                    id: "wamid.live.1",
                    timestamp: "1739230955",
                    type: "text",
                    text: { body: "Live inbound" },
                  },
                ],
                statuses: [
                  {
                    id: "wamid.live.status",
                    status: "read",
                    timestamp: "1739230960",
                    recipient_id: "919900000001",
                  },
                ],
              },
            },
            {
              field: "smb_message_echoes",
              value: {
                message_echoes: [
                  {
                    from: "15550783881",
                    to: "919900000001",
                    id: "wamid.echo.mixed",
                    timestamp: "1700255121",
                    type: "text",
                    text: { body: "Echo" },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    const parsed = parseWhatsAppWebhookBody(body);
    expect(parsed.inboundMessages).toHaveLength(1);
    expect(parsed.statusEvents).toHaveLength(1);
    expect(parsed.messageEchoEvents).toHaveLength(1);
    expect(parsed.historyEvents).toHaveLength(0);
    expect(parsed.smbAppStateSyncEvents).toHaveLength(0);
  });
});
