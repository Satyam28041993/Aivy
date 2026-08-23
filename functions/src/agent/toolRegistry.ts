/**
 * The tools the agent can reach for, and how a call is dispatched.
 *
 * Declarations are deliberately written as instructions to the model, not as
 * dry field docs — the difference between "when_phrase: a date" and "the words
 * the user actually said, do not convert them" is most of what keeps the model
 * from inventing dates.
 */

import {
  cancelDraftTool,
  createMeetingTool,
  createReminderTool,
  recordOrderTool,
  recordPaymentDueTool,
  recordPaymentReceivedTool,
  recordQuotationTool,
  rememberFactTool,
} from "./tools/writeTools";
import {
  findRecordsTool,
  getAgendaTool,
  getClientSummaryTool,
  getImportantTool,
  getPendingPaymentsTool,
  searchClientsTool,
  webSearchTool,
} from "./tools/readTools";
import { fail, type ToolContext, type ToolResult } from "./toolTypes";

/** Minimal JSON-schema subset Gemini accepts for a function declaration. */
export interface ToolSchema {
  type: "object";
  properties: Record<string, unknown>;
  required?: string[];
}

export interface ToolDeclaration {
  name: string;
  description: string;
  parameters: ToolSchema;
}

type ToolHandler = (ctx: ToolContext, args: Record<string, unknown>) => Promise<ToolResult>;

const WHEN_PHRASE = {
  type: "string",
  description:
    "The date/time words exactly as the user said them, e.g. 'kal 11 baje', " +
    "'agle somvar', '15 tarikh', '2 din baad'. Do NOT convert to a date — the " +
    "server resolves it.",
};

const WHEN_TENSE = {
  type: "string",
  enum: ["future", "past"],
  description:
    "Whether the sentence points forward or back. Hindi 'kal' and 'parso' mean " +
    "both directions, so read it from the grammar: 'kal meeting hai' is future, " +
    "'kal payment aaya tha' is past. Defaults to future.",
};

const DAY_PERIOD = {
  type: "string",
  enum: ["morning", "afternoon", "evening", "night"],
  description:
    "Part of the day when the sentence implies one but gives no am/pm — from " +
    "words like subah/shaam/raat, or from context (an 11 baje business meeting " +
    "is morning). Omit if genuinely unclear.",
};

const CLIENT_NAME = {
  type: "string",
  description:
    "The client name as the user said it. Pass the raw words — the server " +
    "matches it and will ask you to disambiguate if several clients match.",
};

const WINDOW = {
  type: "string",
  enum: [
    "today",
    "tomorrow",
    "yesterday",
    "this_week",
    "last_week",
    "next_week",
    "this_month",
    "last_month",
    "overdue",
    "all",
  ],
  description: "Time window to look at.",
};

export const TOOL_DECLARATIONS: ToolDeclaration[] = [
  // ---- write ----
  {
    name: "create_meeting",
    description:
      "Record a meeting the user has, and set a reminder for it automatically. " +
      "Use when they mention meeting/milna/mulakat with a time. Creates a draft " +
      "for confirmation — nothing is saved yet.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        when_phrase: WHEN_PHRASE,
        when_tense: WHEN_TENSE,
        day_period: DAY_PERIOD,
        agenda: {
          type: "string",
          description:
            "What the meeting is about — the 'kis baare me' part, e.g. 'new labels'.",
        },
        note: { type: "string", description: "Anything extra worth keeping." },
        reminder_lead_minutes: {
          type: "number",
          description: "Minutes before the meeting to be reminded. Default 15.",
        },
      },
      required: ["when_phrase"],
    },
  },
  {
    name: "create_reminder",
    description:
      "Set a reminder, call reminder, follow-up or task. Use for 'yaad dila dena', " +
      "'call karna hai', 'follow up karna hai'. Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "What to be reminded about, in the user's own words.",
        },
        when_phrase: WHEN_PHRASE,
        when_tense: WHEN_TENSE,
        day_period: DAY_PERIOD,
        client_name: CLIENT_NAME,
        reminder_type: {
          type: "string",
          enum: ["call", "followup", "task", "meeting", "personal"],
          description: "Kind of reminder. 'personal' for non-business things.",
        },
        priority: { type: "string", enum: ["high", "medium", "low"] },
        note: { type: "string" },
      },
      required: ["title", "when_phrase"],
    },
  },
  {
    name: "record_quotation",
    description:
      "Record a quotation the user gave a client ('quotation diya', 'quote bheja'). " +
      "Also sets a follow-up reminder. Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        amount: { type: "number", description: "Quotation amount in rupees." },
        followup_phrase: {
          type: "string",
          description: "When to follow up, in the user's words. Defaults to 7 days.",
        },
        note: { type: "string" },
      },
      required: ["client_name", "amount"],
    },
  },
  {
    name: "record_order",
    description:
      "Record a new order received from a client ('order aaya', 'order mila'). " +
      "Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        amount: { type: "number", description: "Order value in rupees." },
        note: { type: "string" },
      },
      required: ["client_name", "amount"],
    },
  },
  {
    name: "record_payment_due",
    description:
      "Record money a client owes ('X se itna lena hai', 'due banaya'). " +
      "Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        amount: { type: "number" },
        due_phrase: {
          type: "string",
          description: "When it is due, in the user's words. Defaults to 30 days.",
        },
        note: { type: "string" },
      },
      required: ["client_name", "amount"],
    },
  },
  {
    name: "record_payment_received",
    description:
      "Record money received from a client ('payment aaya', 'paise mil gaye'). " +
      "Settles it against their open dues. Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        amount: { type: "number" },
        when_phrase: {
          type: "string",
          description: "When it came in, in the user's words. Defaults to today.",
        },
        when_tense: WHEN_TENSE,
        note: { type: "string" },
      },
      required: ["client_name", "amount"],
    },
  },
  {
    name: "remember_fact",
    description:
      "Remember something about the user for future conversations — a preference, " +
      "a habit, a personal detail they shared. Use this when they tell you " +
      "something worth carrying forward, not for every passing remark.",
    parameters: {
      type: "object",
      properties: {
        category: {
          type: "string",
          description: "Short label, e.g. 'preference', 'family', 'business'.",
        },
        fact: { type: "string", description: "The thing to remember, in one line." },
      },
      required: ["fact"],
    },
  },
  {
    name: "cancel_draft",
    description:
      "Drop a pending draft when the user changes their mind ('rehne do', 'nahi').",
    parameters: {
      type: "object",
      properties: {
        draft_id: { type: "string", description: "Omit to cancel the latest one." },
      },
    },
  },

  // ---- read ----
  {
    name: "get_agenda",
    description:
      "What is scheduled — calls, meetings, follow-ups, tasks — for a time window. " +
      "Use for 'aaj kisko call karna hai', 'kal kya hai', 'is week kya hai'.",
    parameters: {
      type: "object",
      properties: {
        window: WINDOW,
        only: {
          type: "string",
          enum: ["calls", "meetings", "followups"],
          description: "Narrow to one kind. Omit for everything.",
        },
      },
    },
  },
  {
    name: "get_important",
    description:
      "Everything that needs attention right now: overdue tasks, today's work, " +
      "overdue payments and risky clients. Use for open-ended questions like " +
      "'koi important cheez hai kya' or 'kya chal raha hai'.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "find_records",
    description:
      "Look up past records — quotations, orders, payments, reminders, meetings. " +
      "Use when the user asks what they did: 'kisko quotation diya', " +
      "'is mahine kitne order aaye'.",
    parameters: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: ["quotation", "order", "payment", "reminder", "meeting"],
        },
        client_name: CLIENT_NAME,
        window: WINDOW,
      },
      required: ["type"],
    },
  },
  {
    name: "get_pending_payments",
    description:
      "Outstanding dues — everything owed, or one client's. Use for 'kitna pending hai', " +
      "'overdue kya hai', 'X se kitna lena hai'.",
    parameters: {
      type: "object",
      properties: {
        client_name: CLIENT_NAME,
        only_overdue: { type: "boolean" },
      },
    },
  },
  {
    name: "get_client_summary",
    description:
      "One client's full picture: quotations, orders, dues and what is scheduled " +
      "with them. Use for 'X ka kya scene hai'.",
    parameters: {
      type: "object",
      properties: { client_name: CLIENT_NAME },
      required: ["client_name"],
    },
  },
  {
    name: "search_clients",
    description: "Find clients by name when you need to check who exists.",
    parameters: {
      type: "object",
      properties: { query: { type: "string" } },
    },
  },
  {
    name: "web_search",
    description:
      "Search the web for general knowledge, news, prices, how-to questions — " +
      "anything outside the user's own business data. Use it whenever a factual " +
      "answer would benefit from current information rather than guessing.",
    parameters: {
      type: "object",
      properties: { query: { type: "string" } },
      required: ["query"],
    },
  },
];

const HANDLERS: Record<string, ToolHandler> = {
  create_meeting: createMeetingTool,
  create_reminder: createReminderTool,
  record_quotation: recordQuotationTool,
  record_order: recordOrderTool,
  record_payment_due: recordPaymentDueTool,
  record_payment_received: recordPaymentReceivedTool,
  remember_fact: rememberFactTool,
  cancel_draft: cancelDraftTool,
  get_agenda: getAgendaTool,
  get_important: (ctx) => getImportantTool(ctx),
  find_records: findRecordsTool,
  get_pending_payments: getPendingPaymentsTool,
  get_client_summary: getClientSummaryTool,
  search_clients: searchClientsTool,
  web_search: webSearchTool,
};

/** Tools that create a draft, so the loop knows to surface a card. */
export const WRITE_TOOLS: ReadonlySet<string> = new Set([
  "create_meeting",
  "create_reminder",
  "record_quotation",
  "record_order",
  "record_payment_due",
  "record_payment_received",
  "remember_fact",
]);

export function isKnownTool(name: string): boolean {
  return Object.prototype.hasOwnProperty.call(HANDLERS, name);
}

/**
 * Runs one tool call. A thrown error becomes a failure result rather than
 * killing the turn — the model can tell the user something went wrong and carry
 * on talking.
 */
export async function dispatchTool(
  name: string,
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const handler = HANDLERS[name];
  if (!handler) {
    return fail("invalid", `Unknown tool: ${name}`);
  }
  try {
    return await handler(ctx, args ?? {});
  } catch (e) {
    return fail(
      "failed",
      e instanceof Error ? e.message : "Tool chalane me dikkat aayi.",
    );
  }
}
