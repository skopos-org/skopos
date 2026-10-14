import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  apiClient,
  apiData,
  authenticationExpiredEvent,
  clearStoredToken,
  storeToken,
  storedToken,
} from "@/api/client";
import { AuthenticationContext, type Account } from "@/auth/context";
import type { components } from "@/api/schema";
import i18n, { normalizeLocale, type SupportedLocale } from "@/i18n/config";

type OIDCStatus = components["schemas"]["OIDCStatusResponse"]["data"];

type OIDCMessage = {
  type: "skopos:oidc-session" | "skopos:oidc-linked" | "skopos:oidc-error";
  token?: string;
  account?: Account;
};

function browserOIDC(path: string, successType: OIDCMessage["type"]) {
  return new Promise<{ token: string; account: Account }>((resolve, reject) => {
    const popup = window.open("about:blank", "skopos-oidc", "popup,width=640,height=720");
    if (!popup) {
      reject(new Error("The browser blocked the OIDC sign-in window."));
      return;
    }

    let settled = false;

    const finish = (result: { token: string; account: Account } | Error) => {
      if (settled) return;
      settled = true;
      window.removeEventListener("message", receive);
      window.clearInterval(closed);
      window.clearTimeout(expired);
      popup.close();
      if (result instanceof Error) reject(result);
      else resolve(result);
    };

    const receive = (event: MessageEvent<unknown>) => {
      if (event.origin !== window.location.origin || event.source !== popup) return;
      const message = event.data as Partial<OIDCMessage>;

      if (message.type === successType && message.token && message.account) {
        finish({ token: message.token, account: message.account });
      } else if (message.type === "skopos:oidc-error") {
        finish(new Error("OIDC authentication failed."));
      }
    };

    const closed = window.setInterval(() => {
      if (popup.closed) finish(new Error("The OIDC sign-in window was closed."));
    }, 500);
    const expired = window.setTimeout(
      () => finish(new Error("OIDC authentication timed out.")),
      10 * 60 * 1_000,
    );

    window.addEventListener("message", receive);
    popup.location.replace(path);
  });
}

export function AuthenticationProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [loading, setLoading] = useState(Boolean(storedToken()));
  const [oidcStatus, setOIDCStatus] = useState<OIDCStatus>({
    enabled: false,
    authorization_url: null,
    callback_uri: "",
  });

  useEffect(() => {
    const expire = () => {
      setAccount(null);
      setLoading(false);
    };

    window.addEventListener(authenticationExpiredEvent, expire);
    return () => window.removeEventListener(authenticationExpiredEvent, expire);
  }, []);

  useEffect(() => {
    apiClient
      .GET("/api/v1/oidc")
      .then((result) => setOIDCStatus(apiData(result).data))
      .catch(() => setOIDCStatus({ enabled: false, authorization_url: null, callback_uri: "" }));
  }, []);

  useEffect(() => {
    if (!storedToken()) return;

    let active = true;
    apiClient
      .GET("/api/v1/session")
      .then((result) => {
        if (active) setAccount(apiData(result).data.account);
      })
      .catch(() => {
        if (active) setAccount(null);
      })
      .finally(() => {
        if (active) setLoading(false);
      });

    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (account) void i18n.changeLanguage(account.preferred_language);
  }, [account]);

  const signIn = useCallback(async (email: string, password: string) => {
    const { data } = apiData(
      await apiClient.POST("/api/v1/sessions", {
        body: { session: { email, password } },
      }),
    );
    storeToken(data.token);
    setAccount(data.account);
  }, []);

  const signInWithOIDC = useCallback(async () => {
    if (!oidcStatus.enabled || !oidcStatus.authorization_url) {
      throw new Error("OIDC authentication is not enabled.");
    }

    const result = await browserOIDC(oidcStatus.authorization_url, "skopos:oidc-session");
    storeToken(result.token);
    setAccount(result.account);
  }, [oidcStatus]);

  const linkOIDC = useCallback(async () => {
    const { data } = apiData(await apiClient.POST("/api/v1/oidc/link-requests"));
    const result = await browserOIDC(data.authorization_url, "skopos:oidc-linked");
    storeToken(result.token);
    setAccount(result.account);
  }, []);

  const bootstrap = useCallback(
    async (email: string, password: string, confirmation: string) => {
      const preferredLanguage = normalizeLocale(i18n.resolvedLanguage);
      await apiClient.POST("/api/v1/accounts/bootstrap", {
        body: {
          account: { email, password, password_confirmation: confirmation },
        },
      });
      await signIn(email, password);
      const { data } = apiData(
        await apiClient.PATCH("/api/v1/account/language", {
          body: { account: { preferred_language: preferredLanguage } },
        }),
      );
      setAccount(data);
    },
    [signIn],
  );

  const signOut = useCallback(async () => {
    try {
      await apiClient.DELETE("/api/v1/session");
    } finally {
      clearStoredToken();
      setAccount(null);
    }
  }, []);

  const changePreferredLanguage = useCallback(async (language: SupportedLocale) => {
    const { data } = apiData(
      await apiClient.PATCH("/api/v1/account/language", {
        body: { account: { preferred_language: language } },
      }),
    );
    setAccount(data);
  }, []);

  const value = useMemo(
    () => ({
      account,
      loading,
      oidcEnabled: oidcStatus.enabled,
      bootstrap,
      signIn,
      signInWithOIDC,
      linkOIDC,
      changePreferredLanguage,
      signOut,
    }),
    [
      account,
      bootstrap,
      changePreferredLanguage,
      linkOIDC,
      loading,
      oidcStatus.enabled,
      signIn,
      signInWithOIDC,
      signOut,
    ],
  );

  return <AuthenticationContext.Provider value={value}>{children}</AuthenticationContext.Provider>;
}
