export type MetaWhatsappClientConfig = {
  appId: string;
  embeddedSignupConfigId: string;
  graphApiVersion: string;
  webhookVerifyToken: string;
  appSecret: string;
  defaultContactsOwnerUid: string;
};

export type WhatsappConnectionMetadata = {
  wabaId: string;
  phoneNumberId: string;
  displayPhoneNumber: string;
  connectionStatus: string;
  historySyncStatus: string;
  coexistenceEnabled: boolean;
  tokenSecretRef: string;
  ownerUid: string;
  onboardedAtMs: number;
  outboundTemplateName: string;
  outboundTemplateLanguage: string;
  outboundTemplateBodyParamCount: number;
  contactsOwnerUid: string;
};

export type ExchangeCodeResult = {
  accessToken: string;
  tokenType: string | null;
  expiresInSec: number | null;
};
