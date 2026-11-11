# Why Safari rejects your internal certificate (and Chrome doesn't)

[![ci](https://github.com/Walaskien/apple-tls-398/actions/workflows/ci.yml/badge.svg)](https://github.com/Walaskien/apple-tls-398/actions/workflows/ci.yml)

Apple clients reject TLS server certificates with a very long validity, even when the private
CA that issued them is installed and trusted. The failure looks like a trust problem and is
not one. This repository describes the symptom, a script that shows the validity period of a
server certificate, and a `cert-manager` example with a 365-day leaf.

The repository name refers to the 398-day limit. Read the next section before relying on
that number for a private CA.

## Which limit applies

Apple documents two limits on TLS server certificates:

- **825 days** for certificates issued after 1 July 2019 (iOS 13, macOS 10.15),
  [HT210176](https://support.apple.com/en-us/103769). The page does not exempt private CAs.
- **398 days** for certificates issued on or after 1 September 2020,
  [HT211025](https://support.apple.com/en-us/102028). The same page says: "This change will
  not affect certificates issued from user-added or administrator-added Root CAs."

So for an internal CA the 398-day figure is not the rule Apple states, and 825 days is the
limit to stay under. A 10-year leaf is over both. 365 days is under both, and it is what the
example uses. I have not reproduced the failure on a device in this repository, so I cannot
say from here which of the two checks fired in the original case (see Verified).

## The symptom

A single-page app is served from an internal domain over a private CA. The browser loads the
UI, but signing in silently fails. The server log is the confusing part:

```
INFO  OauthController : Success login by basic auth from 10.x.x.x
```

The login succeeded and the server issued a token, yet the browser behaves as if nothing
happened and no further API request arrives.

The UI and the API live on different hostnames, say `app.example.internal` and
`api.example.internal`. The user clicked through a certificate warning for the first one. The
second never gets a warning, because browsers do not prompt on XHR/fetch, they fail the
request silently and the response is discarded before any JavaScript sees it.

Installing the internal root CA on the client is necessary. In the case this repository comes
from it was not enough: the leaf certificates had a 10-year validity, and Apple clients kept
refusing them until they were reissued with a 365-day validity.

Errors seen on Apple platforms for this kind of failure: `errSSLXCertChainInvalid` (`-9807`),
or `NSURLErrorServerCertificateUntrusted` (`-1202`) at the URLSession layer. Both read like
"the chain is broken", which sends you looking at the CA, the part that is fine.

Chrome applies its own limit only to publicly trusted certificates and exempts locally
installed roots, which is one reason an internal PKI with long-lived leaves can work on
Windows and in Chrome and still fail on Macs and iPhones.

## Confirming it

`curl` is a poor witness on macOS: it validates against `/etc/ssl/cert.pem`, not the system
keychain, so it keeps failing even after the CA is correctly trusted:

```console
$ curl -sv https://app.example.internal 2>&1 | grep CAfile
*  CAfile: /etc/ssl/cert.pem
```

Use `nscurl` instead. It goes through `NSURLSession`, the same trust evaluation Safari uses:

```console
$ nscurl https://app.example.internal
Load failed with error: ... Code=-1202 "The certificate for this server is invalid."
```

Then check the validity period. [`check-cert-validity.sh`](check-cert-validity.sh) does this
for any host. It exits 1 above 825 days and prints a warning above 398 days:

```console
$ ./check-cert-validity.sh app.example.internal
app.example.internal:443
  not before : 2026-08-13
  not after  : 2036-08-10
  validity   : 3650 days
  FAIL, exceeds Apple's 825-day limit for TLS server certificates
```

If `openssl verify` succeeds against your CA while Apple clients still refuse the connection,
check the validity period first:

```console
$ openssl verify -CAfile ca.pem leaf.pem
leaf.pem: OK
```

## The fix

Shorten the leaf certificates and leave the root alone. The limits are about server
certificates, and a long-lived root is what you want: clients install it once.

With `cert-manager` that is two fields, see [`examples/certificate.yaml`](examples/certificate.yaml):

```yaml
spec:
  duration: 8760h    # 365 days
  renewBefore: 1440h # renew 60 days before expiry
```

`renewBefore` must be smaller than `duration`, or the resource is rejected. This is easy to
miss when shortening a certificate that was issued for years: its old `renewBefore` is often
larger than the new `duration`.

```console
$ kubectl -n <namespace> patch certificate <name> --type merge \
    -p '{"spec":{"duration":"8760h","renewBefore":"1440h"}}'
```

cert-manager reissues immediately and renews on its own from then on.

### Choosing a duration

cert-manager's default is 90 days, following Let's Encrypt, which is a good default when
renewal is monitored. For a small internal deployment 365 days can be the better trade: if
cert-manager stops working and nobody notices, 90-day certificates take the estate down within
a quarter, while 365-day certificates leave about a year to catch it. Use the shorter interval
when you alert on certificate expiry.

## Checklist

- [ ] Leaf certificate validity at most 398 days (365 is a round choice under both limits)
- [ ] `renewBefore` smaller than `duration`
- [ ] Root CA installed on every Apple client; for iOS it can ship in the same `.mobileconfig`
      as a VPN profile
- [ ] On macOS, trust the root with an explicit policy, or the trust settings come out empty:
      `sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain ca.pem`
- [ ] Check with `security dump-trust-settings -d` that the settings count is not 0
- [ ] Test with `nscurl`, not `curl`

## Verified

| Check | Result |
|---|---|
| `bash -n` and `shellcheck` on `check-cert-validity.sh` | clean (in CI) |
| Script against local TLS servers with 90, 500 and 900 day certificates | OK, WARN (exit 0), FAIL (exit 1) |
| GitHub Actions (see the badge) | repeats the three checks with generated certificates |

Not verified: the `Certificate` example against a live cert-manager in this repository (it is
used in [single-node-k8s-platform](https://github.com/Walaskien/single-node-k8s-platform)), and
Safari or iOS behaviour on a device, including which of the two Apple limits triggers for a
certificate from a user-added root.

## Limitations

- The script reads the server certificate only. It does not check chain trust or SANs.
- The limits are Apple's published figures at the time of writing; check the Apple pages
  before relying on them.

## References

- [Apple: Requirements for trusted certificates in iOS 13 and macOS 10.15](https://support.apple.com/en-us/103769)
- [Apple: About upcoming limits on trusted certificates](https://support.apple.com/en-us/102028)
- [cert-manager: Certificate resource](https://cert-manager.io/docs/usage/certificate/)

## Related

- [single-node-k8s-platform](https://github.com/Walaskien/single-node-k8s-platform): uses 365-day leaf certificates from cert-manager.
- [dual-homed-routing](https://github.com/Walaskien/dual-homed-routing): another short write-up of a failure that looks like one thing and is another.

## License

MIT, see [LICENSE](LICENSE).
