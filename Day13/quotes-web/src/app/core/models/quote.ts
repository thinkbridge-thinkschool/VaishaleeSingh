/** A single quote returned by the API. */
export interface Quote {
  readonly id: number;
  readonly author: string;
  readonly text: string;
  readonly backgroundImageUrl: string;
  readonly createdByUserId: string | null;
}

export interface PagedResult<T> {
  readonly page: number;
  readonly size: number;
  readonly total: number;
  readonly items: readonly T[];
}

export interface CreateQuoteRequest {
  readonly author: string;
  readonly text: string;
  readonly backgroundImageUrl: string;
}

export interface UpdateQuoteRequest {
  readonly author: string;
  readonly text: string;
  readonly backgroundImageUrl: string;
}

export interface QuoteBackgroundOption {
  readonly label: string;
  readonly url: string;
}

export const QUOTE_BACKGROUND_OPTIONS: readonly QuoteBackgroundOption[] = [
  { label: 'Mountain Dawn', url: '/quote-backgrounds/mountain-1.jpg' },
  { label: 'Alpine Valley', url: '/quote-backgrounds/mountain-2.jpg' },
  { label: 'Snow Peaks', url: '/quote-backgrounds/mountain-3.jpg' },
  { label: 'Forest Ridge', url: '/quote-backgrounds/mountain-4.jpg' },
  { label: 'Lake Reflection', url: '/quote-backgrounds/mountain-5.jpg' },
  { label: 'Highland Sunset', url: '/quote-backgrounds/mountain-6.jpg' },
] as const;

export const DEFAULT_QUOTE_BACKGROUND_URL = QUOTE_BACKGROUND_OPTIONS[0].url;

export const QUOTE_LIMITS = {
  authorMaxLength: 200,
  textMaxLength: 1000,
} as const;

/** Resolves backend-owned relative assets against the API origin. */
export function resolveQuoteBackgroundUrl(url: string, apiBaseUrl: string): string {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }

  const assetUrl = url.startsWith('/quote-backgrounds/') ? url.replace(/\.webp$/i, '.jpg') : url;

  return assetUrl.startsWith('/') ? `${apiBaseUrl}${assetUrl}` : assetUrl;
}
