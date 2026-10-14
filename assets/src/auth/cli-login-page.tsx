import { useMemo, useState } from "react";
import { AlertCircle, Terminal } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useParams } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";

export function CLILoginPage() {
  const { requestId } = useParams<{ requestId: string }>();
  const { account } = useAuthentication();
  const { t } = useTranslation();
  const [submitting, setSubmitting] = useState(false);
  const [failed, setFailed] = useState(false);
  const startToken = useMemo(
    () => new URLSearchParams(window.location.hash.slice(1)).get("token"),
    [],
  );

  const validRequest = Boolean(requestId && startToken);

  async function decide(action: "approve" | "deny") {
    if (!requestId || !startToken) return;

    setSubmitting(true);
    setFailed(false);

    try {
      const request = { request: { start_token: startToken } };
      const result =
        action === "approve"
          ? await apiClient.POST("/api/v1/cli/session-requests/{id}/approve", {
              params: { path: { id: requestId } },
              body: request,
            })
          : await apiClient.POST("/api/v1/cli/session-requests/{id}/deny", {
              params: { path: { id: requestId } },
              body: request,
            });
      const { data } = apiData(result);
      window.location.replace(data.redirect_uri);
    } catch {
      setFailed(true);
      setSubmitting(false);
    }
  }

  return (
    <main className="grid min-h-svh place-items-center bg-muted/40 p-4">
      <Card className="w-full max-w-md">
        <CardHeader>
          <div className="mb-2 flex size-10 items-center justify-center rounded-lg bg-primary text-primary-foreground">
            <Terminal className="size-5" />
          </div>
          <CardTitle>{t("cliLogin.title")}</CardTitle>
          <CardDescription>{t("cliLogin.description")}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="rounded-md border bg-muted/30 p-3 text-sm">
            <div className="font-medium">Skopos CLI</div>
            <div className="mt-1 text-muted-foreground">{t("cliLogin.loopback")}</div>
            {account && <div className="mt-2">{account.email}</div>}
          </div>

          {(!validRequest || failed) && (
            <Alert variant="destructive">
              <AlertCircle />
              <AlertDescription>
                {t(validRequest ? "cliLogin.failed" : "cliLogin.invalid")}
              </AlertDescription>
            </Alert>
          )}

          <div className="flex gap-3">
            <Button
              className="flex-1"
              disabled={!validRequest || submitting}
              onClick={() => void decide("approve")}
            >
              {submitting && <Spinner />}
              {t("cliLogin.approve")}
            </Button>
            <Button
              className="flex-1"
              variant="outline"
              disabled={!validRequest || submitting}
              onClick={() => void decide("deny")}
            >
              {t("cliLogin.deny")}
            </Button>
          </div>
        </CardContent>
      </Card>
    </main>
  );
}
