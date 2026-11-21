# SMSTunnel for Zammad

An SMS provider for [Zammad](https://zammad.org). Agents answer tickets by text, triggers send SMS notifications, and
the texts your phone receives become tickets. Everything goes through [SMSTunnel](https://smstunnel.io): texts leave as
ordinary texts from your own Android phone, from your own number, under your own mobile plan.

- **SMSTunnel** appears under **Channels → SMS**, for SMS accounts and for SMS notifications.
- **Replies by text** from the ticket, from the phone the customer wrote to.
- **SMS notifications** from triggers and the scheduler, one text per number.
- **Received texts** open a ticket, or land on the customer's open ticket.
- **Safe retries.** Zammad repeats a failed SMS job. Each text carries a key that makes a repeat harmless, so a lost
  answer can't send it twice.
- **Signed webhook.** A received text is accepted only with a valid SMSTunnel signature.

## Requirements

- Zammad 7.2. Built for and tested on 7.2.3.
- An [SMSTunnel](https://smstunnel.io) account and the
  [SMSTunnel app](https://play.google.com/store/apps/details?id=io.smstunnel.app) on an Android phone.
- For received texts: Zammad at a public `https://` address with a valid certificate. Sending works without it.

## Install

Download `smstunnel.szpm` from the [latest release](https://github.com/narcisbodea/smstunnel-zammad/releases/latest).

### Zammad installed from packages (DEB or RPM)

1. Open **Admin → System → Packages**, choose `smstunnel.szpm` and click **Install Package**.
2. On the server, as root:

   ```sh
   zammad run rake zammad:package:post_install
   systemctl restart zammad
   ```

### Zammad in Docker

Zammad refuses to install packages in a running container, because each container has its own copy of the code. The
package goes into your image instead. Next to `smstunnel.szpm`, create this `Dockerfile`, with the image tag your stack
runs today:

```dockerfile
FROM ghcr.io/zammad/zammad:7.2.3-0015
COPY --chown=1000:1000 smstunnel.szpm /opt/zammad/packages/install/smstunnel.zpm
RUN ruby script/build/unpack_addon_packages.rb
```

```sh
docker build -t zammad-smstunnel:7.2.3-0015 .
```

In the `.env` of your `zammad-docker-compose` folder, set:

```sh
IMAGE_REPO=zammad-smstunnel
VERSION=7.2.3-0015
```

Then run `docker compose up -d`. Zammad's init container registers the package. Build the image again whenever you
update Zammad.

## Set it up

1. In the [SMSTunnel dashboard](https://dashboard.smstunnel.io), open **Apps → Add an app** and copy the API key.
2. In Zammad, open **Channels → SMS**. Under **SMS Accounts** click **New** and choose **SMSTunnel**. Paste the **API
   Key**, pick the **Destination Group** and click **Submit**. Leave **Signing Secret** empty for now.
3. Copy the **Webhook** address shown for the new account.
4. In the SMSTunnel dashboard, open **Apps → Forward received texts** and save that address. Copy the signing secret
   (`whsec_…`): it is shown once. If you already had one, **New secret** makes another.
5. Back in Zammad, click **Edit** on the account, paste it as **Signing Secret** and click **Submit**.
6. In the SMSTunnel dashboard, click **Send a test**, then turn forwarding on. In the app on your phone, turn on **Sync
   received texts**.
7. For notifications, click **New** under **SMS Notification**, choose **SMSTunnel** and paste the API key. Then use
   the **SMS** action in a trigger or a scheduler job.

The **Test** button in Zammad's dialog sends one real text to the number you enter.

## Good to know

- **Numbers need `+` and a country code,** like `+14155550123`. Spaces and dashes are fine. Anything else is refused
  before a request is made and the ticket says why. If a customer's number arrived without a country code, correct it
  in the **To** field when you reply.
- **Texts are handed to your phone.** Zammad marks a text as sent once SMSTunnel has taken it. SMSTunnel can't confirm
  that a text arrived, and a phone that is offline gets it when it comes back, within 3 days.
- **When a text fails,** the ticket shows a **Delivery failed** note: at once if no retry can help, otherwise after
  Zammad's last try, about 12 minutes later. If the answer was unclear, the note says the text may already have gone
  out. Zammad's own retries can't send it twice, but check your phone before writing it again.
- **More than one phone.** A reply goes out from the phone the customer wrote to. If that phone is offline and another
  phone of your account is online, SMSTunnel uses that one, so the customer may see a different number. Notifications
  go from your main phone.
- **160 characters.** Zammad cuts every SMS to 160 characters, whichever provider it uses.
- **Speed.** One phone sends about 28 SMS parts every 65 seconds (Android's limit). More texts wait their turn.
- **Which texts become tickets.** Texts from a phone number. Texts from a sender name or a short code, such as a bank's
  sign-in code, and texts encrypted end to end are skipped: nobody can answer them.
- **Use a phone meant for support.** SMSTunnel forwards every text your account's phones receive to one address, and
  in Zammad agents of the destination group can read them.
- **Sender numbers can be faked,** as with any SMS. Don't treat a text as proof of who wrote it.

## Uninstall

First turn off **Forward received texts** in the SMSTunnel dashboard, so that no text reaches a Zammad that can no
longer read it.

Uninstalling removes the SMSTunnel channels, with their API key and signing secret. Tickets stay. Replies on tickets
that came from a removed channel can no longer be sent by SMS.

**DEB or RPM:** in **Admin → System → Packages**, uninstall SMSTunnel, then on the server run:

```sh
zammad run rake zammad:package:post_install
systemctl restart zammad
```

**Docker:** build an image that carries the package for removal:

```dockerfile
FROM ghcr.io/zammad/zammad:7.2.3-0015
COPY --chown=1000:1000 smstunnel.szpm /opt/zammad/packages/uninstall/smstunnel.zpm
RUN ruby script/build/unpack_addon_packages.rb
```

```sh
docker build -t zammad-smstunnel:remove .
```

Set `VERSION=remove` in `.env`, then:

```sh
docker compose stop zammad-nginx zammad-railsserver zammad-scheduler zammad-websocket
docker compose run --rm zammad-init
```

Finally remove `IMAGE_REPO` from `.env`, set `VERSION` back to the tag you ran before, and run `docker compose up -d`.

If you went back to the plain image without these steps, Zammad keeps working, but the SMSTunnel channels stay in the
database with their key and show an error. Delete them under **Channels → SMS**.

## Development

The sources are in `src/`, laid out as they land in Zammad. `ruby script/build.rb` builds `smstunnel.szpm`, and
`ruby script/build.rb --check` fails if it is out of date. `test/driver_checks.rb` checks the driver's rules inside a
running Zammad with the package installed, and sends nothing:

```sh
bundle exec rails r /path/to/driver_checks.rb
```

## License

MIT, © 2026 NARBOWEB SRL. Support: support@smstunnel.io.

Zammad is a trademark of the Zammad Foundation. This package is not affiliated with or endorsed by the Zammad Foundation
or Zammad GmbH.
