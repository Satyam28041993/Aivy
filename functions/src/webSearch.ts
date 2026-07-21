import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

export interface SearchResultItem {
  title: string;
  link: string;
  snippet: string;
}

export interface WebSearchResponse {
  query: string;
  results: SearchResultItem[];
  success: boolean;
  error?: string;
}

/**
 * Runs a Google Search query via Serper.dev API.
 * Configured dynamically via Firestore `app_config/search` document with field `serperApiKey`,
 * falling back to process.env.SERPER_API_KEY.
 */
export async function runWebSearch(query: string): Promise<WebSearchResponse> {
  const q = query.trim();
  if (!q) {
    return { query: "", results: [], success: false, error: "Empty query" };
  }

  try {
    const db = getFirestore();
    const configSnap = await db.collection("app_config").doc("search").get();
    const configData = configSnap.data() ?? {};
    
    const apiKey = String(
      configData.serperApiKey ?? 
      process.env.SERPER_API_KEY ?? 
      ""
    ).trim();

    if (!apiKey) {
      logger.warn("Serper.dev Google Search API Key is missing in Firestore/Env");
      return {
        query: q,
        results: [],
        success: false,
        error: "Search API Key not configured. Please add serperApiKey to Firestore app_config/search.",
      };
    }

    logger.info("Executing Google Search via Serper.dev", { query: q });

    const response = await fetch("https://google.serper.dev/search", {
      method: "POST",
      headers: {
        "X-API-KEY": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ q }),
    });

    if (!response.ok) {
      const errText = await response.text().catch(() => "");
      throw new Error(`Serper HTTP ${response.status}: ${errText.slice(0, 300)}`);
    }

    const data = (await response.json()) as {
      organic?: Array<{
        title?: string;
        link?: string;
        snippet?: string;
      }>;
    };

    const organicList = data.organic ?? [];
    const results: SearchResultItem[] = organicList
      .slice(0, 4) // Fetch top 4 highly relevant search results
      .map((item) => ({
        title: String(item.title ?? "Web Result").trim(),
        link: String(item.link ?? "").trim(),
        snippet: String(item.snippet ?? "").trim(),
      }))
      .filter((item) => item.link.startsWith("http"));

    logger.info("Serper.dev Search successfully fetched results", {
      query: q,
      count: results.length,
    });

    return {
      query: q,
      results,
      success: true,
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    logger.error("webSearch failed", { query: q, error: msg });
    return {
      query: q,
      results: [],
      success: false,
      error: msg,
    };
  }
}
