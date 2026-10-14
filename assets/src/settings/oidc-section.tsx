import { useEffect, useState, type FormEvent } from "react";
import { KeyRound, Link } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";

type OIDCProvider = components["schemas"]["OIDCProvider"];

type Props = {
  canManage: boolean;
  onError: (message: string) => void;
};

export function OIDCSetup({ canManage, onError }: Props) {
  const { t } = useTranslation();
  const { linkOIDC, oidcEnabled } = useAuthentication();
  const [provider, setProvider] = useState<OIDCProvider | null>(null);
  const [enabled, setEnabled] = useState(true);
  const [editing, setEditing] = useState(false);
  const [pending, setPending] = useState<"configure" | "link" | null>(null);
  const [linked, setLinked] = useState(false);

  useEffect(() => {
    if (!canManage) return;

    let active = true;
    apiClient
      .GET("/api/v1/oidc/provider")
      .then(apiData)
      .then(({ data }) => {
        if (!active) return;
        setProvider(data);
        setEnabled(data.enabled);
      })
      .catch(() => {
        if (active) onError(t("setup.requestFailed"));
      });

    return () => {
      active = false;
    };
  }, [canManage, onError, t]);

  async function configure(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const issuer = form.get("issuer");
    const clientId = form.get("client_id");
    const clientSecret = form.get("client_secret");
    const idTokenAlg = form.get("id_token_alg");

    if (
      typeof issuer !== "string" ||
      typeof clientId !== "string" ||
      typeof clientSecret !== "string" ||
      !isIDTokenAlgorithm(idTokenAlg)
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    setPending("configure");
    setLinked(false);
    onError("");
    try {
      const { data } = apiData(
        await apiClient.PUT("/api/v1/oidc/provider", {
          body: {
            oidc_provider: {
              issuer,
              client_id: clientId,
              client_secret: clientSecret,
              id_token_alg: idTokenAlg,
              enabled,
            },
          },
        }),
      );
      setProvider(data);
      setEnabled(data.enabled);
      setEditing(false);
      const secretInput = formElement.elements.namedItem("client_secret");
      if (secretInput instanceof HTMLInputElement) secretInput.value = "";
    } catch {
      onError(t("setup.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  async function linkAccount() {
    setPending("link");
    setLinked(false);
    onError("");
    try {
      await linkOIDC();
      setLinked(true);
    } catch {
      onError(t("setup.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  const connectionEnabled = provider?.enabled ?? oidcEnabled;

  return (
    <section id="oidc" className="scroll-mt-20 space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("setup.oidcTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("setup.oidcDescription")}</p>
      </div>

      <Card>
        <CardHeader className="border-b">
          <div className="flex items-center justify-between gap-3">
            <CardTitle className="text-base">{t("setup.oidcConnection")}</CardTitle>
            <Badge variant={connectionEnabled ? "default" : "secondary"}>
              {t(
                canManage && !provider?.issuer
                  ? "setup.oidcUnconfiguredStatus"
                  : connectionEnabled
                    ? "setup.enabled"
                    : "setup.disabled",
              )}
            </Badge>
          </div>
        </CardHeader>
        <CardContent className="space-y-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="min-w-0 break-all text-sm text-muted-foreground">
              {canManage
                ? provider?.issuer || t("setup.oidcNotConfigured")
                : t(connectionEnabled ? "setup.oidcAvailable" : "setup.oidcUnavailable")}
            </p>
            {canManage && (
              <Button variant="outline" size="sm" onClick={() => setEditing((open) => !open)}>
                {t(
                  editing
                    ? "common.close"
                    : provider?.issuer
                      ? "setup.oidcEdit"
                      : "setup.oidcConfigure",
                )}
              </Button>
            )}
          </div>

          {canManage && editing && (
            <form
              key={provider?.revision ?? "new"}
              className="grid gap-4 border-t pt-5 md:grid-cols-2"
              onSubmit={configure}
            >
              <CardDescription className="md:col-span-2">
                {t("setup.oidcSecretDescription")}
              </CardDescription>
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="oidc-callback-uri">{t("setup.oidcCallback")}</Label>
                <Input id="oidc-callback-uri" value={provider?.callback_uri ?? ""} readOnly />
                <p className="text-sm text-muted-foreground">
                  {t("setup.oidcCallbackDescription")}
                </p>
              </div>
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="oidc-issuer">{t("setup.oidcIssuer")}</Label>
                <Input
                  id="oidc-issuer"
                  name="issuer"
                  type="url"
                  defaultValue={provider?.issuer}
                  placeholder="https://id.example.com/realms/skopos"
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="oidc-client-id">{t("setup.oidcClientId")}</Label>
                <Input
                  id="oidc-client-id"
                  name="client_id"
                  defaultValue={provider?.client_id}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="oidc-client-secret">{t("setup.oidcClientSecret")}</Label>
                <Input
                  id="oidc-client-secret"
                  name="client_secret"
                  type="password"
                  autoComplete="off"
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="oidc-id-token-alg">{t("setup.oidcIdTokenAlg")}</Label>
                <Input
                  id="oidc-id-token-alg"
                  name="id_token_alg"
                  defaultValue={provider?.id_token_alg ?? "RS256"}
                  required
                />
              </div>
              <div className="flex items-center justify-between gap-4 rounded-lg border p-4 md:col-span-2">
                <Label htmlFor="oidc-enabled">{t("setup.oidcEnabled")}</Label>
                <Switch id="oidc-enabled" checked={enabled} onCheckedChange={setEnabled} />
              </div>
              <Button type="submit" className="md:w-fit" disabled={pending !== null}>
                {pending === "configure" ? <Spinner /> : <KeyRound />}
                {t("setup.saveOIDC")}
              </Button>
            </form>
          )}

          {connectionEnabled && (
            <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-5">
              <div>
                <p className="text-sm font-medium">{t("setup.linkOIDCTitle")}</p>
                <p className="mt-1 text-sm text-muted-foreground">
                  {t("setup.linkOIDCDescription")}
                </p>
              </div>
              <Button
                variant="outline"
                size="sm"
                disabled={pending !== null}
                onClick={() => void linkAccount()}
              >
                {pending === "link" ? <Spinner /> : <Link />}
                {t("setup.linkOIDC")}
              </Button>
              {linked && <span className="text-sm text-success">{t("setup.oidcLinked")}</span>}
            </div>
          )}
        </CardContent>
      </Card>
    </section>
  );
}

function isIDTokenAlgorithm(
  value: FormDataEntryValue | null,
): value is "RS256" | "PS256" | "ES256" | "ES384" | "ES512" | "EdDSA" | "Ed25519" | "Ed448" {
  return (
    typeof value === "string" &&
    ["RS256", "PS256", "ES256", "ES384", "ES512", "EdDSA", "Ed25519", "Ed448"].includes(value)
  );
}
