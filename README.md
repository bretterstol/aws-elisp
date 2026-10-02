# aws-ssm.el

A Magit-style interface for AWS SSM sessions in Emacs. Pick a profile, see its
running EC2 instances, and connect to one — a real shell by default, or a port
forward when you give a port.

```
AWS SSM   profile myapp-dev (eu-west-1)   SSO valid 7h 12m

Active sessions (2)
  ● myapp-bastion  localhost:5432 → db-0.cluster-abc:5432    up 12m
  ● myapp-worker   shell                                     up 3m

Instances (3)
  ● myapp-bastion            i-0a1b2c3d4e5f60718   t3.micro   10.0.1.14
  ● myapp-worker             i-04f3e2d1c0b9a8877   t3.small   10.0.2.31
    myapp-batch              i-0997e6d5c4b3a2211   m5.large   10.0.2.87

? help   RET shell   p port   o host   D database   x kill   P profile   g r refresh
```

There is nothing to declare up front. The only thing aws-ssm cares about is
which profile you are using.

## Requirements

- Emacs 29.1+
- `transient` (bundled with Emacs 29+)
- [`vterm`](https://github.com/akermu/emacs-libvterm) — for shell sessions, unless
  you send them to iTerm2 with `aws-ssm-shell-display`
- The AWS CLI v2 and the `session-manager-plugin`

## Installation

Clone the repository and put it on your `load-path`:

```elisp
(use-package aws-ssm
  :load-path "~/src/div/elisp-aws"
  :commands (aws-ssm))
```

## Usage

`M-x aws-ssm` opens the status buffer. It lists the running EC2 instances of
the current profile, with the sessions you have open above them. Point at an
instance and act on it; `?` opens the transient with every action.

| Key | Action |
| --- | --- |
| `?` | Transient menu |
| `RET` / `c` | Connect — a shell, or a port forward if the transient arguments carry a port |
| `p` | Forward a port on the instance, prompting for remote and local port |
| `o` | Forward through the instance to another host, prompting for host and ports |
| `D` | Forward to an RDS or DocumentDB database discovered in AWS — no host or port to type |
| `x` / `X` | Kill the session at point / kill all sessions |
| `r` | Restart the session at point |
| `s` | Show the session buffer |
| `y` | Copy a client URL for a forwarded port |
| `d` | Describe the instance at point |
| `P` | Switch profile |
| `L` | `aws sso login` for a profile |
| `g r` | Refresh the instance list |
| `g R` | Clear the instance and database caches |
| `q` | Quit the window |

## Connecting

**Without a port you get a shell.** It runs in a `vterm` buffer, so it is a
real terminal: tab-completion, colours and full-screen programs behave as they
would anywhere else. Shell buffers are named `*aws-ssm shell: NAME*` and are
displayed as soon as the session starts.

Where they are displayed is `aws-ssm-shell-display`:

- `frame` (the default) — the shell gets a GUI frame of its own, named after
  the instance, so a full-screen terminal never rearranges the windows you were
  working in. The frame is deleted again when the session ends. On a terminal
  Emacs this falls back to `window`.
- `window` — the buffer is displayed in the selected frame, like any other.
- `iterm` — the session is handed to iTerm2 in a new window instead of running
  inside Emacs. Those sessions belong to iTerm2, so they are neither listed in
  the status buffer nor killable from it; quit the shell to end them.

`aws-ssm-shell-frame-parameters` are the frame parameters `frame` uses,
`((width . 132) (height . 43))` by default. Its `name` is the instance the
shell runs on unless you set one there yourself.

**With a port you get a forward**, running quietly in a comint buffer named
`*aws-ssm forward: NAME:PORT*`. Set `aws-ssm-pop-to-session-buffer` to non-nil
if you want it displayed too. Two flavours, chosen by whether you supply a
host:

- **Port only** — `AWS-StartPortForwardingSession`, forwarding your local port
  to that port on the instance itself.
- **Port and host** — `AWS-StartPortForwardingSessionToRemoteHost`, with the
  instance acting as a bastion to somewhere else in the VPC. Use this for RDS,
  DocumentDB, ElastiCache. `o` prompts for both.

The local port defaults to the remote port.

## Databases

`D` removes the typing from the common case. It lists the databases of the
current profile and forwards to the one you pick, through the instance at
point, taking both the host and the port from AWS:

```
Database through myapp-bastion:
  docdb     myapp-mongo (reader)      myapp-mongo.cluster-ro-xyz    27017
  docdb     myapp-mongo (writer)      myapp-mongo.cluster-xyz       27017
  mariadb   wiki                      wiki.abc123                    3306
  mysql     legacy-billing (writer)   legacy.cluster-x1              3306
  postgres  legacy-reports            legacy-reports.abc123          5432
  postgres  myapp-db (reader)         myapp-db.cluster-ro-abc        5432
  postgres  myapp-db (writer)         myapp-db.cluster-abc           5432
```

Three listings feed it: `aws rds describe-db-clusters`, `aws docdb
describe-db-clusters` and `aws rds describe-db-instances` — so **Aurora
clusters, DocumentDB clusters and standalone RDS instances** all appear. Both
endpoints of a cluster are offered, labelled `writer` and `reader`, so you can
send heavy read queries to a replica deliberately; a standalone instance has
one endpoint and no label. The local port is the database's own port,
unprompted: Postgres lands on `localhost:5432`, MySQL on `localhost:3306`.

Nothing is listed twice. Instances that belong to a cluster are dropped from
the instance listing, since the cluster already covers them behind the endpoint
you actually want, and DocumentDB and Neptune are filtered out of the RDS
results. **ElastiCache is not queried** — use `o` for Redis.

The listing is cached per profile and region for the same
`aws-ssm-instance-cache-ttl` as the instances, and `g R` clears both caches.
Unlike the instance list it is fetched synchronously, since you are waiting on
the prompt; expect a second or two on the first use in a region, for the three
calls. If one listing fails — a missing `docdb:DescribeDBClusters` permission,
say — the others are still shown and you get a note in the echo area naming
what could not be read.

The transient carries the same three values as sticky infixes — `-p` remote
port, `-l` local port, `-h` remote host — so you can set them once and then
connect with `RET` without any prompt. Leave them empty for a shell.

One shell and any number of forwards can run against the same instance at once;
each session is identified by the instance plus its local port. Killing a
session sends `SIGINT` first so the CLI can tear down the
`session-manager-plugin` child, falling back to `SIGKILL` after two seconds.

## Profiles

Profiles are read from `~/.aws/config` (`aws-ssm-config-file`) — both `[profile
NAME]` sections and a plain `[default]`. A profile's `region` is used when it
declares one, otherwise `aws-ssm-default-region` applies.

`P` switches profile and reloads the instance list. Your choice is remembered
across restarts in `aws-ssm-profile-state-file`
(`~/.cache/aws-ssm/profile` by default); set that to nil to keep it for the
current Emacs session only.

## Instances

The list comes from `aws ec2 describe-instances`, filtered to instances in the
`running` state, showing the `Name` tag, instance ID, instance type and private
IP. It is fetched asynchronously and cached per profile and region for
`aws-ssm-instance-cache-ttl` seconds (one hour by default). `g r` fetches it
again; `g R` drops the cache without fetching.

Instances without the SSM agent are not filtered out — they appear in the list
but connecting to them will fail.

## Credentials

The header shows the current profile, its region, and how long the cached SSO
token is still valid:

```
AWS SSM   profile myapp-dev (eu-west-1)   SSO valid 7h 12m
```

The expiry is read from `~/.aws/sso/cache` without making a network call. When
a call fails in a way that looks like expired credentials, you are offered
`aws sso login` for that profile; `L` runs it on demand.

## Other options

| Variable | Meaning |
| --- | --- |
| `aws-ssm-executable` | Name of, or path to, the AWS CLI. Defaults to `"aws"`. |
| `aws-ssm-default-region` | Region for profiles that do not declare one. |
| `aws-ssm-shell-display` | Where a shell session is shown: `frame`, `window` or `iterm`. See [Connecting](#connecting). |
| `aws-ssm-shell-frame-parameters` | Frame parameters used by `aws-ssm-shell-display` `frame`. |
| `aws-ssm-abbreviate-hosts` | Shorten AWS service suffixes of forwarded hosts in the status buffer. The full host is always used when connecting. |
| `aws-ssm-sso-cache-directory` | Where the AWS CLI keeps cached SSO tokens. |

## Evil users

Evil is supported out of the box — nothing to configure, and nothing changes
for anyone not using it. When Evil is loaded, the status buffer opens in
**motion state** and its keymap is marked as overriding, so the single-letter
bindings above win over Evil's own:

| Key | Behaviour under Evil |
| --- | --- |
| `j` / `k`, `C-d` / `C-u`, `/` `n` `N` | Motion state as usual |
| `g g` / `G` | First / last line — rebound explicitly, see below |
| `?` | `aws-ssm` transient, not `evil-search-backward` |
| `c` `d` `p` `x` `y` `r` `s` | The `aws-ssm` commands; motion state has no operators, so nothing is lost |

The one casualty is Evil's `g` map, which `g r` and `g R` displace. `g g` and
`G` are rebound in the buffer to `evil-goto-first-line` and `evil-goto-line`;
the rarer `g j`, `g k`, `g 0`, `g _` are not available there.

To use a different state instead, override it after loading `aws-ssm`:

```elisp
(with-eval-after-load 'aws-ssm
  (evil-set-initial-state 'aws-ssm-mode 'emacs))
```
