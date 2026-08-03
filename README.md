# aws-ssm.el

A Magit-style interface for AWS SSM sessions in Emacs. Declare your bastion
port-forwards and shell sessions once, then open them from a status buffer that
shows what is currently running.

```
AWS SSM   SSO valid 7h 12m

Active sessions (1)
  ● postgres-dev            localhost:5432      up 12m

myapp (3)
  ● postgres-dev            myapp-dev           5432 → db-0.cluster-abc:5432
    postgres-prod           myapp-prod          5432 → db-0.cluster-xyz:5432
    bastion-shell           myapp-dev           shell

? help   RET connect   k kill   r restart   c copy url   g refresh
```

## Requirements

- Emacs 29.1+
- `transient` (bundled with Emacs 29+)
- The AWS CLI v2 and the `session-manager-plugin`

## Installation

Clone the repository and put it on your `load-path`:

```elisp
(use-package aws-ssm
  :load-path "~/src/div/elisp-aws"
  :commands (aws-ssm))
```

## Configuration

Connections are plists in `aws-ssm-connections`:

```elisp
(setq aws-ssm-connections
      '((:name "postgres-dev"
         :group "myapp"
         :profile "myapp-dev"
         :type remote-port
         :bastion-tag "myapp-bastion"
         :host "db-0.cluster-abc.eu-west-1.rds.amazonaws.com"
         :port 5432
         :local-port 5432)

        (:name "bastion-shell"
         :group "myapp"
         :profile "myapp-dev"
         :type shell
         :bastion-tag "myapp-bastion")))
```

### Connection keys

| Key | Meaning |
| --- | --- |
| `:name` | Unique identifier. Required. |
| `:profile` | AWS CLI profile. Required. |
| `:type` | `remote-port`, `local-port`, `shell` or `document`. Defaults to `shell`. |
| `:group` | Grouping in the status buffer. Defaults to `"other"`. |
| `:region` | Defaults to `aws-ssm-default-region`. |
| `:bastion-tag` | Value of the target instance's `Name` tag. |
| `:filters` | Extra EC2 filters as an alist of `(NAME . VALUE)`, for targets not found by their `Name` tag. |
| `:instance-id` | Target this instance directly, skipping the lookup. |
| `:host` | Remote host to forward to (`remote-port`). |
| `:port` | Remote port to forward to. |
| `:local-port` | Local port to bind. Defaults to `:port`. |
| `:document` | SSM document name. Required for `document`; overrides the default document otherwise. |
| `:reason` | Passed to `aws ssm start-session --reason`. |
| `:url-scheme` | Scheme used by the copy-URL command. Inferred from the local port when omitted. |
| `:desc` | Free-form description shown instead of the generated one. |

### Connection types

- **`remote-port`** — forwards a local port to a host reachable from the
  bastion, via `AWS-StartPortForwardingSessionToRemoteHost`. Use for RDS,
  DocumentDB, ElastiCache.
- **`local-port`** — forwards a local port to a port on the target instance
  itself, via `AWS-StartPortForwardingSession`.
- **`shell`** — an interactive shell on the instance.
- **`document`** — runs a custom SSM document.

## Usage

`M-x aws-ssm` opens the status buffer. Point at a connection and act on it;
`?` opens the transient with every action.

| Key | Action |
| --- | --- |
| `?` | Transient menu |
| `RET` / `c` | Connect |
| `p` | Connect, prompting for a local port |
| `h` | Connect, prompting for a remote host |
| `P` | Connect, prompting for a remote port |
| `k` / `K` | Kill session / kill all sessions |
| `r` | Restart session |
| `b` | Show the session buffer |
| `y` | Copy a client URL for the forwarded port |
| `d` | Describe the connection |
| `L` | `aws sso login` for a profile |
| `s` / `S` | Set / clear the current login |
| `F` | Clear the instance-ID cache |
| `g` | Refresh (also clears the cache) |
| `TAB` | Fold the group at point |

The transient also carries the overrides as infixes (`-l` local port, `-p`
remote port, `-h` remote host, `-P` profile), so you can set one and then
connect without a prompt.

Each session runs in its own `comint` buffer named `*aws-ssm: NAME*`. Shell
sessions are displayed automatically; port forwards stay in the background
unless `aws-ssm-pop-to-session-buffer` is non-nil. Killing a session sends
`SIGINT` first so the CLI can tear down the `session-manager-plugin` child,
falling back to `SIGKILL` after two seconds.

## Instance resolution

The target instance is resolved with `aws ec2 describe-instances` at connect
time and cached per profile, region and filter set for
`aws-ssm-instance-cache-ttl` seconds (one hour by default). `g` refreshes the
view and drops the cache; `F` drops the cache alone.

Lookups are restricted to instances in the `running` state, so a recently
terminated instance — which lingers in the EC2 API for about an hour — is not
picked as the target. Set `aws-ssm-require-running-instance` to nil to disable
this.

## Credentials

The header shows the current login and how long the cached SSO token is still
valid:

```
AWS SSM   login sl18-prod   SSO valid 7h 12m
```

The expiry is read from `~/.aws/sso/cache` without making a network call. When
a lookup fails in a way that looks like expired credentials, you are offered
`aws sso login` for the relevant profile; `L` runs it on demand.

### Current login

The current login is simply the profile you last logged in with via `L`, or
picked explicitly with `s`. It is remembered across restarts in
`aws-ssm-login-state-file` (`~/.cache/aws-ssm/login` by default); set that to
nil to keep it for the current Emacs session only, and `S` forgets it.

This is a label, not a mode: connections always use their own `:profile`
regardless of which login is shown. Nothing is queried from AWS to produce it,
so it reflects what you chose rather than what the CLI would resolve.

## Evil users

The mode uses single-letter bindings in the style of Magit. With Evil, put the
status buffer in Emacs state so they are reachable:

```elisp
(evil-set-initial-state 'aws-ssm-mode 'emacs)
```
