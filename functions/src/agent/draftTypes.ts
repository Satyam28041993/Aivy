/**
 * Shapes for the agent's two-phase writes.
 *
 * A write tool never touches the business collections directly. It resolves
 * everything (client, date, amount), stores a *draft*, and returns a card. Only
 * `aivyAgentCommit` — which the user triggers by tapping "Sahi hai" — turns a
 * draft into a real record. That way a misunderstanding is visible on screen
 * before it reaches the ledger, and "Badlo" can be plain speech instead of a
 * field picker.
 */

export type DraftKind =
  | "meeting"
  | "reminder"
  | "quotation"
  | "order"
  | "payment_due"
  | "payment_received"
  | "remember_fact"
  | "calendar_event"
  | "email"
  | "sheet_row"
  | "saved_place";

export type DraftStatus = "pending" | "committed" | "cancelled" | "superseded";

export interface DraftClientRef {
  /** Null when the client does not exist yet and will be created on commit. */
  id: string | null;
  name: string;
  /** True when commit should create the client first. */
  createNew: boolean;
}

export interface MeetingDraftData {
  kind: "meeting";
  client: DraftClientRef | null;
  agenda: string;
  whenIso: string;
  whenMs: number;
  whenLabel: string;
  /** Minutes before the meeting for the automatic reminder. */
  reminderLeadMinutes: number;
  note: string | null;
  /**
   * Also put it on Google Calendar when the turn carried a Google token.
   * Optional so drafts written before this existed still commit.
   */
  addToCalendar?: boolean;
  /** Minutes the calendar event should block out. */
  durationMinutes?: number;
}

export interface ReminderDraftData {
  kind: "reminder";
  title: string;
  client: DraftClientRef | null;
  whenIso: string;
  whenMs: number;
  whenLabel: string;
  /** call | followup | task | meeting */
  reminderType: string;
  priority: string;
  note: string | null;
}

export interface QuotationDraftData {
  kind: "quotation";
  client: DraftClientRef;
  amount: number;
  followUpIso: string;
  followUpMs: number;
  followUpLabel: string;
  note: string | null;
}

export interface OrderDraftData {
  kind: "order";
  client: DraftClientRef;
  amount: number;
  note: string | null;
}

export interface PaymentDueDraftData {
  kind: "payment_due";
  client: DraftClientRef;
  amount: number;
  dueIso: string;
  dueMs: number;
  dueLabel: string;
  note: string | null;
}

export interface PaymentReceivedDraftData {
  kind: "payment_received";
  client: DraftClientRef;
  amount: number;
  receivedIso: string;
  receivedMs: number;
  receivedLabel: string;
  /** Open due rows this receipt will be applied against, best match first. */
  targets: Array<{
    paymentId: string;
    remaining: number;
    dueMs: number | null;
    label: string;
  }>;
  note: string | null;
}

export interface CalendarEventDraftData {
  kind: "calendar_event";
  summary: string;
  description: string | null;
  whenIso: string;
  whenMs: number;
  whenLabel: string;
  durationMinutes: number;
  timezone: string;
  attendeeEmails: string[];
}

export interface EmailDraftData {
  kind: "email";
  to: string;
  /** Who it is, when the address came from a contact lookup. */
  toName: string | null;
  subject: string;
  body: string;
}

export interface SheetRowDraftData {
  kind: "sheet_row";
  /** Null means "use the default sheet saved in settings" at commit time. */
  spreadsheetId: string | null;
  tab: string;
  cells: string[];
}

export interface SavedPlaceDraftData {
  kind: "saved_place";
  name: string;
  lat: number;
  lng: number;
  address: string;
  /** True when a place of this name already exists and will be moved. */
  replacing: boolean;
}

/** One thing to remember, filed under a key of its own. */
export interface RememberedFact {
  /** Stable subject key — "wife", "anniversary", "city". */
  key: string;
  /** What to remember about that subject, in one line. */
  value: string;
}

export interface RememberFactDraftData {
  kind: "remember_fact";
  category: string;
  fact: string;
  /**
   * Several facts saved together, which is how a batch of personal details
   * arrives. Older drafts have only `category`/`fact`, so both are read.
   */
  facts?: RememberedFact[];
}

export type DraftData =
  | MeetingDraftData
  | ReminderDraftData
  | QuotationDraftData
  | OrderDraftData
  | PaymentDueDraftData
  | PaymentReceivedDraftData
  | RememberFactDraftData
  | CalendarEventDraftData
  | EmailDraftData
  | SheetRowDraftData
  | SavedPlaceDraftData;

/** One line on the confirm card: "Client", "Rohan Traders". */
export interface DraftCardLine {
  label: string;
  value: string;
}

/** What the client renders and what commit replays. */
export interface AgentDraft {
  id: string;
  kind: DraftKind;
  status: DraftStatus;
  /** Card heading, e.g. "Meeting". */
  title: string;
  /** Emoji shown on the card. */
  icon: string;
  lines: DraftCardLine[];
  data: DraftData;
  chatId: string | null;
  createdAtMs: number;
  committedAtMs: number | null;
  /** Ids created on commit, for the "saved" reference the next turn sees. */
  resultIds: string[];
}
