# GB SMTP Service

A self-hosted, multi-domain mail server (SMTP + IMAP) for GoldBucks group domains, built on
[docker-mailserver](https://github.com/docker-mailserver/docker-mailserver) (Postfix, Dovecot, Rspamd, Fail2ban).
It runs two separate environments, **PRD** and **UAT**, from the same compose file.

## Environments

| | PRD | UAT |
|---|---|---|
| Mail host | `mail.goldbucks.org` | `mail-uat.goldbucks.org` |
| Domains | goldbucks.org, mygoldbucks.com, goldnpay.in, signalsarena.com | uatmail.goldbucks.org, uatmail.mygoldbucks.com, uatmail.goldnpay.in, uatmail.signalsarena.com |
| Mailboxes | `config/prd/mailboxes.txt` | `config/uat/mailboxes.txt` |
| Config | `env/prd.env` | `env/uat.env` |
| Data | `data/prd/` | `data/uat/` |
| Passwords | `secrets/prd/credentials.txt` | `secrets/uat/credentials.txt` |

UAT uses dedicated `uatmail.` sub-domains (separate from the `uat.` app sub-domains) so it never competes with PRD for the real domains' MX records,
and test mail never goes out from a real customer-facing address.

### PRD mailboxes

| Domain | Mailboxes |
|---|---|
| goldbucks.org | no-reply@, support@, balamohan.k@ |
| mygoldbucks.com | no-reply@, support@ |
| goldnpay.in | no-reply@, support@, service@, grievance@ |
| signalsarena.com | no-reply@, support@, service@, grievance@ |

Each domain also gets `postmaster@`, `abuse@` and `dmarc@` aliases (see `config/prd/aliases.txt`).

### UAT mailboxes

`test@uatmail.goldbucks.org`, `test@uatmail.mygoldbucks.com`, `test@uatmail.goldnpay.in`, `test@uatmail.signalsarena.com`

## Project layout

```
docker-compose.yml        single service definition, parameterised per environment
env/prd.env, env/uat.env  environment settings (no secrets)
config/<env>/             mailboxes.txt, aliases.txt
scripts/
  build.sh                validate config, pin image digest, package a release
  setup.sh                first-time setup / add mailboxes (idempotent)
  start.sh                start / restart / upgrade
  stop.sh                 stop (data kept)
  status.sh               health, mailboxes, queue, cert expiry, logs
  dns-records.sh          print the DNS records to publish
  backup.sh               backup data + keys + credentials
data/<env>/               (runtime, git-ignored) mail, accounts, DKIM keys, queue, logs
secrets/<env>/            (runtime, git-ignored) generated mailbox passwords
dns/<env>-dns-records.txt (generated, git-ignored)
```

## Server requirements

- Linux VPS (Ubuntu 22.04/24.04 recommended), 2 GB RAM minimum (4 GB+ to enable ClamAV)
- Docker Engine + Docker Compose v2, `openssl`, `curl` (`certbot` is installed by setup if missing)
- **Outbound port 25 open.** AWS, GCP and Azure block it, and DigitalOcean usually does until you file a ticket. Hetzner, OVH and Contabo are fine.
- A static public IPv4 with **reverse DNS (PTR)** set to the mail host name
- Firewall inbound: `25, 80 (certificate issuance/renewal), 465, 587, 993`
- One server/IP per environment. Only one server can receive on port 25 per IP.

## Deploy

```bash
# On the server
sudo git clone <repo-url> /opt/gbsmtpservice && cd /opt/gbsmtpservice

# 1. Create the A record for the mail host FIRST (needed for the TLS certificate)
#    PRD: mail.goldbucks.org     -> <PRD server IP>
#    UAT: mail-uat.goldbucks.org -> <UAT server IP>

# 2. Validate
./scripts/build.sh --pull

# 3. Set up the environment (certificate, mailboxes, aliases, DKIM, start, DNS sheet)
sudo ./scripts/setup.sh prd        # or: uat

# 4. Publish everything in dns/prd-dns-records.txt at each domain's registrar
# 5. Set the PTR record in the VPS provider panel
# 6. Collect the passwords
sudo cat secrets/prd/credentials.txt
```

## Day-to-day

```bash
./scripts/status.sh prd                  # health, mailboxes, queue, cert, logs
./scripts/start.sh prd --restart         # restart
./scripts/start.sh prd --pull            # upgrade docker-mailserver
./scripts/stop.sh prd                    # stop (mail is kept in data/prd)
./scripts/dns-records.sh prd             # reprint DNS records
sudo ./scripts/backup.sh prd             # backup to BACKUP_DIR
```

**Add a mailbox:** add the address to `config/<env>/mailboxes.txt`, then run `sudo ./scripts/setup.sh <env>`.
Existing mailboxes are never changed. The new password is appended to `secrets/<env>/credentials.txt`.
A new domain also gets a DKIM key, so re-publish DNS from `dns/<env>-dns-records.txt`.

**Change or reset a password:**
```bash
docker exec -it gbsmtp-prd setup email update support@goldnpay.in 'NewStrongPassword'
```

**Delete a mailbox** (removing it from the list does not delete it):
```bash
docker exec -it gbsmtp-prd setup email del support@goldnpay.in
```

## Connecting clients and apps

| | Value |
|---|---|
| IMAP | `mail.goldbucks.org`, port 993, SSL/TLS |
| SMTP | `mail.goldbucks.org`, port 465 SSL/TLS or 587 STARTTLS, authentication on |
| Username | full email address |

For UAT use `mail-uat.goldbucks.org`. Every domain uses the same host name, because the certificate covers the mail host and not each domain.

App example (Node.js / Nodemailer):
```js
nodemailer.createTransport({
  host: process.env.SMTP_HOST,          // mail.goldbucks.org | mail-uat.goldbucks.org
  port: 465, secure: true,
  auth: { user: process.env.SMTP_USER,  // no-reply@goldnpay.in | test@uatmail.goldnpay.in
          pass: process.env.SMTP_PASS },
});
```
Spoof protection is on, so an account can only send as its own address or its aliases.

## Deliverability checklist

- [ ] A record for the mail host and PTR record both point to each other
- [ ] MX, SPF, DKIM and DMARC records published for every domain (`dns/<env>-dns-records.txt`)
- [ ] [mail-tester.com](https://www.mail-tester.com) score of 9/10 or better
- [ ] Gmail "Show original" shows SPF, DKIM and DMARC as PASS
- [ ] Server IP not listed on [MXToolbox blacklist check](https://mxtoolbox.com/blacklists.aspx)
- [ ] Sending volume ramped up gradually on a new IP
- [ ] After about 2 clean weeks, move `DMARC_POLICY` from `none` to `quarantine`, then `reject`, and re-publish

## Backups

`data/<env>/` holds everything: mail (Maildir), accounts, aliases, DKIM keys and the queue.
Restarting or recreating the container loses nothing. Losing the disk loses everything, so schedule
`scripts/backup.sh` with cron and copy `BACKUP_DIR` off the server.
