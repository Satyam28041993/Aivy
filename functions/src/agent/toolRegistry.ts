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
import {
  appendSheetRowTool,
  createCalendarEventTool,
  findContactTool,
  listCalendarEventsTool,
  listRecentEmailsTool,
  sendEmailTool,
} from "./tools/googleTools";
import {
  findPlacesTool,
  forgetPlaceTool,
  getDirectionsTool,
  getSavedPlaceTool,
  listSavedPlacesTool,
  savePlaceTool,
  whereAmITool,
} from "./tools/mapsTools";
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
        duration_minutes: {
          type: "number",
          description: "How long the meeting runs. Default 60.",
        },
        add_to_calendar: {
          type: "boolean",
          description:
            "Also put it on their Google Calendar. Default true — pass false only " +
            "if they say they don't want it on the calendar.",
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
      "Remember things about the user for future conversations — family, dates, " +
      "work, preferences, how they like things done. When they give you several " +
      "details at once, pass them all in `facts` in a single call.",
    parameters: {
      type: "object",
      properties: {
        facts: {
          type: "array",
          description:
            "Everything to remember from this message. Preferred over `fact`.",
          items: {
            type: "object",
            properties: {
              key: {
                type: "string",
                description:
                  "The subject, as a short stable label: 'wife', 'daughter', " +
                  "'son', 'mother', 'father', 'anniversary', 'city', 'employer', " +
                  "'job_title'. One subject per fact — a key is overwritten when " +
                  "it is used again, so never file two different people under one.",
              },
              value: {
                type: "string",
                description:
                  "What to remember about that subject, in one line, including " +
                  "any date: 'Ruchi Singh, born 19 Oct 1995'.",
              },
            },
            required: ["key", "value"],
          },
        },
        category: {
          type: "string",
          description: "Subject key for a single fact. Same rules as facts[].key.",
        },
        fact: { type: "string", description: "A single thing to remember, in one line." },
      },
      required: [],
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

  {
    name: "create_calendar_event",
    description:
      "Put something on the user's Google Calendar that is not a client meeting — " +
      "a personal appointment, a reminder to block time, a travel slot. For a " +
      "client meeting use create_meeting instead, which does both. Creates a " +
      "draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        summary: { type: "string", description: "Event title." },
        when_phrase: WHEN_PHRASE,
        when_tense: WHEN_TENSE,
        day_period: DAY_PERIOD,
        duration_minutes: { type: "number", description: "Default 60." },
        description: { type: "string" },
        attendee_emails: {
          type: "array",
          items: { type: "string" },
          description: "Email addresses to invite. Only real addresses.",
        },
      },
      required: ["summary", "when_phrase"],
    },
  },
  {
    name: "send_email",
    description:
      "Send an email from the user's Gmail. Write the mail yourself in their " +
      "voice from what they told you — they will read it on the card before it " +
      "goes. Creates a draft for confirmation; nothing is sent until they " +
      "confirm.",
    parameters: {
      type: "object",
      properties: {
        to: {
          type: "string",
          description:
            "Email address, or just the person's name — if it is a name the " +
            "server looks it up in their contacts.",
        },
        subject: { type: "string" },
        body: {
          type: "string",
          description:
            "The full mail body, ready to send. Write it properly — greeting, " +
            "the message, sign-off — in the language the user would use.",
        },
      },
      required: ["to", "body"],
    },
  },
  {
    name: "append_sheet_row",
    description:
      "Add a row to the user's Google Sheet — for keeping a log or a tracker. " +
      "Uses their default sheet unless a spreadsheet id is given. Creates a " +
      "draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        cells: {
          type: "array",
          items: { type: "string" },
          description: "The row, left to right.",
        },
        sheet_tab: { type: "string", description: "Tab name. Default Sheet1." },
        spreadsheet_id: {
          type: "string",
          description: "Only when the user names a specific sheet.",
        },
      },
      required: ["cells"],
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
      "Use when the user asks what they did: 'who did I quote', 'how many orders " +
      "this month', 'how many orders are pending'. The result carries a per-status " +
      "breakdown, so counting questions are answered from it rather than guessed.",
    parameters: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: ["quotation", "order", "payment", "reminder", "meeting"],
        },
        client_name: CLIENT_NAME,
        window: WINDOW,
        status: {
          type: "string",
          description:
            "Narrow to one status, e.g. 'pending' or 'dispatched' for orders. " +
            "Omit to get every status with counts.",
        },
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
    name: "list_calendar_events",
    description:
      "What is on the user's Google Calendar in a time window. Use for " +
      "'calendar me kya hai', 'kal calendar par kya hai'. This is their Google " +
      "Calendar, separate from the reminders in this app — for those use get_agenda.",
    parameters: {
      type: "object",
      properties: { window: WINDOW },
    },
  },
  {
    name: "list_recent_emails",
    description:
      "Recent inbox mail — sender, subject, a snippet. Use for 'koi mail aaya kya', " +
      "'inbox me kya hai', or to find a specific mail with a query.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "number", description: "How many. Default 8, max 15." },
        query: {
          type: "string",
          description: "Gmail search query, e.g. 'from:rohan' or 'invoice'. Optional.",
        },
      },
    },
  },
  {
    name: "find_contact",
    description:
      "Look up someone's email or phone in the user's Google Contacts. Use when " +
      "you need an address before writing a mail, or when they ask for someone's " +
      "number.",
    parameters: {
      type: "object",
      properties: { query: { type: "string", description: "Name to search for." } },
      required: ["query"],
    },
  },
  {
    name: "find_places",
    description:
      "Find a real place on Google Maps — a shop, a supplier, an office, a " +
      "restaurant — with its address, phone, rating and whether it is open. Use " +
      "for 'paas me koi printing press hai', 'X ka address kya hai', 'is area me " +
      "courier wale'. This is Maps, not the user's own client list — for their " +
      "clients use search_clients.",
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "What to look for, e.g. 'printing press', 'Rohan Traders'.",
        },
        near: {
          type: "string",
          description:
            "Area or city to look around. OMIT for 'paas me' / 'yahan' — the " +
            "server then uses their phone's live location, which is better than " +
            "any name. Pass this only when they name somewhere else.",
        },
        open_now: { type: "boolean", description: "Only places open right now." },
        limit: { type: "number", description: "How many. Default 5, max 10." },
      },
      required: ["query"],
    },
  },
  {
    name: "save_place",
    description:
      "Save where the user is standing right now under a name they choose — " +
      "'is location ko Rohan Office ke naam se save karlo', 'ye godown save kar " +
      "lo'. Uses their phone's live position. Creates a draft for confirmation.",
    parameters: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "The name they gave it, e.g. 'Rohan Office', 'godown'.",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "get_saved_place",
    description:
      "Give back a place they saved earlier — its map link, address, and how " +
      "far it is from here. Use for 'Rohan Office ka link bhejo', 'godown kahan " +
      "hai', 'Rohan Office kitni door hai'.",
    parameters: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
  {
    name: "list_saved_places",
    description: "All the places they have saved. Use for 'kaun kaun si jagah save hai'.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "forget_place",
    description: "Remove a saved place. Use for 'Rohan Office hata do'.",
    parameters: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
  {
    name: "where_am_i",
    description:
      "Where the user is right now, from their phone's location — address plus a " +
      "map link. Use for 'main kahan hoon', or when you need their exact spot " +
      "rather than their city.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "get_directions",
    description:
      "Distance and travel time between two places, with live traffic. Use for " +
      "'kitni door hai', 'kitna time lagega', 'kaise jaana hai'. Give places in " +
      "plain words — Maps works out the addresses itself.",
    parameters: {
      type: "object",
      properties: {
        destination: {
          type: "string",
          description:
            "Where they are going. A saved place name works here too — the " +
            "server checks their saved places before asking Google.",
        },
        origin: {
          type: "string",
          description:
            "Starting point. OMIT for 'yahan se' — the server starts from their " +
            "phone's live location. Pass this only when they name a starting point.",
        },
        travel_mode: {
          type: "string",
          enum: ["car", "bike", "walk", "cycle", "transit"],
          description: "How they are travelling. Default car.",
        },
      },
      required: ["destination"],
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
  create_calendar_event: createCalendarEventTool,
  send_email: sendEmailTool,
  append_sheet_row: appendSheetRowTool,
  list_calendar_events: listCalendarEventsTool,
  list_recent_emails: listRecentEmailsTool,
  find_contact: findContactTool,
  find_places: findPlacesTool,
  get_directions: getDirectionsTool,
  where_am_i: (ctx) => whereAmITool(ctx),
  save_place: savePlaceTool,
  get_saved_place: getSavedPlaceTool,
  list_saved_places: (ctx) => listSavedPlacesTool(ctx),
  forget_place: forgetPlaceTool,
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
  "create_calendar_event",
  "send_email",
  "append_sheet_row",
  "save_place",
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
