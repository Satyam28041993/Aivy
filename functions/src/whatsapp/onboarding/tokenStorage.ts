import { SecretManagerServiceClient } from "@google-cloud/secret-manager";
import { logger } from "firebase-functions";

const client = new SecretManagerServiceClient();

function sanitizeUid(uid: string): string {
  return uid.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 120);
}

function secretIdForUid(uid: string): string {
  return `whatsapp-business-token-${sanitizeUid(uid)}`;
}

function resolveProjectId(): string {
  return (
    process.env.GCLOUD_PROJECT ??
    process.env.GCP_PROJECT ??
    process.env.GOOGLE_CLOUD_PROJECT ??
    ""
  ).trim();
}

export async function storeBusinessTokenSecret(opts: {
  ownerUid: string;
  accessToken: string;
}): Promise<string> {
  const ownerUid = String(opts.ownerUid ?? "").trim();
  const accessToken = String(opts.accessToken ?? "").trim();
  const projectId = resolveProjectId();

  if (!ownerUid) {
    throw new Error("ownerUid is required");
  }
  if (!accessToken) {
    throw new Error("accessToken is required");
  }
  if (!projectId) {
    throw new Error("GCP project id is unavailable");
  }

  const secretId = secretIdForUid(ownerUid);
  const parent = `projects/${projectId}`;
  const secretName = `${parent}/secrets/${secretId}`;

  try {
    await client.getSecret({ name: secretName });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.toLowerCase().includes("not found")) {
      throw error;
    }
    await client.createSecret({
      parent,
      secretId,
      secret: {
        replication: { automatic: {} },
        labels: {
          product: "aivy",
          channel: "whatsapp",
        },
      },
    });
    logger.info("[whatsapp-onboarding] created business token secret", { secretId });
  }

  const [version] = await client.addSecretVersion({
    parent: secretName,
    payload: { data: Buffer.from(accessToken, "utf8") },
  });

  const tokenSecretRef = String(version.name ?? "").trim();
  if (!tokenSecretRef) {
    throw new Error("Secret Manager did not return a version name");
  }
  return tokenSecretRef;
}

export async function readBusinessTokenSecret(tokenSecretRef: string): Promise<string> {
  const name = String(tokenSecretRef ?? "").trim();
  if (!name) {
    throw new Error("tokenSecretRef is required");
  }
  const [version] = await client.accessSecretVersion({ name });
  const data = version.payload?.data;
  if (!data) {
    throw new Error("Secret version payload missing");
  }
  return Buffer.from(data).toString("utf8").trim();
}

export function latestSecretRefForUid(ownerUid: string): string {
  const projectId = resolveProjectId();
  const secretId = secretIdForUid(ownerUid);
  return `projects/${projectId}/secrets/${secretId}/versions/latest`;
}
