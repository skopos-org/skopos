import {
  BookOpenCheck,
  Bot,
  Boxes,
  Check,
  FileText,
  Globe2,
  Moon,
  RadioTower,
  Settings,
  ShieldCheck,
  Sun,
  Webhook,
} from "lucide-react";
import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { useTheme } from "@/components/theme-provider";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";
import { normalizeLocale, supportedLocales } from "@/i18n/config";

const navigation = [
  {
    label: "navigation.operations",
    items: [
      ["/cases", "navigation.cases", RadioTower],
      ["/audits", "navigation.audits", ShieldCheck],
      ["/reports", "navigation.reports", FileText],
    ],
  },
  {
    label: "navigation.configuration",
    items: [
      ["/targets", "navigation.targets", Boxes],
      ["/ai", "navigation.ai", Bot],
      ["/signals", "navigation.signals", Webhook],
      ["/settings", "navigation.settings", Settings],
    ],
  },
] as const;

export function AppShell() {
  const { account, changePreferredLanguage, signOut } = useAuthentication();
  const { t, i18n } = useTranslation();
  const { resolvedTheme, setTheme } = useTheme();
  const location = useLocation();
  const previousPathname = useRef(location.pathname);
  const initials = account?.email.slice(0, 2).toUpperCase() ?? "OP";

  useEffect(() => {
    if (previousPathname.current === location.pathname) return;
    previousPathname.current = location.pathname;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById("main-content")?.focus();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [location.pathname]);

  return (
    <SidebarProvider>
      <a
        href="#main-content"
        className="fixed top-2 left-2 z-50 -translate-y-20 rounded-md bg-background px-3 py-2 text-sm font-medium shadow focus:translate-y-0"
      >
        {t("common.skipToContent")}
      </a>
      <Sidebar collapsible="icon">
        <SidebarHeader>
          <div className="flex h-10 items-center gap-2 px-2 font-semibold">
            <BookOpenCheck className="size-5 text-primary" />
            <span className="group-data-[collapsible=icon]:hidden">Skopos</span>
          </div>
        </SidebarHeader>
        <SidebarContent>
          {navigation.map((section) => (
            <SidebarGroup key={section.label}>
              <SidebarGroupLabel>{t(section.label)}</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  {section.items.map(([to, label, Icon]) => (
                    <SidebarMenuItem key={to}>
                      <SidebarMenuButton
                        asChild
                        isActive={
                          location.pathname === to || location.pathname.startsWith(`${to}/`)
                        }
                        tooltip={t(label)}
                      >
                        <NavLink to={to}>
                          <Icon />
                          <span>{t(label)}</span>
                        </NavLink>
                      </SidebarMenuButton>
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          ))}
        </SidebarContent>
        <SidebarFooter>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" className="h-auto w-full justify-start gap-2 p-2">
                <Avatar size="sm">
                  <AvatarFallback>{initials}</AvatarFallback>
                </Avatar>
                <span className="min-w-0 truncate group-data-[collapsible=icon]:hidden">
                  {account?.email}
                </span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent side="top" align="start" className="min-w-56">
              <DropdownMenuGroup>
                <DropdownMenuLabel>{account?.email}</DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={() => void signOut()}>
                  {t("common.signOut")}
                </DropdownMenuItem>
              </DropdownMenuGroup>
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarFooter>
      </Sidebar>
      <SidebarInset id="main-content" tabIndex={-1} className="min-w-0">
        <header className="flex h-14 items-center justify-between border-b px-4">
          <SidebarTrigger aria-label={t("common.toggleNavigation")} />
          <div className="flex items-center gap-1 text-sm text-muted-foreground">
            <Button
              id="application-theme"
              size="icon-sm"
              variant="ghost"
              aria-label={t("common.theme")}
              onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
            >
              {resolvedTheme === "dark" ? <Moon /> : <Sun />}
            </Button>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  id="application-language"
                  size="icon-sm"
                  variant="ghost"
                  aria-label={t("common.language")}
                >
                  <Globe2 />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="min-w-36">
                {supportedLocales.map(({ value, label }) => (
                  <DropdownMenuItem
                    key={value}
                    closeOnClick
                    onClick={() => void changePreferredLanguage(value)}
                  >
                    {label}
                    {normalizeLocale(i18n.resolvedLanguage) === value && (
                      <Check className="ml-auto" />
                    )}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>
        <div className="mx-auto w-full max-w-[96rem]">
          <Outlet />
        </div>
      </SidebarInset>
    </SidebarProvider>
  );
}
