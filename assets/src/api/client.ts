import createClient, { type Middleware } from "openapi-fetch";
import type { paths } from "@/api/schema";

const tokenKey = "skopos.session";
export const authenticationExpiredEvent = "skopos:authentication-expired";
export const commaSeparatedQuery = { array: { style: "form", explode: false } } as const;

type ErrorBody = {
  error?: { code?: string; message?: string; request_id?: string };
};

function errorBody(value: unknown): ErrorBody {
  if (typeof value !== "object" || value === null || !("error" in value)) return {};
  const error = value.error;
  return typeof error === "object" && error !== null ? { error } : {};
}

export class ApiError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly requestId?: string;

  constructor(status: number, body: unknown) {
    const parsed = errorBody(body);
    super(parsed.error?.message ?? `Request failed (${status})`);
    this.name = "ApiError";
    this.status = status;
    this.code = parsed.error?.code;
    this.requestId = parsed.error?.request_id;
  }
}

export function storedToken() {
  return sessionStorage.getItem(tokenKey);
}

export function storeToken(token: string) {
  sessionStorage.setItem(tokenKey, token);
}

export function clearStoredToken() {
  sessionStorage.removeItem(tokenKey);
}

const authentication: Middleware = {
  onRequest({ request }) {
    if (!request.headers.has("Accept")) request.headers.set("Accept", "application/json");
    const token = storedToken();
    if (token) request.headers.set("Authorization", `Bearer ${token}`);
    return request;
  },
  async onResponse({ response }) {
    if (response.status === 401 && storedToken()) {
      clearStoredToken();
      window.dispatchEvent(new Event(authenticationExpiredEvent));
    }

    if (!response.ok) {
      const body = await response
        .clone()
        .json()
        .catch(() => ({}));
      throw new ApiError(response.status, body);
    }
  },
};

export const apiClient = createClient<paths>();
apiClient.use(authentication);

export function apiData<T>(result: { data?: T; response: Response }): NonNullable<T> {
  if (result.data === undefined || result.data === null) {
    throw new ApiError(result.response.status, {});
  }
  return result.data;
}
