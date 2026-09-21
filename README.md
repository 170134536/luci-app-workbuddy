# luci-app-workbuddy

A LuCI application for OpenWrt 25.12+ that turns the router into a small
**OpenAI-compatible relay for WorkBuddy models**, so every device on the LAN
can use them without installing anything.

- Web UI to log in to WorkBuddy and obtain / refresh the access token
- Free-models-only mode by default, with an option to also relay paid models
- OpenAI-compatible `/v1/models` and `/v1/chat/completions`, streaming included
- No Node.js, no extra daemons: shell + `ucode`, both already in the firmware
- Optional share token so only devices you choose can use the relay

## Quick install

Download the `.apk` from [Releases](../../releases/latest), copy it to the
router, and install it:

```sh
scp luci-app-workbuddy-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/luci-app-workbuddy-*.apk'
```

Then open **Services → WorkBuddy** in LuCI and click **Log in to WorkBuddy**.

> Built for `aarch64_cortex-a53` (IPQ6000). See
> [Building the package](#building-the-package) to target another architecture.

## Requirements

| | |
|---|---|
| Firmware | OpenWrt 25.12+ / ImmortalWrt with the APK package manager |
| Architecture | `aarch64_cortex-a53` for IPQ6000 (rebuild with `--arch` for others) |
| Packages | `ucode`, `ucode-mod-uloop`, `ucode-mod-socket`, `curl`, `luci-base` |
| Network | The router itself must be able to reach `www.workbuddy.ai` |

## Install from a local file

```sh
apk add --allow-untrusted /tmp/luci-app-workbuddy-1.0.0-r1.apk
```

`--allow-untrusted` is required because this package is self-built and
therefore unsigned. That is the documented path for local packages — see the
[OpenWrt apk docs](https://openwrt.org/docs/guide-user/additional-software/apk).

Then open **Services → WorkBuddy** in LuCI.

## Getting a token

The relay needs a WorkBuddy access token. The page offers two ways:

1. **Log in to WorkBuddy** — requests an auth URL from WorkBuddy, opens it, and
   polls until you finish logging in. The token is then stored in UCI.
2. **Paste a token** — if you already have one, paste it into the Token field.

From the command line:

```sh
workbuddy-ctl login-start          # prints {state, authUrl}
workbuddy-ctl login-poll           # poll until it returns a token
workbuddy-ctl set-token <token>    # or set one directly
```

## Using the relay

Point any OpenAI-compatible client at the router:

```
Base URL:  http://<router-ip>:8789/v1
API key:   (leave empty, or the share token if you set one)
```

List the models:

```sh
curl http://<router-ip>:8789/v1/models
```

Chat:

```sh
curl http://<router-ip>:8789/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","stream":true,
       "messages":[{"role":"system","content":"You are helpful."},
                   {"role":"user","content":"hi"}]}'
```

> WorkBuddy only serves streaming responses, and requires the first message to
> be a `system` message. The relay handles both, but a non-streaming client
> will receive an SSE body it must parse.

## Endpoints

| Path | Purpose |
|---|---|
| `GET /v1/models` | Exposed models, filtered by the free-only setting |
| `GET /models/refresh` | Bypass the 6-hour catalogue cache |
| `POST /v1/chat/completions` | Relay a chat completion (streaming) |
| `GET /status` | Relay state as JSON |
| `GET /login/start` | Begin the web login flow |
| `GET /login/poll?state=…` | Poll once for the resulting token |

## Configuration

`/etc/config/workbuddy`:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `0` | Start the relay on boot |
| `listen_host` | `0.0.0.0` | `127.0.0.1` restricts it to the router |
| `listen_port` | `8789` | Listen port |
| `access_token` | — | WorkBuddy token, filled in by the login flow |
| `endpoint` | `https://www.workbuddy.ai` | Upstream base URL |
| `client_version` | `5.5.2` | Sent as `WorkBuddy/<ver>`; the catalogue API rejects unknown UAs |
| `free_only` | `1` | Expose only models that are currently free |
| `share_token` | — | When set, `/v1/*` requires `Authorization: Bearer <this>` |
| `debug` | `0` | Verbose logging to the system log |

## Command-line helper

```sh
workbuddy-ctl status        # JSON state
workbuddy-ctl login-start   # begin login
workbuddy-ctl login-poll    # poll for the token
workbuddy-ctl set-token ...  # set a token
workbuddy-ctl clear-token   # forget the token
workbuddy-ctl models        # list exposed models
workbuddy-ctl url           # print the LAN base URL
```

## Building the package

APK v3 is not a tar archive — it is a binary `ADB` container, so a package
cannot be assembled with `tar`. Two supported routes:

### On Windows or any host with Python 3 (no Linux required)

```
python make-package.py
python make-package.py --arch aarch64_cortex-a53
python make-package.py --debug          # skip compression, for inspection
```

`mkapk.py` implements the ADB container directly. Verify it with its own
self-test, which round-trips a synthetic package:

```
python mkapk.py
```

### As part of a firmware image

Drop the directory into the buildroot's `package/` and compile it there; the
included `Makefile` covers that route and works for both opkg and apk output
formats.

## Files installed

```
/etc/config/workbuddy                              UCI configuration (preserved on upgrade)
/etc/init.d/workbuddy                              procd service
/usr/bin/workbuddy-server                          service entry point
/usr/bin/workbuddy-ctl                             CLI helper
/usr/share/workbuddy/workbuddy.uc                  the relay itself
/usr/share/luci/menu.d/luci-app-workbuddy.json     menu registration
/usr/share/rpcd/acl.d/luci-app-workbuddy.json      ACL
/www/luci-static/resources/view/workbuddy/relay.js the LuCI page
```

## Notes and limitations

- The relay streams by closing the socket at end of response, so clients must
  tolerate a `Connection: close` event stream (all common OpenAI SDKs do).
- Tokens expire. When requests start returning 401, run the login flow again.
- The model catalogue is cached for 6 hours; `/models/refresh` forces a refetch.
- Free/paid is decided by the `credits` field: `0` means free. A missing or
  empty value is *unrated* and is deliberately not treated as free.

## Licence

MIT
