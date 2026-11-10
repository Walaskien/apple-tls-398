# Why Safari rejects your internal certificate (and Chrome doesn't)

[![ci](https://github.com/Walaskien/apple-tls-398/actions/workflows/ci.yml/badge.svg)](https://github.com/Walaskien/apple-tls-398/actions/workflows/ci.yml)

A trusted private CA is not enough. Apple's TLS stack rejects any server certificate
whose validity period exceeds **398 days**, and it does so *after* the chain has been
verified — so the failure looks nothing like a trust problem.

This repository explains the failure mode, shows how to confirm it in under a minute,
and gives a working `cert-manager` configuration that avoids it.

## The symptom

A single-page app is served from an internal domain over a private CA. The browser
loads the UI fine, but signing in silently fails. The server log is the confusing part:

```
INFO  OauthController : Success login by basic auth from 10.x.x.x
```

The login *succeeded*. The server issued a token. Yet the browser behaves as if nothing
happened, and no further API request ever arrives.

The reason is that the UI and the API live on different hostnames — say `app.example.internal`
and `api.example.internal`. The user clicked through a certificate warning for the first one.
The second one never gets a warning, because **browsers do not prompt on XHR/fetch** — they
fail the request silently. The response is discarded before any JavaScript sees it.

## The part that surprises people

The obvious fix is to install the internal root CA on the client. That is necessary, but on
Apple platforms it is often not sufficient, and the reason is a policy rather than a trust
decision.

Since September 2020, Apple rejects TLS server certificates valid for more than 398 days:

> TLS server certificates issued on or after September 1, 2020 must not have a validity
> period greater than 398 days. Connections to TLS servers violating these requirements
> will fail.
>
> — [Apple Support HT211025](https://support.apple.com/en-us/HT211025)

The failure surfaces as `errSSLXCertChainInvalid` (`-9807`), or `NSURLErrorServerCertificateUntrusted`
(`-1202`) at the URLSession layer. Both read like "the chain is broken", which sends you
looking at the CA — the one thing that is actually fine.

Chrome and Firefox enforce the same limit, but **exempt locally-installed roots**. So an
internal PKI with long-lived leaf certificates works on Windows, works in Chrome, works in
Firefox — and fails only on Macs and iPhones. That asymmetry is what makes it hard to spot.

## Confirming it in one minute

`curl` is a poor witness here. On macOS it validates against `/etc/ssl/cert.pem`, not the
system keychain, so it keeps failing even after the CA is correctly trusted:

```console
$ curl -sv https://app.example.internal 2>&1 | grep CAfile
*  CAfile: /etc/ssl/cert.pem
```

Use `nscurl` instead — it goes through `NSURLSession` and therefore the same trust
evaluation Safari uses:

```console
$ nscurl https://app.example.internal
Load failed with error: ... Code=-1202 "The certificate for this server is invalid."
```

Then check the validity period directly. [`check-cert-validity.sh`](check-cert-validity.sh)
does this for any host:

```console
$ ./check-cert-validity.sh app.example.internal
app.example.internal:443
  not before : 2026-08-13
  not after  : 2036-08-10
  validity   : 3650 days
  FAIL — exceeds Apple's 398-day limit; Safari and iOS will reject this certificate
```

If `openssl verify` succeeds against your CA while Apple clients still refuse the
connection, the validity period is almost always the reason:

```console
$ openssl verify -CAfile ca.pem leaf.pem
leaf.pem: OK
```

A cryptographically valid chain that Apple rejects is the signature of a policy failure,
not a trust failure.

## The fix

Shorten the **leaf** certificates. Leave the root CA alone — the 398-day limit applies to
server certificates, not to CAs, and a long-lived root is exactly what you want: clients
install it once and never think about it again.

With `cert-manager`, that is a two-field change. See
[`examples/certificate.yaml`](examples/certificate.yaml):

```yaml
spec:
  duration: 8760h    # 365 days — comfortably under the 398-day limit
  renewBefore: 1440h # renew 60 days before expiry
```

`renewBefore` must be smaller than `duration`, or the resource is rejected. This is easy to
miss when shortening an existing certificate that was issued for years: its old
`renewBefore` is usually larger than the new `duration`.

Applying it:

```console
$ kubectl -n <namespace> patch certificate <name> --type merge \
    -p '{"spec":{"duration":"8760h","renewBefore":"1440h"}}'
```

cert-manager reissues immediately and renews on its own from then on. Ingress controllers
pick the new secret up without a restart.

### Choosing a duration

cert-manager's own default is 90 days, following the Let's Encrypt convention. That is a
good default when renewal is monitored.

For a small internal deployment, 365 days can be the better tradeoff. The reasoning is
about failure modes rather than security: if cert-manager stops working and nobody notices,
90-day certificates take the estate down within a quarter, while 365-day certificates leave
roughly a year to catch it. Pick the shorter interval when you have alerting on certificate
expiry, and the longer one when you do not.

Either way, renewal is automatic and clients need nothing: the leaf rotates underneath a
root they already trust. Distributing the root is a one-time job.

## Checklist

- [ ] Leaf certificate validity ≤ 398 days (365 is a safe, round choice)
- [ ] `renewBefore` < `duration`
- [ ] Root CA installed on every Apple client — for iOS, ship it inside the same
      `.mobileconfig` as any VPN profile so both install in one tap
- [ ] On macOS, trust the root with an explicit policy, or the trust settings come out empty:
      `sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain ca.pem`
- [ ] Verify with `security dump-trust-settings -d` — the settings count must not be 0
- [ ] Test with `nscurl`, never with `curl`

## References

- [Apple: Requirements for trusted certificates in iOS 13 and macOS 10.15](https://support.apple.com/en-us/HT210176)
- [Apple: About upcoming limits on trusted certificates](https://support.apple.com/en-us/HT211025)
- [cert-manager: Certificate resource](https://cert-manager.io/docs/usage/certificate/)

## Verified

| Check | Result |
|---|---|
| `bash -n` and `shellcheck` on `check-cert-validity.sh` | clean |
| Script against a local TLS server with a 500-day certificate | `validity: 500 days`, FAIL, exit code 1 |
| Script against a public server with a 90-day certificate | OK, exit code 0 |
| GitHub Actions (`ci`) | see the badge; the job repeats the 500-day and 90-day checks with local test certificates |

Not verified: the `Certificate` example against a live cert-manager in this repository (it is exercised in [single-node-k8s-platform](https://github.com/Walaskien/single-node-k8s-platform)), and Safari or iOS behaviour on a device.

## Limitations

- The script reads the server certificate only; it does not check chain trust or the Subject Alternative Names.
- The 398-day figure is Apple's published limit for newly issued server certificates; check the current Apple documentation before relying on it.

## Related

- [single-node-k8s-platform](https://github.com/Walaskien/single-node-k8s-platform): uses 365-day leaf certificates from cert-manager.
- [dual-homed-routing](https://github.com/Walaskien/dual-homed-routing): another short write-up of a failure that looks like one thing and is another.

## License

MIT — see [LICENSE](LICENSE).
