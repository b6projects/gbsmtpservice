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
| Data (`DATA_ROOT`) | `/root/projects/gbsmtpservice/prd/` | `/root/projects/gbsmtpservice/uat/` |
| Passwords | `/root/projects/gbsmtpservice/prd/secrets/credentials.txt` | `/root/projects/gbsmtpservice/uat/secrets/credentials.txt` |

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
  passwd.sh               change / reset a mailbox password
  add-mailbox.sh          add a mailbox on an existing domain
  suspend.sh              suspend / resume a mailbox, list suspended
  backup.sh               backup data + keys + credentials
```

Runtime data lives **outside the code checkout**, in each environment's `DATA_ROOT` folder (PRD: `/root/projects/gbsmtpservice/prd`, UAT: `/root/projects/gbsmtpservice/uat`), so a
Jenkins workspace wipe or a fresh `git clone` never touches mail:

```
$DATA_ROOT/
  mail-data/          mailboxes (Maildir)
  mail-state/         queue, spam-filter state
  mail-logs/          delivery logs
  config/             accounts, aliases, DKIM keys, Rspamd config
  secrets/            generated mailbox passwords (root only)
  dns-records.txt     DNS records to publish
```

## Server requirements

- Linux VPS (Ubuntu 22.04/24.04 recommended), 2 GB RAM minimum (4 GB+ to enable ClamAV)
- Docker Engine + Docker Compose v2, `openssl`, `curl` (`certbot`, plus its nginx plugin when nginx owns port 80, is installed by setup if missing)
- **Outbound port 25 open.** AWS, GCP and Azure block it, and DigitalOcean usually does until you file a ticket. Hetzner, OVH and Contabo are fine.
- A static public IPv4 with **reverse DNS (PTR)** set to the mail host name
- Firewall inbound: `25, 80 (certificate issuance/renewal), 465, 587, 993`
- One server/IP per environment. Only one server can receive on port 25 per IP.

## Deploy

```bash
# On the server (any checkout location works, e.g. /opt/gbsmtpservice or a Jenkins workspace)
sudo git clone <repo-url> /opt/gbsmtpservice && cd /opt/gbsmtpservice

# 1. Create the A record for the mail host FIRST (needed for the TLS certificate)
#    PRD: mail.goldbucks.org     -> <PRD server IP>
#    UAT: mail-uat.goldbucks.org -> <UAT server IP>

# 2. Validate
./scripts/build.sh --pull

# 3. Set up the environment (certificate, mailboxes, aliases, DKIM, start, DNS sheet)
sudo ./scripts/setup.sh prd        # or: uat

# 4. Publish everything in /root/projects/gbsmtpservice/prd/dns-records.txt at each domain's registrar
# 5. Set the PTR record in the VPS provider panel
# 6. Collect the passwords
sudo cat /root/projects/gbsmtpservice/prd/secrets/credentials.txt
```

## Day-to-day

```bash
./scripts/status.sh prd                  # health, mailboxes, queue, cert, logs
./scripts/start.sh prd --restart         # restart
./scripts/start.sh prd --pull            # upgrade docker-mailserver
./scripts/stop.sh prd                    # stop (mail is kept in /root/projects/gbsmtpservice/prd)
./scripts/dns-records.sh prd             # reprint DNS records
sudo ./scripts/backup.sh prd             # backup to BACKUP_DIR
```

### Mailbox administration (run on the server as root)

| Task | Command |
|---|---|
| Change / reset a password (prompts) | `bash scripts/passwd.sh prd support@goldnpay.in` |
| Reset to a random password (shown once) | `bash scripts/passwd.sh prd support@goldnpay.in --generate` |
| Add a mailbox (random password) | `bash scripts/add-mailbox.sh prd accounts@goldnpay.in` |
| Add a mailbox with your own password and a quota | `bash scripts/add-mailbox.sh prd accounts@goldnpay.in --password --quota 10G` |
| Suspend (login blocked, mail still arrives) | `bash scripts/suspend.sh prd service@goldnpay.in` |
| Suspend and bounce new incoming mail | `bash scripts/suspend.sh prd service@goldnpay.in --block-incoming` |
| Resume (same password as before) | `bash scripts/suspend.sh prd service@goldnpay.in --resume` |
| List suspended mailboxes | `bash scripts/suspend.sh prd --list` |
| Change one mailbox's quota | `docker exec gbsmtp-prd setup quota set support@goldnpay.in 10G` |
| Delete a mailbox permanently | `docker exec -it gbsmtp-prd setup email del support@goldnpay.in` |

- Every change is live within a few seconds, with no restart. Password changes and suspensions also end open IMAP sessions.
- New and changed passwords are recorded in `$DATA_ROOT/secrets/credentials.txt`.
- `add-mailbox.sh` only works on domains this environment already serves. **For a new domain**, add the address to `config/<env>/mailboxes.txt`, commit, and run `setup.sh`, which also creates the DKIM key and the DNS records.
- After `add-mailbox.sh`, add the address to `config/<env>/mailboxes.txt` in git too, so the list stays the source of truth. `setup.sh` warns about mailboxes that exist on the server but not in the list.
- A suspended mailbox keeps its mail and password. Its password can't be changed until it is resumed.

### Fail2ban allow-list

Fail2ban bans an IP after repeated failed logins. Attackers are banned as normal, but so is an
admin PC or app with a wrong password. Addresses in `FAIL2BAN_IGNOREIP` (in `env/<env>.env`) are
never banned. The server's own IP, localhost and private/Docker networks are always added.

```bash
# env/prd.env  (space-separated, keep the quotes)
FAIL2BAN_IGNOREIP="49.206.9.75 203.0.113.0/24"
```
Commit, pull on the server, then run `bash scripts/setup.sh prd`. It rewrites `config/fail2ban-jail.cf`
and restarts the container only if the list changed.

```bash
docker exec gbsmtp-prd setup fail2ban                 # list banned IPs
docker exec gbsmtp-prd setup fail2ban unban <ip>      # lift a ban
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
- [ ] MX, SPF, DKIM and DMARC records published for every domain (`$DATA_ROOT/dns-records.txt`)
- [ ] [mail-tester.com](https://www.mail-tester.com) score of 9/10 or better
- [ ] Gmail "Show original" shows SPF, DKIM and DMARC as PASS
- [ ] Server IP not listed on [MXToolbox blacklist check](https://mxtoolbox.com/blacklists.aspx)
- [ ] Sending volume ramped up gradually on a new IP
- [ ] After about 2 clean weeks, move `DMARC_POLICY` from `none` to `quarantine`, then `reject`, and re-publish

## TLS certificate

`setup.sh` gets a Let's Encrypt certificate for the mail host. With `CERT_METHOD=auto` (the default),
it uses certbot's **nginx** plugin when nginx already serves port 80, which leaves your other sites
untouched (certonly mode answers the challenge without editing site configs). Otherwise it uses
**standalone** mode. Renewal is automatic, and a deploy hook restarts the mail container afterwards.

## Backups

`$DATA_ROOT/` holds everything: mail (Maildir), accounts, aliases, DKIM keys, passwords and the queue.
Restarting or recreating the container loses nothing. Losing the disk loses everything, so schedule
`scripts/backup.sh` with cron and copy `BACKUP_DIR` off the server.
