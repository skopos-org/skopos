# First-time setup

Connect an AI service and one Target, choose authority, then create a Case and
check its result. Use either the Web or CLI path below.
Adding connections and changing authority requires an administrator account.

## Web

1. Open the server URL. On the sign-in screen, select **First use? Create administrator**.
   Enter your email and a password of at least 12 characters, confirm it, and
   select **Create administrator**.
2. In **Connect Skopos to your environment**, select **Configure AI**.
   Choose your service, enter the model and credentials, and select the AI usage
   role. Use **Both (Resolver and Reviewer)** to assign both roles. Save the connection,
   select **Check**, then **Enable**.
3. Open **AI → AI authority and limits**. Choose an authority mode and limits,
   enter the change reason, and save. Leave automatic incoming-Signal resolution
   disabled while setting up. See [authority settings](configuration.md).
4. Open **Targets → Add Target**. Choose the category and type, enter the name,
   and save. On the Target page, select **Add access method → New connection**.
   Choose the protocol, enter the endpoint and credentials, and create the connection.
   Add the access method, then select **Check**. Select **Edit access method**,
   choose the permitted capabilities, and save.
5. Open **Signals → Add Signal connection**. Choose your monitoring adapter,
   enter a source name and webhook secret, save, check, and enable it.
   Configure the monitoring sender with the displayed webhook URL and secret.
   Add the Target's external identity to match the sender's Target reference.
6. Open **Cases → Create Case**. Select the Target, enter the observed problem
   and the desired outcome, and create the Case. Describe a result that can be
   checked on the Target, rather than an action such as “restart the service.”
7. Open the created Case. Follow observations, proposed changes, and verification.
   In Ask mode, approve or reject the proposed change. Confirm the recovery
   evidence and report using [Operations](operations.md).

## CLI

Run `skopos auth login` on a computer with a browser. Sign in and authorize the
CLI in the opened page. For a new installation, create the initial administrator
from that sign-in screen before authorizing.

Replace `https://skopos.example.org` with your Skopos server URL.

```sh
skopos config set-server https://skopos.example.org
skopos auth login
skopos auth status
```

Prepare the JSON files in [Configuration](configuration.md).
Use the IDs returned by each command below. Before a check or enable operation,
put the resource's current `revision` in `revision.json`.

1. Register the AI connection, check it, and enable it:

   ```sh
   skopos provider services
   skopos provider create --input ai.json
   skopos provider show AI_PROVIDER_ID
   skopos provider check AI_PROVIDER_ID --input revision.json
   skopos provider show AI_PROVIDER_ID
   skopos provider enable AI_PROVIDER_ID --input revision.json
   skopos ai-role list
   ```

2. Read the authority settings and apply your chosen mode and limits:

   ```sh
   skopos authority show
   skopos authority set --input authority.json
   ```

3. Register the Target and its connection. Enable the Provider, then use its
   returned revision in `method.json`:

   ```sh
   skopos target-type list
   skopos target create --input target.json
   skopos provider create --input target-provider.json
   skopos provider show TARGET_PROVIDER_ID
   skopos provider enable TARGET_PROVIDER_ID --input revision.json
   skopos access-method create --input method.json
   skopos access-method show METHOD_ID
   skopos access-method check METHOD_ID --input revision.json
   ```

4. Register and enable monitoring. Use the adapter's webhook URL and your secret
   in the sender, and register the matching Target identity:

   ```sh
   skopos provider create --input signal.json
   skopos provider show SIGNAL_PROVIDER_ID
   skopos provider check SIGNAL_PROVIDER_ID --input revision.json
   skopos provider show SIGNAL_PROVIDER_ID
   skopos provider enable SIGNAL_PROVIDER_ID --input revision.json
   skopos identity create --input identity.json
   ```

5. Create the Case and follow its result:

   ```sh
   skopos case create --input case.json
   skopos case show CASE_ID
   skopos case wait CASE_ID --interval 1000 --timeout 60
   ```

In Ask mode, a Case can stop for approval. Follow the [CLI approval and result
steps](operations.md#cli) before waiting again.

After confirming the connections and the Case result, enable **Start resolution
from incoming Signals** through Web authority settings or by setting
`signal_automation_enabled` to `true` with `skopos authority set`.
