# First-time setup

## Create the initial administrator

Open the Web interface after [installation](installation.md). A new database
offers **Create the initial administrator**. Enter an email address and a
password of at least 12 characters, and confirm the password. This bootstrap
creates the first administrator; later accounts are managed by an administrator.

The onboarding screen records setup progress. You can leave it and resume using
the saved configuration.

## Connect AI

Add an AI connection, supply its endpoint/model configuration and credentials,
check the connection, and enable it. Assign an enabled connection to the
**Resolver** role. Resolver assignments let Skopos investigate Cases and propose
actions.

**Auto** authority also requires an eligible **Reviewer** assignment. Assigning a
connection only to Resolver does not give it Reviewer duties. A connection may be
assigned both roles explicitly.

## Review authority and limits

Open **AI authority and limits**, select a mode, review the finite resolution
limits, and save a reason for the revision.

| Mode | Remote effects |
| --- | --- |
| Read only | Observe and reason without remote changes |
| Ask | Require a human decision for each proposed effect |
| Auto | Run proposed changes after a Reviewer approves them |
| Full access | Allow effects without human or Reviewer approval |

Limits include elapsed time, Resolver turns, Target requests, effects, related
Targets, AI usage units, and turns without progress. Settings are captured when a
new Case starts.

**Start resolution from incoming Signals** is a separate setting. When disabled,
incoming alerts remain visible without starting automated resolution. Review the
connections, scope, authority, and limits before enabling it.

## Connect monitoring and Targets

Add, check, and enable a monitoring webhook connection. The available Signal
adapters include Alertmanager, generic webhooks, and Zabbix. Configure the sending
monitoring system for the selected adapter's endpoint and authentication.

Register a Target and attach an Access Method backed by a Target Provider. Choose
the protocol and profile that match the connection you intend to use, then check
it. For example, IOS XE can use SSH/CLI, NETCONF, or RESTCONF; the device identity
does not force a single management protocol.

When onboarding readiness is complete, use **Cases** to inspect an incident or
create one manually. Review its observations and proposed actions before
expanding automatic operation. See [Operations](operations.md).

## Additional accounts

Administrators manage accounts with administrator, operator, or viewer roles.
OIDC authentication is optional and can be configured in Settings. Existing
accounts link an OIDC identity explicitly; creating a Provider connection does
not itself link users.
